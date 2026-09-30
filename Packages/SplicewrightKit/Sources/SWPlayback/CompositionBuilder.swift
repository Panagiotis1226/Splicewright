import AVFoundation
import SWCore
import SWMedia

/// Source tracks for one media item, loaded once and reused across rebuilds.
struct LoadedMedia {
    var asset: AVURLAsset
    var video: AVAssetTrack?
    var audio: AVAssetTrack?
    var naturalSize: CGSize
    var preferredTransform: CGAffineTransform
    var duration: CMTime
}

/// Caches loaded assets by media ID and file path.
public actor MediaAssetCache {
    private var loaded: [String: LoadedMedia] = [:]

    public init() {}

    func media(for item: MediaItem) async -> LoadedMedia? {
        let key = "\(item.id)|\(item.filePath)"
        if let cached = loaded[key] { return cached }
        guard FileManager.default.fileExists(atPath: item.filePath) else { return nil }
        let asset = AVURLAsset(url: item.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let duration = try await asset.load(.duration)
            let video = try await asset.loadTracks(withMediaType: .video).first
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            var size = CGSize.zero
            var transform = CGAffineTransform.identity
            if let video {
                (size, transform) = try await video.load(.naturalSize, .preferredTransform)
            }
            let media = LoadedMedia(asset: asset, video: video, audio: audio, naturalSize: size,
                                    preferredTransform: transform, duration: duration)
            loaded[key] = media
            return media
        } catch {
            return nil
        }
    }
}

/// Everything AVFoundation needs to play or export a sequence.
public struct CompositionOutput {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix
    public let durationFrames: Int64
}

/// Compiles an `EditSequence` into an AVFoundation composition. Each timeline track becomes
/// one composition track (clips on a track never overlap), and the render plan's segments
/// become compositor instructions.
public struct CompositionBuilder {
    /// 1, 0.5 or 0.25: the Program monitor's playback resolution.
    public var renderScale: Double
    /// Exact output size (export). Overrides `renderScale` when set.
    public var renderSize: CGSize?
    /// Encode for this color space instead of the sequence's (e.g. an SDR deliverable
    /// from an HDR sequence; HDR clips are tone-mapped).
    public var outputColorSpace: SequenceColorSpace?
    /// Diagnostic overlay for the Program monitor. Exports always use `.none`.
    public var overlay: OverlayMode

    public init(renderScale: Double = 1, renderSize: CGSize? = nil, outputColorSpace: SequenceColorSpace? = nil,
                overlay: OverlayMode = .none) {
        self.renderScale = renderScale
        self.renderSize = renderSize
        self.outputColorSpace = outputColorSpace
        self.overlay = overlay
    }

    public func build(_ sequence: EditSequence, project: Project, cache: MediaAssetCache) async -> CompositionOutput {
        let rate = sequence.rate
        func time(_ frames: Int64) -> CMTime { RationalTime(frames: frames, rate: rate).cmTime }

        var loaded: [UUID: LoadedMedia] = [:]
        let usedMedia = Set(sequence.allTracks.flatMap { $0.clips.map(\.mediaID) })
        for id in usedMedia {
            if let item = project.item(id), let media = await cache.media(for: item) { loaded[id] = media }
        }

        let composition = AVMutableComposition()
        let totalFrames = max(sequence.durationFrames, 1)
        var videoTrackIDs: [CMPersistentTrackID] = []
        var baseTrack: AVMutableCompositionTrack?
        for track in sequence.videoTracks {
            let compositionTrack = composition.addMutableTrack(withMediaType: .video,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid)
            videoTrackIDs.append(compositionTrack?.trackID ?? kCMPersistentTrackID_Invalid)
            guard let compositionTrack else { continue }
            if baseTrack == nil { baseTrack = compositionTrack }
            for clip in track.clips {
                guard let source = loaded[clip.mediaID], let sourceTrack = source.video else { continue }
                insert(clip, from: sourceTrack, duration: source.duration, into: compositionTrack, rate: rate)
            }
        }
        // Keep the composition as long as the sequence so instructions always cover it.
        if let baseTrack {
            let end = baseTrack.segments.last?.timeMapping.target.end ?? .zero
            if end < time(totalFrames) {
                baseTrack.insertEmptyTimeRange(CMTimeRange(start: end, end: time(totalFrames)))
            }
        }

        let audible = RenderPlan.audibleTracks(in: sequence)
        var mixParameters: [AVAudioMixInputParameters] = []
        for (index, track) in sequence.audioTracks.enumerated() {
            guard let compositionTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                     preferredTrackID: kCMPersistentTrackID_Invalid) else {
                continue
            }
            let parameters = AVMutableAudioMixInputParameters(track: compositionTrack)
            for clip in track.clips {
                guard let source = loaded[clip.mediaID], let sourceTrack = source.audio else { continue }
                insert(clip, from: sourceTrack, duration: source.duration, into: compositionTrack, rate: rate)
                // Volume holds until the next change, so setting it at each clip start is enough.
                let gain = audible[index] && clip.isEnabled ? Float(RenderPlan.linearGain(dB: clip.gainDB)) : 0
                parameters.setVolume(gain, at: time(clip.start))
            }
            mixParameters.append(parameters)
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParameters

        let videoComposition = makeVideoComposition(sequence, trackIDs: videoTrackIDs, loaded: loaded,
                                                    totalFrames: totalFrames, project: project)
        return CompositionOutput(composition: composition, videoComposition: videoComposition,
                                 audioMix: audioMix, durationFrames: totalFrames)
    }

