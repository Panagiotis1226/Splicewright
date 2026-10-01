import AVFoundation
import SWTestSupport
import XCTest
@testable import SWCore
@testable import SWMedia

final class ProxyTests: XCTestCase {
    private var store: ProxyStore!
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "proxy-tests-\(UUID().uuidString)")
        store = ProxyStore(root: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func importClip(_ spec: FixtureWriter.VideoSpec, _ name: String) async throws -> MediaItem {
        guard let url = try await FixtureWriter.writeVideo(spec, name: name) else {
            throw XCTSkip("Encoder for \(spec.codec.rawValue) unavailable")
        }
        let result = await MediaImporter().importMedia(from: [url], into: nil, existingPaths: [])
        return try XCTUnwrap(result.items.first, "import failed: \(result.failures)")
    }

    func testHalfResolutionProResProxy() async throws {
        let item = try await importClip(FixtureWriter.h264SDR30(frames: 30, width: 1280, height: 720,
                                                                fill: .grey(0.5, tenBit: false)), "proxy-source.mov")
        let preset = ProxyPreset(resolution: .half)
        let url = try await ProxyGenerator(store: store).makeProxy(for: item, preset: preset)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        let info = try await MediaProber().probe(url)
        let video = try XCTUnwrap(info.video)
        XCTAssertEqual(video.codec, .proRes422Proxy)
        XCTAssertEqual(video.width, 640)
        XCTAssertEqual(video.height, 360)
        XCTAssertEqual(video.color, .rec709)
        XCTAssertEqual(info.duration.frameIndex(at: .fps30), 30)
        XCTAssertTrue(info.audio.isEmpty, "proxies are video only")

        XCTAssertEqual(store.proxy(for: item)?.lastPathComponent, url.lastPathComponent)
        XCTAssertEqual(store.records().count, 1)
        XCTAssertEqual(store.records().first?.width, 640)
        let freed = store.deleteProxies(of: [item])
        XCTAssertGreaterThan(freed, 0)
        XCTAssertNil(store.proxy(for: item))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testHLGProxyKeepsColorAndDepth() async throws {
        let item = try await importClip(FixtureWriter.hevcHLG(fps5994: 30, width: 1280, height: 720,
                                                              fill: .grey(0.5, tenBit: true)), "proxy-hlg.mov")
        let url = try await ProxyGenerator(store: store).makeProxy(for: item, preset: ProxyPreset(resolution: .p720,
                                                                                                  codec: .proRes422LT))
        let probed = try await MediaProber().probe(url)
        let video = try XCTUnwrap(probed.video)
        XCTAssertEqual(video.codec, .proRes422LT)
        XCTAssertEqual(video.color, .rec2100HLG)
        XCTAssertEqual(video.bitDepth, 10)
        XCTAssertEqual(video.frameRate, .fps59_94)
    }

    func testCancelLeavesNoFile() async throws {
        let item = try await importClip(FixtureWriter.h264SDR30(frames: 30, width: 1280, height: 720), "proxy-cancel.mov")
        let generator = ProxyGenerator(store: store)
        generator.cancel()
        do {
            try await generator.makeProxy(for: item, preset: .standard)
            XCTFail("expected cancellation")
        } catch let error as ProxyError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertNil(store.proxy(for: item))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(leftovers.filter { $0.hasSuffix(".mov") }.isEmpty, "\(leftovers)")
    }
}
