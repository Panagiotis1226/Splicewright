import AVFoundation
import Metal
import SWTestSupport
import XCTest
@testable import SWCore
@testable import SWMedia
@testable import SWPlayback

/// Builds real compositions from synthesized clips and renders frames through the Metal
/// compositor with AVAssetImageGenerator, checking the pixels that come out.
final class CompositionTests: XCTestCase {
    private var project = Project()

    override func setUp() async throws {
        project = Project()
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        guard MetalRenderer.shared != nil else {
            XCTFail("Metal renderer failed to initialise (shader compilation?)")
            return
        }
    }

    // MARK: - Helpers

    private func importClip(_ spec: FixtureWriter.VideoSpec, _ name: String) async throws -> MediaItem {
        guard let url = try await FixtureWriter.writeVideo(spec, name: name) else {
            throw XCTSkip("Encoder for \(spec.codec.rawValue) unavailable on this machine")
        }
        let result = await MediaImporter().importMedia(from: [url], into: nil, existingPaths: [])
        let item = try XCTUnwrap(result.items.first, "import failed: \(result.failures)")
        project.addMedia([item])
        return item
    }

    private func makeSequence(_ space: SequenceColorSpace = .rec709, width: Int = 1920, height: Int = 1080) -> EditSequence {
        EditSequence(name: "Test", settings: SequenceSettings(width: width, height: height, frameRate: .fps30,
                                                              colorSpace: space))
    }

