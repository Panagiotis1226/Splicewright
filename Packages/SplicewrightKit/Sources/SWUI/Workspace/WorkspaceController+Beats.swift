import Foundation
import SWCore
import SWExport

/// Sequence ▸ Detect Beats…: find the beat in the music, then mark it or cut the selected
/// video on it.
extension WorkspaceController {
    /// The selected audio clips (the music to listen to), and the selected video clips (to cut).
    func beatSelection() -> (audio: Set<UUID>, video: [UUID]) {
        guard let sequence = activeSequence else { return ([], []) }
        let audio = Set(sequence.audioTracks.flatMap(\.clips).map(\.id)).intersection(timeline.selection)
        let video = sequence.videoTracks.flatMap(\.clips).filter { timeline.selection.contains($0.id) }.map(\.id)
        return (audio, video)
    }

    func findBeats(_ settings: BeatSettings, in range: FrameRange,
                   progress: @escaping @Sendable (Double) -> Void) async throws -> (bpm: Double, frames: [Int64]) {
        guard let sequence = activeSequence else { return (0, []) }
        let music = sequence.soloingAudio(beatSelection().audio)
        return try await BeatScan.beats(in: music, project: project, frames: range, settings: settings,
                                        progress: progress)
    }

    func addBeatMarkers(_ frames: [Int64]) {
        guard !frames.isEmpty else { return }
        editSequence("Add Beat Markers") { sequence, _ in sequence.addBeatMarkers(frames) }
    }

    func cutSelectedVideoOnBeats(_ frames: [Int64]) {
        let video = beatSelection().video
        guard !frames.isEmpty, !video.isEmpty else { return }
        editSequence("Cut on Beats") { sequence, _ in sequence.cutOnBeats(video, at: frames) }
    }
}
