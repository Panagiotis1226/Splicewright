import AVFoundation
import Metal
import SWTestSupport
import XCTest
@testable import SWCore
@testable import SWExport
@testable import SWMedia
@testable import SWPlayback

/// Exports real sequences with every preset, then probes and decodes the files.
/// Media is small (640×360, 1 s) because CI VMs encode HEVC and ProRes in software.
@MainActor
final class ExportTests: XCTestCase {
    private static let width = 640
    private static let height = 360
    private static let frames: Int64 = 30
    /// Fixtures are written once per run, not once per test.
    private static var fixtures: [String: URL] = [:]

    private var project = Project()
    private var sequence = EditSequence(name: "Export", settings: SequenceSettings(
        width: ExportTests.width, height: ExportTests.height, frameRate: .fps30, colorSpace: .rec709))

    override static func setUp() {
        super.setUp()
        // Stream test output to CI logs instead of buffering it until the process exits.
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    override func setUp() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        project = Project()
    }

    // MARK: - Helpers

    private func importClip(_ spec: FixtureWriter.VideoSpec, _ name: String) async throws -> MediaItem {
        if let url = Self.fixtures[name] { return try await importFile(url) }
        guard let url = try await FixtureWriter.writeVideo(spec, name: name) else {
            throw XCTSkip("Encoder for \(spec.codec.rawValue) unavailable on this machine")
        }
        Self.fixtures[name] = url
        return try await importFile(url)
    }

    private func tone() async throws -> MediaItem {
        let name = "export-tone.caf"
        if let url = Self.fixtures[name] { return try await importFile(url) }
        let url = try FixtureWriter.writeSine(name: name, seconds: 2)
        Self.fixtures[name] = url
        return try await importFile(url)
    }

    private func importFile(_ url: URL) async throws -> MediaItem {
        let result = await MediaImporter().importMedia(from: [url], into: nil, existingPaths: [])
        let item = try XCTUnwrap(result.items.first, "import failed: \(result.failures)")
        project.addMedia([item])
        return item
    }

    /// One second of mid grey on V1 with a tone on A1.
    private func makeSequence(_ space: SequenceColorSpace = .rec709, video: MediaItem, audio: MediaItem?) {
        sequence = EditSequence(name: "Export", settings: SequenceSettings(width: Self.width, height: Self.height,
                                                                           frameRate: .fps30, colorSpace: space))
        var placements = [TrackPlacement(trackID: sequence.videoTracks[0].id, clip: Clip(
            mediaID: video.id, name: video.name, start: 0, duration: Self.frames, sourceStart: .zero))]
        if let audio {
            placements.append(TrackPlacement(trackID: sequence.audioTracks[0].id, clip: Clip(
                mediaID: audio.id, name: audio.name, start: 0, duration: Self.frames, sourceStart: .zero)))
        }
        sequence.overwrite(placements)
    }

    private func export(_ settings: ExportSettings, name: String) async throws -> URL {
        let url = FixtureWriter.directory.appending(path: "export-\(name).\(settings.preset.container.fileExtension)")
        let session = ExportSession(sequence: sequence, project: project, settings: settings, outputURL: url)
        let state = try await Self.run(session, timeout: 90)
        if case .failed(let message) = state {
            // A missing hardware encoder on a CI host isn't a Splicewright bug.
            if message.contains("can't encode") { throw XCTSkip(message) }
            XCTFail("Export failed: \(message)")
        }
        XCTAssertEqual(state, .finished(url))
        XCTAssertEqual(session.progress, 1)
        return url
    }

    /// Runs an export, cancelling it and failing if it takes longer than `timeout` seconds.
    private static func run(_ session: ExportSession, timeout: Double) async throws -> ExportState {
        final class Flag { var value = false }
        let fired = Flag()
        let timer = Task { @MainActor in
            try await Task.sleep(for: .seconds(timeout))
            fired.value = true
            session.cancel()
        }
        let state = await session.run()
        timer.cancel()
        if fired.value {
            throw ExportTimeout(message: "export didn't finish in \(Int(timeout)) s (progress \(session.progress))")
        }
        return state
    }

    private struct ExportTimeout: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    private func greyLevel(of url: URL, atSeconds seconds: Double) async throws -> Int {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
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

    private func standardClips(_ space: SequenceColorSpace = .rec709) async throws {
        let video: MediaItem
        switch space {
        case .rec709:
            video = try await importClip(FixtureWriter.h264SDR30(frames: 30, width: Self.width, height: Self.height,
                                                                 fill: .grey(0.5, tenBit: false)), "export-grey.mov")
        case .rec2100HLG, .rec2100PQ:
            video = try await importClip(FixtureWriter.hevcHLG(fps5994: 60, width: Self.width, height: Self.height,
                                                               fill: .grey(0.5, tenBit: true)), "export-hlg-grey.mov")
        }
        makeSequence(space, video: video, audio: try await tone())
    }

    // MARK: - Presets

    func testH264SDR() async throws {
        try await standardClips()
        let url = try await export(ExportSettings(preset: .h264SDR), name: "h264")
        let info = try await MediaProber().probe(url)
        let video = try XCTUnwrap(info.video)
        XCTAssertEqual(info.container, .mpeg4)
        XCTAssertEqual(video.codec.family, .h264)
        XCTAssertEqual(video.bitDepth, 8)
        XCTAssertEqual(video.color, .rec709)
        XCTAssertEqual(video.frameRate, .fps30)
        XCTAssertEqual(video.width, Self.width)
        XCTAssertEqual(info.duration.frameIndex(at: .fps30), Self.frames)
        XCTAssertEqual(info.audio.first?.codec.displayName, "AAC")
        let grey = try await greyLevel(of: url, atSeconds: 0.5)
        XCTAssertLessThanOrEqual(abs(grey - 128), 24, "mid grey came out as \(grey)")
    }

