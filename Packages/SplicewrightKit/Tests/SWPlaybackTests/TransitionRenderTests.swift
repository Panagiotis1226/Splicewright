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
        let middle = try level(try await render(sequence, frame: 60))
        XCTAssertLessThan(middle, 20)
        let quarter = try level(try await render(sequence, frame: 52))
        XCTAssertGreaterThan(quarter, 60, "still fading from white")
    }

    func testDipToWhite() async throws {
        let sequence = try await cutSequence(.dipToWhite)
        let middle = try level(try await render(sequence, frame: 60))
        XCTAssertGreaterThan(middle, 240)
        let late = try level(try await render(sequence, frame: 68))
        XCTAssertGreaterThan(late, 100, "fading from white into black")
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
        let middle = try level(try await render(sequence, frame: 60))
        XCTAssertGreaterThan(middle, 245)

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

/// Titles through the real compositor (no media needed).
final class TitleRenderTests: XCTestCase {
    override func setUp() async throws {
        guard MTLCreateSystemDefaultDevice() != nil, MetalRenderer.shared != nil else { throw XCTSkip("No Metal device") }
    }

    /// Just an opaque white box (the text is a space), so the centre pixel is known.
    private var boxed: TitleSpec {
        TitleSpec(text: " ", size: 0.2, color: .black, shadow: nil, background: .white)
    }

    private func render(_ sequence: EditSequence, frame: Int64) async throws -> CGImage {
        let output = await CompositionBuilder().build(sequence, project: Project(), cache: MediaAssetCache())
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: RationalTime(frames: frame, rate: sequence.rate).cmTime).image
    }

    private func green(_ image: CGImage, x: Double, y: Double) throws -> Int {
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

    func testTitleDrawsOverBlackAndFadesIn() async throws {
        var sequence = EditSequence(name: "T", settings: SequenceSettings(width: 640, height: 360, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        let v1 = sequence.videoTracks[0].id
        sequence.addTitle(boxed, at: 0, duration: 60, trackID: v1)
        let image = try await render(sequence, frame: 40)
        let box = try green(image, x: 0.5, y: 0.5)
        let outside = try green(image, x: 0.05, y: 0.05)
        XCTAssertGreaterThan(box, 240, "white box")
        XCTAssertLessThan(outside, 10, "black outside the title")

        sequence.addTransition(.crossDissolve, trackID: v1, at: 0, duration: 30)
        let fading = try await render(sequence, frame: 15)
        let level = try green(fading, x: 0.5, y: 0.5)
        XCTAssertGreaterThan(level, 120)
        XCTAssertLessThan(level, 235)
    }

    func testGlyphsAreDrawnAtTheTitlePosition() async throws {
        var sequence = EditSequence(name: "T", settings: SequenceSettings(width: 640, height: 360, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        // A full block, white, in the top-left quarter.
        let spec = TitleSpec(text: "\u{2588}\u{2588}", size: 0.3, positionX: 0.25, positionY: 0.3, shadow: nil)
        sequence.addTitle(spec, at: 0, duration: 30, trackID: sequence.videoTracks[0].id)
        let image = try await render(sequence, frame: 5)
        let glyph = try green(image, x: 0.25, y: 0.3)
        let elsewhere = try green(image, x: 0.75, y: 0.75)
        XCTAssertGreaterThan(glyph, 200, "the block glyph")
        XCTAssertLessThan(elsewhere, 10)
    }

    func testCaptionsBurnInAtTheBottomOnlyWhenEnabled() async throws {
        var sequence = EditSequence(name: "C", settings: SequenceSettings(width: 640, height: 360, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        // An invisible title makes the sequence two seconds long.
        sequence.addTitle(TitleSpec(text: " ", shadow: nil), at: 0, duration: 60, trackID: sequence.videoTracks[0].id)
        var style = CaptionStyle.standard
        style.title.background = nil
        style.title.size = 0.15
        let track = sequence.addCaptionTrack(name: "S", language: "en", style: style,
                                             captions: [Caption(start: 10, duration: 30, text: "\u{2588}\u{2588}")])
        let shown = try green(try await render(sequence, frame: 20), x: 0.5, y: style.title.positionY)
        let before = try green(try await render(sequence, frame: 5), x: 0.5, y: style.title.positionY)
        XCTAssertGreaterThan(shown, 200, "the caption's glyphs at the bottom")
        XCTAssertLessThan(before, 10, "nothing before the caption starts")
        sequence.updateCaptionTrack(track) { $0.isOutputEnabled = false }
        let hidden = try green(try await render(sequence, frame: 20), x: 0.5, y: style.title.positionY)
        XCTAssertLessThan(hidden, 10, "a hidden track isn't drawn")
    }

    func testTitleWhiteIsReferenceWhiteInPQ() throws {
        let renderer = try XCTUnwrap(MetalRenderer.shared)
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_64RGBAHalf, attributes, &buffer),
                       kCVReturnSuccess)
        let output = try XCTUnwrap(buffer)
        var spec = boxed
        spec.text = " "
        spec.size = 0.4
        try renderer.render(items: [.layer(.title(TitleFrame(spec: spec, opacity: 1)))], into: output, space: .rec2100PQ)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(output))
        let row = CVPixelBufferGetBytesPerRow(output)
        let centre = base.advanced(by: 45 * row + 80 * 8).assumingMemoryBound(to: UInt16.self)
        let green = Self.half(centre[1])
        // 203 cd/m² (BT.2408 reference white) is 58% PQ.
        XCTAssertEqual(green, 0.58, accuracy: 0.02)
    }

    /// IEEE half-precision bits to Float.
    private static func half(_ bits: UInt16) -> Float {
        let sign: Float = bits & 0x8000 == 0 ? 1 : -1
        let exponent = Int((bits >> 10) & 0x1F)
        let fraction = Float(bits & 0x3FF)
        if exponent == 0 { return sign * fraction * pow(2, -24) }
        return sign * (1 + fraction / 1024) * pow(2, Float(exponent - 15))
    }
}

/// Proxies replace a clip's video in playback, never in export.
final class ProxyPlaybackTests: XCTestCase {
    func testProxiesReplaceVideoOnlyWhenAsked() async throws {
        guard MTLCreateSystemDefaultDevice() != nil, MetalRenderer.shared != nil else { throw XCTSkip("No Metal device") }
        let root = FileManager.default.temporaryDirectory.appending(path: "proxy-playback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProxyStore(root: root)
        guard let url = try await FixtureWriter.writeVideo(
            FixtureWriter.h264SDR30(frames: 30, width: 1280, height: 720, fill: .grey(0.5, tenBit: false)),
            name: "proxy-playback.mov") else { throw XCTSkip("No H.264 encoder") }
        let imported = await MediaImporter().importMedia(from: [url], into: nil, existingPaths: [])
        let item = try XCTUnwrap(imported.items.first)
        var project = Project()
        project.addMedia([item])
        try await ProxyGenerator(store: store).makeProxy(for: item, preset: ProxyPreset(resolution: .half))

        var sequence = EditSequence(name: "P", settings: SequenceSettings(width: 1280, height: 720, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[0].id, clip: Clip(
            mediaID: item.id, name: "P", start: 0, duration: 30, sourceStart: .zero))])

        func sourceWidth(useProxies: Bool) async throws -> Double {
            let output = await CompositionBuilder(useProxies: useProxies, proxyStore: store)
                .build(sequence, project: project, cache: MediaAssetCache())
            let instruction = try XCTUnwrap(output.videoComposition.instructions.first as? CompositionInstruction)
            return try XCTUnwrap(instruction.layers.first).sourceWidth
        }
        let original = try await sourceWidth(useProxies: false)
        let proxied = try await sourceWidth(useProxies: true)
        XCTAssertEqual(original, 1280, "without proxies (and in export) the original is used")
        XCTAssertEqual(proxied, 640, "with proxies on, video comes from the half-size proxy")

        // The proxy still fills the frame with the clip's picture.
        let output = await CompositionBuilder(useProxies: true, proxyStore: store)
            .build(sequence, project: project, cache: MediaAssetCache())
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        let image = try await generator.image(at: CMTime(value: 10, timescale: 30)).image
        XCTAssertEqual(image.width, 1280)
    }
}

/// Scale, position and keyframed opacity through the real compositor.
final class MotionRenderTests: XCTestCase {
    private var project = Project()

    override func setUp() async throws {
        guard MTLCreateSystemDefaultDevice() != nil, MetalRenderer.shared != nil else { throw XCTSkip("No Metal device") }
    }

    private func whiteClipSequence() async throws -> (EditSequence, UUID) {
        guard let url = try await FixtureWriter.writeVideo(
            FixtureWriter.h264SDR30(frames: 60, width: 320, height: 180, fill: .grey(1, tenBit: false)),
            name: "motion-white.mov") else { throw XCTSkip("No H.264 encoder") }
        let imported = await MediaImporter().importMedia(from: [url], into: nil, existingPaths: [])
        let item = try XCTUnwrap(imported.items.first)
        project = Project()
        project.addMedia([item])
        var sequence = EditSequence(name: "M", settings: SequenceSettings(width: 320, height: 180, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        let clip = Clip(mediaID: item.id, name: "W", start: 0, duration: 60, sourceStart: .zero)
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[0].id, clip: clip)])
        return (sequence, clip.id)
    }

    private func green(_ sequence: EditSequence, frame: Int64, x: Double, y: Double, scale: Double = 1,
                       channel: Int = 1) async throws -> Int {
        let output = await CompositionBuilder(renderScale: scale).build(sequence, project: project, cache: MediaAssetCache())
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: RationalTime(frames: frame, rate: .fps30).cmTime).image
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
        return Int(bytes[(py * image.width + px) * 4 + channel])
    }

    func testMissingMediaShowsMediaOffline() async throws {
        let (sequence, _) = try await whiteClipSequence()
        let id = try XCTUnwrap(project.media.first?.id)
        project.relink(id, toPath: "/nonexistent/motion-white.mov", bookmark: nil)
        let red = try await green(sequence, frame: 10, x: 0.05, y: 0.05, channel: 0)
        let greenLevel = try await green(sequence, frame: 10, x: 0.05, y: 0.05)
        XCTAssertGreaterThan(red, 120, "a red Media Offline frame, not black")
        XCTAssertLessThan(greenLevel, 60)
    }

    func testScaleAndPosition() async throws {
        var (sequence, id) = try await whiteClipSequence()
        sequence.updateProperty(.scale, of: id) { $0.values = [50] }
        let centre = try await green(sequence, frame: 10, x: 0.5, y: 0.5)
        let corner = try await green(sequence, frame: 10, x: 0.1, y: 0.1)
        XCTAssertGreaterThan(centre, 240, "half-size white clip in the middle")
        XCTAssertLessThan(corner, 10, "black around it")
        // Move it right by a quarter of the frame (80 px): the left of centre goes black.
        sequence.updateProperty(.position, of: id) { $0.values = [80, 0] }
        let leftOfCentre = try await green(sequence, frame: 10, x: 0.3, y: 0.5)
        let rightOfCentre = try await green(sequence, frame: 10, x: 0.7, y: 0.5)
        XCTAssertLessThan(leftOfCentre, 10)
        XCTAssertGreaterThan(rightOfCentre, 240)
        // The same at half playback resolution: offsets scale with the preview.
        let halfRes = try await green(sequence, frame: 10, x: 0.7, y: 0.5, scale: 0.5)
        XCTAssertGreaterThan(halfRes, 240)
    }

    func testOpacityKeyframesFade() async throws {
        var (sequence, id) = try await whiteClipSequence()
        sequence.updateProperty(.opacity, of: id) { $0.setAnimated(true, at: .zero) }
        sequence.setProperty(.opacity, of: id, to: [0], atFrame: 30)
        let start = try await green(sequence, frame: 0, x: 0.5, y: 0.5)
        let middle = try await green(sequence, frame: 15, x: 0.5, y: 0.5)
        let end = try await green(sequence, frame: 40, x: 0.5, y: 0.5)
        XCTAssertGreaterThan(start, 240)
        XCTAssertGreaterThan(middle, 120)
        XCTAssertLessThan(middle, 235)
        XCTAssertLessThan(end, 10)
    }

    func testTitleMotion() async throws {
        var sequence = EditSequence(name: "T", settings: SequenceSettings(width: 320, height: 180, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        project = Project()
        let added = sequence.addTitle(TitleSpec(text: " ", size: 0.2, shadow: nil, background: .white), at: 0,
                                      duration: 30, trackID: sequence.videoTracks[0].id)
        let id = try XCTUnwrap(added)
        sequence.updateProperty(.position, of: id) { $0.values = [100, 0] }
        let moved = try await green(sequence, frame: 5, x: 0.5 + 100 / 320, y: 0.5)
        let original = try await green(sequence, frame: 5, x: 0.5, y: 0.5)
        XCTAssertGreaterThan(moved, 240, "the title's box moved right with Position")
        XCTAssertLessThan(original, 10)
    }
}

/// Speed, reverse and Time Remapping through the real composition. The fixture's frames get
/// brighter by 1% each, so a frame's level says which source frame is showing.
final class SpeedRenderTests: XCTestCase {
    private var project = Project()
    private var clipID = UUID()

    override func setUp() async throws {
        guard MTLCreateSystemDefaultDevice() != nil, MetalRenderer.shared != nil else { throw XCTSkip("No Metal device") }
        guard let url = try await FixtureWriter.writeVideo(
            FixtureWriter.h264SDR30(frames: 60, width: 160, height: 90), name: "speed-ramp.mov") else {
            throw XCTSkip("No H.264 encoder")
        }
        let imported = await MediaImporter().importMedia(from: [url], into: nil, existingPaths: [])
        let item = try XCTUnwrap(imported.items.first)
        project = Project()
        project.addMedia([item])
    }

    private func sequence(_ change: (inout Clip) -> Void = { _ in }) throws -> EditSequence {
        var sequence = EditSequence(name: "S", settings: SequenceSettings(width: 160, height: 90, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        let item = try XCTUnwrap(project.media.first)
        var clip = Clip(mediaID: item.id, name: "c", start: 0, duration: 60, sourceStart: .zero)
        change(&clip)
        clipID = clip.id
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[0].id, clip: clip)])
        return sequence
    }

    private func level(_ sequence: EditSequence, frame: Int64) async throws -> Int {
        let output = await CompositionBuilder().build(sequence, project: project, cache: MediaAssetCache())
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: RationalTime(frames: frame, rate: .fps30).cmTime).image
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Int(bytes[1])
    }

    /// The level of source frame `frame` at 100%.
    private func original(_ frame: Int64) async throws -> Int {
        try await level(try sequence(), frame: frame)
    }

    func testDoubleSpeedShowsEveryOtherFrame() async throws {
        let fast = try sequence { $0.speed = AnimatableProperty([200]); $0.duration = 30 }
        let shown = try await level(fast, frame: 10)
        let expected = try await original(20)
        let unchanged = try await original(10)
        XCTAssertEqual(shown, expected, accuracy: 2)
        XCTAssertNotEqual(shown, unchanged, "not the 100% frame")
    }

    func testHalfSpeedAndReverse() async throws {
        let slow = try sequence { $0.speed = AnimatableProperty([50]); $0.duration = 120 }
        let slowLevel = try await level(slow, frame: 40)
        let slowExpected = try await original(20)
        XCTAssertEqual(slowLevel, slowExpected, accuracy: 2)
        let reversed = try sequence { $0.isReversed = true; $0.sourceStart = RationalTime(frames: 59, rate: .fps30) }
        let first = try await level(reversed, frame: 0)
        let last = try await level(reversed, frame: 59)
        let sourceLast = try await original(59)
        let sourceFirst = try await original(0)
        XCTAssertEqual(first, sourceLast, accuracy: 2, "starts on the last frame")
        XCTAssertEqual(last, sourceFirst, accuracy: 2, "ends on the first")
    }

    func testTimeRemappingHoldsAndRamps() async throws {
        let remapped = try sequence { clip in
            // 100% for 20 frames, then held.
            clip.speed.setAnimated(true, at: .zero)
            clip.speed.set([0], at: RationalTime(frames: 20, rate: .fps30), tolerance: FrameRate.fps30.frameDuration)
            clip.speed.setInterpolation(.hold, for: Set(clip.speed.keyframes.map(\.id)))
        }
        let early = try await level(remapped, frame: 10)
        let earlyExpected = try await original(10)
        XCTAssertEqual(early, earlyExpected, accuracy: 2)
        let heldA = try await level(remapped, frame: 30)
        let heldB = try await level(remapped, frame: 50)
        XCTAssertEqual(heldA, heldB, accuracy: 1, "held")
        let heldExpected = try await original(20)
        XCTAssertEqual(heldA, heldExpected, accuracy: 2, "on the frame where the speed dropped to 0%")
    }

    func testPitchAlgorithmFollowsMaintainPitch() async throws {
        var edited = try sequence()
        let item = try XCTUnwrap(project.media.first)
        var audio = Clip(mediaID: item.id, name: "a", start: 0, duration: 30, sourceStart: .zero)
        audio.speed = AnimatableProperty([200])
        audio.maintainsPitch = false
        edited.overwrite([TrackPlacement(trackID: edited.audioTracks[0].id, clip: audio)])
        let output = await CompositionBuilder().build(edited, project: project, cache: MediaAssetCache())
        XCTAssertEqual(output.audioTimePitchAlgorithm, .varispeed)
    }
}
