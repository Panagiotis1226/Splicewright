import AVFoundation
import Metal
import SWTestSupport
import XCTest
@testable import SWCore
@testable import SWMedia
@testable import SWPlayback

/// Renders transitions through the real compositor: white clip A cuts to black clip B at
/// frame 60, with a 30-frame transition (frames 45...74) between them.
final class TransitionRenderTests: XCTestCase {
    private static var fixtures: [String: URL] = [:]
    private var project = Project()

    override func setUp() async throws {
        project = Project()
        guard MTLCreateSystemDefaultDevice() != nil, MetalRenderer.shared != nil else { throw XCTSkip("No Metal device") }
    }

    // MARK: - Helpers

    private func clip(_ level: Double, _ name: String) async throws -> MediaItem {
        let url: URL
        if let cached = Self.fixtures[name] {
            url = cached
        } else {
            let spec = FixtureWriter.h264SDR30(frames: 60, width: 320, height: 180, fill: .grey(level, tenBit: false))
            guard let written = try await FixtureWriter.writeVideo(spec, name: name) else {
                throw XCTSkip("No H.264 encoder")
            }
            Self.fixtures[name] = written
            url = written
        }
        let result = await MediaImporter().importMedia(from: [url], into: nil, existingPaths: [])
        let item = try XCTUnwrap(result.items.first)
        project.addMedia([item])
        return item
    }

