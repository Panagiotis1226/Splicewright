import AVFoundation
import Metal
import SWTestSupport
import XCTest
@testable import SWCore
@testable import SWMedia
@testable import SWPlayback

/// Masks on Opacity and on effects through the real compositor, on a mid-grey clip over black.
final class MaskRenderTests: XCTestCase {
    private static var fixture: URL?
    private var project = Project()

    override func setUp() async throws {
        guard MTLCreateSystemDefaultDevice() != nil, MetalRenderer.shared != nil else { throw XCTSkip("No Metal device") }
    }

    private func greySequence() async throws -> (EditSequence, UUID) {
        let url: URL
        if let cached = Self.fixture {
            url = cached
        } else {
            let spec = FixtureWriter.h264SDR30(frames: 30, width: 160, height: 90, fill: .grey(0.5, tenBit: false))
            guard let written = try await FixtureWriter.writeVideo(spec, name: "mask-grey.mov") else {
                throw XCTSkip("No H.264 encoder")
            }
            Self.fixture = written
            url = written
        }
        let result = await MediaImporter().importMedia(from: [url], into: nil, existingPaths: [])
        let item = try XCTUnwrap(result.items.first)
        project = Project()
        project.addMedia([item])
        var sequence = EditSequence(name: "M", settings: SequenceSettings(width: 160, height: 90, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        let clip = Clip(mediaID: item.id, name: "grey", start: 0, duration: 30, sourceStart: .zero)
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[0].id, clip: clip)])
        return (sequence, clip.id)
    }

    /// The red channel (0...255, sRGB) of frame 10 at each point (fractions of the frame).
    private func red(_ sequence: EditSequence, at points: [(Double, Double)]) async throws -> [Int] {
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
            return Int(bytes[(y * image.width + x) * 4])
        }
    }

    private let center = (0.5, 0.5)
    private let corner = (0.03, 0.05)

    func testEllipseOpacityMaskLeavesTheCornersBlack() async throws {
        var (sequence, id) = try await greySequence()
        let plain = try await red(sequence, at: [center, corner])
        XCTAssertGreaterThan(plain[1], 90, "the grey fills the frame without a mask")

        var mask = Mask.ellipse(radiusX: 0.3, radiusY: 0.3)
        mask.feather = AnimatableProperty([0])
        sequence.addMask(mask, to: .opacity, of: id)
        let masked = try await red(sequence, at: [center, corner])
        XCTAssertEqual(masked[0], plain[0], accuracy: 3, "inside the mask the clip shows")
        XCTAssertLessThan(masked[1], 8, "outside it the black below shows")
    }

    func testInvertedAndSubtractMasksAreTheOpposite() async throws {
        var (sequence, id) = try await greySequence()
        var mask = Mask.ellipse(radiusX: 0.3, radiusY: 0.3)
        mask.feather = AnimatableProperty([0])
        mask.isInverted = true
        let maskID = try XCTUnwrap(sequence.addMask(mask, to: .opacity, of: id))
        let inverted = try await red(sequence, at: [center, corner])
        XCTAssertLessThan(inverted[0], 8)
        XCTAssertGreaterThan(inverted[1], 90)

        sequence.updateMask(maskID, of: .opacity, in: id) { mask in
            mask.isInverted = false
            mask.mode = .subtract
        }
        let subtracted = try await red(sequence, at: [center, corner])
        XCTAssertLessThan(subtracted[0], 8, "a subtract mask by itself cuts a hole")
        XCTAssertGreaterThan(subtracted[1], 90)
    }

    func testFeatherSoftensTheEdge() async throws {
        var (sequence, id) = try await greySequence()
        // A rectangle over the left half; sample right on its edge.
        var mask = Mask.rectangle(left: -0.1, top: -0.1, right: 0.5, bottom: 1.1)
        mask.feather = AnimatableProperty([0])
        let maskID = try XCTUnwrap(sequence.addMask(mask, to: .opacity, of: id))
        let points = [(0.25, 0.5), (0.5, 0.5), (0.75, 0.5)]
        let hard = try await red(sequence, at: points)
        sequence.updateMask(maskID, of: .opacity, in: id) { $0.feather = AnimatableProperty([20]) }
        let soft = try await red(sequence, at: points)
        XCTAssertGreaterThan(hard[0], 90)
        XCTAssertLessThan(hard[2], 8)
        XCTAssertGreaterThan(soft[1], 15, "the feathered edge is a gradient")
        XCTAssertLessThan(soft[1], hard[0] - 15)
    }

    func testAnEffectMaskLimitsTheEffect() async throws {
        var (sequence, id) = try await greySequence()
        let plain = try await red(sequence, at: [center, corner])
        let effect = try XCTUnwrap(sequence.addEffect(.colorCorrection, to: [id])[id])
        sequence.updateEffect(effect, of: id) { $0.parameters["exposure"] = AnimatableProperty([1]) }
        var mask = Mask.ellipse(radiusX: 0.3, radiusY: 0.3)
        mask.feather = AnimatableProperty([0])
        sequence.addMask(mask, to: .effect(effect), of: id)
        let graded = try await red(sequence, at: [center, corner])
        XCTAssertGreaterThan(graded[0], plain[0] + 20, "brighter inside the mask")
        XCTAssertEqual(graded[1], plain[1], accuracy: 3, "unchanged outside it")
    }

    func testMasksFollowTheLayerTransform() {
        let space = MaskSpace(transform: Affine2D(a: 2, b: 0, c: 0, d: 2, tx: 10, ty: 20), width: 100, height: 50,
                              pixelScale: 0.5)
        let mask = Mask.rectangle(left: 0, top: 0, right: 1, bottom: 1)
        var resolved = mask.resolved(at: .zero)
        resolved.feather = 8
        let placed = space.place(resolved)
        XCTAssertEqual(placed.vertices[0].x, 10)
        XCTAssertEqual(placed.vertices[0].y, 20)
        XCTAssertEqual(placed.vertices[2].x, 210)
        XCTAssertEqual(placed.vertices[2].y, 120)
        XCTAssertEqual(placed.feather, 4, "feather is in sequence pixels")

        let pixels = MaskResources.rasterize(placed, width: 240, height: 140)
        XCTAssertEqual(pixels?[70 * 240 + 100], 255)
        XCTAssertEqual(pixels?[5 * 240 + 5], 0)
    }
}
