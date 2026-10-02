import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// A radix-2 complex FFT of a fixed size, in place on separate real and imaginary arrays.
/// Accelerate's on Apple platforms (fast even in debug builds, where the audio has to keep up
/// in real time); a plain Swift one elsewhere, with the same conventions.
struct FFT: @unchecked Sendable {
    let size: Int
    #if canImport(Accelerate)
    private let setup: Setup

    /// Owns the vDSP setup (read-only once made, so it can be shared between threads).
    private final class Setup {
        let pointer: FFTSetupD
        let log2Size: vDSP_Length

        init(size: Int) {
            log2Size = vDSP_Length(size.trailingZeroBitCount)
            guard let pointer = vDSP_create_fftsetupD(log2Size, FFTRadix(kFFTRadix2)) else {
                fatalError("Couldn't make an FFT of \(size)")
            }
            self.pointer = pointer
        }

        deinit { vDSP_destroy_fftsetupD(pointer) }
    }
    #else
    private let cosines: [Double]
    private let sines: [Double]
    private let reversed: [Int]
    #endif

    init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        #if canImport(Accelerate)
        setup = Setup(size: size)
        #else
        cosines = (0..<(size / 2)).map { cos(-2 * .pi * Double($0) / Double(size)) }
        sines = (0..<(size / 2)).map { sin(-2 * .pi * Double($0) / Double(size)) }
        let bits = size.trailingZeroBitCount
        reversed = (0..<size).map { index in
            var result = 0
            for bit in 0..<bits where index & (1 << bit) != 0 { result |= 1 << (bits - 1 - bit) }
            return result
        }
        #endif
    }

    /// Forward transform, or inverse (unscaled) with `inverse`.
    func transform(_ real: inout [Double], _ imaginary: inout [Double], inverse: Bool = false) {
        precondition(real.count == size && imaginary.count == size)
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                transform(re.baseAddress!, im.baseAddress!, inverse: inverse)
            }
        }
    }

    /// The same, on `size` values at each pointer.
    func transform(_ real: UnsafeMutablePointer<Double>, _ imaginary: UnsafeMutablePointer<Double>,
                   inverse: Bool = false) {
        #if canImport(Accelerate)
        var split = DSPDoubleSplitComplex(realp: real, imagp: imaginary)
        let direction = FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward)
        vDSP_fft_zipD(setup.pointer, &split, 1, setup.log2Size, direction)
        #else
        cosines.withUnsafeBufferPointer { cosines in
            sines.withUnsafeBufferPointer { sines in
                reversed.withUnsafeBufferPointer { reversed in
                    radix2(real, imaginary, inverse: inverse, tables: (cosines, sines, reversed))
                }
            }
        }
        #endif
    }

    #if !canImport(Accelerate)
    private func radix2(_ real: UnsafeMutablePointer<Double>, _ imaginary: UnsafeMutablePointer<Double>, inverse: Bool,
                        tables: (UnsafeBufferPointer<Double>, UnsafeBufferPointer<Double>, UnsafeBufferPointer<Int>)) {
        let (cosines, sines, reversed) = tables
        for index in 0..<size where reversed[index] > index {
            let other = reversed[index]
            (real[index], real[other]) = (real[other], real[index])
            (imaginary[index], imaginary[other]) = (imaginary[other], imaginary[index])
        }
        var length = 2
        while length <= size {
            let half = length / 2
            let stride = size / length
            for start in Swift.stride(from: 0, to: size, by: length) {
                for k in 0..<half {
                    let c = cosines[k * stride]
                    let s = inverse ? -sines[k * stride] : sines[k * stride]
                    let a = start + k
                    let b = a + half
                    let tr = real[b] * c - imaginary[b] * s
                    let ti = real[b] * s + imaginary[b] * c
                    real[b] = real[a] - tr
                    imaginary[b] = imaginary[a] - ti
                    real[a] += tr
                    imaginary[a] += ti
                }
            }
            length *= 2
        }
    }
    #endif
}

