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

final class ClippingOverlayTests: XCTestCase {
    func testOverlayMarksPixelsAbove1000Nits() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        // A PQ signal of 85% is roughly 2300 nits: above the 1000-nit mastering range.
        guard let url = try await FixtureWriter.writeVideo(
            FixtureWriter.hevcPQ(frames: 10, width: 1280, height: 720, fill: .grey(0.85, tenBit: true)), name: "pq-hot.mp4"
        ) else { throw XCTSkip("HEVC encoder unavailable") }
        var project = Project()
        let imported = await MediaImporter().importMedia(from: [url], into: nil, existingPaths: [])
        let item = try XCTUnwrap(imported.items.first)
        project.addMedia([item])
        var sequence = EditSequence(name: "PQ", settings: SequenceSettings(width: 1280, height: 720, frameRate: .fps30,
                                                                           colorSpace: .rec2100PQ))
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[0].id, clip: Clip(
            mediaID: item.id, name: "hot", start: 0, duration: 10, sourceStart: .zero))])

        func centre(_ overlay: OverlayMode) async throws -> [Int] {
            let output = await CompositionBuilder(overlay: overlay).build(sequence, project: project, cache: MediaAssetCache())
            let generator = AVAssetImageGenerator(asset: output.composition)
            generator.videoComposition = output.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(value: 5, timescale: 30)).image
            var pixel = [UInt8](repeating: 0, count: 4)
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            pixel.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                                width: CGFloat(image.width), height: CGFloat(image.height)))
            }
            return pixel.prefix(3).map(Int.init)
        }
        let marked = try await centre(.clipping)
        XCTAssertGreaterThan(marked[0], 150, "red channel of magenta: \(marked)")
        XCTAssertLessThan(marked[1], 90, "green channel of magenta: \(marked)")
        let plain = try await centre(.none)
        XCTAssertGreaterThan(plain[1], 150, "without the overlay the pixel is a bright grey: \(plain)")
    }

    func testColorOverrideReplacesFileTags() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        guard let url = try await FixtureWriter.writeVideo(
            FixtureWriter.h264SDR30(frames: 10, width: 1280, height: 720, fill: .grey(0.75, tenBit: false)),
            name: "override.mov"
        ) else { throw XCTSkip("H.264 encoder unavailable") }
        var project = Project()
        let imported = await MediaImporter().importMedia(from: [url], into: nil, existingPaths: [])
        let item = try XCTUnwrap(imported.items.first)
        project.addMedia([item])
        var sequence = EditSequence(name: "O", settings: SequenceSettings(width: 1280, height: 720, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[0].id, clip: Clip(
            mediaID: item.id, name: "o", start: 0, duration: 10, sourceStart: .zero))])

        func level() async throws -> Int {
            let output = await CompositionBuilder().build(sequence, project: project, cache: MediaAssetCache())
            let generator = AVAssetImageGenerator(asset: output.composition)
            generator.videoComposition = output.videoComposition
            let image = try await generator.image(at: CMTime(value: 5, timescale: 30)).image
            var pixel = [UInt8](repeating: 0, count: 4)
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            pixel.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                                width: CGFloat(image.width), height: CGFloat(image.height)))
            }
            return Int(pixel[1])
        }
        let asTagged = try await level()
        // The same 75% signal read as PQ is about 1000 nits, which tone-maps to a different SDR level.
        project.setColorOverride(.rec2100PQ, for: [item.id])
        let asPQ = try await level()
        XCTAssertNotEqual(asTagged, asPQ, "override had no effect (\(asTagged))")
    }
}
