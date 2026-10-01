import AppKit
import SWCore

/// Title clips: creating and editing them.
extension WorkspaceController {
    /// Graphics ▸ New Title (⇧⌘T): a five-second title at the playhead, above the video.
    /// Creates a sequence first if none is open.
    public func newTitle(at position: CGPoint? = nil, trackID: UUID? = nil, frame: Int64? = nil) {
        if activeSequence == nil {
            createSequence(named: "Sequence", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps29_97,
                                                                      colorSpace: .rec709))
        }
        guard activeSequence != nil else { return }
        var spec = TitleSpec()
        if let position {
            spec.positionX = Double(position.x)
            spec.positionY = Double(position.y)
        }
        let at = frame ?? playheadFrame
        var added: UUID?
        editSequence("New Title") { sequence, _ in added = sequence.addTitle(spec, at: at, trackID: trackID) }
        guard let added else {
            NSSound.beep()
            return
        }
        timeline.selection = [added]
        activePanel = .effectControls
        program.update(sequence: activeSequence, project: project)
    }

    func updateTitle(_ clipID: UUID, _ actionName: String = "Edit Title", _ change: @escaping (inout TitleSpec) -> Void) {
        editSequence(actionName) { sequence, _ in sequence.updateTitle(clipID, change) }
    }

    /// The selected title clip, if exactly one title is selected.
    var selectedTitleClip: Clip? {
        guard let sequence = activeSequence else { return nil }
        let titles = timeline.selection.compactMap { sequence.clip($0) }.filter(\.isTitle)
        return titles.count == 1 ? titles[0] : nil
    }

    /// The topmost title visible at the playhead, for clicks in the Program monitor.
    var titleAtPlayhead: Clip? {
        guard let sequence = activeSequence else { return nil }
        let frame = playheadFrame
        return sequence.videoTracks.reversed().compactMap { $0.clip(at: frame) }.first { $0.isTitle && $0.isEnabled }
    }
}
