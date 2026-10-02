import AVFoundation
import SWTestSupport
import XCTest
@testable import SWCore
@testable import SWMedia
@testable import SWPlayback

/// Track faders, pan, the Mix fader and clip audio effects, heard through the composition's
/// audio taps. The fixture tone peaks at 0.5 on the left and 0.25 on the right.
final class AudioMixTests: XCTestCase {
    private static var fixture: URL?
    private var project = Project()
    /// Samples that weren't finite in the last `peaks` read (anywhere in the mix).
    private var nonFinite = 0

    private func sequenceWithTone() async throws -> (EditSequence, UUID) {
        let url = try Self.fixture ?? FixtureWriter.writeSine(name: "mixer-tone.caf", seconds: 2)
        Self.fixture = url
        let result = await MediaImporter().importMedia(from: [url], into: nil, existingPaths: [])
        let item = try XCTUnwrap(result.items.first)
        project = Project()
        project.addMedia([item])
        var sequence = EditSequence(name: "Mix", settings: SequenceSettings(width: 320, height: 180, frameRate: .fps30,
                                                                            colorSpace: .rec709))
        let clip = Clip(mediaID: item.id, name: "tone", start: 0, duration: 60, sourceStart: .zero)
        sequence.overwrite([TrackPlacement(trackID: sequence.audioTracks[0].id, clip: clip)])
        return (sequence, clip.id)
    }

    /// Left and right peaks between 0.5 s and 1.5 s of the mix.
    private func peaks(_ sequence: EditSequence, output built: CompositionOutput? = nil) async throws -> [Float] {
        let output: CompositionOutput
        if let built {
            output = built
        } else {
            output = await CompositionBuilder().build(sequence, project: project, cache: MediaAssetCache())
        }
        let tracks = try await output.composition.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: output.composition)
        let mix = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        mix.audioMix = output.audioMix
        reader.add(mix)
        XCTAssertTrue(reader.startReading())
        var peaks: [Float] = [0, 0]
        nonFinite = 0
        while let sample = mix.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let start = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 48_000).rounded())
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            _ = values.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
            }
            nonFinite += values.filter { !$0.isFinite }.count
            for frame in 0..<(values.count / 2) where (24_000..<72_000).contains(start + frame) {
                peaks[0] = max(peaks[0], abs(values[frame * 2]))
                peaks[1] = max(peaks[1], abs(values[frame * 2 + 1]))
            }
        }
        XCTAssertEqual(reader.status, .completed)
        return peaks
    }

    func testUnityLeavesTheToneAlone() async throws {
        let (sequence, _) = try await sequenceWithTone()
        let levels = try await peaks(sequence)
        XCTAssertEqual(levels[0], 0.5, accuracy: 0.02)
        XCTAssertEqual(levels[1], 0.25, accuracy: 0.02)
    }

    func testTrackFaderPanAndMixFader() async throws {
        var (sequence, _) = try await sequenceWithTone()
        let a1 = sequence.audioTracks[0].id
        sequence.setTrackVolume(a1, dB: -6.02)
        var levels = try await peaks(sequence)
        XCTAssertEqual(levels[0], 0.25, accuracy: 0.02, "-6 dB halves it")

        sequence.setTrackVolume(a1, dB: 0)
        sequence.setTrackPan(a1, -100)
        levels = try await peaks(sequence)
        XCTAssertEqual(levels[0], 0.5, accuracy: 0.02, "panned left: the left stays")
        XCTAssertLessThan(levels[1], 0.005, "and the right is silent")

        sequence.setTrackPan(a1, 0)
        sequence.setMixVolume(dB: -6.02)
        levels = try await peaks(sequence)
        XCTAssertEqual(levels[0], 0.25, accuracy: 0.02, "the Mix fader")
    }

    func testFaderMovesWithoutARebuild() async throws {
        var (sequence, _) = try await sequenceWithTone()
        let output = await CompositionBuilder().build(sequence, project: project, cache: MediaAssetCache())
        sequence.setTrackVolume(sequence.audioTracks[0].id, dB: Mixer.silentDB)
        output.mixer?.update(from: sequence)
        let levels = try await peaks(sequence, output: output)
        XCTAssertLessThan(levels[0], 0.001, "the same composition hears the new fader")
        let measured = output.meters?.read()
        XCTAssertNotNil(measured?.tracks[sequence.audioTracks[0].id], "the tap metered the track")
    }

    func testClipCompressorAndDisabledEffects() async throws {
        var (sequence, clipID) = try await sequenceWithTone()
        let added = sequence.addEffect(.compressor, to: [clipID])
        // -20 dB threshold, 4:1: the -6 dBFS left channel comes out near -20 + 14/4 = -16.5 dB.
        var levels = try await peaks(sequence)
        XCTAssertEqual(20 * log10(Double(levels[0])), -16.5, accuracy: 1.5)
        XCTAssertEqual(levels[1] / levels[0], 0.5, accuracy: 0.05, "linked: both sides get the same gain")

        let effectID = try XCTUnwrap(added[clipID])
        sequence.updateEffect(effectID, of: clipID) { $0.isEnabled = false }
        levels = try await peaks(sequence)
        XCTAssertEqual(levels[0], 0.5, accuracy: 0.02)
    }

    /// Noise Reduction alone and in the Clean Up Dialogue chain. It has to keep up in the tap even
    /// in a debug build: when a tap falls behind, the mix comes out silent.
    func testNoiseReductionAndCleanUpDialogueInTheTap() async throws {
        let chain = DialoguePreset.chain
        var results: [String] = []
        _ = AudioTapStats.shared.take()
        // Repeated: a silent mix came and went between runs.
        for parts in [[1], [0, 1, 2], [0, 1, 2, 3], [1], [0, 1, 2, 3], [1], [0, 1, 2, 3]] {
            var (sequence, clipID) = try await sequenceWithTone()
            for part in parts {
                let (kind, values) = chain[part]
                guard let effectID = sequence.addEffect(kind, to: [clipID])[clipID] else { continue }
                sequence.updateEffect(effectID, of: clipID) { effect in
                    for (key, value) in values { effect.parameters[key] = AnimatableProperty([value]) }
                }
            }
            let levels = try await peaks(sequence)
            // A steady tone is learned as noise, so it's taken down, but by no more than Max Reduction.
            let ok = levels[0] > 0.5 / 10 && nonFinite == 0
            results.append("\(ok ? "" : "FAIL ")\(parts.map { "\(chain[$0].0)" }.joined(separator: "+")): "
                           + "\(levels[0]) (\(nonFinite) non-finite; taps: \(AudioTapStats.shared.take()))")
        }
        XCTAssertFalse(results.contains { $0.hasPrefix("FAIL") }, results.joined(separator: "; "))
    }
}
