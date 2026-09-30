import Foundation

/// An exact point in time expressed as `value / timescale` seconds.
///
/// Mirrors `CMTime`'s representation (Int64 value, Int32 timescale) so that
/// bridging is lossless, but lives in SWCore so the editing model has no
/// dependency on CoreMedia and can be tested on any platform.
public struct RationalTime: Sendable, Hashable, Codable {
    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32) {
        precondition(timescale > 0, "RationalTime timescale must be positive")
        self.value = value
        self.timescale = timescale
    }

    public static let zero = RationalTime(value: 0, timescale: 1)

    /// The time at which frame `frames` starts, at `rate`.
    public init(frames: Int64, rate: FrameRate) {
        self.init(value: frames * Int64(rate.denominator), timescale: rate.numerator)
    }

    /// Approximates `seconds` at the given timescale, rounding to the nearest unit.
    public init(seconds: Double, timescale: Int32) {
        self.init(value: Int64((seconds * Double(timescale)).rounded()), timescale: timescale)
    }

    public var seconds: Double { Double(value) / Double(timescale) }

    /// The index of the frame that contains this time at `rate`.
    /// Times before zero belong to negative frame indices (floor semantics).
    public func frameIndex(at rate: FrameRate) -> Int64 {
        // frames = value * num / (timescale * den), floored. Use full width to avoid overflow.
        let numerator = value.multipliedFullWidth(by: Int64(rate.numerator))
        let divisor = Int64(timescale) * Int64(rate.denominator)
        return Self.floorDivide(high: numerator.high, low: numerator.low, by: divisor)
    }

    /// Snaps to the start of the containing frame at `rate`, expressed in that rate's timescale.
    public func snapped(to rate: FrameRate) -> RationalTime {
        RationalTime(frames: frameIndex(at: rate), rate: rate)
    }

    /// Re-expresses this time in `newTimescale`, rounding toward negative infinity.
    public func converted(toTimescale newTimescale: Int32) -> RationalTime {
        if newTimescale == timescale { return self }
        let product = value.multipliedFullWidth(by: Int64(newTimescale))
        let newValue = Self.floorDivide(high: product.high, low: product.low, by: Int64(timescale))
        return RationalTime(value: newValue, timescale: newTimescale)
    }

    // MARK: - Helpers

    static func floorDivide(high: Int64, low: UInt64, by divisor: Int64) -> Int64 {
        precondition(divisor > 0)
        let (quotient, remainder) = divisor.dividingFullWidth((high: high, low: low))
        return (remainder != 0 && (remainder < 0)) ? quotient - 1 : quotient
    }

    static func gcd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        var (a, b) = (abs(lhs), abs(rhs))
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    /// A timescale both operands can be expressed in exactly, or the larger of
    /// the two when the least common multiple does not fit in Int32.
    static func commonTimescale(_ lhs: Int32, _ rhs: Int32) -> Int32 {
        if lhs == rhs { return lhs }
        let lcm = Int64(lhs) / gcd(Int64(lhs), Int64(rhs)) * Int64(rhs)
        return lcm <= Int64(Int32.max) ? Int32(lcm) : max(lhs, rhs)
    }
}

extension RationalTime: Comparable {
    public static func < (lhs: RationalTime, rhs: RationalTime) -> Bool {
        compare(lhs, rhs) < 0
    }

    public static func == (lhs: RationalTime, rhs: RationalTime) -> Bool {
        compare(lhs, rhs) == 0
    }

    public func hash(into hasher: inout Hasher) {
        // Equal times with different timescales must hash identically, so hash the reduced fraction.
        let divisor = Self.gcd(value, Int64(timescale))
        hasher.combine(divisor == 0 ? 0 : value / divisor)
        hasher.combine(divisor == 0 ? 1 : Int64(timescale) / divisor)
    }

    private static func compare(_ lhs: RationalTime, _ rhs: RationalTime) -> Int {
        let left = lhs.value.multipliedFullWidth(by: Int64(rhs.timescale))
        let right = rhs.value.multipliedFullWidth(by: Int64(lhs.timescale))
        if left.high != right.high { return left.high < right.high ? -1 : 1 }
        if left.low != right.low { return left.low < right.low ? -1 : 1 }
        return 0
    }
}

extension RationalTime: AdditiveArithmetic {
    public static func + (lhs: RationalTime, rhs: RationalTime) -> RationalTime {
        let scale = commonTimescale(lhs.timescale, rhs.timescale)
        let a = lhs.converted(toTimescale: scale)
        let b = rhs.converted(toTimescale: scale)
        return RationalTime(value: a.value + b.value, timescale: scale)
    }

    public static func - (lhs: RationalTime, rhs: RationalTime) -> RationalTime {
        let scale = commonTimescale(lhs.timescale, rhs.timescale)
        let a = lhs.converted(toTimescale: scale)
        let b = rhs.converted(toTimescale: scale)
        return RationalTime(value: a.value - b.value, timescale: scale)
    }
}

extension RationalTime: CustomStringConvertible {
    public var description: String { "\(value)/\(timescale)s" }
}
