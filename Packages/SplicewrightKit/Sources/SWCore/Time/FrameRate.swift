import Foundation

/// A video frame rate expressed as an exact ratio, e.g. 30000/1001 for 29.97 fps.
public struct FrameRate: Sendable, Hashable, Codable {
    /// Frames per `denominator` seconds.
    public let numerator: Int32
    public let denominator: Int32

    public init(numerator: Int32, denominator: Int32 = 1) {
        precondition(numerator > 0 && denominator > 0, "FrameRate components must be positive")
        self.numerator = numerator
        self.denominator = denominator
    }

    public static let fps23_976 = FrameRate(numerator: 24000, denominator: 1001)
    public static let fps24 = FrameRate(numerator: 24)
    public static let fps25 = FrameRate(numerator: 25)
    public static let fps29_97 = FrameRate(numerator: 30000, denominator: 1001)
    public static let fps30 = FrameRate(numerator: 30)
    public static let fps50 = FrameRate(numerator: 50)
    public static let fps59_94 = FrameRate(numerator: 60000, denominator: 1001)
    public static let fps60 = FrameRate(numerator: 60)
    public static let fps100 = FrameRate(numerator: 100)
    public static let fps119_88 = FrameRate(numerator: 120_000, denominator: 1001)
    public static let fps120 = FrameRate(numerator: 120)

    /// The frame rates Splicewright offers for sequences and export, up to iPhone slow motion's 120.
    public static let standard: [FrameRate] = [
        .fps23_976, .fps24, .fps25, .fps29_97, .fps30, .fps50, .fps59_94, .fps60, .fps100, .fps119_88, .fps120,
    ]

    public var framesPerSecond: Double { Double(numerator) / Double(denominator) }

    /// Duration of one frame.
    public var frameDuration: RationalTime {
        RationalTime(value: Int64(denominator), timescale: numerator)
    }

    /// Integer frame count per timecode second (30 for 29.97, 24 for 23.976).
    public var timecodeBase: Int {
        Int(framesPerSecond.rounded())
    }

    /// Drop-frame timecode only exists for the NTSC 29.97 and 59.94 rates.
    public var supportsDropFrame: Bool {
        denominator == 1001 && (numerator == 30000 || numerator == 60000)
    }

    /// Matches a measured rate (such as `AVAssetTrack.nominalFrameRate`) to the
    /// closest standard rate within `tolerance` (relative), or nil if none is close.
    public static func nearestStandard(to fps: Double, tolerance: Double = 0.005) -> FrameRate? {
        guard fps.isFinite, fps > 0 else { return nil }
        let best = standard.min { abs($0.framesPerSecond - fps) < abs($1.framesPerSecond - fps) }
        guard let best, abs(best.framesPerSecond - fps) / best.framesPerSecond <= tolerance else {
            return nil
        }
        return best
    }

    /// The standard rate whose frame lasts exactly `value / timescale` seconds, if any.
    /// A track's minimum frame duration is exact, whereas its nominal rate is an
    /// average that can be off noticeably for short clips.
    public static func standard(matchingFrameDuration value: Int64, timescale: Int32) -> FrameRate? {
        guard value > 0, timescale > 0 else { return nil }
        let duration = RationalTime(value: value, timescale: timescale)
        return standard.first { $0.frameDuration == duration }
    }

    /// Chooses a track's frame rate from its measured nominal rate and its minimum frame
    /// duration. The duration is exact but can be quantized: a 600-tick timescale can't
    /// represent 29.97 fps, so such a file reports 1/30 s. It is trusted when it names an
    /// NTSC rate (only a fine timescale can) or agrees with the nominal rate.
    public static func resolve(nominalFPS: Double, minFrameDuration value: Int64, timescale: Int32) -> FrameRate? {
        let nominal = nearestStandard(to: nominalFPS)
        if let exact = standard(matchingFrameDuration: value, timescale: timescale),
           exact.denominator == 1001 || exact == nominal {
            return exact
        }
        return nominal ?? approximating(nominalFPS)
    }

    /// A rational approximation for non-standard rates, in thousandths of a frame.
    public static func approximating(_ fps: Double) -> FrameRate? {
        if let standard = nearestStandard(to: fps) { return standard }
        guard fps.isFinite, fps > 0, fps < 10_000 else { return nil }
        let thousandths = Int32((fps * 1000).rounded())
        guard thousandths > 0 else { return nil }
        let divisor = Int32(RationalTime.gcd(Int64(thousandths), 1000))
        return FrameRate(numerator: thousandths / divisor, denominator: 1000 / divisor)
    }

    /// "29.97", "59.94", "23.976", "30".
    public var displayName: String {
        if denominator == 1 { return "\(numerator)" }
        let fps = framesPerSecond
        var text = String(format: "%.3f", fps)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

public enum FrameRateAnalysis {
    /// Heuristic for variable-frame-rate media (typical of phone recordings):
    /// the shortest frame duration implies a rate noticeably above the nominal one.
    public static func isVariable(nominalFPS: Double, minFrameDurationSeconds: Double) -> Bool {
        guard nominalFPS > 0, minFrameDurationSeconds > 0, minFrameDurationSeconds.isFinite else {
            return false
        }
        let peakFPS = 1.0 / minFrameDurationSeconds
        return peakFPS > nominalFPS * 1.05
    }
}
