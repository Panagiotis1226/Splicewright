import AppKit
import SWCore
import SWPlayback

/// Mouse handling. Drags edit a copy of the sequence (`timeline.preview`) and commit it as
/// one undoable edit on mouse-up.
extension TimelineCanvas {
    struct ClipHit {
        var clip: Clip
        var row: TimelineLayout.Row
        var edge: TrimEdge?
    }

    func clipHit(at point: CGPoint, in sequence: EditSequence) -> ClipHit? {
        guard point.x >= TimelineLayout.headerWidth, let row = row(at: point, in: sequence),
              let track = sequence.track(row.trackID) else { return nil }
        let grab = TimelineLayout.edgeGrabWidth
        for clip in track.clips {
            let rect = clipRect(clip, in: row)
            guard point.x >= rect.minX - grab, point.x <= rect.maxX + grab else { continue }
            let wideEnough = rect.width > grab * 3
            if wideEnough, abs(point.x - rect.minX) <= grab { return ClipHit(clip: clip, row: row, edge: .start) }
            if wideEnough, abs(point.x - rect.maxX) <= grab { return ClipHit(clip: clip, row: row, edge: .end) }
            if rect.contains(CGPoint(x: point.x, y: rect.midY)) { return ClipHit(clip: clip, row: row, edge: nil) }
        }
        return nil
    }

    struct TransitionHit {
        var transition: ResolvedTransition
        var row: TimelineLayout.Row
        var edge: TrimEdge?
    }

    func transitionRect(_ transition: ResolvedTransition, in row: TimelineLayout.Row) -> CGRect {
        CGRect(x: x(for: transition.range.start), y: row.rect.minY + 2,
               width: max(4, CGFloat(transition.range.length) * pixelsPerFrame), height: (row.rect.height - 4) * 0.42)
    }

    func transitionHit(at point: CGPoint, in sequence: EditSequence) -> TransitionHit? {
        guard point.x >= TimelineLayout.headerWidth, let row = row(at: point, in: sequence),
              let track = sequence.track(row.trackID) else { return nil }
        for transition in track.resolvedTransitions {
            let rect = transitionRect(transition, in: row)
            guard rect.insetBy(dx: -3, dy: 0).contains(point) else { continue }
            let grab: CGFloat = 4
            var edge: TrimEdge?
            if rect.width > grab * 4, abs(point.x - rect.minX) <= grab { edge = .start }
            if rect.width > grab * 4, abs(point.x - rect.maxX) <= grab { edge = .end }
            return TransitionHit(transition: transition, row: row, edge: edge)
        }
        return nil
    }

    // MARK: - Mouse down

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        workspace.activePanel = .timeline
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        drag = nil
        guard let sequence = workspace.activeSequence else { return }

