import Foundation

/// How a clip's frames map to its source: at 100%, frame for frame; at a constant speed,
/// scaled (and backwards when reversed); with Time Remapping, by integrating the keyframed
/// speed over the clip. Offsets are seconds from `sourceStart`, which is always the source
/// time shown at the clip's first frame.
public struct ClipTiming: Sendable, Hashable {
    /// Constant speeds, as in Premiere's Speed/Duration (percent).
    public static let constantSpeedRange: ClosedRange<Double> = 1...10_000
    /// Time Remapping speeds (percent); 0 holds a frame.
    public static let remapSpeedRange: ClosedRange<Double> = 0...1_000

    public let sourceStart: RationalTime
    public let fps: Double
    public let duration: Int64
    public let isReversed: Bool
    /// Speed as a factor (1 is 100%) when not remapped.
    public let constantSpeed: Double
    /// With Time Remapping: the source offset at every frame boundary 0...duration.
    private let table: [Double]?
    private let firstSpeed: Double
    private let lastSpeed: Double

    public init(clip: Clip, rate: FrameRate) {
        sourceStart = clip.sourceStart
        fps = rate.framesPerSecond
        duration = clip.duration
        let speed = clip.speed
        if speed.isAnimated {
            isReversed = false
            constantSpeed = 1
            let fps = self.fps
            func factor(_ frame: Double) -> Double {
                let time = RationalTime(seconds: frame / fps, timescale: 600_000)
                return max(0, (speed.value(at: time).first ?? 100) / 100)
            }
            var offsets = [0.0]
            offsets.reserveCapacity(Int(clip.duration) + 1)
            for frame in 0..<max(1, clip.duration) {
                // The speed in the middle of each frame: exact for linear ramps, and a Hold
                // keyframe's step lands on its frame.
                offsets.append(offsets[offsets.count - 1] + factor(Double(frame) + 0.5) / fps)
            }
            table = offsets
            firstSpeed = factor(0)
            lastSpeed = factor(Double(clip.duration))
        } else {
            isReversed = clip.isReversed
            constantSpeed = min(max((speed.values.first ?? 100) / 100, Self.constantSpeedRange.lowerBound / 100),
                                Self.constantSpeedRange.upperBound / 100)
            table = nil
            firstSpeed = constantSpeed
            lastSpeed = constantSpeed
        }
    }

    /// 100%, forwards: source and sequence frames match exactly.
    public var isIdentity: Bool { table == nil && constantSpeed == 1 && !isReversed }
    /// Keyframed speed.
    public var isRemapped: Bool { table != nil }

    /// Source offset (seconds from `sourceStart`) at a fractional clip frame. Outside the clip,
    /// the speed at that end continues (for handles and trims).
    public func sourceOffset(atClipFrame position: Double) -> Double {
        guard let table else {
            let offset = position / fps * constantSpeed
            return isReversed ? -offset : offset
        }
        let last = table.count - 1
        if position <= 0 { return position * firstSpeed / fps }
        if position >= Double(last) { return table[last] + (position - Double(last)) * lastSpeed / fps }
        let index = Int(position)
        let fraction = position - Double(index)
        return table[index] + (table[index + 1] - table[index]) * fraction
    }

    /// The (fractional) clip frame showing a source offset; the inverse of `sourceOffset`.
    /// Infinite when the source is never reached (a held frame at the edge).
    public func clipFrame(atSourceOffset offset: Double) -> Double {
        guard let table else {
            let frames = offset * fps / constantSpeed
            return isReversed ? -frames : frames
        }
        let last = table.count - 1
        if offset <= 0 { return firstSpeed > 0 ? offset * fps / firstSpeed : (offset == 0 ? 0 : -.infinity) }
        if offset >= table[last] {
            return lastSpeed > 0 ? Double(last) + (offset - table[last]) * fps / lastSpeed
                : (offset == table[last] ? Double(last) : .infinity)
        }
        // Offsets never decrease (speed is never negative): binary search.
        var low = 0
        var high = last
        while high - low > 1 {
            let middle = (low + high) / 2
            if table[middle] <= offset { low = middle } else { high = middle }
        }
        let span = table[high] - table[low]
        return Double(low) + (span > 0 ? (offset - table[low]) / span : 0)
    }

