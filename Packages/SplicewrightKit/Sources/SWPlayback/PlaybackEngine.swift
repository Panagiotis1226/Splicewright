import AVFoundation
import Combine
import SWCore
import SWMedia

/// Plays a sequence in the Program monitor. Edits trigger a debounced rebuild of the
/// composition; the playhead and play state survive rebuilds.
@MainActor
public final class PlaybackEngine: ObservableObject {
    public let player = AVPlayer()

    @Published public private(set) var currentFrame: Int64 = 0
    @Published public private(set) var durationFrames: Int64 = 0
    @Published public private(set) var rate: Float = 0
    @Published public private(set) var droppedFrames = 0
    @Published public private(set) var isBuilding = false
    /// The Mix's left/right peak levels (linear, 1 = 0 dBFS), measured as it plays.
    @Published public private(set) var meterLevels: [Float] = [0, 0]
    /// Each audio track's left/right peak levels after its fader, by track ID.
    @Published public private(set) var trackMeterLevels: [UUID: [Float]] = [:]
    @Published public var renderScale: Double = 1 {
        didSet { if renderScale != oldValue { scheduleRebuild(immediately: true) } }
    }
    /// Highlights clipped or out-of-gamut pixels in the Program monitor.
    @Published public var showsClipping = false {
        didSet { if showsClipping != oldValue { scheduleRebuild(immediately: true) } }
    }
    /// Plays proxies where clips have them.
    @Published public var useProxies = false {
        didSet { if useProxies != oldValue { scheduleRebuild(immediately: true) } }
    }

    public private(set) var frameRate: FrameRate = .fps30
    private var sequence: EditSequence?
    private var project = Project()
    private let cache = MediaAssetCache()
    private var buildTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var rateObservation: AnyCancellable?
    private var mixer: MixerLevels?
    private var meters: AudioMeters?
    private var pendingSeekFrame: Int64?
    private var tick = 0

    public init() {
        player.actionAtItemEnd = .pause
        rateObservation = player.publisher(for: \.rate)
            .receive(on: RunLoop.main)
            .sink { [weak self] rate in
                self?.rate = rate
                if rate == 0 {
                    self?.meterLevels = [0, 0]
                    self?.trackMeterLevels = [:]
                }
            }
    }

    public var isPlaying: Bool { rate != 0 }

    // MARK: - Sequence updates

    /// Call whenever the project changes. Rebuilds only if something that affects the
    /// rendered result changed.
    public func update(sequence newSequence: EditSequence?, project newProject: Project) {
        let previous = sequence
        let sequenceChanged = previous != newSequence
        let mediaChanged = newProject.media != project.media
        project = newProject
        sequence = newSequence
        guard sequenceChanged || mediaChanged else { return }
        // Faders and pan are read live by the audio taps: no rebuild for those.
        if !mediaChanged, let previous, let newSequence, previous.id == newSequence.id,
           Self.withoutMixer(previous) == Self.withoutMixer(newSequence), let mixer {
            mixer.update(from: newSequence)
            return
        }
        if previous?.id != newSequence?.id {
            currentFrame = 0
            pendingSeekFrame = 0
        }
        frameRate = newSequence?.rate ?? .fps30
        // Known from the model right away, so seeks made before the rebuild lands clamp correctly.
        durationFrames = max(newSequence?.durationFrames ?? 0, newSequence == nil ? 0 : 1)
        scheduleRebuild(immediately: previous?.id != newSequence?.id)
    }

    /// The sequence with its mixer settings at their defaults, to tell mixer-only changes apart.
    private static func withoutMixer(_ sequence: EditSequence) -> EditSequence {
        var copy = sequence
        copy.mixVolumeDB = 0
        for index in copy.audioTracks.indices {
            copy.audioTracks[index].volumeDB = 0
            copy.audioTracks[index].pan = 0
        }
        return copy
    }

    /// Rebuilds after proxies or caches change outside the project (e.g. a proxy finished).
    public func refresh() {
        scheduleRebuild(immediately: true)
    }

    private func scheduleRebuild(immediately: Bool) {
        buildTask?.cancel()
        guard let sequence else {
            player.replaceCurrentItem(with: nil)
            durationFrames = 0
            return
        }
        let project = self.project
        let cache = self.cache
        let builder = CompositionBuilder(renderScale: renderScale, overlay: showsClipping ? .clipping : .none,
                                         useProxies: useProxies)
        isBuilding = true
        buildTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 120_000_000) }
            guard !Task.isCancelled else { return }
            let output = await builder.build(sequence, project: project, cache: cache)
            guard !Task.isCancelled, let self else { return }
            self.install(output)
        }
    }

    private func install(_ output: CompositionOutput) {
        let resumeRate = player.rate
        let frame = pendingSeekFrame ?? currentFrame
        pendingSeekFrame = nil
        let item = AVPlayerItem(asset: output.composition)
        item.audioTimePitchAlgorithm = output.audioTimePitchAlgorithm
        item.videoComposition = output.videoComposition
        item.audioMix = output.audioMix
        mixer = output.mixer
        meters = output.meters
        if let sequence { mixer?.update(from: sequence) }
        item.seekingWaitsForVideoCompositionRendering = true
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        player.replaceCurrentItem(with: item)
        durationFrames = output.durationFrames
        isBuilding = false
        installTimeObserver()
        seek(toFrame: frame)
        if resumeRate != 0 { player.rate = resumeRate }
    }

    private func installTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: frameRate.cmFrameDuration, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentFrame = RationalTime(time).frameIndex(at: self.frameRate)
                self.updateMeters()
                self.tick += 1
                if self.tick % 30 == 0 {
                    self.droppedFrames = self.player.currentItem?.accessLog()?.events.last?.numberOfDroppedVideoFrames ?? 0
                }
            }
        }
    }

    // MARK: - Transport

    public func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if currentFrame >= durationFrames - 1 { seek(toFrame: 0) }
            player.rate = 1
        }
    }

    public func pause() { player.pause() }

    public func shuttleForward() {
        player.rate = Shuttle.rate(afterForwardFrom: player.rate)
    }

    public func shuttleReverse() {
        guard player.currentItem?.canPlayReverse == true else {
            step(by: -1)
            return
        }
        player.rate = Shuttle.rate(afterReverseFrom: player.rate)
    }

    public func step(by frames: Int64) {
        player.pause()
        seek(toFrame: currentFrame + frames)
    }

    /// Frame-exact seek, clamped to the sequence.
    public func seek(toFrame frame: Int64) {
        let clamped = min(max(frame, 0), max(durationFrames - 1, 0))
        currentFrame = clamped
        guard player.currentItem != nil, !isBuilding else {
            pendingSeekFrame = clamped
            return
        }
        let time = RationalTime(frames: clamped, rate: frameRate).cmTime
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Loose seek for scrubbing: keeps up with the mouse on long-GOP media.
    public func scrub(toFrame frame: Int64) {
        let clamped = min(max(frame, 0), max(durationFrames - 1, 0))
        currentFrame = clamped
        let time = RationalTime(frames: clamped, rate: frameRate).cmTime
        let tolerance = frameRate.cmFrameDuration
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    // MARK: - Meters

    private func updateMeters() {
        guard isPlaying, let meters else { return }
        let levels = meters.read()
        meterLevels = levels.mix
        trackMeterLevels = levels.tracks
    }
}