    /// White A (0...59) then black B (60...119) on `track`, with `kind` across the cut.
    private func cutSequence(_ kind: TransitionKind?, track: Int = 0) async throws -> EditSequence {
        let white = try await clip(1, "transition-white.mov")
        let black = try await clip(0, "transition-black.mov")
        var sequence = EditSequence(name: "T", settings: SequenceSettings(width: 320, height: 180, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        let trackID = sequence.videoTracks[track].id
        sequence.overwrite([
            TrackPlacement(trackID: trackID, clip: Clip(mediaID: white.id, name: "A", start: 0, duration: 60,
                                                        sourceStart: .zero)),
            TrackPlacement(trackID: trackID, clip: Clip(mediaID: black.id, name: "B", start: 60, duration: 60,
                                                        sourceStart: .zero)),
        ])
        if let kind { sequence.addTransition(kind, trackID: trackID, at: 60, duration: 30) }
        return sequence
    }

    private func render(_ sequence: EditSequence, frame: Int64) async throws -> CGImage {
        let output = await CompositionBuilder().build(sequence, project: project, cache: MediaAssetCache())
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: RationalTime(frames: frame, rate: sequence.rate).cmTime).image
    }

    /// Green channel (0...255) at a point, in sRGB.
    private func level(_ image: CGImage, x: Double = 0.5, y: Double = 0.5) throws -> Int {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let px = min(width - 1, Int(Double(width) * x))
        let py = min(height - 1, Int(Double(height) * y))
        return Int(bytes[(py * width + px) * 4 + 1])
    }

    // MARK: - Structure

    func testTransitionUsesTwoCompositionTracks() async throws {
        let sequence = try await cutSequence(.crossDissolve)
        let output = await CompositionBuilder().build(sequence, project: project, cache: MediaAssetCache())
        XCTAssertEqual(output.composition.tracks(withMediaType: .video).count, 2)
        let mixing = output.videoComposition.instructions.filter { $0.containsTweening }
        XCTAssertEqual(mixing.count, 2, "both halves of the transition (either side of the cut)")
        XCTAssertEqual(mixing.first?.requiredSourceTrackIDs?.count, 2)
        let plain = try await cutSequence(nil)
        let single = await CompositionBuilder().build(plain, project: project, cache: MediaAssetCache())
        XCTAssertEqual(single.composition.tracks(withMediaType: .video).count, 1)
    }

    // MARK: - Pixels

    func testCrossDissolve() async throws {
        let sequence = try await cutSequence(.crossDissolve)
        let before = try level(try await render(sequence, frame: 40))
        let middle = try level(try await render(sequence, frame: 60))
        let after = try level(try await render(sequence, frame: 80))
        XCTAssertGreaterThan(before, 245, "A before the transition")
        XCTAssertLessThan(after, 10, "B after the transition")
        // Half white in linear light encodes well above mid grey; A's missing tail handle is
        // a held last frame, so it must not be black.
        XCTAssertGreaterThan(middle, 150)
        XCTAssertLessThan(middle, 235)
        let early = try level(try await render(sequence, frame: 48))
        XCTAssertGreaterThan(early, middle, "the mix moves towards B")
    }

    func testDipToBlackIsBlackAtTheMiddle() async throws {
        let sequence = try await cutSequence(.dipToBlack)
        // Just past the middle: nearly all black, fading up into black B.
        XCTAssertLessThan(try level(try await render(sequence, frame: 60)), 20)
        let quarter = try level(try await render(sequence, frame: 52))
        XCTAssertGreaterThan(quarter, 60, "still fading from white")
    }

    func testDipToWhite() async throws {
        let sequence = try await cutSequence(.dipToWhite)
        XCTAssertGreaterThan(try level(try await render(sequence, frame: 60)), 240)
        XCTAssertGreaterThan(try level(try await render(sequence, frame: 68)), 100, "fading from white into black")
    }

    func testWipeRightRevealsBFromTheLeft() async throws {
        let sequence = try await cutSequence(.wipeRight)
        let image = try await render(sequence, frame: 60)
        XCTAssertLessThan(try level(image, x: 0.2), 10, "B (black) on the left")
        XCTAssertGreaterThan(try level(image, x: 0.8), 245, "A (white) on the right")
    }

    func testDissolveHidesLowerTracks() async throws {
        // White to white on V2 over grey V1: an opaque dissolve must not let V1 show through.
        let white = try await clip(1, "transition-white.mov")
        let grey = try await clip(0.5, "transition-grey.mov")
        var sequence = EditSequence(name: "T", settings: SequenceSettings(width: 320, height: 180, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        let v1 = sequence.videoTracks[0].id
        let v2 = sequence.videoTracks[1].id
        sequence.overwrite([
            TrackPlacement(trackID: v1, clip: Clip(mediaID: grey.id, name: "G", start: 0, duration: 120,
                                                   sourceStart: .zero)),
            TrackPlacement(trackID: v2, clip: Clip(mediaID: white.id, name: "A", start: 0, duration: 60,
                                                   sourceStart: .zero)),
            TrackPlacement(trackID: v2, clip: Clip(mediaID: white.id, name: "B", start: 60, duration: 60,
                                                   sourceStart: .zero)),
        ])
        sequence.addTransition(.crossDissolve, trackID: v2, at: 60, duration: 30)
        XCTAssertGreaterThan(try level(try await render(sequence, frame: 60)), 245)

        // A fade out at the end of V2 does reveal V1.
        sequence.addTransition(.crossDissolve, trackID: v2, at: 120, duration: 30)
        let fading = try level(try await render(sequence, frame: 105))
        XCTAssertGreaterThan(fading, 140)
        XCTAssertLessThan(fading, 240)
    }

    // MARK: - Audio

    func testAudioFadeOut() async throws {
        let toneURL: URL
        if let cached = Self.fixtures["tone"] {
            toneURL = cached
        } else {
            toneURL = try FixtureWriter.writeSine(name: "transition-tone.caf", seconds: 2)
            Self.fixtures["tone"] = toneURL
        }
        let result = await MediaImporter().importMedia(from: [toneURL], into: nil, existingPaths: [])
        let tone = try XCTUnwrap(result.items.first)
        project.addMedia([tone])
        var sequence = EditSequence(name: "A", settings: SequenceSettings(width: 320, height: 180, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        let a1 = sequence.audioTracks[0].id
        sequence.overwrite([TrackPlacement(trackID: a1, clip: Clip(mediaID: tone.id, name: "T", start: 0, duration: 60,
                                                                   sourceStart: .zero))])
        sequence.addTransition(.constantPower, trackID: a1, at: 60, duration: 30)
        let output = await CompositionBuilder().build(sequence, project: project, cache: MediaAssetCache())
        let levels = try await rmsPerQuarterSecond(output)
        XCTAssertGreaterThanOrEqual(levels.count, 7)
        XCTAssertGreaterThan(levels[0], 0.1, "full level before the fade")
        // The fade covers 1...2 s; a constant-power curve is at about 56% and 22% RMS in the
        // last two quarter seconds.
        XCTAssertGreaterThan(levels[3], levels[0] * 0.9, "no fade before 1 s")
        XCTAssertLessThan(levels[6], levels[0] * 0.7, "fading out")
        XCTAssertLessThan(levels[7], levels[0] * 0.35)
    }

    private func rmsPerQuarterSecond(_ output: CompositionOutput) async throws -> [Float] {
        let reader = try AVAssetReader(asset: output.composition)
        let tracks = try await output.composition.loadTracks(withMediaType: .audio)
        let mix = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        mix.audioMix = output.audioMix
        reader.add(mix)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let buffer = mix.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                                                          destination: $0.baseAddress!) }
            samples += chunk
        }
        let window = 12_000
        return stride(from: 0, to: samples.count - window + 1, by: window).map { start in
            let slice = samples[start..<start + window]
            return (slice.reduce(0) { $0 + $1 * $1 } / Float(window)).squareRoot()
        }
    }
}
