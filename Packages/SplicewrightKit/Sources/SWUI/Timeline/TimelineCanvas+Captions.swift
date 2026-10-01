import AppKit
import SwiftUI
import SWCore

/// Subtitle tracks on the timeline, as in Resolve: captions are blocks you can select, move,
/// trim, razor and delete; double-click edits the text in the Captions panel.
extension TimelineCanvas {
    // MARK: - Drawing

    func drawCaptionLanes(_ sequence: EditSequence) {
        let firstVisible = frame(at: TimelineLayout.headerWidth) - 1
        let lastVisible = frame(at: bounds.width) + 1
        for row in captionRows(for: sequence) {
            guard row.rect.maxY >= TimelineLayout.rulerHeight, row.rect.minY <= bounds.height,
                  let track = sequence.captionTrack(row.trackID) else { continue }
            NSColor(white: 0.135, alpha: 1).setFill()
            CGRect(x: TimelineLayout.headerWidth, y: row.rect.minY, width: laneWidth, height: row.rect.height).fill()
            for caption in track.captions where caption.end >= firstVisible && caption.start <= lastVisible {
                drawCaption(caption, in: row, dimmed: !track.isOutputEnabled)
            }
            if track.isLocked {
                NSColor(white: 0, alpha: 0.35).setFill()
                CGRect(x: TimelineLayout.headerWidth, y: row.rect.minY, width: laneWidth, height: row.rect.height)
                    .fill(using: .sourceOver)
            }
        }
    }

    private func drawCaption(_ caption: Caption, in row: TimelineLayout.CaptionRow, dimmed: Bool) {
        let rect = captionRect(caption, in: row)
        let selected = timeline.selection.contains(caption.id)
        var base = NSColor(Theme.captionClip)
        if dimmed { base = base.blended(withFraction: 0.6, of: .darkGray) ?? base }
        if selected { base = base.blended(withFraction: 0.35, of: .white) ?? base }
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        base.setFill()
        path.fill()
        if rect.width > 12 {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let text = caption.text.replacingOccurrences(of: "\n", with: " ")
            ((text.isEmpty ? "(empty)" : text) as NSString).draw(
                in: rect.insetBy(dx: 4, dy: 7),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                 .foregroundColor: NSColor.white.withAlphaComponent(text.isEmpty ? 0.5 : 0.92)])
            NSGraphicsContext.restoreGraphicsState()
        }
        if selected {
            NSColor.white.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    func drawCaptionHeaders(_ sequence: EditSequence) {
        for row in captionRows(for: sequence) {
            guard let track = sequence.captionTrack(row.trackID) else { continue }
            let rect = CGRect(x: 0, y: row.rect.minY, width: TimelineLayout.headerWidth, height: row.rect.height)
            NSColor(Theme.panelHeader).setFill()
            rect.fill()
            NSColor(Theme.divider).setFill()
            CGRect(x: TimelineLayout.headerWidth - 1, y: rect.minY, width: 1, height: rect.height).fill()
            let label = "\(row.name)  \(track.name)" as NSString
            label.draw(in: CGRect(x: 8, y: row.rect.midY - 7, width: 104, height: 14),
                       withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                        .foregroundColor: NSColor(Theme.textPrimary)])
            let lockRect = Self.captionControlRect(0, in: row.rect)
            let eyeRect = Self.captionControlRect(1, in: row.rect)
            drawCaptionSymbol(track.isLocked ? "lock.fill" : "lock.open", in: lockRect, active: track.isLocked)
            drawCaptionSymbol(track.isOutputEnabled ? "eye" : "eye.slash", in: eyeRect, active: track.isOutputEnabled)
        }
    }

