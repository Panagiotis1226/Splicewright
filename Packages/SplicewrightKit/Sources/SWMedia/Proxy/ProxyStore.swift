import Foundation
import SWCore

/// One proxy file on disk.
public struct ProxyRecord: Sendable, Hashable, Codable, Identifiable {
    public var fileName: String
    /// Identifies the source file's contents (path, size, modification date).
    public var sourceKey: String
    public var sourcePath: String
    public var sourceName: String
    public var presetTag: String
    public var width: Int
    public var height: Int
    public var bytes: Int64
    public var created: Date

    public var id: String { fileName }
}

/// Where proxies live and which ones exist. Proxies are found from the source file itself,
/// so projects don't store proxy paths: a proxy made in one project works in every project
/// that uses the same file, and a changed source file simply has no proxy.
///
/// Thread-safe; file operations are quick and done under a lock.
public final class ProxyStore: @unchecked Sendable {
    public static let shared = ProxyStore()

    /// UserDefaults key for a custom proxy folder.
    public static let locationDefaultsKey = "proxyLocation"
    private static let indexName = "index.json"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let fixedRoot: URL?
    /// The index as last read or written, for the folder it belongs to.
    private var cachedIndex: (root: URL, records: [ProxyRecord])?

    /// `root` overrides the user's setting (tests).
    public init(root: URL? = nil, defaults: UserDefaults = .standard) {
        fixedRoot = root
        self.defaults = defaults
    }

    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Splicewright/Proxies", directoryHint: .isDirectory)
    }

    public var root: URL {
        if let fixedRoot { return fixedRoot }
        if let path = defaults.string(forKey: Self.locationDefaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return Self.defaultRoot
    }

    public static func sourceKey(for item: MediaItem) -> String {
        MediaCache.fingerprint(of: item.url, extra: "proxy")
    }

    /// Where a new proxy for `item` at `preset` is written.
    public func url(for item: MediaItem, preset: ProxyPreset) -> URL {
        root.appending(path: "\(Self.sourceKey(for: item))-\(preset.tag).mov")
    }

    /// The newest existing proxy for `item`, at any preset.
    public func proxy(for item: MediaItem) -> URL? {
        let key = Self.sourceKey(for: item)
        return records().filter { $0.sourceKey == key }.max { $0.created < $1.created }
            .map { root.appending(path: $0.fileName) }
    }

    public func records() -> [ProxyRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadIndex().filter { FileManager.default.fileExists(atPath: root.appending(path: $0.fileName).path) }
    }

    /// Records a finished proxy file (already moved to `url`).
    public func register(_ url: URL, for item: MediaItem, preset: ProxyPreset, width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var index = loadIndex().filter { $0.fileName != url.lastPathComponent }
        index.append(ProxyRecord(fileName: url.lastPathComponent, sourceKey: Self.sourceKey(for: item),
                                 sourcePath: item.filePath, sourceName: item.name, presetTag: preset.tag,
                                 width: width, height: height, bytes: size, created: Date()))
        saveIndex(index)
    }

    /// Deletes every proxy of these items. Returns the bytes freed.
    @discardableResult
    public func deleteProxies(of items: [MediaItem]) -> Int64 {
        let keys = Set(items.map(Self.sourceKey))
        return delete { keys.contains($0.sourceKey) }
    }

    /// Deletes the given proxy files. Returns the bytes freed.
    @discardableResult
    public func delete(_ records: [ProxyRecord]) -> Int64 {
        let names = Set(records.map(\.fileName))
        return delete { names.contains($0.fileName) }
    }

    @discardableResult
    public func deleteAll() -> Int64 {
        delete { _ in true }
    }

    private func delete(where matches: (ProxyRecord) -> Bool) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        var freed: Int64 = 0
        var index = loadIndex()
        for record in index where matches(record) {
            let url = root.appending(path: record.fileName)
            freed += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            try? FileManager.default.removeItem(at: url)
        }
        index.removeAll(where: matches)
        saveIndex(index)
        return freed
    }

    // MARK: - Index (call with the lock held)

    private func loadIndex() -> [ProxyRecord] {
        let root = self.root
        if let cachedIndex, cachedIndex.root == root { return cachedIndex.records }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: root.appending(path: Self.indexName)),
              let records = try? decoder.decode([ProxyRecord].self, from: data) else {
            cachedIndex = (root, [])
            return []
        }
        cachedIndex = (root, records)
        return records
    }

    private func saveIndex(_ records: [ProxyRecord]) {
        cachedIndex = (root, records)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: root.appending(path: Self.indexName), options: .atomic)
    }
}
