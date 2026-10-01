import AppKit
import Combine
import SWCore
import SWMedia

/// View state for the Timeline panel: selection, zoom, scroll, snapping, and the preview
/// shown while a drag is in progress (committed to the document on mouse-up).
@MainActor
public final class TimelineState: ObservableObject {
    @Published public var selection: Set<UUID> = [] {
        didSet { if !selection.isEmpty { selectedTransition = nil } }
    }
    /// The selected transition (selecting one clears the clip selection, and vice versa).
    @Published public var selectedTransition: UUID?
    /// Horizontal zoom.
    @Published public var pixelsPerFrame: CGFloat = 3
    /// Horizontal scroll offset of frame 0, in points.
    @Published public var scrollX: CGFloat = 0
    @Published public var scrollY: CGFloat = 0
    @Published public var isSnapping = true
    /// Keyframes and the Opacity/Volume line on clips (Premiere's Timeline Display Settings).
    @Published public var showsVideoKeyframes = true
    @Published public var showsAudioKeyframes = true
    /// Keyframes selected on the timeline (Delete removes them).
    @Published public var selectedKeyframes: Set<UUID> = []
    /// The sequence being dragged; drawn instead of the document's sequence.
    @Published public var preview: EditSequence?
    /// Where the current drag snapped, for the snap line.
    @Published public var snapFrame: Int64?
    /// Frame and track under a Project-panel drag, for the drop indicator.
    @Published public var dropTarget: DropTarget?

    public struct DropTarget: Equatable {
        public var frame: Int64
        public var trackID: UUID
        public var length: Int64
        /// Set for an Effects-panel transition drop: `frame...frame+length` is its would-be range.
        public var transition: TransitionKind?
    }

    public static let minPixelsPerFrame: CGFloat = 0.02
    public static let maxPixelsPerFrame: CGFloat = 40

    private var waveforms: [UUID: WaveformPeaks] = [:]
    private var thumbnails: [UUID: CGImage] = [:]
    // Each item is loaded at most once per session, whether or not loading succeeds.
    private var attemptedWaveforms: Set<UUID> = []
    private var attemptedThumbnails: Set<UUID> = []
    private var cacheObserver: AnyCancellable?

    public init() {
        // After the cache manager deletes artwork, load it again (which rebuilds the files).
        cacheObserver = NotificationCenter.default.publisher(for: .splicewrightCacheCleared)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                let categories = note.userInfo?["categories"] as? [String] ?? []
                self?.clearArtwork(thumbnails: categories.contains(CacheCategory.thumbnails.rawValue),
                                   waveforms: categories.contains(CacheCategory.waveforms.rawValue))
            }
    }

    func clearArtwork(thumbnails clearThumbnails: Bool, waveforms clearWaveforms: Bool) {
        if clearThumbnails {
            thumbnails = [:]
            attemptedThumbnails = []
        }
        if clearWaveforms {
            waveforms = [:]
            attemptedWaveforms = []
        }
        if clearThumbnails || clearWaveforms { objectWillChange.send() }
    }

    public func zoom(by factor: CGFloat, anchorX: CGFloat, headerWidth: CGFloat) {
        let old = pixelsPerFrame
        let new = min(max(old * factor, Self.minPixelsPerFrame), Self.maxPixelsPerFrame)
        // Keep the frame under the anchor in place.
        let frameAtAnchor = (anchorX - headerWidth + scrollX) / old
        pixelsPerFrame = new
        scrollX = max(0, frameAtAnchor * new - (anchorX - headerWidth))
    }

    public func zoomToFit(durationFrames: Int64, laneWidth: CGFloat) {
        guard durationFrames > 0, laneWidth > 40 else { return }
        pixelsPerFrame = min(max((laneWidth - 20) / CGFloat(durationFrames), Self.minPixelsPerFrame),
                             Self.maxPixelsPerFrame)
        scrollX = 0
    }

    // MARK: - Clip artwork

    func waveform(for item: MediaItem) -> WaveformPeaks? {
        if let peaks = waveforms[item.id] { return peaks }
        guard !item.info.audio.isEmpty, MediaLocator.isOnline(item),
              attemptedWaveforms.insert(item.id).inserted else { return nil }
        Task { @MainActor [weak self] in
            guard let peaks = await WaveformProvider.shared.peaks(for: item.url) else { return }
            self?.waveforms[item.id] = peaks
            self?.objectWillChange.send()
        }
        return nil
    }

    func thumbnail(for item: MediaItem) -> CGImage? {
        if let image = thumbnails[item.id] { return image }
        guard item.info.video != nil, MediaLocator.isOnline(item),
              attemptedThumbnails.insert(item.id).inserted else { return nil }
        Task { @MainActor [weak self] in
            guard let image = await ThumbnailProvider.shared.thumbnail(for: item.url, at: 0, maxPixels: 160) else { return }
            self?.thumbnails[item.id] = image
            self?.objectWillChange.send()
        }
        return nil
    }
}
