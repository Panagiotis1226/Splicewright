import AVFoundation
import SWCore
import SWMedia

/// Source tracks for one media item, loaded once and reused across rebuilds.
struct LoadedMedia {
    var asset: AVURLAsset
    /// Keeps the proxy asset alive while its video track is in use (tracks don't retain assets).
    var proxyAsset: AVURLAsset?
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

    /// The item's tracks. With `proxy`, video comes from that proxy file (audio always comes
    /// from the original).
    func media(for item: MediaItem, proxy: URL? = nil) async -> LoadedMedia? {
        // The size and date are in the key so a file that changed on disk is loaded again.
        let key = "\(item.id)|\(item.filePath)|\(item.info.fileSize ?? 0)|"
            + "\(item.fileModifiedAt?.timeIntervalSince1970 ?? 0)|\(proxy?.path ?? "")"
        if let cached = loaded[key] { return cached }
        guard FileManager.default.fileExists(atPath: item.filePath) else { return nil }
        let options = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        let asset = AVURLAsset(url: item.url, options: options)
        do {
            let duration = try await asset.load(.duration)
            var video = try await asset.loadTracks(withMediaType: .video).first
            var proxyAsset: AVURLAsset?
            if let proxy, FileManager.default.fileExists(atPath: proxy.path) {
                let candidate = AVURLAsset(url: proxy, options: options)
                if let proxyTrack = try? await candidate.loadTracks(withMediaType: .video).first {
                    video = proxyTrack
                    proxyAsset = candidate
                }
            }
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            var size = CGSize.zero
            var transform = CGAffineTransform.identity
            if let video {
                (size, transform) = try await video.load(.naturalSize, .preferredTransform)
            }
            let media = LoadedMedia(asset: asset, proxyAsset: proxyAsset, video: video, audio: audio, naturalSize: size,
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
    /// How sped-up or slowed-down audio is resampled: pitch-corrected unless every retimed
    /// clip turned Maintain Audio Pitch off. Set it on the player item or reader output.
    public var audioTimePitchAlgorithm: AVAudioTimePitchAlgorithm = .spectral
    /// The mixer settings the audio taps read; update it to move faders without a rebuild.
    public var mixer: MixerLevels?
    /// Levels the taps measure (playback meters).
    public var meters: AudioMeters?
}

/// Compiles an `EditSequence` into an AVFoundation composition. Each timeline track becomes
/// one composition track, or more where transitions need two of its clips at once (A/B
/// roll), and the render plan's segments become compositor instructions.
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
    /// Render at this rate instead of the sequence's (export). Frames are taken at real
    /// composition times, so 120 fps sources exported at 120 keep every frame.
    public var frameRate: FrameRate?
    /// Play clips' proxies instead of their full-resolution video where proxies exist.
    /// Export never sets this.
    public var useProxies: Bool
    public var proxyStore: ProxyStore

    public init(renderScale: Double = 1, renderSize: CGSize? = nil, outputColorSpace: SequenceColorSpace? = nil,
                overlay: OverlayMode = .none, frameRate: FrameRate? = nil, useProxies: Bool = false,
                proxyStore: ProxyStore = .shared) {
        self.renderScale = renderScale
        self.renderSize = renderSize
        self.outputColorSpace = outputColorSpace
        self.overlay = overlay
        self.frameRate = frameRate
        self.useProxies = useProxies
        self.proxyStore = proxyStore
    }

    public func build(_ sequence: EditSequence, project: Project, cache: MediaAssetCache) async -> CompositionOutput {
        let rate = sequence.rate
        func time(_ frames: Int64) -> CMTime { RationalTime(frames: frames, rate: rate).cmTime }

        var loaded: [UUID: LoadedMedia] = [:]
        let usedMedia = Set(sequence.allTracks.flatMap { $0.clips.map(\.mediaID) })
        for id in usedMedia {
            guard let item = project.item(id) else { continue }
            let proxy = useProxies ? proxyStore.proxy(for: item) : nil
            if let media = await cache.media(for: item, proxy: proxy) { loaded[id] = media }
        }

        let composition = AVMutableComposition()
        let totalFrames = max(sequence.durationFrames, 1)
        var clipTracks: [UUID: CMPersistentTrackID] = [:]
        var baseTrack: AVMutableCompositionTrack?
        for track in sequence.videoTracks {
            let packer = TrackPacker(composition: composition, mediaType: .video)
            let handles = Handles(track)
            for clip in track.clips {
                guard let source = loaded[clip.mediaID], let sourceTrack = source.video else { continue }
                let (head, tail) = handles[clip.id]
                guard let compositionTrack = packer.track(for: clip.start - head, end: clip.end + tail) else { continue }
                if baseTrack == nil { baseTrack = compositionTrack }
                clipTracks[clip.id] = compositionTrack.trackID
                insert(Placement(clip: clip, head: head, tail: tail, freezeMissingHandles: true),
                       from: sourceTrack, duration: source.duration, into: compositionTrack, rate: rate)
            }
        }
        if baseTrack == nil {
            baseTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        // Keep the composition as long as the sequence so instructions always cover it.
        if let baseTrack {
            let end = baseTrack.segments.last?.timeMapping.target.end ?? .zero
            if end < time(totalFrames) {
                baseTrack.insertEmptyTimeRange(CMTimeRange(start: end, end: time(totalFrames)))
            }
        }

        let mixer = MixerLevels(sequence)
        let meters = AudioMeters()
        let mixParameters = addAudio(sequence, to: composition, loaded: loaded, mixer: mixer, meters: meters)
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParameters

        let videoComposition = makeVideoComposition(sequence, clipTracks: clipTracks, loaded: loaded,
                                                    totalFrames: totalFrames, project: project)
        var output = CompositionOutput(composition: composition, videoComposition: videoComposition,
                                       audioMix: audioMix, durationFrames: totalFrames)
        output.mixer = mixer
        output.meters = meters
        let retimed = sequence.audioTracks.flatMap(\.clips).filter(\.isRetimed)
        if !retimed.isEmpty, retimed.allSatisfy({ !$0.maintainsPitch }) { output.audioTimePitchAlgorithm = .varispeed }
        return output
    }

    /// Audio tracks (A/B packed where crossfades need it), their volume automation, and a tap
    /// on each for clip audio effects, the track's fader and pan, and metering.
    private func addAudio(_ sequence: EditSequence, to composition: AVMutableComposition, loaded: [UUID: LoadedMedia],
                          mixer: MixerLevels, meters: AudioMeters) -> [AVAudioMixInputParameters] {
        let rate = sequence.rate
        let audible = RenderPlan.audibleTracks(in: sequence)
        var mixParameters: [AVAudioMixInputParameters] = []
        for (index, track) in sequence.audioTracks.enumerated() {
            let packer = TrackPacker(composition: composition, mediaType: .audio)
            let handles = Handles(track)
            let fades = RenderPlan.audioFades(for: track)
            var parameters: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
            var placed: [CMPersistentTrackID: [Clip]] = [:]
            for clip in track.clips {
                guard let source = loaded[clip.mediaID], let sourceTrack = source.audio else { continue }
                let (head, tail) = handles[clip.id]
                guard let compositionTrack = packer.track(for: clip.start - head, end: clip.end + tail) else { continue }
                insert(Placement(clip: clip, head: head, tail: tail, freezeMissingHandles: false),
                       from: sourceTrack, duration: source.duration, into: compositionTrack, rate: rate)
                let params = parameters[compositionTrack.trackID]
                    ?? AVMutableAudioMixInputParameters(track: compositionTrack)
                parameters[compositionTrack.trackID] = params
                placed[compositionTrack.trackID, default: []].append(clip)
                let range = FrameRange(start: clip.start - head, end: clip.end + tail)
                if audible[index] && clip.isEnabled {
                    AudioEnvelope.apply(clip, fades: fades[clip.id], range: range, to: params, rate: rate)
                } else {
                    params.setVolume(0, at: RationalTime(frames: range.start, rate: rate).cmTime)
                }
            }
            for (trackID, params) in parameters {
                let context = TapContext(trackID: track.id, clips: placed[trackID] ?? [], rate: rate, levels: mixer,
                                         meters: meters)
                params.audioTapProcessor = TapContext.makeTap(context)
            }
            mixParameters += parameters.keys.sorted().compactMap { parameters[$0] }
        }
        return mixParameters
    }

    /// Inserts a clip plus `head`/`tail` frames of handle for its transitions. Handles the
    /// source doesn't have are filled with a held first or last frame (video) or silence.
    private struct Placement {
        var clip: Clip
        var head: Int64
        var tail: Int64
        var freezeMissingHandles: Bool
    }

    private func insert(_ placement: Placement, from sourceTrack: AVAssetTrack, duration: CMTime,
                        into track: AVMutableCompositionTrack, rate: FrameRate) {
        guard !placement.clip.isRetimed else {
            insertRetimed(placement, from: sourceTrack, duration: duration, into: track, rate: rate)
            return
        }
        func time(_ frames: Int64) -> CMTime { RationalTime(frames: frames, rate: rate).cmTime }
        let (clip, head, tail, freezeMissingHandles) = (placement.clip, placement.head, placement.tail,
                                                        placement.freezeMissingHandles)
        let wantedStart = clip.sourceStart.cmTime - time(head)
        let wantedEnd = clip.sourceStart.cmTime + time(clip.duration + tail)
        let start = max(wantedStart, .zero)
        let end = min(wantedEnd, duration)
        guard end > start else { return }
        let at = time(clip.start - head)
        let missingHead = start - wantedStart
        let frame = rate.cmFrameDuration
        if freezeMissingHandles, missingHead > .zero {
            try? track.insertTimeRange(CMTimeRange(start: start, duration: min(frame, end - start)), of: sourceTrack, at: at)
            track.scaleTimeRange(CMTimeRange(start: at, duration: min(frame, end - start)), toDuration: missingHead)
        }
        try? track.insertTimeRange(CMTimeRange(start: start, end: end), of: sourceTrack, at: at + missingHead)
        // Only hold the last frame for the transition's handle, not for media shorter than the clip.
        let missingTail = min(wantedEnd - end, time(tail))
        if freezeMissingHandles, missingTail > .zero {
            let holdAt = at + missingHead + (end - start)
            let last = CMTimeRange(start: max(start, end - frame), end: end)
            try? track.insertTimeRange(last, of: sourceTrack, at: holdAt)
            track.scaleTimeRange(CMTimeRange(start: holdAt, duration: last.duration), toDuration: missingTail)
        }
    }

    /// A clip at another speed. Constant forward speed is one scaled edit (AVFoundation
    /// resamples audio with the item's pitch algorithm). Reversed and time-remapped video is
    /// built a frame at a time; their audio is silent.
    private func insertRetimed(_ placement: Placement, from sourceTrack: AVAssetTrack, duration media: CMTime,
                               into track: AVMutableCompositionTrack, rate: FrameRate) {
        let (clip, isVideo) = (placement.clip, placement.freezeMissingHandles)
        let timing = clip.timing(rate: rate)
        let frame = rate.cmFrameDuration
        let first = -placement.head
        let last = clip.duration + placement.tail
        let source = clip.sourceStart.seconds
        let mediaSeconds = media.seconds
        func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600_000) }
        /// Exact composition time of a whole clip frame.
        func at(frame position: Int64) -> CMTime { RationalTime(frames: clip.start + position, rate: rate).cmTime }
        func at(_ clipFrame: Double) -> CMTime {
            // Whole frames exactly, so edits meet their neighbours without gaps or overlaps.
            if abs(clipFrame - clipFrame.rounded()) < 1e-6 { return at(frame: Int64(clipFrame.rounded())) }
            return RationalTime(frames: clip.start, rate: rate).cmTime + seconds(clipFrame / rate.framesPerSecond)
        }
        /// Shows the source frame at `time` for `frames` sequence frames from clip frame `position`.
        func hold(_ time: Double, from position: Int64, frames: Int64) {
            // A little past `time`, so a time that lands just short of a frame boundary in
            // floating point still shows the frame starting there.
            let start = min(max(time + frame.seconds / 8, 0), max(0, mediaSeconds - frame.seconds))
            let range = CMTimeRange(start: seconds(start), duration: frame)
            guard (try? track.insertTimeRange(range, of: sourceTrack, at: at(frame: position))) != nil else { return }
            track.scaleTimeRange(CMTimeRange(start: at(frame: position), duration: frame),
                                 toDuration: RationalTime(frames: frames, rate: rate).cmTime)
        }

        if !timing.isReversed && !timing.isRemapped {
            // Clamp the wanted source to the media, then scale it onto the timeline.
            let lower = max(0, source + timing.sourceOffset(atClipFrame: Double(first)))
            let upper = min(mediaSeconds, source + timing.sourceOffset(atClipFrame: Double(last)))
            guard upper > lower else { return }
            let startFrame = timing.clipFrame(atSourceOffset: lower - source)
            let endFrame = timing.clipFrame(atSourceOffset: upper - source)
            let sourceRange = CMTimeRange(start: seconds(lower), end: seconds(upper))
            guard (try? track.insertTimeRange(sourceRange, of: sourceTrack, at: at(startFrame))) != nil else { return }
            track.scaleTimeRange(CMTimeRange(start: at(startFrame), duration: sourceRange.duration),
                                 toDuration: at(endFrame) - at(startFrame))
            if isVideo {
                // Hold the first or last frame through a transition handle the source can't fill.
                let headGap = Int64(startFrame.rounded(.down)) - first
                if headGap > 0 { hold(lower, from: first, frames: headGap) }
                let tailStart = max(Int64(endFrame.rounded(.up)), clip.duration)
                if last > tailStart { hold(upper - frame.seconds, from: tailStart, frames: last - tailStart) }
            }
            return
        }
        guard isVideo else { return }
        // One edit per output frame showing the source frame at its mapped time, as Premiere
        // samples reversed and remapped clips.
        for position in first..<last {
            hold(source + timing.sourceOffset(atClipFrame: Double(position)), from: position, frames: 1)
        }
    }

    private func makeVideoComposition(_ sequence: EditSequence, clipTracks: [UUID: CMPersistentTrackID],
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
        videoComposition.frameDuration = (frameRate ?? rate).cmFrameDuration
        videoComposition.renderSize = CGSize(width: renderWidth, height: renderHeight)
        let tags = OutputColorTags(outputSpace.color)
        videoComposition.colorPrimaries = tags.primaries as String
        videoComposition.colorTransferFunction = tags.transfer as String
        videoComposition.colorYCbCrMatrix = tags.matrix as String

        func time(_ frames: Int64) -> CMTime { RationalTime(frames: frames, rate: rate).cmTime }
        let pixelScale = renderWidth / Double(max(settings.width, 1))
        let segments = RenderPlan.videoSegments(for: sequence, minimumFrames: totalFrames) { mediaID in
            // (Title clips render without media.) Missing video files show Media Offline.
            loaded[mediaID]?.video != nil || (loaded[mediaID] == nil && project.item(mediaID)?.info.video != nil)
        }
        let follows = Self.followSamples(sequence, project: project)
        videoComposition.instructions = segments.map { segment in
            func instructionLayer(for layer: RenderLayer) -> InstructionLayer? {
                let transition = layer.transition.map { InstructionTransition($0, rate: rate) }
                if layer.isAdjustment {
                    // No source: its effects work on what's below. Opacity blends the result.
                    return InstructionLayer(trackID: kCMPersistentTrackID_Invalid, opacity: layer.opacity,
                                            transform: .identity, sourceWidth: renderWidth, sourceHeight: renderHeight,
                                            fallbackColor: .rec709, forcedColor: nil, transition: transition,
                                            motion: layer.motion, clipStart: time(layer.clipStart),
                                            sourceStart: layer.sourceStart, pixelScale: pixelScale)
                }
                if let title = layer.title {
                    return InstructionLayer(trackID: kCMPersistentTrackID_Invalid, opacity: layer.opacity,
                                            transform: .identity, sourceWidth: renderWidth, sourceHeight: renderHeight,
                                            fallbackColor: .rec709, forcedColor: nil, transition: transition,
                                            title: title, motion: layer.motion, clipStart: time(layer.clipStart),
                                            sourceStart: layer.sourceStart, pixelScale: pixelScale)
                }
                guard let media = loaded[layer.mediaID] else {
                    guard let item = project.item(layer.mediaID) else { return nil }
                    return InstructionLayer(trackID: kCMPersistentTrackID_Invalid, opacity: layer.opacity,
                                            transform: .identity, sourceWidth: renderWidth, sourceHeight: renderHeight,
                                            fallbackColor: .rec709, forcedColor: nil, transition: transition,
                                            title: .mediaOffline(item.name), motion: Motion(),
                                            clipStart: time(layer.clipStart), sourceStart: layer.sourceStart,
                                            pixelScale: pixelScale)
                }
                guard let trackID = clipTracks[layer.clipID] else { return nil }
                let orientation = Affine2D(media.preferredTransform)
                let transform = Affine2D.fit(sourceWidth: media.naturalSize.width, sourceHeight: media.naturalSize.height,
                                             orientation: orientation, renderWidth: renderWidth,
                                             renderHeight: renderHeight)
                let item = project.item(layer.mediaID)
                var built = InstructionLayer(trackID: trackID, opacity: layer.opacity,
                                            transform: transform, sourceWidth: media.naturalSize.width,
                                            sourceHeight: media.naturalSize.height,
                                            fallbackColor: item?.info.video?.color ?? .untagged,
                                            forcedColor: item?.colorOverride, transition: transition, motion: layer.motion,
                                            clipStart: time(layer.clipStart), sourceStart: layer.sourceStart,
                                            pixelScale: pixelScale, timing: layer.timing)
                // Phone video is stored sideways; masks, crop and flips are set on it upright.
                built.picture = DisplayedPicture(sourceWidth: media.naturalSize.width,
                                                 sourceHeight: media.naturalSize.height, orientation: orientation,
                                                 renderWidth: renderWidth, renderHeight: renderHeight)
                return built
            }
            let layers: [InstructionLayer] = segment.layers.compactMap { layer -> InstructionLayer? in
                var built = instructionLayer(for: layer)
                built?.effects = layer.effects
                built?.isAdjustment = layer.isAdjustment
                built?.opacityMasks = layer.opacityMasks
                built?.follow = follows[layer.clipID]
                return built
            }
            let range = CMTimeRange(start: RationalTime(frames: segment.range.start, rate: rate).cmTime,
                                    end: RationalTime(frames: segment.range.end, rate: rate).cmTime)
            return CompositionInstruction(timeRange: range, layers: layers, outputSpace: outputSpace, overlay: overlay,
                                          everyFrame: (frameRate ?? rate) != rate)
        }
        return videoComposition
    }
}

/// Frames of handle each clip needs on a track: before its start for a transition into it,
/// after its end for a transition out of it.
private struct Handles {
    private var values: [UUID: (head: Int64, tail: Int64)] = [:]

