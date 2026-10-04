import AppKit
import SWCore
import SWPlayback

/// Drops from the Project and Effects panels, and the timeline's context menus.
extension TimelineCanvas {
    // MARK: - Drag and drop

    private func droppedMediaIDs(_ info: NSDraggingInfo) -> [UUID] {
        let items = info.draggingPasteboard.pasteboardItems ?? []
        let strings = items.compactMap { $0.string(forType: .string) }
        return strings.flatMap { $0.split(whereSeparator: \.isNewline) }
            .compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { workspace.project.item($0) != nil }
    }

    private func droppedTransition(_ info: NSDraggingInfo) -> TransitionKind? {
        let strings = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .string) }
        guard let payload = strings.first(where: { $0.hasPrefix(EffectsPanel.transitionPrefix) }) else { return nil }
        return TransitionKind(rawValue: String(payload.dropFirst(EffectsPanel.transitionPrefix.count)))
    }

    /// The clip edge a transition dropped at `info` would attach to, and its would-be range.
    private func transitionDrop(_ kind: TransitionKind, _ info: NSDraggingInfo)
        -> (trackID: UUID, edge: Int64, range: FrameRange)? {
        guard let sequence = workspace.activeSequence else { return nil }
        let point = convert(info.draggingLocation, from: nil)
        guard let row = row(at: point, in: sequence), row.kind == kind.trackKind else { return nil }
        let tolerance = Int64(max(2, (16 / pixelsPerFrame).rounded()))
        guard let edge = sequence.transitionEdge(near: frame(at: point.x), trackID: row.trackID, tolerance: tolerance)
        else { return nil }
        var trial = sequence
        guard let id = trial.addTransition(kind, trackID: row.trackID, at: edge),
              let range = trial.transition(id)?.transition.range else { return nil }
        return (row.trackID, edge, range)
    }

    func dropLocation(_ info: NSDraggingInfo) -> (frame: Int64, trackID: UUID?) {
        let point = convert(info.draggingLocation, from: nil)
        guard let sequence = workspace.activeSequence else { return (0, nil) }
        var frame = frame(at: max(point.x, TimelineLayout.headerWidth))
        if timeline.isSnapping {
            let snapper = Snapper(sequence: sequence, excluding: [], playhead: workspace.program.currentFrame,
                                  threshold: snapThreshold)
            frame = snapper.snap(frame) ?? frame
        }
        let row = row(at: point, in: sequence) ?? rows(for: sequence).first { $0.kind == .video && $0.index == 0 }
        return (frame, row?.trackID)
    }

    private func isTitleDrop(_ info: NSDraggingInfo) -> Bool {
        (info.draggingPasteboard.pasteboardItems ?? []).contains { $0.string(forType: .string) == EffectsPanel.titlePayload }
    }

    private func updateDropTarget(_ info: NSDraggingInfo) -> NSDragOperation {
        if let operation = updateEffectDropTarget(info) { return operation }
        if isTitleDrop(info) {
            let location = dropLocation(info)
            guard let sequence = workspace.activeSequence, let trackID = location.trackID,
                  sequence.videoTracks.contains(where: { $0.id == trackID }) else {
                timeline.dropTarget = nil
                return workspace.activeSequence == nil ? .copy : []
            }
            timeline.dropTarget = TimelineState.DropTarget(frame: location.frame, trackID: trackID,
                                                           length: sequence.defaultTitleDuration)
            return .copy
        }
        if let kind = droppedTransition(info) {
            guard let drop = transitionDrop(kind, info) else {
                timeline.dropTarget = nil
                return []
            }
            timeline.dropTarget = TimelineState.DropTarget(frame: drop.range.start, trackID: drop.trackID,
                                                           length: drop.range.length, transition: kind)
            return .copy
        }
        let ids = droppedMediaIDs(info)
        guard !ids.isEmpty else {
            timeline.dropTarget = nil
            return []
        }
        guard let sequence = workspace.activeSequence else {
            // Any placeholder track ID lights up the empty-state outline.
            timeline.dropTarget = TimelineState.DropTarget(frame: 0, trackID: UUID(), length: 0)
            return .copy
        }
        let location = dropLocation(info)
        let length = ids.compactMap { workspace.project.item($0) }.reduce(Int64(0)) { total, item in
            let range = item.marks.range(duration: item.info.placementDuration, rate: item.info.displayFrameRate)
            return total + max(1, range.duration.frameIndex(at: sequence.rate))
        }
        if let trackID = location.trackID {
            timeline.dropTarget = TimelineState.DropTarget(frame: location.frame, trackID: trackID, length: length)
        }
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropTarget(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropTarget(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        timeline.dropTarget = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { timeline.dropTarget = nil }
        if let handled = performEffectDrop(sender) {
            if handled { window?.makeFirstResponder(self) }
            return handled
        }
        if isTitleDrop(sender) {
            let location = dropLocation(sender)
            let isVideo = workspace.activeSequence?.videoTracks.contains { $0.id == location.trackID } ?? true
            guard isVideo else { return false }
            workspace.newTitle(trackID: location.trackID, frame: location.frame)
            window?.makeFirstResponder(self)
            return true
        }
        if let kind = droppedTransition(sender) {
            guard let drop = transitionDrop(kind, sender) else { return false }
            workspace.addTransition(kind, trackID: drop.trackID, at: drop.edge)
            window?.makeFirstResponder(self)
            return true
        }
        let ids = droppedMediaIDs(sender)
        guard !ids.isEmpty else { return false }
        let location = dropLocation(sender)
        // ⌘-drop inserts (rippling later clips); a plain drop overwrites, as in Premiere.
        let insert = NSEvent.modifierFlags.contains(.command)
        workspace.dropMedia(ids, atFrame: location.frame, trackID: location.trackID, insert: insert)
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: - Context menus

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let sequence = workspace.activeSequence else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        if let menu = rulerMenu(at: point, in: sequence) { return menu }
        if let menu = captionMenu(at: point, in: sequence) { return menu }
        if let menu = keyframeMenu(at: point, in: sequence) { return menu }
        if point.x < TimelineLayout.headerWidth, let row = row(at: point, in: sequence) {
            return trackMenu(for: row, in: sequence)
        }
        if let hit = transitionHit(at: point, in: sequence) {
            timeline.selection = []
            timeline.selectedTransition = hit.transition.id
            return transitionMenu(for: hit.transition)
        }
        guard let hit = clipHit(at: point, in: sequence) else {
            // An empty part of a track: the keyframe display options.
            guard row(at: point, in: sequence) != nil else { return nil }
            let menu = NSMenu()
            keyframeVisibilityItems().forEach(menu.addItem)
            return menu
        }
        if !timeline.selection.contains(hit.clip.id) { timeline.selection = sequence.expandingLinks([hit.clip.id]) }
        return clipMenu(for: hit, in: sequence)
    }

    private func transitionMenu(for transition: ResolvedTransition) -> NSMenu {
        let menu = NSMenu()
        let kinds = NSMenu()
        for kind in transition.kind.isAudio ? TransitionKind.audio : TransitionKind.video {
            let item = ActionMenuItem(kind.displayName) { [weak self] in
                self?.workspace.updateTransition(transition.id, "Change Transition") { $0.kind = kind }
            }
            item.state = kind == transition.kind ? .on : .off
            kinds.addItem(item)
        }
        let kindItem = NSMenuItem(title: "Transition", action: nil, keyEquivalent: "")
        kindItem.submenu = kinds
        menu.addItem(kindItem)
        if transition.left != nil && transition.right != nil {
            let alignments = NSMenu()
            for alignment in TransitionAlignment.allCases {
                let item = ActionMenuItem(alignment.displayName) { [weak self] in
                    self?.workspace.updateTransition(transition.id, "Transition Alignment") { $0.alignment = alignment }
                }
                item.state = alignment == transition.transition.alignment ? .on : .off
                alignments.addItem(item)
            }
            let alignmentItem = NSMenuItem(title: "Alignment", action: nil, keyEquivalent: "")
            alignmentItem.submenu = alignments
            menu.addItem(alignmentItem)
        }
        menu.addItem(ActionMenuItem("Set Duration…") { [weak self] in self?.workspace.activePanel = .effectControls })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Delete") { [weak self] in self?.workspace.deleteTransition(transition.id) })
        return menu
    }

    private func trackMenu(for row: TimelineLayout.Row, in sequence: EditSequence) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Add Video Track") { [weak self] in self?.workspace.addTrack(.video) })
        menu.addItem(ActionMenuItem("Add Audio Track") { [weak self] in self?.workspace.addTrack(.audio) })
        menu.addItem(ActionMenuItem("Add Subtitle Track") { [weak self] in self?.workspace.addCaptionTrack() })
        menu.addItem(ActionMenuItem("Transcribe & Create Captions…") { [weak self] in
            self?.workspace.isTranscribeSheetPresented = true
        })
        let delete = ActionMenuItem("Delete Track") { [weak self] in self?.workspace.removeTrack(row.trackID) }
        let track = sequence.track(row.trackID)
        let kindCount = row.kind == .video ? sequence.videoTracks.count : sequence.audioTracks.count
        delete.isEnabled = track?.clips.isEmpty == true && kindCount > 1
        menu.addItem(delete)
        return menu
    }

    private func clipMenu(for hit: ClipHit, in sequence: EditSequence) -> NSMenu {
        let ids = timeline.selection
        let clips = ids.compactMap { sequence.clip($0) }
        let videoIDs = ids.intersection(sequence.videoTracks.flatMap { $0.clips.map(\.id) })
        let audioIDs = ids.intersection(sequence.audioTracks.flatMap { $0.clips.map(\.id) })
        let menu = NSMenu()
        let allEnabled = clips.allSatisfy(\.isEnabled)
        menu.addItem(ActionMenuItem(allEnabled ? "Disable" : "Enable") { [weak self] in
            self?.workspace.setClipsEnabled(ids, !allEnabled)
        })
        let linked = clips.contains { $0.linkID != nil }
        menu.addItem(ActionMenuItem(linked ? "Unlink" : "Link") { [weak self] in
            self?.workspace.setClipsLinked(ids, !linked)
        })
        menu.addItem(.separator())
        if hit.row.kind == .video {
            let opacity = NSMenu()
            for percent in [100, 75, 50, 25] {
                opacity.addItem(ActionMenuItem("\(percent)%") { [weak self] in
                    self?.workspace.setClipOpacity(videoIDs, Double(percent) / 100)
                })
            }
            let item = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
            item.submenu = opacity
            menu.addItem(item)
        } else {
            let gain = NSMenu()
            for value in [6.0, 3.0, 0.0, -3.0, -6.0, -12.0] {
                gain.addItem(ActionMenuItem(String(format: "%+.0f dB", value)) { [weak self] in
                    self?.workspace.setClipGain(audioIDs, value)
                })
            }
            let item = NSMenuItem(title: "Audio Gain", action: nil, keyEquivalent: "")
            item.submenu = gain
            menu.addItem(item)
        }
        menu.addItem(ActionMenuItem("Speed/Duration…") { [weak self] in self?.workspace.requestSpeedDuration() })
        menu.addItem(.separator())
        let audio = hit.row.kind == .audio
        menu.addItem(ActionMenuItem("Apply Default Transitions") { [weak self] in
            self?.workspace.applyDefaultTransition(audio: audio)
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Reveal in Project") { [weak self] in
            guard let self else { return }
            self.workspace.selectAllMedia()
            self.workspace.selectedMediaIDs = [hit.clip.mediaID]
            self.workspace.activePanel = .project
        })
        menu.addItem(.separator())
        keyframeVisibilityItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Ripple Delete") { [weak self] in self?.workspace.deleteSelectedClips(ripple: true) })
        menu.addItem(ActionMenuItem("Delete") { [weak self] in self?.workspace.deleteSelectedClips(ripple: false) })
        return menu
    }
}

/// An `NSMenuItem` that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
