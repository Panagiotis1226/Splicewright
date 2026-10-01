import AppKit
import SWCore

/// Video effects and adjustment layers.
extension WorkspaceController {
    /// Applies `kind` to the selected video clips (a double-click in the Effects panel), or to
    /// `clipIDs` (a drop on a clip).
    func addEffect(_ kind: VideoEffectKind, to clipIDs: Set<UUID>? = nil) {
        let ids = clipIDs ?? timeline.selection
        var added: [UUID: UUID] = [:]
        editSequence("Add \(kind.displayName)") { sequence, _ in added = sequence.addEffect(kind, to: ids) }
        guard !added.isEmpty else {
            NSSound.beep()
            return
        }
        timeline.selection = Set(added.keys)
        activePanel = .effectControls
    }

    func updateEffect(_ effectID: UUID, of clipID: UUID, _ actionName: String,
                      _ change: @escaping (inout VideoEffect) -> Void) {
        editSequence(actionName) { sequence, _ in sequence.updateEffect(effectID, of: clipID, change) }
    }

    func moveEffect(_ effectID: UUID, of clipID: UUID, by offset: Int) {
        editSequence(offset < 0 ? "Move Effect Up" : "Move Effect Down") { sequence, _ in
            sequence.moveEffect(effectID, of: clipID, by: offset)
        }
    }

    /// Every parameter back to its default, without keyframes.
    func resetEffect(_ effectID: UUID, of clipID: UUID) {
        updateEffect(effectID, of: clipID, "Reset Effect") { effect in
            effect.parameters = VideoEffect(kind: effect.kind).parameters
        }
    }

    func removeEffect(_ effectID: UUID, from clipID: UUID) {
        editSequence("Remove Effect") { sequence, _ in sequence.removeEffect(effectID, from: clipID) }
    }

    /// Graphics ▸ New Adjustment Layer: five seconds at the playhead, above the clips there
    /// (or on `trackID` at `frame`, for a drop from the Effects panel).
    public func newAdjustmentLayer(trackID: UUID? = nil, frame: Int64? = nil) {
        if activeSequence == nil {
            createSequence(named: "Sequence", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps29_97,
                                                                      colorSpace: .rec709))
        }
        guard activeSequence != nil else { return }
        let at = frame ?? playheadFrame
        var added: UUID?
        editSequence("New Adjustment Layer") { sequence, _ in
            added = sequence.addAdjustmentLayer(at: at, trackID: trackID)
        }
        guard let added else {
            NSSound.beep()
            return
        }
        timeline.selection = [added]
        activePanel = .effectControls
    }
}
