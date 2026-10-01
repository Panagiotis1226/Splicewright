import Foundation
import SWCore

/// The kinds of files Splicewright keeps outside projects.
public enum CacheCategory: String, Sendable, Hashable, CaseIterable, Identifiable {
    case thumbnails
    case waveforms
    case proxies

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .thumbnails: return "Thumbnails"
        case .waveforms: return "Audio Waveforms"
        case .proxies: return "Proxies"
        }
    }

    /// What happens if it's deleted.
    public var deletionNote: String {
        switch self {
        case .thumbnails: return "Rebuilt automatically when needed."
        case .waveforms: return "Rebuilt automatically when needed."
        case .proxies: return "Clips play at full resolution until you create proxies again."
        }
    }
}

public struct CacheUsage: Sendable, Hashable {
    public var bytes: Int64
    public var files: Int

    public init(bytes: Int64 = 0, files: Int = 0) {
        self.bytes = bytes
        self.files = files
    }
}

public extension Notification.Name {
    /// Cache files were deleted. `userInfo["categories"]` is a `[String]` of `CacheCategory` raw values.
    static let splicewrightCacheCleared = Notification.Name("SplicewrightCacheCleared")
}

/// Measures and deletes Splicewright's caches. Deleting removes the files inside each cache
/// folder, never the folders, so writers that hold the folder keep working.
public final class CacheManager: @unchecked Sendable {
    public static let shared = CacheManager()

    private let cacheRoot: URL
    private let proxies: ProxyStore

    public init(cacheRoot: URL = MediaCache.rootDirectory, proxies: ProxyStore = .shared) {
        self.cacheRoot = cacheRoot
        self.proxies = proxies
    }

    public func directory(for category: CacheCategory) -> URL {
        switch category {
        case .thumbnails: return cacheRoot.appending(path: "Thumbnails", directoryHint: .isDirectory)
        case .waveforms: return cacheRoot.appending(path: "Waveforms", directoryHint: .isDirectory)
        case .proxies: return proxies.root
        }
    }

    /// Sizes on disk. Reads the file system, so call it off the main thread.
    public func usage() -> [CacheCategory: CacheUsage] {
        var result: [CacheCategory: CacheUsage] = [:]
        for category in CacheCategory.allCases {
            result[category] = files(in: category).reduce(into: CacheUsage()) { usage, file in
                usage.bytes += file.bytes
                usage.files += 1
            }
        }
        return result
    }

    /// Deletes everything in `categories`. Returns the bytes freed.
    @discardableResult
    public func delete(_ categories: Set<CacheCategory>) -> Int64 {
        var freed: Int64 = 0
        for category in categories {
            if category == .proxies {
                freed += proxies.deleteAll()
                // Also remove proxies the index doesn't know about (e.g. interrupted writes).
                freed += remove(files(in: .proxies))
            } else {
                freed += remove(files(in: category))
            }
        }
        announce(categories)
        return freed
    }

    /// Deletes cache files last modified more than `days` days ago. Returns the bytes freed.
    @discardableResult
    public func delete(olderThan days: Int, in categories: Set<CacheCategory> = Set(CacheCategory.allCases),
                       now: Date = Date()) -> Int64 {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var freed: Int64 = 0
        var touched: Set<CacheCategory> = []
        for category in categories {
            let old = files(in: category).filter { $0.modified < cutoff }
            guard !old.isEmpty else { continue }
            touched.insert(category)
            if category == .proxies {
                let names = Set(old.map { $0.url.lastPathComponent })
                freed += proxies.delete(proxies.records().filter { names.contains($0.fileName) })
                freed += remove(old.filter { FileManager.default.fileExists(atPath: $0.url.path) })
            } else {
                freed += remove(old)
            }
        }
        if !touched.isEmpty { announce(touched) }
        return freed
    }

    /// Deletes specific proxy files (from `ProxyStore.records()`).
    @discardableResult
    public func delete(proxies records: [ProxyRecord]) -> Int64 {
        let freed = proxies.delete(records)
        announce([.proxies])
        return freed
    }

    // MARK: - Files

    private struct CacheFile {
        var url: URL
        var bytes: Int64
        var modified: Date
    }

    private func files(in category: CacheCategory) -> [CacheFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory(for: category), includingPropertiesForKeys: keys)
        else { return [] }
        var result: [CacheFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            // The proxy index isn't a cache file.
            if category == .proxies && url.lastPathComponent == "index.json" { continue }
            result.append(CacheFile(url: url, bytes: Int64(values.fileSize ?? 0),
                                    modified: values.contentModificationDate ?? .distantPast))
        }
        return result
    }

    private func remove(_ files: [CacheFile]) -> Int64 {
        files.reduce(Int64(0)) { freed, file in
            (try? FileManager.default.removeItem(at: file.url)) != nil ? freed + file.bytes : freed
        }
    }

    private func announce(_ categories: Set<CacheCategory>) {
        let names = categories.map(\.rawValue)
        Task {
            if categories.contains(.thumbnails) { await ThumbnailProvider.shared.clearMemory() }
            if categories.contains(.waveforms) { await WaveformProvider.shared.clearMemory() }
            await MainActor.run {
                NotificationCenter.default.post(name: .splicewrightCacheCleared, object: nil,
                                                userInfo: ["categories": names])
            }
        }
    }
}