    func testHEVCSDR() async throws {
        try await standardClips()
        let url = try await export(ExportSettings(preset: .hevcSDR), name: "hevc")
        let probed = try await MediaProber().probe(url)
        let video = try XCTUnwrap(probed.video)
        XCTAssertEqual(video.codec.family, .hevc)
        XCTAssertEqual(video.bitDepth, 8)
        XCTAssertEqual(video.color, .rec709)
    }

    func testHEVC10HLG() async throws {
        try await standardClips(.rec2100HLG)
        let url = try await export(ExportSettings(preset: .hevcHLG), name: "hevc-hlg")
        let info = try await MediaProber().probe(url)
        let video = try XCTUnwrap(info.video)
        XCTAssertEqual(info.container, .quickTime)
        XCTAssertEqual(video.codec.family, .hevc)
        XCTAssertEqual(video.bitDepth, 10)
        XCTAssertEqual(video.color, .rec2100HLG)
        XCTAssertEqual(info.duration.frameIndex(at: .fps30), Self.frames)
    }

    func testHEVC10PQ() async throws {
        try await standardClips(.rec2100HLG)
        let url = try await export(ExportSettings(preset: .hevcPQ), name: "hevc-pq")
        let probed = try await MediaProber().probe(url)
        let video = try XCTUnwrap(probed.video)
        XCTAssertEqual(video.bitDepth, 10)
        XCTAssertEqual(video.color, .rec2100PQ)
    }

    func testProResMatchesSequence() async throws {
        try await standardClips()
        let url = try await export(ExportSettings(preset: .proRes(for: sequence)), name: "prores")
        let info = try await MediaProber().probe(url)
        let video = try XCTUnwrap(info.video)
        XCTAssertEqual(video.codec, .proRes422HQ)
        XCTAssertEqual(video.color, .rec709)
        XCTAssertEqual(info.audio.first?.codec, .linearPCM)
    }

    // MARK: - Behaviour

    func testHDRSequenceToSDRDeliverableIsToneMapped() async throws {
        try await standardClips(.rec2100HLG)
        let url = try await export(ExportSettings(preset: .h264SDR), name: "hlg-to-sdr")
        let probed = try await MediaProber().probe(url)
        let video = try XCTUnwrap(probed.video)
        XCTAssertEqual(video.color, .rec709)
        let level = try await greyLevel(of: url, atSeconds: 0.5)
        XCTAssertGreaterThan(level, 40, "HLG grey should not export black")
        XCTAssertLessThan(level, 250, "HLG grey should not clip to white")
    }

    func testInToOutRange() async throws {
        try await standardClips()
        sequence.marks = SequenceMarks(inFrame: 5, outFrame: 19)
        let url = try await export(ExportSettings(preset: .h264SDR, range: .inToOut), name: "range")
        let info = try await MediaProber().probe(url)
        XCTAssertEqual(info.duration.frameIndex(at: .fps30), 15)
    }

    func testFrameSizeAndRateOptions() async throws {
        try await standardClips()
        let settings = ExportSettings(preset: .h264SDR, size: .lines(720), frameRate: .fps60)
        let url = try await export(settings, name: "720p60")
        let info = try await MediaProber().probe(url)
        let video = try XCTUnwrap(info.video)
        XCTAssertEqual(video.width, 1280)
        XCTAssertEqual(video.height, 720)
        XCTAssertEqual(video.frameRate, .fps60)
        XCTAssertEqual(info.duration.frameIndex(at: .fps60), Self.frames * 2)
    }

    func testProResFlavors() async throws {
        try await standardClips()
        for (codec, expected) in [(ExportCodec.proRes422LT, VideoCodec.proRes422LT), (.proRes422Proxy, .proRes422Proxy)] {
            let url = try await export(ExportSettings(preset: .proRes(codec, for: sequence)), name: codec.rawValue)
            let probed = try await MediaProber().probe(url)
            XCTAssertEqual(probed.video?.codec, expected)
        }
    }

    func testVideoOnlySequenceHasNoAudioTrack() async throws {
        let video = try await importClip(FixtureWriter.h264SDR30(frames: 30, width: Self.width, height: Self.height,
                                                                 fill: .grey(0.5, tenBit: false)), "export-grey.mov")
        makeSequence(video: video, audio: nil)
        let url = try await export(ExportSettings(preset: .h264SDR), name: "video-only")
        let probed = try await MediaProber().probe(url)
        XCTAssertTrue(probed.audio.isEmpty)
    }

    func testInvalidSettingsFailWithoutWriting() async throws {
        try await standardClips()
        var preset = ExportPreset.h264SDR
        preset.colorSpace = .rec2100PQ
        let url = FixtureWriter.directory.appending(path: "invalid.mp4")
        let session = ExportSession(sequence: sequence, project: project, settings: ExportSettings(preset: preset),
                                    outputURL: url)
        session.start()
        XCTAssertEqual(session.state, .failed(ExportValidationError.hdrNeedsTenBit.message))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCancelRemovesPartialFile() async throws {
        try await standardClips()
        let url = FixtureWriter.directory.appending(path: "cancelled.mov")
        let session = ExportSession(sequence: sequence, project: project,
                                    settings: ExportSettings(preset: .proRes(for: sequence)), outputURL: url)
        session.cancel()
        let state = try await Self.run(session, timeout: 30)
        XCTAssertEqual(state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
