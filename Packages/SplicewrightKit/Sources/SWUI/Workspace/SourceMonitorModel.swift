import AVFoundation
import Combine
import SWCore
import SWMedia

/// Playback state for the Source monitor: one clip, frame-accurate seeking, JKL shuttle.
///
/// AVPlayer handles decode and HDR presentation. The Program monitor gets its
/// own Metal-based pipeline with the playback engine (M3).
@MainActor
public final class SourceMonitorModel: ObservableObject {
    public let player = AVPlayer()

    @Published public private(set) var mediaID: UUID?
    @Published public private(set) var mediaName = ""
    @Published public private(set) var currentTime: RationalTime = .zero
    @Published public private(set) var duration: RationalTime = .zero
    @Published public private(set) var frameRate: FrameRate = .fps30
    @Published public private(set) var rate: Float = 0
    @Published public private(set) var hasVideo = false
    @Published public private(set) var waveform: WaveformPeaks?

    /// Plays the clip's proxy (video) with the original's audio, when a proxy exists.
    @Published public var useProxies = false {
        didSet { if useProxies != oldValue { reloadForProxies() } }
    }

    private var item: MediaItem?
    private var proxyTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var rateObservation: AnyCancellable?
    private var waveformTask: Task<Void, Never>?
    private var isScrubbing = false

    public init() {
        player.actionAtItemEnd = .pause
        rateObservation = player.publisher(for: \.rate)
            .receive(on: RunLoop.main)
            .sink { [weak self] rate in self?.rate = rate }
    }

    public var isPlaying: Bool { rate != 0 }

    /// Start of the frame currently displayed.
    public var currentFrameTime: RationalTime { currentTime.snapped(to: frameRate) }

    public var lastFrameTime: RationalTime {
        max(.zero, duration - frameRate.frameDuration).snapped(to: frameRate)
    }

    // MARK: - Loading

    public func load(_ item: MediaItem) {
        guard item.id != mediaID else { return }
        unload()
        mediaID = item.id
        mediaName = item.name
        duration = item.info.duration
        frameRate = item.info.displayFrameRate
        hasVideo = item.info.video != nil

        self.item = item
        let playerItem = AVPlayerItem(asset: AVURLAsset(url: item.url))
        player.replaceCurrentItem(with: playerItem)
        installTimeObserver()
        seek(to: item.marks.inPoint ?? .zero)
        if useProxies { reloadForProxies() }

        if !item.info.audio.isEmpty {
            let url = item.url
            waveformTask = Task { [weak self] in
                let peaks = await WaveformProvider.shared.peaks(for: url)
                guard !Task.isCancelled else { return }
                self?.waveform = peaks
            }
        }
    }

    /// Swaps between the original and a proxy composition, keeping the position.
    public func reloadForProxies() {
        proxyTask?.cancel()
        guard let item else { return }
        let proxy = useProxies ? ProxyStore.shared.proxy(for: item) : nil
        let time = currentTime
        proxyTask = Task { [weak self] in
            let asset: AVAsset = await Self.asset(for: item, proxy: proxy)
            guard !Task.isCancelled, let self, self.item?.id == item.id else { return }
            self.player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            self.seek(to: time)
        }
    }

    private static func asset(for item: MediaItem, proxy: URL?) async -> AVAsset {
        let original = AVURLAsset(url: item.url)
        guard let proxy else { return original }
        let composition = AVMutableComposition()
        do {
            let duration = try await original.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let video = try await AVURLAsset(url: proxy).loadTracks(withMediaType: .video).first,
               let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                // The proxy's own range: it may end a frame earlier than the original.
                let videoRange = try await video.load(.timeRange)
                try track.insertTimeRange(videoRange, of: video, at: videoRange.start)
                track.preferredTransform = try await video.load(.preferredTransform)
            }
            if let audio = try await original.loadTracks(withMediaType: .audio).first,
               let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try track.insertTimeRange(range, of: audio, at: .zero)
            }
            return composition
        } catch {
            return original
        }
    }

    public func unload() {
        proxyTask?.cancel()
        item = nil
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        waveformTask?.cancel()
        waveform = nil
        player.replaceCurrentItem(with: nil)
        mediaID = nil
        mediaName = ""
        currentTime = .zero
        duration = .zero
    }

    private func installTimeObserver() {
        let interval = frameRate.cmFrameDuration
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = RationalTime(time)
            }
        }
    }

    // MARK: - Transport

    public func togglePlay() {
        if isPlaying {
            pause()
        } else {
            if currentFrameTime >= lastFrameTime { seek(to: .zero) }
            player.rate = 1
        }
    }

    public func pause() {
        player.pause()
    }

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

    public func step(by frames: Int) {
        pause()
        let target = RationalTime(frames: currentFrameTime.frameIndex(at: frameRate) + Int64(frames), rate: frameRate)
        seek(to: target)
    }

    public func seekToLastFrame() {
        seek(to: lastFrameTime)
    }

    /// Frame-exact seek, clamped to the clip.
    public func seek(to time: RationalTime) {
        let clamped = min(max(time, .zero), lastFrameTime)
        currentTime = clamped
        player.seek(to: clamped.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Scrubbing

    public func beginScrub() {
        isScrubbing = true
        pause()
    }

    /// Scrubs to `fraction` (0...1) of the clip. Uses a loose tolerance while dragging so
    /// long-GOP HEVC stays responsive, then lands exactly on the frame when the drag ends.
    public func scrub(toFraction fraction: Double, final: Bool) {
        let seconds = min(max(fraction, 0), 1) * duration.seconds
        let target = min(RationalTime(seconds: seconds, timescale: frameRate.numerator).snapped(to: frameRate),
                         lastFrameTime)
        currentTime = target
        if final {
            isScrubbing = false
            seek(to: target)
        } else {
            let tolerance = CMTime(value: 1, timescale: 10)
            player.seek(to: target.cmTime, toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
    }
}