/// Noise Reduction: a Wiener filter on overlapping 1024-sample frames. The noise is learned
/// as it plays, per frequency, from the moments that sound like noise (louder ones only let it
/// creep up), so there's no noise print to capture and it adapts when the room changes. Delays the audio by
/// `latency` samples (about 21 ms at 48 kHz).
public struct NoiseReducer: Sendable {
    public static let frameSize = 1024
    static let hop = 256

    private let fft = FFT(size: NoiseReducer.frameSize)
    private let window: [Double]
    private var channels: [ChannelState]
    /// Over-subtraction (how hard noise is pushed down) and the floor no frequency goes below.
    private var strength = 2.5
    private var floorGain = 0.125
    private let rise: Double

    private struct ChannelState: Sendable {
        var input = [Double](repeating: 0, count: NoiseReducer.frameSize)
        var output = [Double](repeating: 0, count: NoiseReducer.frameSize)
        var ready = [Double](repeating: 0, count: NoiseReducer.hop)
        /// The frame being transformed (kept, so a frame doesn't allocate).
        var real = [Double](repeating: 0, count: NoiseReducer.frameSize)
        var imaginary = [Double](repeating: 0, count: NoiseReducer.frameSize)
        var position = 0
        var noise: [Double] = []
        var gains: [Double] = []
        var lastPower: [Double] = []
        var frames = 0

        init() {}

        /// Empty, while the real state is being worked on.
        init(placeholder: Void) {
            input = []
            output = []
            ready = []
            real = []
            imaginary = []
        }
    }

    public var latency: Int { Self.frameSize }

