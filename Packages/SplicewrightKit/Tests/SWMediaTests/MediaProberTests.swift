import AVFoundation
import SWTestSupport
import XCTest
@testable import SWCore
@testable import SWMedia

final class MediaProberTests: XCTestCase {
    private let prober = MediaProber()

    private func fixture(_ spec: FixtureWriter.VideoSpec, _ name: String) async throws -> URL {
        guard let url = try await FixtureWriter.writeVideo(spec, name: name) else {
            throw XCTSkip("This machine can't encode \(spec.codec.rawValue) (common on virtualized CI hosts).")
        }
        return url
    }

    func testH264SDR2997() async throws {
        let url = try await fixture(FixtureWriter.h264SDR(), "h264-2997.mp4")
        let info = try await prober.probe(url)
        let video = try XCTUnwrap(info.video)
        XCTAssertEqual(info.container, .mpeg4)
        XCTAssertEqual(video.codec.family, .h264)
        XCTAssertEqual(video.width, 1920)
        XCTAssertEqual(video.height, 1080)
        XCTAssertEqual(video.frameRate, .fps29_97)
        XCTAssertEqual(video.bitDepth, 8)
        XCTAssertEqual(video.color, .rec709)
        XCTAssertEqual(video.dynamicRange, .sdr)
        XCTAssertFalse(video.isVariableFrameRate)
        // The writer may or may not extend the last frame's duration.
        XCTAssertTrue((29...30).contains(info.duration.frameIndex(at: .fps29_97)))
    }

    func testHEVCMain10HLG5994() async throws {
        let url = try await fixture(FixtureWriter.hevcHLG(), "hevc-hlg-5994.mov")
        let info = try await prober.probe(url)
        let video = try XCTUnwrap(info.video)
        XCTAssertEqual(info.container, .quickTime)
        XCTAssertEqual(video.codec.family, .hevc)
        XCTAssertEqual(video.resolutionName, "UHD 4K")
        XCTAssertEqual(video.frameRate, .fps59_94)
        XCTAssertEqual(video.bitDepth, 10)
        XCTAssertEqual(video.chroma, .yuv420)
        XCTAssertEqual(video.color, .rec2100HLG)
        XCTAssertEqual(video.dynamicRange, .hlg)
        // VideoToolbox adds Dolby Vision 8.4 metadata to HLG HEVC, as iPhones do.
        let warnings = MediaSupport.warnings(for: info).filter { $0 != .dolbyVisionReadAsHLG }
        XCTAssertEqual(warnings, [], "nominal fps \(video.nominalFPS)")
    }

    func testHEVCPQ() async throws {
        let url = try await fixture(FixtureWriter.hevcPQ(), "hevc-pq-30.mp4")
        let info = try await prober.probe(url)
        let video = try XCTUnwrap(info.video)
        XCTAssertEqual(video.color, .rec2100PQ)
        XCTAssertEqual(video.dynamicRange, .pq)
        XCTAssertEqual(video.frameRate, .fps30)
        XCTAssertEqual(video.bitDepth, 10)
    }

    func testProRes422() async throws {
        let url = try await fixture(FixtureWriter.proRes422(), "prores-25.mov")
        let info = try await prober.probe(url)
        let video = try XCTUnwrap(info.video)
        XCTAssertEqual(video.codec, .proRes422)
        XCTAssertEqual(video.frameRate, .fps25)
        XCTAssertEqual(video.bitDepth, 10)
        XCTAssertEqual(video.chroma, .yuv422)
    }

    func testAudioOnlyFile() async throws {
        let url = try FixtureWriter.writeSine(name: "tone.caf", seconds: 2)
        let info = try await prober.probe(url)
        XCTAssertNil(info.video)
        XCTAssertEqual(info.kind, .audio)
        XCTAssertEqual(info.audio.first?.sampleRate, 48_000)
        XCTAssertEqual(info.audio.first?.channelCount, 2)
        XCTAssertEqual(info.duration.seconds, 2, accuracy: 0.01)
    }

    func testUnreadableFileFails() async throws {
        let url = FixtureWriter.directory.appending(path: "not-a-movie.mov")
        try Data("definitely not a movie".utf8).write(to: url)
        do {
            _ = try await prober.probe(url)
            XCTFail("Expected probing garbage to fail")
        } catch {
            // Any error is fine; the importer reports it to the user.
        }
    }
}

final class MediaImporterTests: XCTestCase {
    func testImportsFolderSkipsDuplicatesAndRejectsUnsupported() async throws {
        let folder = FixtureWriter.directory.appending(path: "import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tone = try FixtureWriter.writeSine(name: "import-tone.caf")
        let copied = folder.appending(path: "tone.caf")
        try FileManager.default.copyItem(at: tone, to: copied)
        try Data().write(to: folder.appending(path: "notes.txt"))
        let unsupported = FixtureWriter.directory.appending(path: "clip.mkv")
        try Data().write(to: unsupported)

        let importer = MediaImporter()
        let first = await importer.importMedia(from: [folder, unsupported], into: nil, existingPaths: [])
        XCTAssertEqual(first.items.map(\.name), ["tone"])
        XCTAssertEqual(first.failures.map(\.url.lastPathComponent), ["clip.mkv"])
        XCTAssertNotNil(first.items.first?.bookmark)

        let existing = Set(first.items.map(\.filePath))
        let second = await importer.importMedia(from: [copied], into: nil, existingPaths: existing)
        XCTAssertTrue(second.items.isEmpty)
        XCTAssertEqual(second.duplicates.count, 1)
    }
}

final class WaveformProviderTests: XCTestCase {
    func testPeaksTrackAmplitudePerChannel() async throws {
        let url = try FixtureWriter.writeSine(name: "wave.caf", seconds: 1, amplitude: 0.5)
        let peaks = try await WaveformProvider.generate(url: url)
        XCTAssertEqual(peaks.channels.count, 2)
        XCTAssertEqual(peaks.sampleRate, 48_000)
        XCTAssertEqual(peaks.bucketCount, 200)
        let left = peaks.channels[0].max().map { Float($0) / 255 } ?? 0
        let right = peaks.channels[1].max().map { Float($0) / 255 } ?? 0
        XCTAssertEqual(left, 0.5, accuracy: 0.02)
        XCTAssertEqual(right, 0.25, accuracy: 0.02)
    }

    func testThumbnailForVideo() async throws {
        guard let url = try await FixtureWriter.writeVideo(FixtureWriter.h264SDR(fps2997: 10), name: "thumb.mp4") else {
            throw XCTSkip("H.264 encoder unavailable")
        }
        let provider = ThumbnailProvider(directory: FixtureWriter.directory)
        let image = await provider.thumbnail(for: url, at: 0, maxPixels: 160)
        XCTAssertEqual(image?.width, 160)
    }
}
