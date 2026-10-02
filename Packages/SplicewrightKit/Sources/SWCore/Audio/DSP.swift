import Foundation

/// A second-order IIR filter (transposed direct form II), one channel. Coefficients follow
/// the Audio EQ Cookbook (Robert Bristow-Johnson).
public struct Biquad: Sendable {
    public var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1 = 0.0
    private var z2 = 0.0

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
    }

    /// Normalizes by a0.
    private init(_ b: (Double, Double, Double), _ a: (Double, Double, Double)) {
        self.init(b0: b.0 / a.0, b1: b.1 / a.0, b2: b.2 / a.0, a1: a.1 / a.0, a2: a.2 / a.0)
    }

    public static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        let gain = pow(10, gainDB / 40)
        let w = 2 * .pi * min(frequency, sampleRate * 0.49) / sampleRate
        let alpha = sin(w) / (2 * max(q, 0.01))
        return Biquad((1 + alpha * gain, -2 * cos(w), 1 - alpha * gain), (1 + alpha / gain, -2 * cos(w), 1 - alpha / gain))
    }

    /// A shelf with slope 1. `high` boosts or cuts above `frequency`, otherwise below it.
    public static func shelf(high: Bool, frequency: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let gain = pow(10, gainDB / 40)
        let w = 2 * .pi * min(frequency, sampleRate * 0.49) / sampleRate
        let alpha = sin(w) / 2 * sqrt(2)
        let root = 2 * sqrt(gain) * alpha
        let cosine = cos(w)
        if high {
            return Biquad((gain * ((gain + 1) + (gain - 1) * cosine + root), -2 * gain * ((gain - 1) + (gain + 1) * cosine),
                           gain * ((gain + 1) + (gain - 1) * cosine - root)),
                          ((gain + 1) - (gain - 1) * cosine + root, 2 * ((gain - 1) - (gain + 1) * cosine),
                           (gain + 1) - (gain - 1) * cosine - root))
        }
        return Biquad((gain * ((gain + 1) - (gain - 1) * cosine + root), 2 * gain * ((gain - 1) - (gain + 1) * cosine),
                       gain * ((gain + 1) - (gain - 1) * cosine - root)),
                      ((gain + 1) + (gain - 1) * cosine + root, -2 * ((gain - 1) + (gain + 1) * cosine),
                       (gain + 1) + (gain - 1) * cosine - root))
    }

    public mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    public mutating func process(_ samples: inout [Float]) {
        for index in samples.indices { samples[index] = Float(process(Double(samples[index]))) }
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }
}

/// Premiere-style Parametric EQ: low shelf, mid peak, high shelf.
public struct ParametricEQ: Sendable {
    private var filters: [[Biquad]]

    public init(_ effect: ResolvedEffect, sampleRate: Double, channels: Int) {
        let bands = [Biquad.shelf(high: false, frequency: effect["lowFrequency"], gainDB: effect["lowGain"],
                                  sampleRate: sampleRate),
                     Biquad.peaking(frequency: effect["midFrequency"], gainDB: effect["midGain"], q: effect["midQ"],
                                    sampleRate: sampleRate),
                     Biquad.shelf(high: true, frequency: effect["highFrequency"], gainDB: effect["highGain"],
                                  sampleRate: sampleRate)]
        filters = Array(repeating: bands, count: max(channels, 1))
    }

    /// Changes the bands' settings, keeping each filter's state (for keyframed changes).
    public mutating func update(_ effect: ResolvedEffect, sampleRate: Double) {
        let fresh = ParametricEQ(effect, sampleRate: sampleRate, channels: 1).filters[0]
        for channel in filters.indices {
            for band in filters[channel].indices {
                let new = fresh[band]
                filters[channel][band].b0 = new.b0
                filters[channel][band].b1 = new.b1
                filters[channel][band].b2 = new.b2
                filters[channel][band].a1 = new.a1
                filters[channel][band].a2 = new.a2
            }
        }
    }

    public mutating func process(_ channels: inout [[Float]]) {
        for channel in channels.indices where channel < filters.count {
            for band in filters[channel].indices { filters[channel][band].process(&channels[channel]) }
        }
    }
}

/// A feed-forward compressor, linked across channels (the loudest channel sets the gain).
public struct Compressor: Sendable {
    public var thresholdDB: Double
    public var ratio: Double
    public var makeupDB: Double
    private var attack: Double
    private var release: Double
    /// The smoothed gain reduction, in dB (0 or negative).
    private var reductionDB = 0.0

    public init(_ effect: ResolvedEffect, sampleRate: Double) {
        thresholdDB = effect["threshold"]
        ratio = max(effect["ratio"], 1)
        makeupDB = effect["makeup"]
        attack = Self.coefficient(milliseconds: effect["attack"], sampleRate: sampleRate)
        release = Self.coefficient(milliseconds: effect["release"], sampleRate: sampleRate)
    }

