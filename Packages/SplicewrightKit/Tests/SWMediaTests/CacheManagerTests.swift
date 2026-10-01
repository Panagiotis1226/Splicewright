import Foundation
import XCTest
@testable import SWCore
@testable import SWMedia

final class CacheManagerTests: XCTestCase {
    private var base: URL!
    private var manager: CacheManager!
    private var store: ProxyStore!

    override func setUp() {
        base = FileManager.default.temporaryDirectory.appending(path: "cache-tests-\(UUID().uuidString)")
        store = ProxyStore(root: base.appending(path: "Proxies"))
        manager = CacheManager(cacheRoot: base.appending(path: "Caches"), proxies: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    private func write(_ bytes: Int, to category: CacheCategory, name: String, age days: Double = 0) throws -> URL {
        let folder = manager.directory(for: category)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data(repeating: 1, count: bytes).write(to: url)
        let date = Date().addingTimeInterval(-days * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    /// A registered proxy for a fake source file.
    private func proxy(bytes: Int, name: String) throws -> (MediaItem, URL) {
        let source = base.appending(path: "\(name).mov")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 10).write(to: source)
        let info = MediaInfo(container: .quickTime, duration: RationalTime(value: 1, timescale: 1), video: nil, audio: [])
        let item = MediaItem(name: name, filePath: source.path, info: info)
        let url = store.url(for: item, preset: .standard)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 3, count: bytes).write(to: url)
        store.register(url, for: item, preset: .standard, width: 1920, height: 1080)
        return (item, url)
    }

    func testUsageAndDeletingOneCategory() throws {
        try write(1000, to: .thumbnails, name: "a.jpg")
        try write(500, to: .thumbnails, name: "b.jpg")
        try write(300, to: .waveforms, name: "a.json")
        try proxy(bytes: 4000, name: "clip")

        let usage = manager.usage()
        XCTAssertEqual(usage[.thumbnails], CacheUsage(bytes: 1500, files: 2))
        XCTAssertEqual(usage[.waveforms], CacheUsage(bytes: 300, files: 1))
        XCTAssertEqual(usage[.proxies], CacheUsage(bytes: 4000, files: 1), "the proxy index isn't counted")

        let cleared = expectation(forNotification: .splicewrightCacheCleared, object: nil) { note in
            (note.userInfo?["categories"] as? [String]) == ["thumbnails"]
        }
        XCTAssertEqual(manager.delete([.thumbnails]), 1500)
        wait(for: [cleared], timeout: 5)
        let after = manager.usage()
        XCTAssertEqual(after[.thumbnails], CacheUsage())
        XCTAssertEqual(after[.waveforms]?.files, 1, "other categories are untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.directory(for: .thumbnails).path),
                      "the folder itself stays")
    }

    func testDeletingAllAndSelectedProxies() throws {
        let (first, firstURL) = try proxy(bytes: 100, name: "one")
        let (second, _) = try proxy(bytes: 200, name: "two")
        let record = try XCTUnwrap(store.records().first { $0.sourceName == "two" })
        XCTAssertEqual(manager.delete(proxies: [record]), 200)
        XCTAssertNil(store.proxy(for: second))
        XCTAssertEqual(store.proxy(for: first)?.lastPathComponent, firstURL.lastPathComponent)

        try write(50, to: .waveforms, name: "w.json")
        XCTAssertEqual(manager.delete(Set(CacheCategory.allCases)), 150)
        XCTAssertNil(store.proxy(for: first))
        XCTAssertEqual(manager.usage().values.reduce(0) { $0 + $1.files }, 0)
    }

    func testDeletingOldFiles() throws {
        try write(100, to: .thumbnails, name: "old.jpg", age: 40)
        try write(100, to: .thumbnails, name: "new.jpg", age: 2)
        try write(100, to: .waveforms, name: "old.json", age: 31)
        XCTAssertEqual(manager.delete(olderThan: 30), 200)
        XCTAssertEqual(manager.usage()[.thumbnails], CacheUsage(bytes: 100, files: 1))
        XCTAssertEqual(manager.usage()[.waveforms], CacheUsage())
    }
}
