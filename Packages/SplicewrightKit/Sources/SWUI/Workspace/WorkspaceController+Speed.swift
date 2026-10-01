import AppKit
import SWCore

/// Speed/Duration (⌘R), Rate Stretch and the Speed row of Effect Controls.
extension WorkspaceController {
    /// Opens Speed/Duration for the selected clips (and their linked partners).
    public func requestSpeedDuration() {
        guard let sequence = activeSequence else { return }
        let ids = sequence.expandingLinks(timeline.selection).filter { id in
            sequence.clip(id).map { !$0.isTitle } ?? false
        }
        guard !ids.isEmpty else {
            NSSound.beep()
            return
        }
        speedSheetClipIDs = ids
    }

    func changeSpeed(_ ids: Set<UUID>, _ change: SpeedChange, live: Bool = false) {
        let edit: (inout EditSequence) -> Void = { $0.changeSpeed(ids, change) }
        if live {
            // Each step of a drag starts again from before the drag, so clamping doesn't compound.
            guard let id = activeSequenceID, let document else { return }
            if liveEditOriginal == nil { liveEditOriginal = document.project }
            let original = liveEditOriginal
            document.performWithoutUndo { project in
                if let original { project = original }
                project.updateSequence(id, edit)
            }
        } else {
            editSequence("Speed/Duration") { sequence, _ in edit(&sequence) }
            AppLog.shared.info("Speed/Duration on \(ids.count) clip(s): \(change.percent.map { "\($0)%" } ?? "-")"
                               + (change.isReversed ? ", reversed" : ""), category: "edit")
        }
    }

    /// The constant speed from Effect Controls: like Speed/Duration without ripple, on the clip
    /// and its linked partners.
    func setConstantSpeed(_ percent: Double, of clip: Clip, live: Bool) {
        guard let sequence = activeSequence else { return }
        let ids = sequence.expandingLinks([clip.id])
        changeSpeed(ids, SpeedChange(percent: percent, isReversed: clip.isReversed, maintainsPitch: clip.maintainsPitch),
                    live: live)
    }
}