    public init(sampleRate: Double, channels: Int) {
        let n = Self.frameSize
        // √Hann on the way in and out: Hann overall, which sums to 2 at 75% overlap.
        window = (0..<n).map { (0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(n))).squareRoot() }
        self.channels = Array(repeating: ChannelState(), count: max(channels, 1))
        // The noise estimate may rise about 3 dB a second, so it follows a noisier room.
        rise = pow(10, 0.3 / (sampleRate / Double(Self.hop)))
    }

    public init(_ effect: ResolvedEffect, sampleRate: Double, channels: Int) {
        self.init(sampleRate: sampleRate, channels: channels)
        update(effect)
    }

    /// Amount (0...100 %) sets how hard; Max Reduction (dB) how far down noise may go.
    public mutating func update(_ effect: ResolvedEffect) {
        strength = 1 + 3 * min(max(effect["amount"], 0), 100) / 100
        floorGain = pow(10, -min(max(effect["reduction"], 0), 60) / 20)
    }

    public mutating func process(_ buffers: inout [[Float]]) {
        let hop = Self.hop
        let start = Self.frameSize - hop
        for channel in buffers.indices where channel < channels.count {
            // Take the state out while working on it, so its arrays aren't copied per sample.
            var state = channels[channel]
            channels[channel] = ChannelState(placeholder: ())
            var samples = buffers[channel]
            buffers[channel] = []
            var index = 0
            while index < samples.count {
                // Up to the end of this hop at a time.
                let count = min(hop - state.position, samples.count - index)
                let position = state.position
                samples.withUnsafeMutableBufferPointer { samples in
                    state.input.withUnsafeMutableBufferPointer { input in
                        state.ready.withUnsafeBufferPointer { ready in
                            for offset in 0..<count {
                                input[start + position + offset] = Double(samples[index + offset])
                                samples[index + offset] = Float(ready[position + offset])
                            }
                        }
                    }
                }
                index += count
                state.position += count
                if state.position == hop {
                    frame(&state)
                    state.position = 0
                }
            }
            buffers[channel] = samples
            channels[channel] = state
        }
    }

    /// One frame: analyse, cut the noise, resynthesize, and overlap-add.
    private func frame(_ state: inout ChannelState) {
        let n = Self.frameSize
        let hop = Self.hop
        let bins = n / 2 + 1
        state.frames += 1
        // Until a whole frame of audio has come in, the frame is mostly the silence before it.
        let filled = n / hop
        let analysing = state.frames >= filled
        let learning = state.frames < filled + 40
        if analysing, state.noise.isEmpty {
            state.noise = [Double](repeating: .greatestFiniteMagnitude, count: bins)
            state.gains = [Double](repeating: 1, count: bins)
            state.lastPower = [Double](repeating: 0, count: bins)
        }
        let (strength, floorGain, rise) = (strength, floorGain, rise)
        // Moved out while the frame's buffers are borrowed below.
        var (noise, gains, lastPower) = (state.noise, state.gains, state.lastPower)
        (state.noise, state.gains, state.lastPower) = ([], [], [])
        defer { (state.noise, state.gains, state.lastPower) = (noise, gains, lastPower) }
        withPointers(&state) { re, im, input, output, window, fft in
            for index in 0..<n {
                re[index] = input[index] * window[index]
                im[index] = 0
            }
            fft.transform(re, im)
            if analysing {
                noise.withUnsafeMutableBufferPointer { noise in
                    gains.withUnsafeMutableBufferPointer { gains in
                        lastPower.withUnsafeMutableBufferPointer { lastPower in
                            for k in 0..<bins {
                                let power = re[k] * re[k] + im[k] * im[k]
                                // The noise level: an average over frames that look like noise (not far
                                // above it); louder frames only let it creep up, so speech isn't learned.
                                if noise[k] == .greatestFiniteMagnitude {
                                    noise[k] = power
                                } else if learning {
                                    // The first fraction of a second: learn quickly, whatever is there.
                                    noise[k] = 0.8 * noise[k] + 0.2 * power
                                } else if power < 3 * noise[k] {
                                    noise[k] = 0.92 * noise[k] + 0.08 * power
                                } else {
                                    noise[k] *= rise
                                }
                                // Decision-directed signal-to-noise estimate (Ephraim–Malah): mostly the last
                                // frame's cleaned power, so random noise peaks don't open the gate.
                                let level = max(noise[k], 1e-20)
                                let posterior = max(power / level - 1, 0)
                                let prior = 0.98 * gains[k] * gains[k] * lastPower[k] / level + 0.02 * posterior
                                let applied = max(prior / (prior + strength), floorGain)
                                gains[k] = applied
                                lastPower[k] = power
                                re[k] *= applied
                                im[k] *= applied
                                if k > 0, k < n / 2 {
                                    re[n - k] *= applied
                                    im[n - k] *= applied
                                }
                            }
                        }
                    }
                }
            }
            // Back to samples, overlap-added into the output.
            fft.transform(re, im, inverse: true)
            let scale = 0.5 / Double(n)
            for index in 0..<n { output[index] += re[index] * scale * window[index] }
        }
        // Hand on the finished hop and move both frames along by one.
        state.ready.withUnsafeMutableBufferPointer { ready in
            state.output.withUnsafeMutableBufferPointer { output in
                for index in 0..<hop { ready[index] = output[index] }
                for index in 0..<(n - hop) { output[index] = output[index + hop] }
                for index in (n - hop)..<n { output[index] = 0 }
            }
        }
        state.input.withUnsafeMutableBufferPointer { input in
            for index in 0..<(n - hop) { input[index] = input[index + hop] }
            for index in (n - hop)..<n { input[index] = 0 }
        }
    }

    private typealias Pointer = UnsafeMutablePointer<Double>

    /// The frame's buffers as pointers, for the loops that run every hop.
    private func withPointers(_ state: inout ChannelState,
                              _ body: (Pointer, Pointer, UnsafePointer<Double>, Pointer, UnsafePointer<Double>, FFT) -> Void) {
        state.real.withUnsafeMutableBufferPointer { re in
            state.imaginary.withUnsafeMutableBufferPointer { im in
                state.input.withUnsafeBufferPointer { input in
                    state.output.withUnsafeMutableBufferPointer { output in
                        window.withUnsafeBufferPointer { window in
                            body(re.baseAddress!, im.baseAddress!, input.baseAddress!, output.baseAddress!,
                                 window.baseAddress!, fft)
                        }
                    }
                }
            }
        }
    }
}