    private func insert(_ clip: Clip, from sourceTrack: AVAssetTrack, duration: CMTime,
                        into track: AVMutableCompositionTrack, rate: FrameRate) {
        let start = clip.sourceStart.cmTime
        var length = RationalTime(frames: clip.duration, rate: rate).cmTime
        // Never read past the end of the source.
        if start + length > duration { length = duration - start }
        guard length > .zero else { return }
        let at = RationalTime(frames: clip.start, rate: rate).cmTime
        try? track.insertTimeRange(CMTimeRange(start: start, duration: length), of: sourceTrack, at: at)
    }

    private func makeVideoComposition(_ sequence: EditSequence, trackIDs: [CMPersistentTrackID],
                                      loaded: [UUID: LoadedMedia], totalFrames: Int64,
                                      project: Project) -> AVMutableVideoComposition {
        let settings = sequence.settings
        let rate = sequence.rate
        let outputSpace = outputColorSpace ?? settings.colorSpace
        let renderWidth = max(2, renderSize.map { Double($0.width) } ?? (Double(settings.width) * renderScale).rounded(.down))
        let renderHeight = max(2, renderSize.map { Double($0.height) }
                               ?? (Double(settings.height) * renderScale).rounded(.down))

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = SplicewrightCompositor.self
        videoComposition.frameDuration = rate.cmFrameDuration
        videoComposition.renderSize = CGSize(width: renderWidth, height: renderHeight)
        let tags = OutputColorTags(outputSpace.color)
        videoComposition.colorPrimaries = tags.primaries as String
        videoComposition.colorTransferFunction = tags.transfer as String
        videoComposition.colorYCbCrMatrix = tags.matrix as String

        let segments = RenderPlan.videoSegments(for: sequence, minimumFrames: totalFrames) { mediaID in
            loaded[mediaID]?.video != nil
        }
        videoComposition.instructions = segments.map { segment in
            let layers: [InstructionLayer] = segment.layers.compactMap { layer in
                guard let media = loaded[layer.mediaID], trackIDs.indices.contains(layer.trackIndex) else { return nil }
                let orientation = Affine2D(media.preferredTransform)
                let transform = Affine2D.fit(sourceWidth: media.naturalSize.width, sourceHeight: media.naturalSize.height,
                                             orientation: orientation, renderWidth: renderWidth,
                                             renderHeight: renderHeight)
                let item = project.item(layer.mediaID)
                return InstructionLayer(trackID: trackIDs[layer.trackIndex], opacity: layer.opacity,
                                        transform: transform, sourceWidth: media.naturalSize.width,
                                        sourceHeight: media.naturalSize.height,
                                        fallbackColor: item?.info.video?.color ?? .untagged,
                                        forcedColor: item?.colorOverride)
            }
            let range = CMTimeRange(start: RationalTime(frames: segment.range.start, rate: rate).cmTime,
                                    end: RationalTime(frames: segment.range.end, rate: rate).cmTime)
            return CompositionInstruction(timeRange: range, layers: layers, outputSpace: outputSpace, overlay: overlay)
        }
        return videoComposition
    }
}

extension Affine2D {
    init(_ transform: CGAffineTransform) {
        self.init(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: transform.tx, ty: transform.ty)
    }
}