    /// Seconds of source the clip plays (always positive).
    public var sourceSpan: Double { abs(sourceOffset(atClipFrame: Double(duration))) }

    /// The source time range the clip touches, earliest first.
    public var sourceRange: (lower: Double, upper: Double) {
        let start = sourceStart.seconds
        let end = start + sourceOffset(atClipFrame: Double(duration))
        return (min(start, end), max(start, end))
    }
}

public extension Clip {
    func timing(rate: FrameRate) -> ClipTiming {
        ClipTiming(clip: self, rate: rate)
    }

    /// Whether the clip plays at anything but 100% forwards.
    var isRetimed: Bool {
        speed.isAnimated || isReversed || (speed.values.first ?? 100) != 100
    }

    /// The constant speed in percent (Time Remapping keyframes aside).
    var speedPercent: Double { speed.values.first ?? 100 }

    /// Source time at a fractional sequence position.
    func sourceTime(atSequencePosition position: Double, rate: FrameRate) -> RationalTime {
        let offset = timing(rate: rate).sourceOffset(atClipFrame: position - Double(start))
        return sourceStart + RationalTime(seconds: offset, timescale: 600_000)
    }

    /// Where a keyframe of `property` goes for sequence frame `frame`: source time for most
    /// properties, time from the clip's start for Speed.
    func keyframeTime(for property: ClipProperty, atSequenceFrame frame: Int64, rate: FrameRate) -> RationalTime {
        property == .speed ? RationalTime(frames: frame - start, rate: rate) : sourceTime(atSequenceFrame: frame, rate: rate)
    }

    /// The sequence frame of a keyframe of `property`.
    func sequenceFrame(ofKeyframeTime time: RationalTime, for property: ClipProperty, rate: FrameRate) -> Int64 {
        property == .speed ? start + time.frameIndex(at: rate) : sequenceFrame(atSourceTime: time, rate: rate)
    }

    /// Moves the clip's start by `frames` (positive trims the head), keeping every later
    /// frame showing the same picture.
    mutating func moveStart(by frames: Int64, rate: FrameRate) {
        guard frames != 0 else { return }
        sourceStart = sourceTime(atSequenceFrame: start + frames, rate: rate)
        start += frames
        duration -= frames
        if speed.isAnimated { speed = speed.retimed(by: RationalTime(frames: -frames, rate: rate)) }
    }

    /// Timeline frames the start can extend left before the source runs out (`media` is the
    /// source duration, if known).
    func framesBefore(media: RationalTime?, rate: FrameRate) -> Int64 {
        let timing = timing(rate: rate)
        if timing.isIdentity { return max(0, sourceStart.frameIndex(at: rate)) }
        // Forwards, the earlier source is before `sourceStart`; reversed, it's after.
        let available: Double
        if timing.isReversed {
            guard let media else { return Int64(Int32.max) }
            available = max(0, (media - sourceStart).seconds)
        } else {
            available = max(0, sourceStart.seconds)
        }
        let position = timing.clipFrame(atSourceOffset: timing.isReversed ? available : -available)
        guard position.isFinite else { return Int64(Int32.max) }
        return max(0, Int64((-position + 1e-6).rounded(.down)))
    }

    /// The longest the clip can be before its source runs out, or nil if unknown.
    func maximumDuration(media: RationalTime?, rate: FrameRate) -> Int64? {
        let timing = timing(rate: rate)
        let available: Double
        if timing.isReversed {
            available = max(0, sourceStart.seconds)
        } else {
            guard let media else { return nil }
            if timing.isIdentity { return max(0, (media - sourceStart).frameIndex(at: rate)) }
            available = max(0, (media - sourceStart).seconds)
        }
        let position = timing.clipFrame(atSourceOffset: timing.isReversed ? -available : available)
        guard position.isFinite else { return nil }
        return max(0, Int64((position + 1e-6).rounded(.down)))
    }
}
