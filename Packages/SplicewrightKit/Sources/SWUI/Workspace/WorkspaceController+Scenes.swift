import AVFoundation
import SWCore
import SWMedia

/// Clip ▸ Scene Edit Detection…: find the shot changes inside clips (a flattened video, say) and
/// cut at them or mark them.
extension WorkspaceController {
    enum SceneAction: String, CaseIterable, Identifiable {
        case edits, markers

        var id: String { rawValue }
        var displayName: String { self == .edits ? "Add an edit at each cut" : "Add a marker at each cut" }
    }

    /// The video clips to look in: the selected ones, or the top footage at the playhead.
    func sceneDetectionClips() -> [Clip] {
        guard let sequence = activeSequence else { return [] }
        let videoIDs = Set(sequence.videoTracks.flatMap { $0.clips.map(\.id) })
        let selected = timeline.selection.filter { videoIDs.contains($0) }.compactMap { sequence.clip($0) }
            .filter { !$0.isGenerated }.sorted { $0.start < $1.start }
        if !selected.isEmpty { return selected }
        return footageClip(at: program.currentFrame).map { [$0] } ?? []
    }

    /// Finds the cuts in each clip's part of its media and applies `action`. Returns how many.
    func detectScenes(in clips: [Clip], settings: SceneSettings, action: SceneAction,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        guard let rate = activeSequence?.rate else { return 0 }
        var found: [(clip: Clip, frames: [Int64])] = []
        for (index, clip) in clips.enumerated() {
            guard let url = project.item(clip.mediaID)?.url else { continue }
            let span = clip.timing(rate: rate).sourceRange
            // The span of the media the clip shows (in source seconds).
            let range = CMTimeRange(start: CMTime(seconds: span.lower, preferredTimescale: 600_000),
                                    end: CMTime(seconds: span.upper, preferredTimescale: 600_000))
            let share = 1 / Double(clips.count)
            let cuts = try await SceneScan.cuts(in: url, range: range, settings: settings) { fraction in
                progress((Double(index) + fraction) * share)
            }
            let frames = cuts.map { clip.sequenceFrame(atSourceTime: RationalTime($0), rate: rate) }
                .filter { $0 > clip.start && $0 < clip.end }
            found.append((clip, Array(Set(frames)).sorted()))
        }
        var count = 0
        editSequence(action == .edits ? "Scene Edit Detection" : "Mark Scenes") { sequence, _ in
            for (clip, frames) in found {
                if action == .edits {
                    count += sequence.addSceneEdits(to: clip.id, at: frames)
                } else {
                    sequence.addSceneMarkers(frames, clipName: clip.name)
                    count += frames.count
                }
            }
        }
        return count
    }
}