    private static func coefficient(milliseconds: Double, sampleRate: Double) -> Double {
        exp(-1 / (max(milliseconds, 0.01) / 1000 * sampleRate))
    }

    public mutating func update(_ effect: ResolvedEffect, sampleRate: Double) {
        let fresh = Compressor(effect, sampleRate: sampleRate)
        (thresholdDB, ratio, makeupDB, attack, release) = (fresh.thresholdDB, fresh.ratio, fresh.makeupDB,
                                                           fresh.attack, fresh.release)
    }

    public mutating func process(_ channels: inout [[Float]]) {
        guard let frames = channels.first?.count else { return }
        let makeup = pow(10, makeupDB / 20)
        for frame in 0..<frames {
            var peak: Float = 0
            for channel in channels.indices { peak = max(peak, abs(channels[channel][frame])) }
            let levelDB = 20 * log10(max(Double(peak), 1e-9))
            let over = levelDB - thresholdDB
            let target = over > 0 ? -over * (1 - 1 / ratio) : 0
            // Attack while the reduction grows, release while it shrinks.
            let coefficient = target < reductionDB ? attack : release
            reductionDB = target + coefficient * (reductionDB - target)
            let gain = Float(pow(10, reductionDB / 20) * makeup)
            for channel in channels.indices { channels[channel][frame] *= gain }
        }
    }
}

/// A brick-wall limiter: nothing passes above the ceiling, and the gain recovers over 50 ms.
public struct HardLimiter: Sendable {
    public var ceiling: Double
    public var boost: Double
    private var gain = 1.0
    private let release: Double

    public init(ceilingDB: Double, boostDB: Double = 0, sampleRate: Double) {
        ceiling = pow(10, min(ceilingDB, 0) / 20)
        boost = pow(10, max(boostDB, 0) / 20)
        release = exp(-1 / (0.05 * sampleRate))
    }

    public init(_ effect: ResolvedEffect, sampleRate: Double) {
        self.init(ceilingDB: effect["ceiling"], boostDB: effect["inputBoost"], sampleRate: sampleRate)
    }

    public mutating func update(_ effect: ResolvedEffect, sampleRate: Double) {
        ceiling = pow(10, min(effect["ceiling"], 0) / 20)
        boost = pow(10, max(effect["inputBoost"], 0) / 20)
    }

    public mutating func process(_ channels: inout [[Float]]) {
        guard let frames = channels.first?.count else { return }
        for frame in 0..<frames {
            var peak = 0.0
            for channel in channels.indices { peak = max(peak, Double(abs(channels[channel][frame])) * boost) }
            // Recover towards unity, but never let this sample exceed the ceiling.
            gain = 1 - release * (1 - gain)
            if peak * gain > ceiling { gain = ceiling / peak }
            let applied = Float(gain * boost)
            for channel in channels.indices { channels[channel][frame] *= applied }
        }
    }
}

/// One clip's audio effect chain, keeping each effect's state between buffers.
public struct AudioEffectChain: Sendable {
    private enum Processor: Sendable {
        case eq(ParametricEQ)
        case compressor(Compressor)
        case limiter(HardLimiter)
        case noise(NoiseReducer)
    }

    private var processors: [Processor] = []
    private var kinds: [EffectKind] = []
    public let sampleRate: Double
    public let channels: Int

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Runs `effects` (in order) over the buffers. A changed list of effects starts fresh.
    public mutating func process(_ effects: [ResolvedEffect], _ buffers: inout [[Float]]) {
        let wanted = effects.map(\.kind)
        if wanted != kinds {
            kinds = wanted
            processors = effects.compactMap { effect in
                switch effect.kind {
                case .parametricEQ: return .eq(ParametricEQ(effect, sampleRate: sampleRate, channels: channels))
                case .compressor: return .compressor(Compressor(effect, sampleRate: sampleRate))
                case .hardLimiter: return .limiter(HardLimiter(effect, sampleRate: sampleRate))
                case .noiseReduction: return .noise(NoiseReducer(effect, sampleRate: sampleRate, channels: channels))
                default: return nil
                }
            }
        }
        for (index, effect) in zip(processors.indices, effects) {
            switch processors[index] {
            case .eq(var eq):
                eq.update(effect, sampleRate: sampleRate)
                eq.process(&buffers)
                processors[index] = .eq(eq)
            case .compressor(var compressor):
                compressor.update(effect, sampleRate: sampleRate)
                compressor.process(&buffers)
                processors[index] = .compressor(compressor)
            case .limiter(var limiter):
                limiter.update(effect, sampleRate: sampleRate)
                limiter.process(&buffers)
                processors[index] = .limiter(limiter)
            case .noise(var reducer):
                reducer.update(effect)
                reducer.process(&buffers)
                processors[index] = .noise(reducer)
            }
        }
    }
}
