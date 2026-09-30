import Foundation

/// SMPTE timecode (HH:MM:SS:FF), with drop-frame support for 29.97 and 59.94.
///
/// Display follows Premiere Pro: non-drop uses colons (`00:00:00:00`),
/// drop-frame uses semicolons (`00;00;00;00`).
public struct Timecode: Sendable, Hashable {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int
    public var isDropFrame: Bool

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int, isDropFrame: Bool) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.isDropFrame = isDropFrame
    }

    /// Timecode for a zero-based frame count. Negative counts clamp to zero.
    /// `dropFrame` defaults to drop-frame wherever the rate supports it.
    public init(frame: Int64, rate: FrameRate, dropFrame: Bool? = nil) {
        let useDrop = (dropFrame ?? rate.supportsDropFrame) && rate.supportsDropFrame
        let base = Int64(rate.timecodeBase)
        var count = max(0, frame)

        if useDrop {
            // Drop 2 (29.97) or 4 (59.94) frame numbers at the start of every
            // minute except each tenth minute.
            let drop = base / 15
            let framesPerMinute = base * 60 - drop
            let framesPer10Minutes = base * 600 - drop * 9
            let tens = count / framesPer10Minutes
            let remainder = count % framesPer10Minutes
            count += drop * 9 * tens
            if remainder > drop {
                count += drop * ((remainder - drop) / framesPerMinute)
            }
        }

        self.init(
            hours: Int(count / (base * 3600)),
            minutes: Int((count / (base * 60)) % 60),
            seconds: Int((count / base) % 60),
            frames: Int(count % base),
            isDropFrame: useDrop
        )
    }

    public init(time: RationalTime, rate: FrameRate, dropFrame: Bool? = nil) {
        self.init(frame: time.frameIndex(at: rate), rate: rate, dropFrame: dropFrame)
    }

    /// The zero-based frame count this timecode represents at `rate`.
    public func frameNumber(rate: FrameRate) -> Int64 {
        let base = Int64(rate.timecodeBase)
        let totalMinutes = Int64(hours) * 60 + Int64(minutes)
        var result = (Int64(hours) * 3600 + Int64(minutes) * 60 + Int64(seconds)) * base + Int64(frames)
        if isDropFrame && rate.supportsDropFrame {
            let drop = base / 15
            result -= drop * (totalMinutes - totalMinutes / 10)
        }
        return result
    }

    /// Parses "HH:MM:SS:FF" or "HH;MM;SS;FF" (any `;` marks drop-frame).
    public init?(string: String, rate: FrameRate) {
        let isDrop = string.contains(";")
        let parts = string.split(whereSeparator: { $0 == ":" || $0 == ";" }).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        guard values[1] < 60, values[2] < 60, values[3] < rate.timecodeBase, values.allSatisfy({ $0 >= 0 }) else {
            return nil
        }
        self.init(hours: values[0], minutes: values[1], seconds: values[2], frames: values[3],
                  isDropFrame: isDrop && rate.supportsDropFrame)
    }
}

extension Timecode: CustomStringConvertible {
    public var description: String {
        let separator = isDropFrame ? ";" : ":"
        return [hours, minutes, seconds, frames]
            .map { String(format: "%02d", $0) }
            .joined(separator: separator)
    }
}
