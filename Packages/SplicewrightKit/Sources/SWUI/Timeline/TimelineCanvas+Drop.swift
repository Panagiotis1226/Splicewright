import AppKit
import SWCore

/// Drops from the Project panel and the timeline's context menus.
extension TimelineCanvas {
    // MARK: - Drag and drop

    private func droppedMediaIDs(_ info: NSDraggingInfo) -> [UUID] {
        let items = info.draggingPasteboard.pasteboardItems ?? []
        let strings = items.compactMap { $0.string(forType: .string) }
        return strings.flatMap { $0.split(whereSeparator: \.isNewline) }
            .compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { workspace.project.item($0) != nil }
    }

    private func dropLocation(_ info: NSDraggingInfo) -> (frame: Int64, trackID: UUID?) {
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

    private func updateDropTarget(_ info: NSDraggingInfo) -> NSDragOperation {
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
            let range = item.marks.range(duration: item.info.duration, rate: item.info.displayFrameRate)
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
        if point.x < TimelineLayout.headerWidth, let row = row(at: point, in: sequence) {
            return trackMenu(for: row, in: sequence)
        }
        guard let hit = clipHit(at: point, in: sequence) else { return nil }
        if !timeline.selection.contains(hit.clip.id) { timeline.selection = sequence.expandingLinks([hit.clip.id]) }
        return clipMenu(for: hit, in: sequence)
    }

    private func trackMenu(for row: TimelineLayout.Row, in sequence: EditSequence) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Add Video Track") { [weak self] in self?.workspace.addTrack(.video) })
        menu.addItem(ActionMenuItem("Add Audio Track") { [weak self] in self?.workspace.addTrack(.audio) })
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
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Reveal in Project") { [weak self] in
            guard let self else { return }
            self.workspace.selectAllMedia()
            self.workspace.selectedMediaIDs = [hit.clip.mediaID]
            self.workspace.activePanel = .project
        })
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
