import AppKit
import SWCore

/// Transitions: applying, editing and deleting them.
extension WorkspaceController {
    /// Apply Video/Audio Transition (⌘D / ⇧⌘D): the default transition at both edges of the
    /// selected clips, or else at the edit point nearest the playhead on the targeted tracks.
    public func applyDefaultTransition(audio: Bool) {
        guard let sequence = activeSequence else { return }
        let kind = audio ? EffectDefaults.shared.audioTransition : EffectDefaults.shared.videoTransition
        let tracks = audio ? sequence.audioTracks : sequence.videoTracks
        let selected = tracks.flatMap { track in
            track.clips.filter { timeline.selection.contains($0.id) }.map { (track.id, $0) }
        }
        let frame = playheadFrame
        var added: [UUID] = []
        editSequence("Apply \(kind.displayName)") { sequence, _ in
            if selected.isEmpty {
                let targeted = tracks.filter { $0.isTargeted && !$0.isLocked }.map(\.id)
                // Within two seconds of the playhead, like Premiere's nearest edit point.
                added = sequence.applyTransition(kind, near: frame, trackIDs: targeted.isEmpty ? [tracks[0].id] : targeted,
                                                 tolerance: Int64(sequence.rate.timecodeBase * 2))
            } else {
                for (trackID, clip) in selected {
                    for edge in [clip.start, clip.end] {
                        if let id = sequence.addTransition(kind, trackID: trackID, at: edge) { added.append(id) }
                    }
                }
            }
        }
        if added.isEmpty { NSSound.beep() }
        timeline.selectedTransition = added.last
    }

    /// Adds `kind` at the clip edge at `frame` on `trackID` (a drop from the Effects panel).
    func addTransition(_ kind: TransitionKind, trackID: UUID, at frame: Int64) {
        var added: UUID?
        editSequence("Add \(kind.displayName)") { sequence, _ in
            added = sequence.addTransition(kind, trackID: trackID, at: frame)
        }
        if added == nil { NSSound.beep() }
        timeline.selection = []
        timeline.selectedTransition = added
    }

    public var selectedTransition: (trackID: UUID, transition: ResolvedTransition)? {
        guard let id = timeline.selectedTransition else { return nil }
        return activeSequence?.transition(id)
    }

    func updateTransition(_ id: UUID, _ actionName: String, _ change: @escaping (inout Transition) -> Void) {
        editSequence(actionName) { sequence, _ in sequence.updateTransition(id, change) }
    }

    func deleteTransition(_ id: UUID) {
        editSequence("Delete Transition") { sequence, _ in sequence.removeTransitions([id]) }
        if timeline.selectedTransition == id { timeline.selectedTransition = nil }
    }
}