    private func place(_ item: MediaItem, on sequence: inout EditSequence, track: Int = 0, at frame: Int64,
                       frames: Int64, opacity: Double = 1) {
        let clip = Clip(mediaID: item.id, name: item.name, start: frame, duration: frames, sourceStart: .zero,
                        opacity: opacity)
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[track].id, clip: clip)])
    }

    private func render(_ sequence: EditSequence, frame: Int64) async throws -> CGImage {
        let output = await CompositionBuilder().build(sequence, project: project, cache: MediaAssetCache())
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = RationalTime(frames: frame, rate: sequence.rate).cmTime
        return try await generator.image(at: time).image
    }

    /// RGB (0...255) of the pixel at a fraction of the image's width/height, in sRGB.
    private func pixel(_ image: CGImage, x: Double = 0.5, y: Double = 0.5) throws -> [Int] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        let px = min(width - 1, Int(Double(width) * x))
        let py = min(height - 1, Int(Double(height) * y))
        let offset = (py * width + px) * 4
        return [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
    }

    private func assertGrey(_ rgb: [Int], near value: Int, tolerance: Int, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        for channel in rgb {
            XCTAssertLessThanOrEqual(abs(channel - value), tolerance, "\(message): got \(rgb)", file: file, line: line)
        }
    }

    // MARK: - Structure

    func testCompositionMatchesSequenceTiming() async throws {
        let item = try await importClip(FixtureWriter.h264SDR30(frames: 60), "structure.mov")
        var sequence = makeSequence()
        place(item, on: &sequence, at: 30, frames: 30)
        let output = await CompositionBuilder().build(sequence, project: project, cache: MediaAssetCache())
        XCTAssertEqual(output.durationFrames, 60)
        XCTAssertEqual(output.composition.duration, CMTime(value: 2, timescale: 1))
        let instructions = output.videoComposition.instructions
        XCTAssertEqual(instructions.count, 2)
        XCTAssertEqual(instructions.first?.timeRange.start, .zero)
        XCTAssertEqual(instructions.last?.timeRange.end, CMTime(value: 2, timescale: 1))
        XCTAssertNil(instructions.first?.requiredSourceTrackIDs, "the gap needs no sources")
        XCTAssertEqual(instructions.last?.requiredSourceTrackIDs?.count, 1)
        XCTAssertEqual(output.videoComposition.renderSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(output.videoComposition.colorTransferFunction, AVVideoTransferFunction_ITU_R_709_2)
    }

    func testHalfResolutionPlayback() async throws {
        let sequence = makeSequence(.rec2100HLG, width: 3840, height: 2160)
        let output = await CompositionBuilder(renderScale: 0.5).build(sequence, project: project, cache: MediaAssetCache())
        XCTAssertEqual(output.videoComposition.renderSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(output.videoComposition.colorTransferFunction, AVVideoTransferFunction_ITU_R_2100_HLG)
    }

    // MARK: - Pixels

    func testSDRGreyPassesThroughAndGapsAreBlack() async throws {
        let item = try await importClip(FixtureWriter.h264SDR30(fill: .grey(0.5, tenBit: false)), "grey.mov")
        var sequence = makeSequence()
        place(item, on: &sequence, at: 15, frames: 15)
        let gap = try pixel(try await render(sequence, frame: 5))
        assertGrey(gap, near: 0, tolerance: 6, "gap before the clip")
        let grey = try pixel(try await render(sequence, frame: 20))
        // 50% video-range grey should come out close to 50% (≈128) once converted to sRGB.
        assertGrey(grey, near: 128, tolerance: 22, "mid grey")
    }

    func testOpacityBlendsOverLowerLayer() async throws {
        let white = try await importClip(FixtureWriter.h264SDR30(fill: .grey(1, tenBit: false)), "white.mov")
        var sequence = makeSequence()
        place(white, on: &sequence, track: 1, at: 0, frames: 30, opacity: 0.5)
        let blended = try pixel(try await render(sequence, frame: 10))
        let full = try pixel(try await render({
            var opaque = sequence
            opaque.videoTracks[1].clips[0].opacity = 1
            return opaque
        }(), frame: 10))
        assertGrey(full, near: 255, tolerance: 6, "opaque white")
        // Half-opacity white over black is 50% linear light, which encodes well above mid grey.
        XCTAssertGreaterThan(blended[1], 150)
        XCTAssertLessThan(blended[1], 235)
    }

    func testPillarboxesNarrowerSource() async throws {
        let item = try await importClip(FixtureWriter.h264SDR30(width: 1440, height: 1080, fill: .grey(1, tenBit: false)),
                                        "narrow.mov")
        var sequence = makeSequence()
        place(item, on: &sequence, at: 0, frames: 30)
        let image = try await render(sequence, frame: 5)
        assertGrey(try pixel(image, x: 0.05), near: 0, tolerance: 6, "left pillar")
        assertGrey(try pixel(image, x: 0.95), near: 0, tolerance: 6, "right pillar")
        assertGrey(try pixel(image, x: 0.5), near: 255, tolerance: 6, "picture")
    }

    func testHLGReferenceWhiteToneMapsIntoSDR() async throws {
        // HLG reference white (75% signal, 203 nits) must land near, but not beyond, SDR white.
        let item = try await importClip(FixtureWriter.hevcHLG(fps5994: 10, width: 1920, height: 1080,
                                                              fill: .grey(0.75, tenBit: true)), "hlg-white.mov")
        var sequence = makeSequence()
        place(item, on: &sequence, at: 0, frames: 5)
        let rgb = try pixel(try await render(sequence, frame: 2))
        for channel in rgb {
            XCTAssertGreaterThan(channel, 190, "HLG reference white too dark in SDR: \(rgb)")
        }
    }

    func testRendersIntoHDRSequences() async throws {
        let item = try await importClip(FixtureWriter.h264SDR30(fill: .grey(0.5, tenBit: false)), "sdr-in-hdr.mov")
        for space in [SequenceColorSpace.rec2100HLG, .rec2100PQ] {
            var sequence = makeSequence(space)
            place(item, on: &sequence, at: 0, frames: 30)
            let image = try await render(sequence, frame: 5)
            XCTAssertEqual(image.width, 1920, "\(space)")
            let rgb = try pixel(image)
            XCTAssertGreaterThan(rgb[1], 20, "\(space) rendered black: \(rgb)")
        }
    }
}
