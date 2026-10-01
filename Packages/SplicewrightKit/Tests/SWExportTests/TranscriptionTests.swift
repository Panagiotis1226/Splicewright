import AVFoundation
import SWTestSupport
import XCTest
@testable import SWCore
@testable import SWExport
@testable import SWMedia

/// The audio mixdown always runs. Real transcription needs on-device speech recognition and
/// (on macOS 15) permission, which CI machines don't have, so it runs only when
/// SPLICEWRIGHT_TEST_SPEECH=1 is set.
final class TranscriptionTests: XCTestCase {
    private func importFile(_ url: URL, into project: inout Project) async throws -> MediaItem {
        let result = await MediaImporter().importMedia(from: [url], into: nil, existingPaths: [])
        let item = try XCTUnwrap(result.items.first, "import failed: \(result.failures)")
        project.addMedia([item])
        return item
    }

    private func audioSequence(_ item: MediaItem, frames: Int64) -> EditSequence {
        var sequence = EditSequence(name: "T", settings: SequenceSettings(width: 640, height: 360, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        let clip = Clip(mediaID: item.id, name: item.name, start: 0, duration: frames, sourceStart: .zero)
        sequence.overwrite([TrackPlacement(trackID: sequence.audioTracks[0].id, clip: clip)])
        return sequence
    }

    func testMixdownIsMonoSixteenKilohertzForTheRange() async throws {
        var project = Project()
        let tone = try await importFile(try FixtureWriter.writeSine(name: "mixdown-tone.caf", seconds: 2), into: &project)
        let sequence = audioSequence(tone, frames: 60)
        let url = try await AudioMixdown.render(sequence, project: project, range: FrameRange(start: 15, end: 45))
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(Double(file.length), 16_000, accuracy: 400, "one second")
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4000))
        try file.read(into: buffer, frameCount: 4000)
        let peak = (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1, "the tone is in the mix")
    }

    func testMixdownWithoutAudioFails() async throws {
        let sequence = EditSequence(name: "Empty", settings: SequenceSettings(width: 640, height: 360, frameRate: .fps30,
                                                                              colorSpace: .rec709))
        do {
            _ = try await AudioMixdown.render(sequence, project: Project(), range: FrameRange(start: 0, end: 30))
            XCTFail("expected noAudio")
        } catch let failure as AudioMixdown.Failure {
            XCTAssertEqual(failure, .noAudio)
        }
    }

    @MainActor
    func testTranscribesSpeechIntoCaptions() async throws {
        guard ProcessInfo.processInfo.environment["SPLICEWRIGHT_TEST_SPEECH"] == "1" else {
            throw XCTSkip("Set SPLICEWRIGHT_TEST_SPEECH=1 to run on-device speech recognition")
        }
        guard let speech = try await FixtureWriter.writeSpeech("Hello world. This is Splicewright.",
                                                               name: "speech.caf") else {
            throw XCTSkip("No text-to-speech voice")
        }
        var project = Project()
        let item = try await importFile(speech, into: &project)
        let frames = item.info.duration.frameIndex(at: .fps30)
        let sequence = audioSequence(item, frames: frames)
        let mix = try await AudioMixdown.render(sequence, project: project, range: FrameRange(start: 0, end: frames))
        defer { try? FileManager.default.removeItem(at: mix) }
        let words: [TimedWord]
        do {
            words = try await Transcriber.words(in: mix, locale: Locale(identifier: "en-US"), requestPermission: false)
        } catch let failure as Transcriber.Failure {
            throw XCTSkip("Speech recognition unavailable here: \(failure.localizedDescription)")
        }
        let spoken = words.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        XCTAssertTrue(spoken.contains("hello") && spoken.contains("world"), "\(spoken)")
        XCTAssertEqual(words.map(\.start), words.map(\.start).sorted(), "in order")
        let captions = CaptionSegmenter.captions(from: words, rate: .fps30, style: .standard)
        XCTAssertFalse(captions.isEmpty)
    }
}
