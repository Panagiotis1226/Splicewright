import Foundation

/// Reference implementations of the transfer functions the Metal compositor uses.
///
/// The compositor's working space is linear-light Rec.2020 scaled so 1.0 is SDR reference
/// white, which BT.2408 places at 203 cd/m² in HDR. The shader in SWPlayback mirrors these
/// functions; the tests pin their values.
public enum TransferFunctions {
    public static let referenceWhiteNits = 203.0
    public static let hlgPeakNits = 1000.0

    // MARK: PQ (SMPTE ST 2084)

    private static let m1 = 2610.0 / 16384
    private static let m2 = 2523.0 / 4096 * 128
    private static let c1 = 3424.0 / 4096
    private static let c2 = 2413.0 / 4096 * 32
    private static let c3 = 2392.0 / 4096 * 32

    /// Signal (0...1) → absolute luminance in nits.
    public static func pqToNits(_ signal: Double) -> Double {
        let p = pow(max(signal, 0), 1 / m2)
        return 10_000 * pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    /// Absolute luminance in nits → signal (0...1).
    public static func nitsToPQ(_ nits: Double) -> Double {
        let y = pow(min(max(nits, 0), 10_000) / 10_000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    // MARK: HLG (BT.2100)

    private static let hlgA = 0.17883277
    private static let hlgB = 1 - 4 * 0.17883277
    private static let hlgC = 0.5 - 0.17883277 * log(4 * 0.17883277)

    /// Inverse OETF: signal → normalized scene light (0...1).
    public static func hlgToScene(_ signal: Double) -> Double {
        let e = max(signal, 0)
        return e <= 0.5 ? e * e / 3 : (exp((e - hlgC) / hlgA) + hlgB) / 12
    }

    /// OETF: normalized scene light → signal.
    public static func sceneToHLG(_ scene: Double) -> Double {
        let e = max(scene, 0)
        return e <= 1.0 / 12 ? sqrt(3 * e) : hlgA * log(12 * e - hlgB) + hlgC
    }

    /// HLG system gamma for a display of `peakNits` (1.2 at 1000 nits).
    public static func hlgSystemGamma(peakNits: Double = hlgPeakNits) -> Double {
        1.2 + 0.42 * log10(peakNits / 1000)
    }

    /// HLG signal for a neutral (grey) pixel → display nits, including the OOTF.
    public static func hlgGreyToNits(_ signal: Double) -> Double {
        let scene = hlgToScene(signal)
        return hlgPeakNits * pow(scene, hlgSystemGamma())
    }

    // MARK: SDR (BT.1886 with a 2.4 gamma)

    public static func sdrToLinear(_ signal: Double) -> Double { pow(max(signal, 0), 2.4) }
    public static func linearToSDR(_ linear: Double) -> Double { pow(min(max(linear, 0), 1), 1 / 2.4) }
}
