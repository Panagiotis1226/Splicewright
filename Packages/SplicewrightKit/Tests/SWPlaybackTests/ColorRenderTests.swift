import AVFoundation
import Metal
import SWTestSupport
import XCTest
@testable import SWCore
@testable import SWMedia
@testable import SWPlayback

/// Color Correction, curves and LUTs through the real compositor, on a mid-grey clip.
final class ColorRenderTests: XCTestCase {
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
            guard let written = try await FixtureWriter.writeVideo(spec, name: "color-grey.mov") else {
                throw XCTSkip("No H.264 encoder")
            }
            Self.fixture = written
            url = written
        }
        let result = await MediaImporter().importMedia(from: [url], into: nil, existingPaths: [])
        let item = try XCTUnwrap(result.items.first)
        project = Project()
        project.addMedia([item])
        var sequence = EditSequence(name: "C", settings: SequenceSettings(width: 160, height: 90, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        let clip = Clip(mediaID: item.id, name: "grey", start: 0, duration: 30, sourceStart: .zero)
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[0].id, clip: clip)])
        return (sequence, clip.id)
    }

    /// Red, green and blue (0...255, sRGB) at the middle of frame 10.
    private func rgb(_ sequence: EditSequence) async throws -> [Int] {
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
        let offset = (image.height / 2 * image.width + image.width / 2) * 4
        return [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
    }

    private func set(_ kind: EffectKind, _ values: [String: Double], on clipID: UUID, in sequence: inout EditSequence,
                     configure: (inout ClipEffect) -> Void = { _ in }) throws {
        let added = sequence.addEffect(kind, to: [clipID])
        let effectID = try XCTUnwrap(added[clipID])
        sequence.updateEffect(effectID, of: clipID) { effect in
            for (key, value) in values { effect.parameters[key] = AnimatableProperty([value]) }
            configure(&effect)
        }
    }

    private func writeCube(_ name: String, size: Int = 9, _ transform: ([Float]) -> [Float]) throws -> String {
        var lines = ["LUT_3D_SIZE \(size)"]
        let n = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    lines.append(transform([Float(r) / n, Float(g) / n, Float(b) / n]).map { String($0) }.joined(separator: " "))
                }
            }
        }
        let url = FixtureWriter.directory.appending(path: name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testExposureAndTemperature() async throws {
        var (sequence, id) = try await greySequence()
        let before = try await rgb(sequence)
        XCTAssertEqual(Double(before[1]), 128, accuracy: 12, "mid grey")
        try set(.colorCorrection, ["exposure": 1], on: id, in: &sequence)
        let brighter = try await rgb(sequence)
        XCTAssertGreaterThan(brighter[1], before[1] + 25, "+1 stop is clearly brighter")

        var (warm, warmID) = try await greySequence()
        try set(.colorCorrection, ["temperature": 100], on: warmID, in: &warm)
        let warmed = try await rgb(warm)
        XCTAssertGreaterThan(warmed[0], warmed[2] + 20, "warmer: more red than blue")
    }

    func testIdentityAndInvertLUTs() async throws {
        var (sequence, id) = try await greySequence()
        let before = try await rgb(sequence)
        let identity = try writeCube("identity.cube") { $0 }
        try set(.lut, [:], on: id, in: &sequence) { $0.lutPath = identity }
        let same = try await rgb(sequence)
        XCTAssertEqual(Double(same[1]), Double(before[1]), accuracy: 4, "an identity LUT changes nothing")

        var (inverted, invertedID) = try await greySequence()
        let invert = try writeCube("invert.cube") { $0.map { 1 - $0 } }
        try set(.lut, ["intensity": 100], on: invertedID, in: &inverted) { $0.lutPath = invert }
        let flipped = try await rgb(inverted)
        XCTAssertEqual(Double(flipped[1]), Double(255 - before[1]), accuracy: 16, "inverted in display values")

        var (missing, missingID) = try await greySequence()
        try set(.lut, [:], on: missingID, in: &missing) { $0.lutPath = "/nowhere/missing.cube" }
        let untouched = try await rgb(missing)
        XCTAssertEqual(Double(untouched[1]), Double(before[1]), accuracy: 4, "a missing file is skipped")
    }

    func testCurvesLiftTheMidtones() async throws {
        var (sequence, id) = try await greySequence()
        let before = try await rgb(sequence)
        var curves = ColorCurves()
        curves[.rgb] = [.init(0, 0), .init(0.5, 0.7), .init(1, 1)]
        try set(.colorCorrection, [:], on: id, in: &sequence) { $0.curves = curves }
        let lifted = try await rgb(sequence)
        XCTAssertGreaterThan(lifted[1], before[1] + 25)
    }

    func testColorCorrectionOnAnAdjustmentLayer() async throws {
        var (sequence, _) = try await greySequence()
        let before = try await rgb(sequence)
        let layer = try XCTUnwrap(sequence.addAdjustmentLayer(at: 0, duration: 30, trackID: sequence.videoTracks[1].id))
        try set(.colorCorrection, ["exposure": -2], on: layer, in: &sequence)
        let darker = try await rgb(sequence)
        XCTAssertLessThan(darker[1], before[1] - 30, "the track below is darkened")
    }
}
