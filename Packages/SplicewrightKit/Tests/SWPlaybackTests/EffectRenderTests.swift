import AVFoundation
import Metal
import SWTestSupport
import XCTest
@testable import SWCore
@testable import SWMedia
@testable import SWPlayback

/// Video effects and adjustment layers through the real compositor, on a 320×180 sequence.
final class EffectRenderTests: XCTestCase {
    private static var fixtures: [String: URL] = [:]
    private var project = Project()

    override func setUp() async throws {
        project = Project()
        guard MTLCreateSystemDefaultDevice() != nil, MetalRenderer.shared != nil else { throw XCTSkip("No Metal device") }
    }

    // MARK: - Helpers

    private func media(_ level: Double, _ name: String) async throws -> MediaItem {
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

    private func emptySequence() -> EditSequence {
        EditSequence(name: "E", settings: SequenceSettings(width: 320, height: 180, frameRate: .fps30, colorSpace: .rec709))
    }

    /// A 60-frame clip of `level` grey on video track `track`.
    @discardableResult
    private func place(_ level: Double, on track: Int, in sequence: inout EditSequence) async throws -> UUID {
        let item = try await media(level, level >= 1 ? "effect-white.mov" : "effect-grey.mov")
        let clip = Clip(mediaID: item.id, name: "C", start: 0, duration: 60, sourceStart: .zero)
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[track].id, clip: clip)])
        return clip.id
    }

    /// Adds `kind` to the clip with the given parameter values.
    private func apply(_ kind: VideoEffectKind, _ values: [String: Double], to clipID: UUID,
                       in sequence: inout EditSequence) throws {
        let added = sequence.addEffect(kind, to: [clipID])
        let effectID = try XCTUnwrap(added[clipID])
        sequence.updateEffect(effectID, of: clipID) { effect in
            for (key, value) in values { effect.parameters[key] = AnimatableProperty([value]) }
        }
    }

    private func render(_ sequence: EditSequence, frame: Int64 = 10, scale: Double = 1) async throws -> CGImage {
        let output = await CompositionBuilder(renderScale: scale).build(sequence, project: project, cache: MediaAssetCache())
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: RationalTime(frames: frame, rate: sequence.rate).cmTime).image
    }

    /// Green (0...255, sRGB) at a point given as a fraction of the frame, from the top left.
    private func green(_ image: CGImage, _ x: Double, _ y: Double) throws -> Int {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let px = min(image.width - 1, Int(Double(image.width) * x))
        let py = min(image.height - 1, Int(Double(image.height) * y))
        return Int(bytes[(py * image.width + px) * 4 + 1])
    }

    /// A white block glyph centred at (x, y), as a title on `track`.
    private func block(at x: Double, _ y: Double, on track: Int, in sequence: inout EditSequence) -> UUID? {
        let spec = TitleSpec(text: "\u{2588}", size: 0.25, positionX: x, positionY: y, shadow: nil)
        return sequence.addTitle(spec, at: 0, duration: 60, trackID: sequence.videoTracks[track].id)
    }

    // MARK: - Geometry

    func testCropBlacksOutTheCroppedSide() async throws {
        var sequence = emptySequence()
        let id = try await place(1, on: 0, in: &sequence)
        try apply(.crop, ["left": 50], to: id, in: &sequence)
        let image = try await render(sequence)
        XCTAssertLessThan(try green(image, 0.25, 0.5), 10, "cropped away")
        XCTAssertGreaterThan(try green(image, 0.75, 0.5), 240, "kept")
    }

    func testFlipsMirrorTheFrame() async throws {
        var sequence = emptySequence()
        let title = try XCTUnwrap(block(at: 0.25, 0.3, on: 0, in: &sequence))
        let plain = try await render(sequence)
        XCTAssertGreaterThan(try green(plain, 0.25, 0.3), 200)
        XCTAssertLessThan(try green(plain, 0.75, 0.3), 10)

        try apply(.horizontalFlip, [:], to: title, in: &sequence)
        let flipped = try await render(sequence)
        XCTAssertLessThan(try green(flipped, 0.25, 0.3), 10)
        XCTAssertGreaterThan(try green(flipped, 0.75, 0.3), 200, "moved to the right")

        try apply(.verticalFlip, [:], to: title, in: &sequence)
        let both = try await render(sequence)
        XCTAssertGreaterThan(try green(both, 0.75, 0.7), 200, "and to the bottom")
    }

    func testMirrorReflectsTheLeftOntoTheRight() async throws {
        var sequence = emptySequence()
        let title = try XCTUnwrap(block(at: 0.25, 0.5, on: 0, in: &sequence))
        try apply(.mirror, [:], to: title, in: &sequence)
        let image = try await render(sequence)
        XCTAssertGreaterThan(try green(image, 0.25, 0.5), 200, "the original")
        XCTAssertGreaterThan(try green(image, 0.75, 0.5), 200, "its reflection")
    }

    // MARK: - Passes

    func testBlurSpreadsAnEdgeAtAnyPreviewResolution() async throws {
        var sequence = emptySequence()
        let id = try await place(1, on: 0, in: &sequence)
        // A half-size white box (x 80...240) on black.
        sequence.updateProperty(.scale, of: id) { $0.values = [50] }
        let sharp = try await render(sequence)
        XCTAssertLessThan(try green(sharp, 0.23, 0.5), 10, "6 px outside the box")

        try apply(.gaussianBlur, ["blurriness": 20], to: id, in: &sequence)
        let blurred = try await render(sequence)
        XCTAssertGreaterThan(try green(blurred, 0.23, 0.5), 40, "the edge spreads out")
        XCTAssertGreaterThan(try green(blurred, 0.5, 0.5), 235, "the middle stays white")
        XCTAssertLessThan(try green(blurred, 0.03, 0.5), 10, "far away stays black")
        let half = try await render(sequence, scale: 0.5)
        XCTAssertEqual(Double(try green(half, 0.23, 0.5)), Double(try green(blurred, 0.23, 0.5)), accuracy: 30,
                       "the blur scales with the preview")
    }

    func testDropShadowFallsDownAndRight() async throws {
        var sequence = emptySequence()
        try await place(0.5, on: 0, in: &sequence)
        let box = try await place(1, on: 1, in: &sequence)
        sequence.updateProperty(.scale, of: box) { $0.values = [50] }
        // 135° (down-right), 20 px, hard edged, fully opaque.
        try apply(.dropShadow, ["opacity": 100, "distance": 20, "softness": 0], to: box, in: &sequence)
        let image = try await render(sequence)
        let background = try green(image, 0.05, 0.05)
        let shadow = try green(image, 245 / 320, 140 / 180)
        let opposite = try green(image, 75 / 320, 40 / 180)
        XCTAssertGreaterThan(background, 60)
        XCTAssertLessThan(shadow, background - 40, "shadow below and right of the box")
        XCTAssertEqual(Double(opposite), Double(background), accuracy: 6, "none above and left")
        XCTAssertGreaterThan(try green(image, 0.5, 0.5), 240, "the box draws over its shadow")
    }

    // MARK: - Adjustment layers

    func testAdjustmentLayerAffectsOnlyTracksBelowIt() async throws {
        var sequence = emptySequence()
        let below = try await place(1, on: 0, in: &sequence)
        sequence.updateProperty(.scale, of: below) { $0.values = [50] }
        let layer = try XCTUnwrap(sequence.addAdjustmentLayer(at: 0, duration: 60, trackID: sequence.videoTracks[1].id))
        // A small white box above the adjustment layer, top left (x 8...72, y 7...43).
        let above = try await place(1, on: 2, in: &sequence)
        sequence.updateProperty(.scale, of: above) { $0.values = [20] }
        sequence.updateProperty(.position, of: above) { $0.values = [-120, -65] }
        let plain = try await render(sequence)
        XCTAssertLessThan(try green(plain, 0.23, 0.5), 10, "no effects: it draws nothing")

        try apply(.gaussianBlur, ["blurriness": 20], to: layer, in: &sequence)
        let image = try await render(sequence)
        let blurredEdge = try green(image, 0.23, 0.5)
        XCTAssertGreaterThan(blurredEdge, 40, "V1 under it is blurred")
        XCTAssertGreaterThan(try green(image, 69 / 320, 25 / 180), 235, "V3 above it stays sharp")

        sequence.updateProperty(.opacity, of: layer) { $0.values = [0.5] }
        let halfImage = try await render(sequence)
        let half = try green(halfImage, 0.23, 0.5)
        XCTAssertGreaterThan(half, 10, "half the blur")
        XCTAssertLessThan(half, blurredEdge)

        sequence.updateEffect(sequence.clip(layer)!.effects[0].id, of: layer) { $0.isEnabled = false }
        let disabled = try await render(sequence)
        XCTAssertLessThan(try green(disabled, 0.23, 0.5), 10, "a disabled effect does nothing")
    }

    func testAdjustmentLayerKeepsWhatsUnderItWhereItEnds() async throws {
        var sequence = emptySequence()
        let below = try await place(1, on: 0, in: &sequence)
        sequence.updateProperty(.scale, of: below) { $0.values = [50] }
        let layer = try XCTUnwrap(sequence.addAdjustmentLayer(at: 0, duration: 20, trackID: sequence.videoTracks[1].id))
        try apply(.crop, ["left": 100], to: layer, in: &sequence)
        let during = try await render(sequence, frame: 10)
        let after = try await render(sequence, frame: 30)
        XCTAssertLessThan(try green(during, 0.5, 0.5), 10, "cropped to nothing")
        XCTAssertGreaterThan(try green(after, 0.5, 0.5), 240, "after the layer ends")
    }
}
