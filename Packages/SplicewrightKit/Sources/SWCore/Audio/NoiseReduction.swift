import Foundation

/// A radix-2 complex FFT of a fixed size, in place on separate real and imaginary arrays.
struct FFT: Sendable {
    let size: Int
    private let cosines: [Double]
    private let sines: [Double]
    private let reversed: [Int]

    init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        cosines = (0..<(size / 2)).map { cos(-2 * .pi * Double($0) / Double(size)) }
        sines = (0..<(size / 2)).map { sin(-2 * .pi * Double($0) / Double(size)) }
        let bits = size.trailingZeroBitCount
        reversed = (0..<size).map { index in
            var result = 0
            for bit in 0..<bits where index & (1 << bit) != 0 { result |= 1 << (bits - 1 - bit) }
            return result
        }
    }

    /// Forward transform, or inverse (unscaled) with `inverse`.
    func transform(_ real: inout [Double], _ imaginary: inout [Double], inverse: Bool = false) {
        for index in 0..<size where reversed[index] > index {
            real.swapAt(index, reversed[index])
            imaginary.swapAt(index, reversed[index])
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
            for index in buffers[channel].indices {
                state.input[start + state.position] = Double(buffers[channel][index])
                buffers[channel][index] = Float(state.ready[state.position])
                state.position += 1
                if state.position == hop {
                    frame(&state)
                    state.position = 0
                }
            }
            channels[channel] = state
        }
    }

    /// One frame: analyse, cut the noise, resynthesize, and overlap-add.
    private func frame(_ state: inout ChannelState) {
        let n = Self.frameSize
        let hop = Self.hop
        var real = (0..<n).map { state.input[$0] * window[$0] }
        var imaginary = [Double](repeating: 0, count: n)
        fft.transform(&real, &imaginary)
        let bins = n / 2 + 1
        state.frames += 1
        // Until a whole frame of audio has come in, the frame is mostly the silence before it.
        let filled = n / hop
        guard state.frames >= filled else {
            finish(&state, real: &real, imaginary: &imaginary)
            return
        }
        let learning = state.frames < filled + 40
        if state.noise.isEmpty {
            state.noise = [Double](repeating: .greatestFiniteMagnitude, count: bins)
            state.gains = [Double](repeating: 1, count: bins)
            state.lastPower = [Double](repeating: 0, count: bins)
        }
        for k in 0..<bins {
            let power = real[k] * real[k] + imaginary[k] * imaginary[k]
            // The noise level: an average over frames that look like noise (not far above it);
            // louder frames only let it creep up, so speech isn't learned as noise.
            if state.noise[k] == .greatestFiniteMagnitude {
                state.noise[k] = power
            } else if learning {
                // The first fraction of a second: learn quickly, whatever is there.
                state.noise[k] = 0.8 * state.noise[k] + 0.2 * power
            } else if power < 3 * state.noise[k] {
                state.noise[k] = 0.92 * state.noise[k] + 0.08 * power
            } else {
                state.noise[k] *= rise
            }
            // Decision-directed signal-to-noise estimate (Ephraim–Malah): mostly the last frame's
            // cleaned power, so random noise peaks don't open the gate ("musical noise").
            let noise = max(state.noise[k], 1e-20)
            let posterior = max(power / noise - 1, 0)
            let prior = 0.98 * state.gains[k] * state.gains[k] * state.lastPower[k] / noise + 0.02 * posterior
            let applied = max(prior / (prior + strength), floorGain)
            state.gains[k] = applied
            state.lastPower[k] = power
            real[k] *= applied
            imaginary[k] *= applied
            if k > 0, k < n / 2 {
                real[n - k] *= applied
                imaginary[n - k] *= applied
            }
        }
        finish(&state, real: &real, imaginary: &imaginary)
    }

    /// Back to samples, overlap-added into the output, and the frames moved on by a hop.
    private func finish(_ state: inout ChannelState, real: inout [Double], imaginary: inout [Double]) {
        let n = Self.frameSize
        let hop = Self.hop
        fft.transform(&real, &imaginary, inverse: true)
        for index in 0..<n {
            state.output[index] += real[index] / Double(n) * window[index] * 0.5
        }
        for index in 0..<hop { state.ready[index] = state.output[index] }
        state.output.removeFirst(hop)
        state.output.append(contentsOf: repeatElement(0, count: hop))
        state.input.removeFirst(hop)
        state.input.append(contentsOf: repeatElement(0, count: hop))
    }
}