    init(_ track: Track) {
        for transition in track.resolvedTransitions {
            if let left = transition.left { values[left.id, default: (0, 0)].tail = transition.after }
            if let right = transition.right { values[right.id, default: (0, 0)].head = transition.before }
        }
    }

    subscript(_ clipID: UUID) -> (head: Int64, tail: Int64) { values[clipID] ?? (0, 0) }
}

/// Spreads one timeline track's clips over as few composition tracks as possible: a clip
/// goes on the first track that's free for its whole range (handles included).
private final class TrackPacker {
    private let composition: AVMutableComposition
    private let mediaType: AVMediaType
    private var tracks: [(track: AVMutableCompositionTrack, end: Int64)] = []

    init(composition: AVMutableComposition, mediaType: AVMediaType) {
        self.composition = composition
        self.mediaType = mediaType
    }

    func track(for start: Int64, end: Int64) -> AVMutableCompositionTrack? {
        if let index = tracks.firstIndex(where: { $0.end <= start }) {
            tracks[index].end = end
            return tracks[index].track
        }
        guard let track = composition.addMutableTrack(withMediaType: mediaType,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        tracks.append((track, end))
        return track
    }
}

/// Clip gain, keyframed volume and fade ramps on an audio mix track.
enum AudioEnvelope {
    static func apply(_ clip: Clip, fades: ClipFades?, range: FrameRange,
                      to parameters: AVMutableAudioMixInputParameters, rate: FrameRate) {
        func time(_ frames: Double) -> CMTime {
            CMTime(seconds: frames / rate.framesPerSecond, preferredTimescale: 48_000)
        }
        let points = RenderPlan.audioEnvelope(for: clip, fades: fades, range: range, rate: rate)
        guard let first = points.first else { return }
        guard points.count > 1, points.contains(where: { $0.gain != first.gain }) else {
            // Volume holds until the next change, so one setting covers the clip.
            parameters.setVolume(Float(first.gain), at: time(first.frame))
            return
        }
        for (from, to) in zip(points, points.dropFirst()) where to.frame > from.frame {
            parameters.setVolumeRamp(fromStartVolume: Float(from.gain), toEndVolume: Float(to.gain),
                                     timeRange: CMTimeRange(start: time(from.frame), end: time(to.frame)))
        }
    }
}

extension Affine2D {
    init(_ transform: CGAffineTransform) {
        self.init(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: transform.tx, ty: transform.ty)
    }
}

extension CompositionBuilder {
    /// Clips following a tracked mask: their motion on each frame, worked out once per clip.
    static func followSamples(_ sequence: EditSequence, project: Project) -> [UUID: FollowSamples] {
        let settings = sequence.settings
        let pictureSize = { (clip: Clip) -> (width: Double, height: Double) in
            if !clip.isGenerated, let video = project.item(clip.mediaID)?.info.video, video.width > 0 {
                return (Double(video.width), Double(video.height))
            }
            return (Double(settings.width), Double(settings.height))
        }
        var follows: [UUID: FollowSamples] = [:]
        for clip in sequence.videoTracks.flatMap(\.clips) where clip.follow != nil {
            let transforms = (clip.start..<clip.end).map {
                sequence.followTransform(of: clip, atFrame: $0, pictureSize: pictureSize) ?? .identity
            }
            follows[clip.id] = FollowSamples(transforms: transforms, fps: sequence.rate.framesPerSecond)
        }
        return follows
    }
}
