import Foundation
import Testing
@testable import SWCore

@Suite("Noise Reduction")
struct NoiseReductionTests {
    private let rate = 48_000.0

    private func effect(amount: Double, reduction: Double) -> ResolvedEffect {
        ResolvedEffect(kind: .noiseReduction, values: ["amount": amount, "reduction": reduction])
    }

    /// Runs mono samples through in 512-sample buffers, as playback does.
    private func run(_ input: [Float], _ effect: ResolvedEffect) -> [Float] {
        var reducer = NoiseReducer(effect, sampleRate: rate, channels: 1)
        var output: [Float] = []
        for start in stride(from: 0, to: input.count, by: 512) {
            var buffer = [Array(input[start..<min(start + 512, input.count)])]
            reducer.process(&buffer)
            output += buffer[0]
        }
        return output
    }

    private func noise(seconds: Double, level: Float, seed: UInt64) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        return (0..<Int(seconds * rate)).map { _ in Float.random(in: -1...1, using: &generator) * level }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        (samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(samples.count, 1))).squareRoot()
    }

    /// The level of one frequency (Goertzel).
    private func level(of frequency: Double, in samples: ArraySlice<Float>) -> Double {
        let w = 2 * Double.pi * frequency / rate
        var (s1, s2) = (0.0, 0.0)
        for sample in samples {
            let s0 = Double(sample) + 2 * cos(w) * s1 - s2
            (s2, s1) = (s1, s0)
        }
        let power = s1 * s1 + s2 * s2 - 2 * cos(w) * s1 * s2
        return power.squareRoot() / Double(samples.count) * 2
    }

    @Test func withNoReductionItOnlyDelays() {
        let input = noise(seconds: 0.5, level: 0.5, seed: 3)
        let output = run(input, effect(amount: 50, reduction: 0))
        let latency = NoiseReducer.frameSize
        var worst: Float = 0
        for index in (latency * 2)..<(input.count - 1) { worst = max(worst, abs(output[index] - input[index - latency])) }
        #expect(worst < 1e-4, "overlap-add rebuilds the signal exactly")
    }

    @Test func steadyNoiseGoesDownAndSpeechLikeToneStays() {
        // Two seconds of hiss, then hiss with a tone over it.
        let hiss = noise(seconds: 4, level: 0.05, seed: 9)
        let input = hiss.indices.map { index -> Float in
            let t = Double(index) / rate
            return hiss[index] + (t >= 2 ? Float(0.3 * sin(2 * .pi * 440 * t)) : 0)
        }
        let output = run(input, effect(amount: 50, reduction: 18))
        let quiet = Int(1.0 * rate)..<Int(2.0 * rate)
        let reduced = 20 * log10(rms(output[quiet]) / rms(input[quiet]))
        #expect(reduced < -10, "hiss down by \(reduced) dB")
        let toneIn = level(of: 440, in: input[Int(3 * rate)..<Int(3.5 * rate)])
        let toneOut = level(of: 440, in: output[Int(3 * rate)..<Int(3.5 * rate)])
        #expect(abs(20 * log10(toneOut / toneIn)) < 1.5, "the tone keeps its level")
        let finite = output.allSatisfy { $0.isFinite }
        #expect(finite)
    }

    @Test func maxReductionLimitsHowFarNoiseGoes() {
        let hiss = noise(seconds: 2, level: 0.05, seed: 13)
        let gentle = run(hiss, effect(amount: 100, reduction: 6))
        let range = Int(1.0 * rate)..<Int(2.0 * rate)
        let reduced = 20 * log10(rms(gentle[range]) / rms(hiss[range]))
        #expect(reduced > -8 && reduced < -3, "about the 6 dB allowed, got \(reduced)")
    }

    @Test func itsAnAudioEffectThatRunsInTheChain() {
        #expect(EffectKind.noiseReduction.isAudio)
        #expect(effect(amount: 0, reduction: 18).isNoOp)
        var chain = AudioEffectChain(sampleRate: rate, channels: 2)
        var buffers = [noise(seconds: 0.1, level: 0.1, seed: 1), noise(seconds: 0.1, level: 0.1, seed: 2)]
        chain.process([effect(amount: 50, reduction: 18)], &buffers)
        #expect(buffers.count == 2 && buffers[0].count == Int(0.1 * rate))
    }
}

@Suite("Clean Up Dialogue")
struct DialoguePresetTests {
    @Test func addsTheChainToAudioClipsOnly() {
        var seq = EditSequence(name: "D", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                                     colorSpace: .rec709))
        let link = UUID()
        let video = Clip(mediaID: UUID(), name: "v", start: 0, duration: 100, sourceStart: .zero, linkID: link)
        var audio = video
        audio.id = UUID()
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: video),
                       TrackPlacement(trackID: seq.audioTracks[0].id, clip: audio)])
        #expect(seq.cleanUpDialogue([video.id, audio.id]) == 1)
        let effects = seq.clip(audio.id)?.effects ?? []
        #expect(effects.map(\.kind) == [.parametricEQ, .noiseReduction, .compressor, .hardLimiter])
        #expect(effects[0].value("lowGain", at: .zero) == -12 && effects[2].value("ratio", at: .zero) == 3)
        #expect(seq.clip(video.id)?.effects.isEmpty == true)
    }
}
