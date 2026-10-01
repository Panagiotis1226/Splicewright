import Foundation

/// Export loudness normalization targets, with true peak limited to `truePeakCeiling`.
public enum LoudnessTarget: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case streaming, podcast, broadcast

    public static let truePeakCeiling = -1.0

    public var id: String { rawValue }

    /// Integrated loudness in LUFS.
    public var lufs: Double {
        switch self {
        case .streaming: return -14
        case .podcast: return -16
        case .broadcast: return -23
        }
    }

    public var displayName: String {
        switch self {
        case .streaming: return "-14 LUFS (YouTube, Spotify)"
        case .podcast: return "-16 LUFS (Apple Podcasts)"
        case .broadcast: return "-23 LUFS (EBU R128 broadcast)"
        }
    }
}

/// Integrated loudness (ITU-R BS.1770-4 / EBU R128) and true peak, fed buffer by buffer.
/// Channels are weighted equally (mono and stereo; no surround weights).
public struct LoudnessMeter: Sendable {
    public let sampleRate: Double
    public let channels: Int

    private var filters: [(shelf: Biquad, highPass: Biquad)]
    /// Sum of K-weighted squares per channel in the 100 ms step being filled.
    private var stepEnergy: [Double]
    private var stepFill = 0
    private let stepLength: Int
    /// Finished 100 ms steps: the mean square summed over channels.
    private var steps: [Double] = []
    private var oversampler: [TruePeakOversampler]
    private var peak = 0.0
    private var samplePeak = 0.0

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = max(channels, 1)
        filters = Array(repeating: Self.kWeighting(sampleRate: sampleRate), count: self.channels)
        stepEnergy = Array(repeating: 0, count: self.channels)
        stepLength = max(1, Int((sampleRate / 10).rounded()))
        oversampler = Array(repeating: TruePeakOversampler(), count: self.channels)
    }

    /// The two K-weighting stages for any sample rate (libebur128's derivation of the
    /// BS.1770 48 kHz coefficients).
    static func kWeighting(sampleRate: Double) -> (shelf: Biquad, highPass: Biquad) {
        var f0 = 1681.974450955533
        let gainDB = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(.pi * f0 / sampleRate)
        let vh = pow(10, gainDB / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(.pi * f0 / sampleRate)
        a0 = 1 + k / q + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        return (shelf, highPass)
    }

    /// Adds one buffer per channel (all the same length).
    public mutating func process(_ buffers: [[Float]]) {
        guard let frames = buffers.first?.count else { return }
        for frame in 0..<frames {
            for channel in 0..<min(channels, buffers.count) {
                let sample = Double(buffers[channel][frame])
                samplePeak = max(samplePeak, abs(sample))
                peak = max(peak, oversampler[channel].peak(after: sample))
                let weighted = filters[channel].highPass.process(filters[channel].shelf.process(sample))
                stepEnergy[channel] += weighted * weighted
            }
            stepFill += 1
            if stepFill == stepLength {
                steps.append(stepEnergy.reduce(0, +) / Double(stepLength))
                stepEnergy = Array(repeating: 0, count: channels)
                stepFill = 0
            }
        }
    }

    private static func loudness(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(max(meanSquare, 1e-20)) }

    /// Integrated loudness in LUFS, or nil when everything is below the -70 LUFS gate (silence).
    public var integratedLoudness: Double? {
        // 400 ms blocks overlapping by 75%: four consecutive 100 ms steps.
        guard steps.count >= 4 else { return nil }
        let blocks = (0...(steps.count - 4)).map { steps[$0..<($0 + 4)].reduce(0, +) / 4 }
        let audible = blocks.filter { Self.loudness($0) > -70 }
        guard !audible.isEmpty else { return nil }
        let relativeGate = Self.loudness(audible.reduce(0, +) / Double(audible.count)) - 10
        let gated = audible.filter { Self.loudness($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return Self.loudness(gated.reduce(0, +) / Double(gated.count))
    }

    /// The highest true (4× oversampled) peak, in dBTP.
    public var truePeakDB: Double { 20 * log10(max(peak, samplePeak, 1e-9)) }

    /// The highest sample, in dBFS.
    public var samplePeakDB: Double { 20 * log10(max(samplePeak, 1e-9)) }

    /// The gain (dB, at most +24) that brings the measured audio to `target` LUFS, and whether
    /// its peaks then need limiting to stay under `ceiling` dBTP. Nil for silence.
    public func normalization(target: Double, ceiling: Double) -> (gainDB: Double, needsLimiting: Bool)? {
        guard let loudness = integratedLoudness else { return nil }
        let gain = min(target - loudness, 24)
        return (gain, truePeakDB + gain > ceiling)
    }
}

/// Estimates the peaks between samples: a 4× windowed-sinc interpolator over the last samples.
struct TruePeakOversampler: Sendable {
    private static let halfTaps = 8
    /// Interpolation weights for the 3 in-between positions (1/4, 2/4, 3/4), over 2·halfTaps samples.
    private static let phases: [[Double]] = (1...3).map { phase in
        let offset = Double(phase) / 4
        return (0..<(2 * halfTaps)).map { index in
            let distance = Double(index - halfTaps + 1) - offset
            let sinc = distance == 0 ? 1 : sin(.pi * distance) / (.pi * distance)
            // Hann window over the span.
            let position = (Double(index) + 1 - offset) / Double(2 * halfTaps)
            let window = 0.5 - 0.5 * cos(2 * .pi * position)
            return sinc * window
        }
    }.map { weights in
        // Unity gain at DC, so a flat signal reads its own level.
        let sum = weights.reduce(0, +)
        return weights.map { $0 / sum }
    }

    private var history = [Double](repeating: 0, count: 2 * halfTaps)
    private var next = 0

    /// Adds a sample and returns the largest magnitude among the in-between points around the
    /// middle of the history (latency doesn't matter for a meter).
    mutating func peak(after sample: Double) -> Double {
        history[next] = sample
        next = (next + 1) % history.count
        var largest = 0.0
        for weights in Self.phases {
            var sum = 0.0
            for index in 0..<history.count { sum += weights[index] * history[(next + index) % history.count] }
            largest = max(largest, abs(sum))
        }
        return largest
    }
}
