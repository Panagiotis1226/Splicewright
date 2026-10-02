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

    /// Phone video: encoded 160×90, turned 90° clockwise for display, in a 90×160 frame. Masks and
    /// Crop are set on the upright picture, so they must land there, not transposed.
    func testRotatedVideoMasksAndCropFollowTheDisplayedPicture() throws {
        let orientation = Affine2D(a: 0, b: 1, c: -1, d: 0, tx: 90, ty: 0)
        let fit = Affine2D.fit(sourceWidth: 160, sourceHeight: 90, orientation: orientation, renderWidth: 90,
                               renderHeight: 160)
        var layer = InstructionLayer(trackID: 1, opacity: 1, transform: fit, sourceWidth: 160, sourceHeight: 90,
                                     fallbackColor: .rec709)
        layer.picture = DisplayedPicture(sourceWidth: 160, sourceHeight: 90, orientation: orientation,
                                         renderWidth: 90, renderHeight: 160)
        XCTAssertEqual(layer.picture?.width, 90)
        XCTAssertEqual(layer.picture?.height, 160)
        // The left half of the picture as shown.
        layer.opacityMasks = [Mask.rectangle(left: 0, top: 0, right: 0.5, bottom: 1)]
        var crop = ClipEffect(kind: .crop)
        crop.parameters["left"] = AnimatableProperty([25])
        layer.effects = [crop]
        let (geometry, passes) = layer.effects(at: .zero, renderWidth: 90, renderHeight: 160)
        guard case .mask(let masks)? = passes.last else { return XCTFail("no opacity mask pass") }
        let points = masks[0].vertices.map { [$0.x, $0.y] }
        XCTAssertEqual(points, [[0, 0], [45, 0], [45, 160], [0, 160]], "the left half of the frame, upright")
        // The shown left edge is the encoded bottom (the encoded top is on the right).
        XCTAssertEqual(geometry.crop.bottom, 0.25, accuracy: 1e-9)
        XCTAssertEqual(geometry.crop.left, 0)
        let flipped = LayerGeometry(flipHorizontal: true).reoriented(quarterTurns: 1)
        XCTAssertTrue(flipped.flipVertical && !flipped.flipHorizontal, "left-right shown is top-bottom encoded")
    }

    /// The Stabilizer moves the picture between its fit and Motion, scaled to the asset's size
    /// (a proxy at half size moves half as many of its own pixels).
    func testStabilizerCorrectionMovesTheLayer() {
        var data = StabilizationData(pictureWidth: 200, pictureHeight: 100)
        data.times = [0]
        data.path = [StabilizationData.numbers(.identity)]
        data.corrections = [[1, 0, 0, 1, 10, -4]]
        data.isComplete = true
        var effect = ClipEffect(kind: .stabilizer)
        effect.stabilization = data
        // Full size: the fit doubles it into a 400 × 200 frame.
        var layer = InstructionLayer(trackID: 1, opacity: 1, transform: .scale(2, 2), sourceWidth: 200, sourceHeight: 100,
                                     fallbackColor: .rec709)
        layer.effects = [effect]
        let moved = layer.transform(at: .zero, renderWidth: 400, renderHeight: 200).apply(x: 0, y: 0)
        XCTAssertEqual(moved.x, 20, accuracy: 1e-9)
        XCTAssertEqual(moved.y, -8, accuracy: 1e-9)
        // A half-size proxy, fitted ×4 into the same frame, lands in the same place.
        var proxy = InstructionLayer(trackID: 1, opacity: 1, transform: .scale(4, 4), sourceWidth: 100, sourceHeight: 50,
                                     fallbackColor: .rec709)
        proxy.effects = [effect]
        let proxyMoved = proxy.transform(at: .zero, renderWidth: 400, renderHeight: 200).apply(x: 0, y: 0)
        XCTAssertEqual(proxyMoved.x, 20, accuracy: 1e-9)
        XCTAssertEqual(proxyMoved.y, -8, accuracy: 1e-9)
        effect.isEnabled = false
        layer.effects = [effect]
        XCTAssertEqual(layer.transform(at: .zero, renderWidth: 400, renderHeight: 200), .scale(2, 2))
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