        if point.y < TimelineLayout.rulerHeight {
            if markerMouseDown(at: point, event: event, in: sequence) { return }
            if point.x >= TimelineLayout.headerWidth {
                workspace.program.pause()
                drag = Drag(kind: .scrub, original: nil, actionName: "")
                workspace.program.scrub(toFrame: frame(at: point.x))
            }
            return
        }
        if captionMouseDown(at: point, event: event, in: sequence) { return }
        if point.x < TimelineLayout.headerWidth {
            headerClicked(at: point, in: sequence)
            return
        }
        if event.clickCount == 2, transitionHit(at: point, in: sequence) != nil {
            workspace.activePanel = .effectControls
            return
        }
        if event.clickCount == 2, let hit = clipHit(at: point, in: sequence), hit.edge == nil {
            if hit.clip.isTitle {
                // Titles are edited in Effect Controls.
                timeline.selection = [hit.clip.id]
                workspace.activePanel = .effectControls
                return
            }
            // Double-click opens the clip's source in the Source monitor, like Premiere.
            workspace.openInSource(hit.clip.mediaID)
            return
        }
        toolDown(workspace.activeTool, at: point, event: event, sequence: sequence)
    }

    private func toolDown(_ tool: EditTool, at point: CGPoint, event: NSEvent, sequence: EditSequence) {
        let hit = clipHit(at: point, in: sequence)
        switch tool {
        case .hand:
            drag = Drag(kind: .hand(startScroll: CGPoint(x: timeline.scrollX, y: timeline.scrollY)), original: nil,
                        actionName: "")
        case .zoom:
            timeline.zoom(by: event.modifierFlags.contains(.option) ? 0.5 : 2, anchorX: point.x,
                          headerWidth: TimelineLayout.headerWidth)
        case .razor:
            if let hit { razor(hit, at: point, in: sequence, onlyThisTrack: event.modifierFlags.contains(.option)) }
        case .trackSelectForward:
            let onlyRow = event.modifierFlags.contains(.shift) ? row(at: point, in: sequence) : nil
            selectForward(from: frame(at: point.x), row: onlyRow, in: sequence)
        case .slip, .slide:
            guard let hit else { return }
            select(hit.clip, in: sequence, event: event)
            drag = Drag(kind: tool == .slip ? .slip(hit.clip.id) : .slide(hit.clip.id), original: sequence,
                        actionName: tool == .slip ? "Slip" : "Slide")
        case .rippleEdit, .rollingEdit:
            guard let hit, let edge = hit.edge else { return }
            drag = Drag(kind: .trim(clipID: hit.clip.id, edge: edge, mode: tool == .rippleEdit ? .ripple : .roll),
                        original: sequence, actionName: tool == .rippleEdit ? "Ripple Trim" : "Rolling Edit")
        case .rateStretch where hit?.edge != nil:
            guard let hit, let edge = hit.edge else { return }
            select(hit.clip, in: sequence, event: event)
            drag = Drag(kind: .rateStretch(clipID: hit.clip.id, edge: edge), original: sequence, actionName: "Rate Stretch")
        case .selection, .rateStretch, .pen, .type:
            selectionDown(at: point, hit: hit, event: event, sequence: sequence)
        }
    }

    /// Selection tool: transitions (edges change their length), clip edges trim, clips move.
    private func selectionDown(at point: CGPoint, hit: ClipHit?, event: NSEvent, sequence: EditSequence) {
        if let transition = transitionHit(at: point, in: sequence) {
            timeline.selection = []
            timeline.selectedTransition = transition.transition.id
            if let edge = transition.edge {
                let resolved = transition.transition
                drag = Drag(kind: .transitionDuration(id: resolved.id, edge: edge, original: resolved.duration,
                                                      symmetric: resolved.before > 0 && resolved.after > 0),
                            original: sequence, actionName: "Transition Duration")
            }
            return
        }
        timeline.selectedTransition = nil
        guard let hit else {
            timeline.selection = []
            return
        }
        if let edge = hit.edge {
            drag = Drag(kind: .trim(clipID: hit.clip.id, edge: edge, mode: .normal), original: sequence,
                        actionName: "Trim")
            return
        }
        select(hit.clip, in: sequence, event: event)
        drag = Drag(kind: .move(ids: timeline.selection, startRow: hit.row), original: sequence, actionName: "Move")
    }

    /// Premiere selection: click selects the clip and its linked partners; ⇧ toggles;
    /// ⌥ ignores links.
    private func select(_ clip: Clip, in sequence: EditSequence, event: NSEvent) {
        let group = event.modifierFlags.contains(.option) ? [clip.id] : sequence.expandingLinks([clip.id])
        if event.modifierFlags.contains(.shift) {
            if timeline.selection.contains(clip.id) {
                timeline.selection.subtract(group)
            } else {
                timeline.selection.formUnion(group)
            }
        } else if !timeline.selection.contains(clip.id) {
            timeline.selection = group
        }
    }

    private func razor(_ hit: ClipHit, at point: CGPoint, in sequence: EditSequence, onlyThisTrack: Bool) {
        var cut = frame(at: point.x)
        if timeline.isSnapping, abs(cut - workspace.program.currentFrame) <= snapThreshold {
            cut = workspace.program.currentFrame
        }
        var tracks: Set<UUID> = [hit.row.trackID]
        if !onlyThisTrack {
            for id in sequence.expandingLinks([hit.clip.id]) {
                if let track = sequence.trackID(containing: id) { tracks.insert(track) }
            }
        }
        workspace.editSequence("Razor") { sequence, _ in sequence.razor(at: cut, trackIDs: tracks) }
    }

    private func selectForward(from frame: Int64, row: TimelineLayout.Row?, in sequence: EditSequence) {
        var ids: Set<UUID> = []
        for track in sequence.allTracks where row == nil || row?.trackID == track.id {
            for clip in track.clips where clip.end > frame { ids.insert(clip.id) }
        }
        timeline.selection = ids
        if !ids.isEmpty {
            drag = Drag(kind: .move(ids: ids, startRow: row ?? rows(for: sequence)[0]), original: sequence,
                        actionName: "Move")
        }
    }

    private func headerClicked(at point: CGPoint, in sequence: EditSequence) {
        guard let row = row(at: point, in: sequence), let track = sequence.track(row.trackID) else { return }
        for control in TimelineLayout.HeaderControl.controls(for: row.kind)
        where control.rect(in: row.rect, kind: row.kind).insetBy(dx: -3, dy: -3).contains(point) {
            toggle(control, track: track)
            return
        }
    }

    private func toggle(_ control: TimelineLayout.HeaderControl, track: Track) {
        switch control {
        case .target:
            workspace.setTrackFlags(track.id, "Target Track") { $0.isTargeted.toggle() }
        case .lock:
            workspace.setTrackFlags(track.id, track.isLocked ? "Unlock Track" : "Lock Track") { $0.isLocked.toggle() }
        case .syncLock:
            workspace.setTrackFlags(track.id, "Sync Lock") { $0.isSyncLocked.toggle() }
        case .output:
            workspace.setTrackFlags(track.id, track.kind == .video ? "Toggle Track Output" : "Mute Track") {
                $0.isOutputEnabled.toggle()
            }
        case .solo:
            workspace.setTrackFlags(track.id, "Solo Track") { $0.isSolo.toggle() }
        }
    }

    // MARK: - Dragging

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch drag.kind {
        case .scrub:
            workspace.program.scrub(toFrame: frame(at: point.x))
        case .hand(let start):
            timeline.scrollX = max(0, start.x - (point.x - dragOrigin.x))
            timeline.scrollY = clampedScrollY(start.y - (point.y - dragOrigin.y))
        default:
            guard let original = drag.original else { return }
            timeline.preview = previewSequence(for: drag.kind, original: original, point: point)
        }
    }

    private func previewSequence(for kind: DragKind, original: EditSequence, point: CGPoint) -> EditSequence {
        var copy = original
        var delta = frameDelta(from: dragOrigin, to: point)
        let media = workspace.project.mediaDurations
        let playhead = workspace.program.currentFrame
        timeline.snapFrame = nil
        switch kind {
        case .move(let ids, let startRow):
            if timeline.isSnapping {
                let snapper = Snapper(sequence: original, excluding: ids, playhead: playhead, threshold: snapThreshold)
                let edges = ids.compactMap { original.clip($0) }.flatMap { [$0.start, $0.end] }
                let snapped = snapper.snapDelta(delta, edges: edges)
                delta = snapped.delta
                timeline.snapFrame = snapped.point
            }
            var offset = 0
            if let current = row(at: point, in: original), current.kind == startRow.kind {
                offset = current.index - startRow.index
            }
            copy.move(ids, by: delta, trackOffset: offset)
        case .trim(let clipID, let edge, let mode):
            delta = snappedEdgeDelta(clipID, edge: edge, delta: delta, in: original, playhead: playhead)
            switch mode {
            case .normal: copy.trim(clipID, edge: edge, by: delta, media: media)
            case .ripple: copy.rippleTrim(clipID, edge: edge, by: delta, media: media)
            case .roll: copy.roll(clipID: clipID, edge: edge, by: delta, media: media)
            }
        case .slip(let clipID):
            // Dragging right reveals earlier source frames, as in Premiere.
            copy.slip(clipID, by: -delta, media: media)
        case .slide(let clipID):
            copy.slide(clipID, by: delta, media: media)
        case .caption(let id, let edge):
            return captionPreview(id, edge: edge, original: original, delta: delta)
        case .marker(let id, let startFrame):
            return markerPreview(id, startFrame: startFrame, original: original, delta: delta)
        case .rateStretch(let clipID, let edge):
            delta = snappedEdgeDelta(clipID, edge: edge, delta: delta, in: original, playhead: playhead)
            copy.rateStretch(clipID, edge: edge, by: delta)
        case .transitionDuration(let id, let edge, let original, let symmetric):
            // Centered transitions grow on both sides, so an edge moves half as far as the duration.
            let change = (symmetric ? 2 : 1) * (edge == .end ? delta : -delta)
            copy.updateTransition(id) { $0.duration = max(1, original + change) }
        case .scrub, .hand:
            break
        }
        return copy
    }

    /// Snaps a dragged clip edge to nearby edit points and the playhead.
    private func snappedEdgeDelta(_ clipID: UUID, edge: TrimEdge, delta: Int64, in original: EditSequence,
                                  playhead: Int64) -> Int64 {
        guard timeline.isSnapping, let clip = original.clip(clipID) else { return delta }
        let excluded = original.expandingLinks([clipID])
        let snapper = Snapper(sequence: original, excluding: excluded, playhead: playhead, threshold: snapThreshold)
        let edgeFrame = edge == .start ? clip.start : clip.end
        guard let point = snapper.snap(edgeFrame + delta) else { return delta }
        timeline.snapFrame = point
        return point - edgeFrame
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            timeline.preview = nil
            timeline.snapFrame = nil
        }
        guard let drag, let original = drag.original, let preview = timeline.preview, preview != original else {
            if case .scrub? = self.drag?.kind {
                workspace.program.seek(toFrame: frame(at: convert(event.locationInWindow, from: nil).x))
            }
            return
        }
        workspace.commitTimelineEdit(drag.actionName, preview)
    }

    // MARK: - Scrolling and zoom

    func clampedScrollY(_ value: CGFloat) -> CGFloat {
        guard let sequence = workspace.activeSequence else { return 0 }
        let overflow = TimelineLayout.contentHeight(for: sequence) - bounds.height
        return min(max(0, value), max(0, overflow))
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            timeline.zoom(by: exp(event.scrollingDeltaY * 0.01), anchorX: point.x, headerWidth: TimelineLayout.headerWidth)
            return
        }
        let fitsVertically = clampedScrollY(.greatestFiniteMagnitude) == 0
        var horizontal = event.scrollingDeltaX
        var vertical = event.scrollingDeltaY
        if event.modifierFlags.contains(.shift) || (fitsVertically && horizontal == 0) {
            horizontal = vertical
            vertical = 0
        }
        timeline.scrollX = max(0, timeline.scrollX - horizontal)
        timeline.scrollY = clampedScrollY(timeline.scrollY - vertical)
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        timeline.zoom(by: 1 + event.magnification, anchorX: point.x, headerWidth: TimelineLayout.headerWidth)
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursor(at: point).set()
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        guard let sequence = workspace.activeSequence, point.x >= TimelineLayout.headerWidth,
              point.y >= TimelineLayout.rulerHeight else { return .arrow }
        switch workspace.activeTool {
        case .hand: return .openHand
        case .razor, .zoom: return .crosshair
        case .selection, .rippleEdit, .rollingEdit, .rateStretch:
            if captionRow(at: point, in: sequence) != nil {
                return captionHit(at: point, in: sequence)?.edge != nil ? .resizeLeftRight : .arrow
            }
            return clipHit(at: point, in: sequence)?.edge != nil ? .resizeLeftRight : .arrow
        case .slip, .slide: return clipHit(at: point, in: sequence) != nil ? .resizeLeftRight : .arrow
        default: return .arrow
        }
    }
}
