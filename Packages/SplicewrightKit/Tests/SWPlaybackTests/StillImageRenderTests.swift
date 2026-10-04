import AVFoundation
import ImageIO
import Metal
import SWTestSupport
import UniformTypeIdentifiers
import XCTest
@testable import SWCore
@testable import SWMedia
@testable import SWPlayback

/// Still images through import and the real compositor: a 2:1 PNG, red on its left half and
/// transparent on its right, over a grey clip in a 16:9 frame.
final class StillImageRenderTests: XCTestCase {
    private var project = Project()

    override func setUp() async throws {
        guard MTLCreateSystemDefaultDevice() != nil, MetalRenderer.shared != nil else { throw XCTSkip("No Metal device") }
    }

    private func writePNG() throws -> URL {
        let (width, height) = (200, 100)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<(width / 2) {
                let index = (y * width + x) * 4
                pixels.replaceSubrange(index..<index + 4, with: [255, 0, 0, 255])
            }
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try pixels.withUnsafeMutableBytes { raw -> CGImage in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return try XCTUnwrap(context.makeImage())
        }
        let url = FixtureWriter.directory.appending(path: "still-half.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                        1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func importFile(_ url: URL) async throws -> MediaItem {
        let result = await MediaImporter().importMedia(from: [url], into: nil, existingPaths: [])
        let item = try XCTUnwrap(result.items.first, "\(result.failures)")
        project.addMedia([item])
        return item
    }

    func testImportsAsAStill() async throws {
        let item = try await importFile(try writePNG())
        XCTAssertTrue(item.info.isStill)
        XCTAssertEqual(item.info.video?.width, 200)
        XCTAssertEqual(item.info.video?.height, 100)
        XCTAssertEqual(item.info.placementDuration, MediaInfo.stillPlacement)
        let thumbnail = await ThumbnailProvider.generate(url: item.url, seconds: 0, maxPixels: 64)
        XCTAssertEqual(thumbnail?.width, 64)
    }

    func testDrawnFittedWithItsTransparency() async throws {
        let still = try await importFile(try writePNG())
        let spec = FixtureWriter.h264SDR30(frames: 30, width: 160, height: 90, fill: .grey(0.5, tenBit: false))
        guard let greyURL = try await FixtureWriter.writeVideo(spec, name: "still-grey.mov") else {
            throw XCTSkip("No H.264 encoder")
        }
        let grey = try await importFile(greyURL)
        var sequence = EditSequence(name: "S", settings: SequenceSettings(width: 160, height: 90, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        sequence.addTrack(.video)
        sequence.overwrite([
            TrackPlacement(trackID: sequence.videoTracks[0].id,
                           clip: Clip(mediaID: grey.id, name: "grey", start: 0, duration: 30, sourceStart: .zero)),
            TrackPlacement(trackID: sequence.videoTracks[1].id,
                           clip: Clip(mediaID: still.id, name: "still", start: 0, duration: 30, sourceStart: .zero)),
        ])
        // The 2:1 picture fits 160×80 in the 160×90 frame: red left, grey through the right half.
        let pixels = try await rgb(sequence, at: [(0.25, 0.5), (0.75, 0.5)])
        XCTAssertGreaterThan(pixels[0].red, 200, "red on the left: \(pixels[0])")
        XCTAssertLessThan(pixels[0].green, 40)
        XCTAssertEqual(pixels[1].red, pixels[1].green, accuracy: 6, "grey shows through the transparent half: \(pixels[1])")
        XCTAssertGreaterThan(pixels[1].red, 80)

        // Alone, with nothing below, the letterbox is black.
        sequence.videoTracks[0].clips = []
        let alone = try await rgb(sequence, at: [(0.5, 0.01), (0.75, 0.5)])
        XCTAssertLessThan(alone[0].red, 10)
        XCTAssertLessThan(alone[1].red, 10)
    }

    /// Red, green and blue (0...255, sRGB) of frame 10 at each point.
    private func rgb(_ sequence: EditSequence, at points: [(Double, Double)]) async throws
        -> [(red: Int, green: Int, blue: Int)] {
        let output = await CompositionBuilder().build(sequence, project: project, cache: MediaAssetCache())
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: RationalTime(frames: 10, rate: sequence.rate).cmTime).image
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return points.map { point in
            let x = min(image.width - 1, Int(point.0 * Double(image.width)))
            let y = min(image.height - 1, Int(point.1 * Double(image.height)))
            let index = (y * image.width + x) * 4
            return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
        }
    }
}
