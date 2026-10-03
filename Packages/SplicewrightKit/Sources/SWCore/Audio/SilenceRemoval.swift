import Foundation

/// How Remove Silence decides what's a pause.
public struct SilenceSettings: Sendable, Hashable, Codable {
    /// Quieter than this (dBFS, measured over 20 ms) counts as silence.
    public var thresholdDB: Double
    /// Pauses shorter than this stay.
    public var minimumSeconds: Double
    /// Kept on each side of a pause, so words don't run into each other.
    public var paddingSeconds: Double

    public init(thresholdDB: Double = -42, minimumSeconds: Double = 0.5, paddingSeconds: Double = 0.15) {
        self.thresholdDB = thresholdDB
        self.minimumSeconds = minimumSeconds
        self.paddingSeconds = paddingSeconds
    }

    public static let thresholdRange: ClosedRange<Double> = -70 ... -15
    public static let minimumRange: ClosedRange<Double> = 0.1...5
    public static let paddingRange: ClosedRange<Double> = 0...1
}

/// Finds pauses in audio fed to it in buffers: the level of each 20 ms window (both channels
/// together), then runs of windows under the threshold that last long enough, less the padding.
public struct SilenceDetector: Sendable {
    public let sampleRate: Double
    public let settings: SilenceSettings
    private let window: Int
    private var sum = 0.0
    private var count = 0
    /// Mean square per window.
    private var levels: [Double] = []

    public init(sampleRate: Double, settings: SilenceSettings) {
        self.sampleRate = sampleRate
        self.settings = settings
        window = max(1, Int((sampleRate * 0.02).rounded()))
    }

    public mutating func process(_ channels: [[Float]]) {
        guard let frames = channels.first?.count, !channels.isEmpty else { return }
        for frame in 0..<frames {
            var square = 0.0
            for channel in channels where frame < channel.count { square += Double(channel[frame] * channel[frame]) }
            sum += square / Double(channels.count)
            count += 1
            if count == window {
                levels.append(sum / Double(window))
                (sum, count) = (0, 0)
            }
        }
    }

    /// Seconds analysed so far.
    public var duration: Double { Double(levels.count * window + count) / sampleRate }

    /// The pauses, in seconds from the start of what was fed in, shortened by the padding (except
    /// at the very start and end, where there's nothing to keep a gap from).
    public func silences() -> [ClosedRange<Double>] {
        let threshold = pow(10, settings.thresholdDB / 10)
        let step = Double(window) / sampleRate
        let total = duration
        var found: [ClosedRange<Double>] = []
        var runStart: Int?
        for index in 0...levels.count {
            let quiet = index < levels.count && levels[index] < threshold
            if quiet, runStart == nil { runStart = index }
            guard !quiet, let first = runStart else { continue }
            runStart = nil
            let start = Double(first) * step
            let end = index == levels.count ? total : Double(index) * step
            guard end - start >= settings.minimumSeconds else { continue }
            let padded = (start <= 0 ? start : start + settings.paddingSeconds)
                ... (index == levels.count ? end : end - settings.paddingSeconds)
            if padded.upperBound > padded.lowerBound { found.append(padded) }
        }
        return found
    }
}

public extension EditSequence {
    /// Pauses found from sequence frame `origin` on, as whole frames (pauses shorter than a frame drop out).
    static func frameRanges(_ silences: [ClosedRange<Double>], from origin: Int64, rate: FrameRate) -> [FrameRange] {
        silences.compactMap { silence in
            let start = origin + Int64((silence.lowerBound * rate.framesPerSecond).rounded(.up))
            let end = origin + Int64((silence.upperBound * rate.framesPerSecond).rounded(.down))
            return end > start ? FrameRange(start: start, end: end) : nil
        }
    }

    /// Takes `ranges` out of every unlocked track and closes the gaps, moving captions and markers
    /// with the cut (one inside a range moves to where it was cut). Returns how many frames went.
    @discardableResult
    mutating func rippleRemove(_ ranges: [FrameRange]) -> Int64 {
        let tracks = Set(allTracks.filter { !$0.isLocked }.map(\.id))
        var removed: Int64 = 0
        for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.start > $1.start }) {
            extract(range, trackIDs: tracks)
            func moved(_ frame: Int64) -> Int64 {
                frame <= range.start ? frame : (frame >= range.end ? frame - range.length : range.start)
            }
            for index in captionTracks.indices where !captionTracks[index].isLocked {
                captionTracks[index].captions = captionTracks[index].captions.compactMap { caption in
                    let (start, end) = (moved(caption.start), moved(caption.end))
                    guard end > start else { return nil }
                    var cut = caption
                    cut.start = start
                    cut.duration = end - start
                    cut.words = caption.words.compactMap { word in
                        let (from, to) = (moved(word.start), moved(word.end))
                        return to > from ? CaptionWord(text: word.text, start: from, duration: to - from) : nil
                    }
                    return cut
                }
            }
            for index in markers.indices {
                let end = moved(markers[index].frame + markers[index].duration)
                markers[index].frame = moved(markers[index].frame)
                markers[index].duration = max(0, end - markers[index].frame)
            }
            removed += range.length
        }
        return removed
    }

    /// Cuts every unlocked track at each range's edges, leaving the pauses as clips of their own to
    /// review. Returns those clips.
    mutating func cutAtRanges(_ ranges: [FrameRange]) -> Set<UUID> {
        let tracks = Set(allTracks.filter { !$0.isLocked }.map(\.id))
        for range in ranges where !range.isEmpty {
            razor(at: range.start, trackIDs: tracks)
            razor(at: range.end, trackIDs: tracks)
        }
        return Set(allTracks.filter { tracks.contains($0.id) }.flatMap(\.clips).filter { clip in
            ranges.contains { clip.start >= $0.start && clip.end <= $0.end }
        }.map(\.id))
    }
}