    private func drawCaptionSymbol(_ name: String, in rect: CGRect, active: Bool) {
        let color = active ? NSColor(Theme.textPrimary) : NSColor(Theme.textSecondary).withAlphaComponent(0.6)
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        image.draw(in: CGRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                              width: image.size.width, height: image.size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Lock (0) and eye (1) at the right of a caption header.
    static func captionControlRect(_ index: Int, in row: CGRect) -> CGRect {
        CGRect(x: TimelineLayout.headerWidth - 52 + CGFloat(index) * 24, y: row.midY - 10, width: 20, height: 20)
    }

    func captionRect(_ caption: Caption, in row: TimelineLayout.CaptionRow) -> CGRect {
        CGRect(x: x(for: caption.start), y: row.rect.minY + 2,
               width: max(1, CGFloat(caption.duration) * pixelsPerFrame), height: row.rect.height - 4)
    }

    // MARK: - Hit testing

    struct CaptionHit {
        var caption: Caption
        var row: TimelineLayout.CaptionRow
        var edge: TrimEdge?
    }

    func captionHit(at point: CGPoint, in sequence: EditSequence) -> CaptionHit? {
        guard point.x >= TimelineLayout.headerWidth, let row = captionRow(at: point, in: sequence),
              let track = sequence.captionTrack(row.trackID) else { return nil }
        let grab = TimelineLayout.edgeGrabWidth
        for caption in track.captions {
            let rect = captionRect(caption, in: row)
            guard point.x >= rect.minX - grab, point.x <= rect.maxX + grab else { continue }
            let wideEnough = rect.width > grab * 3
            if wideEnough, abs(point.x - rect.minX) <= grab { return CaptionHit(caption: caption, row: row, edge: .start) }
            if wideEnough, abs(point.x - rect.maxX) <= grab { return CaptionHit(caption: caption, row: row, edge: .end) }
            if point.x >= rect.minX, point.x <= rect.maxX { return CaptionHit(caption: caption, row: row, edge: nil) }
        }
        return nil
    }

    // MARK: - Mouse

    /// Handles a click in a caption row. Returns false when the point isn't in one.
    func captionMouseDown(at point: CGPoint, event: NSEvent, in sequence: EditSequence) -> Bool {
        guard let row = captionRow(at: point, in: sequence), let track = sequence.captionTrack(row.trackID) else {
            return false
        }
        workspace.activeCaptionTrackID = track.id
        if point.x < TimelineLayout.headerWidth {
            if Self.captionControlRect(0, in: row.rect).insetBy(dx: -3, dy: -3).contains(point) {
                workspace.updateCaptionTrack(track.id, track.isLocked ? "Unlock Track" : "Lock Track") {
                    $0.isLocked.toggle()
                }
            } else if Self.captionControlRect(1, in: row.rect).insetBy(dx: -3, dy: -3).contains(point) {
                workspace.updateCaptionTrack(track.id, "Toggle Captions") { $0.isOutputEnabled.toggle() }
            }
            return true
        }
        timeline.selectedTransition = nil
        guard let hit = captionHit(at: point, in: sequence) else {
            timeline.selection = []
            return true
        }
        if event.clickCount == 2 {
            timeline.selection = [hit.caption.id]
            workspace.editCaption(hit.caption.id)
            return true
        }
        if workspace.activeTool == .razor {
            workspace.splitCaption(hit.caption.id, at: frame(at: point.x))
            return true
        }
        if event.modifierFlags.contains(.shift) {
            timeline.selection.formSymmetricDifference([hit.caption.id])
        } else {
            timeline.selection = [hit.caption.id]
        }
        workspace.focusedCaptionID = hit.caption.id
        guard !track.isLocked else { return true }
        drag = Drag(kind: .caption(id: hit.caption.id, edge: hit.edge), original: sequence,
                    actionName: hit.edge == nil ? "Move Caption" : "Trim Caption")
        return true
    }

    /// The sequence while a caption drag is in progress (snaps to the playhead and other captions).
    func captionPreview(_ id: UUID, edge: TrimEdge?, original: EditSequence, delta: Int64) -> EditSequence {
        var copy = original
        guard let caption = original.caption(id)?.caption else { return copy }
        var delta = delta
        if timeline.isSnapping {
            let targets = [workspace.program.currentFrame]
                + original.captionTracks.flatMap { $0.captions.filter { $0.id != id }.flatMap { [$0.start, $0.end] } }
                + original.editPoints
            let edges: [Int64] = edge == .start ? [caption.start] : edge == .end ? [caption.end] : [caption.start, caption.end]
            var best: (distance: Int64, delta: Int64, point: Int64)?
            for edgeFrame in edges {
                for target in targets {
                    let distance = abs(edgeFrame + delta - target)
                    if distance <= snapThreshold, distance < (best?.distance ?? .max) {
                        best = (distance, target - edgeFrame, target)
                    }
                }
            }
            if let best {
                delta = best.delta
                timeline.snapFrame = best.point
            }
        }
        switch edge {
        case nil: copy.moveCaption(id, to: caption.start + delta)
        case .start?: copy.trimCaption(id, edge: .start, to: caption.start + delta)
        case .end?: copy.trimCaption(id, edge: .end, to: caption.end + delta)
        }
        return copy
    }

    // MARK: - Context menu

    func captionMenu(at point: CGPoint, in sequence: EditSequence) -> NSMenu? {
        guard let row = captionRow(at: point, in: sequence), let track = sequence.captionTrack(row.trackID) else {
            return nil
        }
        workspace.activeCaptionTrackID = track.id
        let menu = NSMenu()
        if point.x >= TimelineLayout.headerWidth, let hit = captionHit(at: point, in: sequence) {
            if !timeline.selection.contains(hit.caption.id) { timeline.selection = [hit.caption.id] }
            let id = hit.caption.id
            let playhead = workspace.program.currentFrame
            menu.addItem(ActionMenuItem("Edit Text…") { [weak self] in self?.workspace.editCaption(id) })
            let split = ActionMenuItem("Split at Playhead") { [weak self] in self?.workspace.splitCaption(id, at: playhead) }
            split.isEnabled = hit.caption.range.contains(playhead) && playhead > hit.caption.start
            menu.addItem(split)
            menu.addItem(ActionMenuItem("Merge with Next") { [weak self] in self?.workspace.mergeCaptionWithNext(id) })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Delete") { [weak self] in self?.workspace.deleteSelectedClips(ripple: false) })
            return menu
        }
        let frame = point.x >= TimelineLayout.headerWidth ? self.frame(at: point.x) : workspace.program.currentFrame
        menu.addItem(ActionMenuItem("Add Caption Here") { [weak self] in
            self?.workspace.addCaption(on: track.id, at: frame)
        })
        menu.addItem(.separator())
        workspace.addCaptionTrackItems(to: menu, track: track)
        return menu
    }
}
