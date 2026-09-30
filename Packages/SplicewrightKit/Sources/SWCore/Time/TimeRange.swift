import Foundation

/// A half-open span of time: `[start, start + duration)`.
public struct TimeRange: Sendable, Hashable, Codable {
    public var start: RationalTime
    public var duration: RationalTime

    public init(start: RationalTime, duration: RationalTime) {
        self.start = start
        self.duration = duration
    }

    public init(start: RationalTime, end: RationalTime) {
        self.init(start: start, duration: end - start)
    }

    public var end: RationalTime { start + duration }
    public var isEmpty: Bool { duration.value <= 0 }

    public func contains(_ time: RationalTime) -> Bool {
        time >= start && time < end
    }

    public func clamping(_ time: RationalTime) -> RationalTime {
        min(max(time, start), end)
    }

    public func intersection(_ other: TimeRange) -> TimeRange? {
        let lower = max(start, other.start)
        let upper = min(end, other.end)
        return lower < upper ? TimeRange(start: lower, end: upper) : nil
    }
}
