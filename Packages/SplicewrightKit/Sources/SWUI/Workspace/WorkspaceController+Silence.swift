import Foundation
import SWCore
import SWExport

/// Sequence ▸ Remove Silence…: find the pauses in what the sequence plays, then take them out
/// (closing the gaps) or just cut around them to review.
extension WorkspaceController {
    /// What Remove Silence looks at: In to Out, else the selected clips' span, else the whole sequence.
    func silenceScope() -> (range: FrameRange, name: String)? {
        guard let sequence = activeSequence, sequence.durationFrames > 0 else { return nil }
        if let marked = sequence.marks.range, !marked.isEmpty { return (marked, "Sequence In to Out") }
        let selected = timeline.selection.compactMap { sequence.clip($0) }
        if let start = selected.map(\.start).min(), let end = selected.map(\.end).max(), end > start {
            return (FrameRange(start: start, end: end), "the selected clips")
        }
        return (FrameRange(start: 0, end: sequence.durationFrames), "the entire sequence")
    }

    func findSilences(_ settings: SilenceSettings, in range: FrameRange,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> [FrameRange] {
        guard let sequence = activeSequence else { return [] }
        return try await SilenceScan.pauses(in: sequence, project: project, frames: range, settings: settings,
                                            progress: progress)
    }

    /// Takes the pauses out, or with `cutOnly` splits around them and selects them.
    func removeSilences(_ pauses: [FrameRange], cutOnly: Bool) {
        guard !pauses.isEmpty else { return }
        if cutOnly {
            var cut: Set<UUID> = []
            editSequence("Cut at Pauses") { sequence, _ in cut = sequence.cutAtRanges(pauses) }
            timeline.selection = cut
        } else {
            editSequence("Remove Silence") { sequence, _ in sequence.rippleRemove(pauses) }
            timeline.selection = []
        }
    }
}
