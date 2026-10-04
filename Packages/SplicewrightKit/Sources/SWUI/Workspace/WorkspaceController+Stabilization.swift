import Foundation
import SWCore

/// A Stabilizer analysing its clip: shown in Effect Controls with progress and Cancel.
@MainActor
public final class StabilizationJob: ObservableObject {
    public let clipID: UUID
    public let effectID: UUID
    public let frameCount: Int
    @Published public internal(set) var framesDone = 0
    var isCancelled = false

    init(clipID: UUID, effectID: UUID, frameCount: Int) {
        self.clipID = clipID
        self.effectID = effectID
        self.frameCount = frameCount
    }

    public var progress: Double { frameCount > 0 ? Double(framesDone) / Double(frameCount) : 0 }

    public func cancel() { isCancelled = true }
}

extension WorkspaceController {
    /// Analyses the clip's camera motion for its Stabilizer, frame by frame over the part of the
    /// source the clip uses. The result is one undo step; cancelling keeps what was there.
    func analyzeStabilization(clipID: UUID, effectID: UUID) {
        guard stabilizationJob == nil, let sequence = activeSequence, let clip = sequence.clip(clipID),
              let item = project.item(clip.mediaID), let video = item.info.video, !clip.isGenerated,
              !item.info.isStill, !offlineMediaIDs.contains(item.id) else { return }
        let job = StabilizationJob(clipID: clipID, effectID: effectID, frameCount: Int(max(clip.duration - 1, 0)))
        stabilizationJob = job
        let url = (useProxies ? ProxyQueue.shared.proxyURL(item) : nil) ?? item.url
        let size = (Double(video.width), Double(video.height))
        Task { @MainActor in
            defer { stabilizationJob = nil }
            do {
                guard let data = try await analyse(clip, url: url, pictureSize: size, rate: sequence.rate, job: job),
                      !job.isCancelled else { return }
                updateEffect(effectID, of: clipID, "Analyze Stabilizer") { effect in
                    var analysed = data
                    analysed.settings = effect.stabilization?.settings ?? data.settings
                    analysed.update()
                    effect.stabilization = analysed
                }
            } catch {
                AppLog.shared.warning("Stabilizer couldn't read \(url.lastPathComponent): \(error.localizedDescription)",
                                      category: "stabilizer")
            }
        }
    }

    private func analyse(_ clip: Clip, url: URL, pictureSize: (Double, Double), rate: FrameRate,
                         job: StabilizationJob) async throws -> StabilizationData? {
        let settings = clip.effects.first { $0.id == job.effectID }?.stabilization?.settings ?? StabilizationSettings()
        let reader = TrackingFrameReader(url: url, analysisSize: 640, levels: 4)
        func time(_ frame: Int64) -> RationalTime { clip.keyframeTime(for: .clip(.position), atSequenceFrame: frame,
                                                                       rate: rate) }
        var data = StabilizationData(pictureWidth: pictureSize.0, pictureHeight: pictureSize.1)
        data.settings = settings
        let first = try await reader.image(at: time(clip.start))
        let analyzer = StabilizationAnalyzer(first: first, method: settings.method, pictureWidth: pictureSize.0)
        data.times = [time(clip.start).seconds]
        data.path = [StabilizationData.numbers(.identity)]
        var frame = clip.start + 1
        while frame < clip.end, !job.isCancelled {
            let image = try await reader.image(at: time(frame))
            let (camera, _) = await Task.detached { analyzer.add(image) }.value
            data.times.append(time(frame).seconds)
            data.path.append(StabilizationData.numbers(camera))
            job.framesDone += 1
            frame += 1
        }
        // A reversed clip plays its source backwards; keep the times in order for lookups.
        if let firstTime = data.times.first, let lastTime = data.times.last, lastTime < firstTime {
            data.times.reverse()
            data.path.reverse()
        }
        data.isComplete = !job.isCancelled
        return data
    }

    /// Changes how the Stabilizer smooths (no new analysis needed).
    func setStabilizationSettings(_ settings: StabilizationSettings, effectID: UUID, of clipID: UUID,
                                  live: Bool = false) {
        let change: (inout ClipEffect) -> Void = { effect in
            guard var data = effect.stabilization else { return }
            data.settings = settings
            data.update()
            effect.stabilization = data
        }
        if live {
            liveEdit { $0.updateEffect(effectID, of: clipID, change) }
        } else {
            updateEffect(effectID, of: clipID, "Stabilizer Settings", change)
        }
    }

    /// Whether the clip now covers frames its analysis doesn't (it was extended or slipped).
    func stabilizationNeedsAnalysis(_ clip: Clip, effect: ClipEffect) -> Bool {
        guard let data = effect.stabilization, data.isComplete, let first = data.times.first,
              let last = data.times.last, let rate = activeSequence?.rate else { return true }
        let start = clip.keyframeTime(for: .clip(.position), atSequenceFrame: clip.start, rate: rate).seconds
        let end = clip.keyframeTime(for: .clip(.position), atSequenceFrame: clip.end - 1, rate: rate).seconds
        let slack = rate.frameDuration.seconds * 1.5
        return min(start, end) < first - slack || max(start, end) > last + slack
    }
}
