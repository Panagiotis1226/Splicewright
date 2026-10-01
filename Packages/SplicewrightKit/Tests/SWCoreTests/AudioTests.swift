import Foundation
import Testing
@testable import SWCore

@Suite("Audio mixer, DSP and loudness")
struct AudioTests {
    private let rate = 48_000.0

    /// `seconds` of a sine at `dBFS` peak, one buffer per channel.
    private func sine(_ frequency: Double, dBFS: Double, seconds: Double, channels: Int = 2,
                      phase: Double = 0) -> [[Float]] {
        let amplitude = pow(10, dBFS / 20)
        let samples = (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate + phase)) }
        return Array(repeating: samples, count: channels)
    }

    private func silence(seconds: Double, channels: Int = 2) -> [[Float]] {
        Array(repeating: [Float](repeating: 0, count: Int(seconds * rate)), count: channels)
    }

    private func peak(_ buffers: [[Float]], last seconds: Double = 0.5) -> Double {
        let count = Int(seconds * rate)
        return Double(buffers.map { $0.suffix(count).map(abs).max() ?? 0 }.max() ?? 0)
    }

    // MARK: - Loudness (EBU Tech 3341 cases)

    @Test func stereoSineAtMinus23IsMinus23LUFS() throws {
        var meter = LoudnessMeter(sampleRate: rate, channels: 2)
        meter.process(sine(1000, dBFS: -23, seconds: 20))
        let loudness = try #require(meter.integratedLoudness)
        #expect(abs(loudness - -23) < 0.1)
        var quiet = LoudnessMeter(sampleRate: 44_100, channels: 2)
        let tone = (0..<441_000).map { Float(pow(10, -33.0 / 20) * sin(2 * .pi * 1000 * Double($0) / 44_100)) }
        quiet.process([tone, tone])
        #expect(abs((quiet.integratedLoudness ?? 0) - -33) < 0.1, "any sample rate")
    }

    @Test func gatingIgnoresSilenceAndQuietParts() throws {
        var meter = LoudnessMeter(sampleRate: rate, channels: 2)
        meter.process(silence(seconds: 5))
        meter.process(sine(1000, dBFS: -36, seconds: 10))
        meter.process(sine(1000, dBFS: -23, seconds: 60))
        meter.process(sine(1000, dBFS: -36, seconds: 10))
        let loudness = try #require(meter.integratedLoudness)
        #expect(abs(loudness - -23) < 0.1, "-36 is more than 10 LU below, so it's gated out")
        var silent = LoudnessMeter(sampleRate: rate, channels: 1)
        silent.process(silence(seconds: 3, channels: 1))
        #expect(silent.integratedLoudness == nil)
    }

    @Test func truePeakFindsOversBetweenSamples() {
        // A quarter-rate sine sampled at 45°: every sample is at 0.707 of the real peak.
        var meter = LoudnessMeter(sampleRate: rate, channels: 1)
        meter.process(sine(rate / 4, dBFS: 0, seconds: 1, channels: 1, phase: .pi / 4))
        #expect(abs(meter.samplePeakDB - -3.01) < 0.05)
        #expect(meter.truePeakDB > -0.5 && meter.truePeakDB < 0.3)
    }

    @Test func normalizationGainAndLimiting() throws {
        var meter = LoudnessMeter(sampleRate: rate, channels: 2)
        meter.process(sine(1000, dBFS: -23, seconds: 10))
        let streaming = try #require(meter.normalization(target: LoudnessTarget.streaming.lufs, ceiling: -1))
        #expect(abs(streaming.gainDB - 9) < 0.15 && !streaming.needsLimiting, "-23 → -14 LUFS; the peak lands at -14")
        let loud = try #require(meter.normalization(target: 0, ceiling: -1))
        #expect(abs(loud.gainDB - 23) < 0.15 && loud.needsLimiting, "the peak would reach 0 dBTP")
    }

    // MARK: - DSP

    @Test func eqBoostsOnlyItsBand() {
        var effect = ClipEffect(kind: .parametricEQ).resolved(at: .zero)
        effect.values["midGain"] = 6
        var low = sine(100, dBFS: -12, seconds: 1)
        var mid = sine(1000, dBFS: -12, seconds: 1)
        var eq = ParametricEQ(effect, sampleRate: rate, channels: 2)
        eq.process(&mid)
        var other = ParametricEQ(effect, sampleRate: rate, channels: 2)
        other.process(&low)
        #expect(abs(20 * log10(peak(mid)) - -6) < 0.3, "+6 dB at 1 kHz")
        #expect(abs(20 * log10(peak(low)) - -12) < 0.5, "100 Hz untouched")
    }

    @Test func shelvesWorkAtTheirEnds() {
        var effect = ClipEffect(kind: .parametricEQ).resolved(at: .zero)
        effect.values["lowGain"] = -12
        var deep = sine(30, dBFS: -6, seconds: 1)
        var eq = ParametricEQ(effect, sampleRate: rate, channels: 2)
        eq.process(&deep)
        #expect(abs(20 * log10(peak(deep)) - -18) < 1, "-12 dB well below the 100 Hz shelf")
    }

    @Test func compressorReducesAboveThreshold() {
        // -20 dB threshold, 4:1: a 0 dBFS tone comes out at -20 + 20/4 = -15 dB.
        let effect = ClipEffect(kind: .compressor).resolved(at: .zero)
        var loud = sine(1000, dBFS: 0, seconds: 1)
        var compressor = Compressor(effect, sampleRate: rate)
        compressor.process(&loud)
        #expect(abs(20 * log10(peak(loud)) - -15) < 1.5)
        var quiet = sine(1000, dBFS: -30, seconds: 1)
        var untouched = Compressor(effect, sampleRate: rate)
        untouched.process(&quiet)
        #expect(abs(20 * log10(peak(quiet)) - -30) < 0.2, "below threshold")
    }

    @Test func limiterNeverExceedsItsCeiling() {
        var boosted = sine(440, dBFS: 0, seconds: 1)
        var limiter = HardLimiter(ceilingDB: -1, boostDB: 6, sampleRate: rate)
        limiter.process(&boosted)
        #expect(peak(boosted, last: 1) <= pow(10, -1.0 / 20) + 1e-6)
        #expect(peak(boosted) > 0.85, "and it's still loud")
    }

    @Test func chainRunsEffectsInOrderAndSkipsVideoKinds() {
        var compressor = ClipEffect(kind: .compressor).resolved(at: .zero)
        compressor.values["makeup"] = 12
        let limiter = ClipEffect(kind: .hardLimiter).resolved(at: .zero)
        var buffers = sine(1000, dBFS: 0, seconds: 1)
        var chain = AudioEffectChain(sampleRate: rate, channels: 2)
        chain.process([compressor, limiter, ClipEffect(kind: .crop).resolved(at: .zero)], &buffers)
        // -15 dB + 12 dB makeup = -3 dB, then limited to -1 dB: stays at -3.
        #expect(abs(20 * log10(peak(buffers)) - -3) < 1.5)
    }

    // MARK: - Mixer

    @Test func fadersPanAndPersistence() throws {
        #expect(Mixer.gain(dB: Mixer.silentDB) == 0)
        #expect(abs(Mixer.gain(dB: -6) - 0.501) < 0.001)
        #expect(Mixer.balance(0) == (1, 1))
        let left = Mixer.balance(-100)
        #expect(left.left == 1 && abs(left.right) < 1e-9)
        #expect(abs(Mixer.balance(50).left - cos(.pi / 4)) < 1e-9)
        #expect(Mixer.label(dB: -100) == "-∞" && Mixer.label(dB: 3) == "+3.0" && Mixer.label(dB: -6.04) == "-6.0")

        var seq = EditSequence(name: "S", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                                     colorSpace: .rec709))
        let a1 = seq.audioTracks[0].id
        seq.setTrackVolume(a1, dB: 20)
        seq.setTrackPan(a1, -150)
        seq.setMixVolume(dB: -3)
        #expect(seq.audioTracks[0].volumeDB == Mixer.maximumDB && seq.audioTracks[0].pan == -100)
        let data = try JSONEncoder().encode(seq)
        let decoded = try JSONDecoder().decode(EditSequence.self, from: data)
        #expect(decoded.audioTracks[0].volumeDB == 6 && decoded.audioTracks[0].pan == -100 && decoded.mixVolumeDB == -3)
        // Older files have no mixer settings.
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["mixVolumeDB"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(EditSequence.self, from: old).mixVolumeDB == 0)
    }

    @Test func audioEffectsGoOnAudioClipsOnly() {
        var seq = EditSequence(name: "S", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                                     colorSpace: .rec709))
        let video = Clip(mediaID: UUID(), name: "v", start: 0, duration: 30, sourceStart: .zero)
        var audio = video
        audio.id = UUID()
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: video),
                       TrackPlacement(trackID: seq.audioTracks[0].id, clip: audio)])
        #expect(Set(seq.addEffect(.compressor, to: [video.id, audio.id]).keys) == [audio.id])
        #expect(Set(seq.addEffect(.gaussianBlur, to: [video.id, audio.id]).keys) == [video.id])
        #expect(seq.clip(audio.id)?.resolvedEffects(at: .zero).isEmpty == true, "not drawn")
        #expect(seq.clip(audio.id)?.resolvedAudioEffects(at: .zero).map(\.kind) == [.compressor])
    }
}
