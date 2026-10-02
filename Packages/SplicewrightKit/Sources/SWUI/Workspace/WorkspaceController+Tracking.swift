import AVFoundation
import CoreGraphics
import Foundation
import SWCore

/// Reads a clip's frames for tracking: upright (the track's rotation applied), at the analysis
/// size, as `TrackingImage`s.
final class TrackingFrameReader: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private let levels: Int

    init(url: URL, analysisSize: Int, levels: Int) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: analysisSize, height: analysisSize)
        self.levels = levels
    }

    func image(at time: RationalTime) async throws -> TrackingImage {
        let image = try await generator.image(at: time.cmTime).image
        let (width, height) = (image.width, image.height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw CocoaError(.fileReadCorruptFile) }
        let (pixels, levels) = (rgba, self.levels)
        return await Task.detached { TrackingImage(width: width, height: height, rgba: pixels, pyramidLevels: levels) }
            .value
    }
}

/// A mask being tracked: shown in Effect Controls with its progress and a Stop button.
@MainActor
public final class MaskTrackingJob: ObservableObject {
    public let selection: MaskSelection
    public let isForward: Bool
    /// The sequence frame tracking starts from (the mask as drawn there).
    public let startFrame: Int64
    public let frameCount: Int
    @Published public internal(set) var framesDone = 0
    @Published public internal(set) var confidence = 1.0
    var isCancelled = false

    init(selection: MaskSelection, isForward: Bool, startFrame: Int64, frameCount: Int) {
        self.selection = selection
        self.isForward = isForward
        self.startFrame = startFrame
        self.frameCount = frameCount
    }

    public var progress: Double { frameCount > 0 ? Double(framesDone) / Double(frameCount) : 0 }

    public func cancel() { isCancelled = true }
}

/// What the last track of a mask ended with, when it's worth saying (lost the object, no frames).
public struct MaskTrackingMessage: Sendable, Hashable {
    public var selection: MaskSelection
    public var text: String
}

extension WorkspaceController {
    /// The mask's tracking options (the defaults until changed).
    func trackingSettings(_ selection: MaskSelection) -> TrackingSettings {
        mask(selection)?.tracking ?? TrackingSettings()
    }

    func setTrackingSettings(_ settings: TrackingSettings, of selection: MaskSelection) {
        updateMask(selection, "Tracking Options") { $0.tracking = settings == TrackingSettings() ? nil : settings }
    }

    /// Tracks the mask from the playhead to the clip's end (or start), or one frame, writing a
    /// Mask Path keyframe on each frame; the playhead follows. One undo step. `maxFrames` limits
    /// how far (smoke tests).
    public func trackMask(_ selection: MaskSelection, forward: Bool, oneFrame: Bool, maxFrames: Int? = nil) {
        guard trackingJob == nil, let sequence = activeSequence, let clip = sequence.clip(selection.target.clipID),
              let mask = mask(selection) else { return }
        guard !clip.isGenerated, let item = project.item(clip.mediaID), item.info.video != nil,
              !offlineMediaIDs.contains(item.id) else {
            trackingMessage = MaskTrackingMessage(selection: selection,
                                                  text: "Tracking follows a video clip's picture; this clip has none.")
            return
        }
        let start = min(max(playheadFrame, clip.start), clip.end - 1)
        let end = forward ? clip.end - 1 : clip.start
        var count = Int(abs(end - start))
        if oneFrame { count = min(count, 1) }
        if let maxFrames { count = min(count, maxFrames) }
        guard count > 0 else {
            trackingMessage = MaskTrackingMessage(selection: selection, text: forward
                ? "The playhead is on the clip's last frame: move it back to track forward."
                : "The playhead is on the clip's first frame: move it on to track backward.")
            return
        }
        let job = MaskTrackingJob(selection: selection, isForward: forward, startFrame: start, frameCount: count)
        trackingJob = job
        trackingMessage = nil
        let url = (useProxies ? ProxyQueue.shared.proxyURL(item) : nil) ?? item.url
        Task { @MainActor in
            await self.runTracking(job, clip: clip, mask: mask, url: url, rate: sequence.rate)
        }
    }

    private func runTracking(_ job: MaskTrackingJob, clip: Clip, mask: Mask, url: URL, rate: FrameRate) async {
        let selection = job.selection
        let start = job.startFrame
        let settings = mask.tracking ?? TrackingSettings()
        let ref = selection.ref(.path)
        func time(_ frame: Int64) -> RationalTime { clip.keyframeTime(for: ref, atSequenceFrame: frame, rate: rate) }
        let reader = TrackingFrameReader(url: url, analysisSize: settings.quality.analysisSize,
                                         levels: settings.searchRange.pyramidLevels)
        defer {
            endLiveEdit("Track Mask")
            trackingJob = nil
        }
        do {
            let first = try await reader.image(at: time(start))
            let vertices = mask.vertices(at: time(start))
            let made = await Task.detached { MaskTrackingSession(settings: settings, first: first, vertices: vertices) }.value
            guard let session = made else {
                trackingMessage = MaskTrackingMessage(selection: selection, text: settings.method == .color
                    ? "The mask's colors don't stand out from around it. Try Points or Texture."
                    : "There's too little detail inside the mask to follow. Try Texture or Color, or a larger mask.")
                return
            }
            // The path animates from where tracking starts.
            let startTime = time(start)
            liveEdit { sequence in
                sequence.updateMask(selection.maskID, of: selection.target.owner, in: selection.target.clipID) { mask in
                    if !mask.path.isAnimated { mask.path.setAnimated(true, at: startTime) }
                }
            }
            var frame = start
            for _ in 0..<job.frameCount where !job.isCancelled {
                frame += job.isForward ? 1 : -1
                let image = try await reader.image(at: time(frame))
                let step = await Task.detached { session.track(image) }.value
                job.confidence = step.confidence
                if step.isLost && settings.stopsWhenLost {
                    let timecode = Timecode(frame: frame, rate: rate).description
                    trackingMessage = MaskTrackingMessage(selection: selection, text: "Lost the object at \(timecode). "
                        + "Fix the mask on the frame before and track again, or try another method.")
                    break
                }
                let at = time(frame)
                liveEdit { sequence in
                    sequence.updateMask(selection.maskID, of: selection.target.owner, in: selection.target.clipID) {
                        $0.setVertices(step.vertices, at: at, tolerance: rate.frameDuration)
                    }
                }
                job.framesDone += 1
                program.seek(toFrame: frame)
            }
        } catch {
            AppLog.shared.warning("Tracking couldn't read \(url.lastPathComponent): \(error.localizedDescription)",
                                  category: "tracking")
            trackingMessage = MaskTrackingMessage(selection: selection, text: "Couldn't read the clip's frames.")
        }
    }
}
