import Foundation
import SWCore
import SWMedia

/// Sequence ▸ Auto Reframe Sequence…: a copy at another shape, each clip filling the frame and
/// following its subject.
extension WorkspaceController {
    /// Analyses every video clip of the active sequence and adds the reframed copy (one undo
    /// step), opening it. Returns its ID.
    @discardableResult
    func autoReframe(_ settings: ReframeSettings,
                     progress: @escaping @MainActor (Double) -> Void) async throws -> UUID? {
        guard let sequence = activeSequence else { return nil }
        let clips = sequence.videoTracks.flatMap(\.clips).filter { !$0.isGenerated }
        var pictures: [UUID: (width: Double, height: Double)] = [:]
        var paths: [UUID: [ReframeSample]] = [:]
        for (index, clip) in clips.enumerated() {
            try Task.checkCancellation()
            guard let item = project.item(clip.mediaID), let video = item.info.video,
                  !offlineMediaIDs.contains(item.id) else { continue }
            pictures[clip.id] = (Double(video.width), Double(video.height))
            let done = Double(index) / Double(clips.count), share = 1 / Double(clips.count)
            if item.info.isStill {
                if let image = StillImage.image(at: item.url, maxPixels: 640) {
                    paths[clip.id] = [SubjectScan.sample(of: image)]
                }
                progress(done + share)
                continue
            }
            let url = (useProxies ? ProxyQueue.shared.proxyURL(item) : nil) ?? item.url
            let rate = sequence.rate
            let first = clip.keyframeTime(for: .clip(.position), atSequenceFrame: clip.start, rate: rate).seconds
            let last = clip.keyframeTime(for: .clip(.position), atSequenceFrame: clip.end - 1, rate: rate).seconds
            paths[clip.id] = try await SubjectScan.path(in: url, from: min(first, last), to: max(first, last)) { part in
                Task { @MainActor in progress(done + share * part) }
            }
        }
        try Task.checkCancellation()
        var created: UUID?
        document?.perform("Auto Reframe Sequence", undoManager: undoManager) { project in
            var reframed = sequence.reframed(settings, pictures: pictures, paths: paths)
            // A name no other sequence has.
            let placeholder = project.addSequence(named: reframed.name, settings: reframed.settings)
            reframed.id = placeholder.id
            reframed.name = placeholder.name
            project.updateSequence(placeholder.id) { $0 = reframed }
            created = reframed.id
        }
        if let created { openSequence(created) }
        return created
    }
}
