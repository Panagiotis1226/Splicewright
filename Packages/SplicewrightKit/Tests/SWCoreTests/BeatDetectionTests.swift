import Foundation
import Testing
@testable import SWCore

/// Repeatable noise for the test signals.
private struct SeededNoise: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@Suite("Beat detection")
struct BeatDetectionTests {
    /// A drum-like pattern: a kick (a falling low thump with a click) on every beat, louder on the
    /// first of each bar, a quiet hi-hat (high noise) between, over a soft pad, from `start` seconds.
    private func music(bpm: Double, seconds: Double, start: Double = 0.25, sampleRate: Double = 48_000) -> [Float] {
        // The pad fades in, so its start isn't an onset of its own.
        var samples = (0..<Int(seconds * sampleRate)).map { index -> Float in
            let t = Double(index) / sampleRate
            return Float(0.05 * min(1, t / 0.2) * sin(2 * .pi * 220 * t))
        }
        var noise = SeededNoise(state: UInt64(bpm * 1000))
        let beat = 60 / bpm
        var time = start
        var count = 0
        while time < seconds {
            let kick = Int(time * sampleRate)
            let level = count % 4 == 0 ? 0.9 : 0.7
            var phase = 0.0
            for step in 0..<Int(0.15 * sampleRate) where kick + step < samples.count {
                let t = Double(step) / sampleRate
                phase += 2 * .pi * (50 + 100 * exp(-t / 0.02)) / sampleRate
                let click = step < 96 ? Double.random(in: -0.5...0.5, using: &noise) : 0
                samples[kick + step] += Float(level * (exp(-t / 0.05) * sin(phase) + click))
            }
            let hat = Int((time + beat / 2) * sampleRate)
            var last = 0.0
            for step in 0..<Int(0.04 * sampleRate) where hat + step < samples.count {
                let value = Double.random(in: -1...1, using: &noise)
                samples[hat + step] += Float(0.12 * exp(-Double(step) / (0.008 * sampleRate)) * (value - last))
                last = value
            }
            time += beat
            count += 1
        }
        return samples
    }

    private func analyse(_ samples: [Float], settings: BeatSettings = BeatSettings()) -> BeatAnalysis {
        var detector = BeatDetector(sampleRate: 48_000)
        var index = 0
        while index < samples.count {
            let chunk = Array(samples[index..<min(samples.count, index + 4096)])
            detector.process([chunk, chunk])
            index += 4096
        }
        return detector.analysis(settings)
    }

    @Test(arguments: [72.0, 90.0, 100.0, 120.0, 128.0, 140.0, 150.0, 174.0])
    func findsTheTempoAndBeats(bpm: Double) {
        let result = analyse(music(bpm: bpm, seconds: 12), settings: BeatSettings())
        #expect(abs(result.bpm - bpm) / bpm < 0.02, "tempo \(result.bpm) for \(bpm)")
        let period = 60 / bpm
        let expected = Array(stride(from: 0.25, to: 12, by: period))
        // Each beat found lies on a real beat.
        let errors = result.beats.map { beat in expected.map { abs($0 - beat) }.min() ?? 1 }
        let mean = errors.reduce(0, +) / Double(max(errors.count, 1))
        #expect(errors.allSatisfy { $0 < 0.035 }, "worst \(errors.max() ?? 0), mean \(mean)")
        #expect(result.beats.count >= expected.count - 3, "\(result.beats.count) of \(expected.count)")
    }

    @Test func silenceHasNoBeats() {
        let result = analyse([Float](repeating: 0, count: 48_000 * 3))
        #expect(result.beats.isEmpty && result.bpm == 0)
    }

    @Test func everyNthBeatFromAnOffset() {
        let beats = [0.0, 0.5, 1, 1.5, 2, 2.5, 3]
        #expect(BeatSettings(every: 2, offset: 1).picked(beats) == [0.5, 1.5, 2.5])
        #expect(BeatSettings(every: 4).picked(beats) == [0, 2])
        #expect(BeatSettings().picked(beats) == beats)
    }

    @Test func markersAndCutsOnBeats() {
        var sequence = EditSequence(name: "B", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        let clip = Clip(mediaID: UUID(), name: "v", start: 0, duration: 120, sourceStart: .zero)
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[0].id, clip: clip)])
        let frames = EditSequence.beatFrames([0.5, 1.0, 1.001, 2.0, 5.0], from: 10, rate: sequence.rate)
        #expect(frames == [25, 40, 70, 160], "rounded to frames, repeats dropped")
        sequence.addBeatMarkers(frames)
        #expect(sequence.markers.map(\.name) == ["Beat 1", "Beat 2", "Beat 3", "Beat 4"])
        #expect(sequence.cutOnBeats([clip.id], at: frames) == 3, "the beat past the clip's end isn't cut")
        #expect(sequence.videoTracks[0].clips.map(\.start) == [0, 25, 40, 70])
    }

    @Test func soloingKeepsOnlyTheChosenAudio() {
        var sequence = EditSequence(name: "B", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        let music = Clip(mediaID: UUID(), name: "music", start: 0, duration: 120, sourceStart: .zero)
        let voice = Clip(mediaID: UUID(), name: "voice", start: 0, duration: 120, sourceStart: .zero)
        sequence.overwrite([TrackPlacement(trackID: sequence.audioTracks[0].id, clip: music),
                            TrackPlacement(trackID: sequence.audioTracks[1].id, clip: voice)])
        let solo = sequence.soloingAudio([music.id])
        #expect(solo.audioTracks.flatMap(\.clips).map(\.id) == [music.id])
        #expect(sequence.soloingAudio([UUID()]).audioTracks.flatMap(\.clips).count == 2, "nothing chosen: all of it")
    }
}
