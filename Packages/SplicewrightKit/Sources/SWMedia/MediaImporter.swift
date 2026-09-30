import Foundation
import SWCore

public struct ImportFailure: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

public struct ImportResult: Sendable {
    public var items: [MediaItem]
    public var failures: [ImportFailure]
    /// Files skipped because they are already in the project.
    public var duplicates: [URL]
}

/// Turns dropped or chosen URLs into `MediaItem`s. Folders are searched recursively.
public struct MediaImporter: Sendable {
    public var prober: MediaProber
    /// How many files are probed at once.
    public var concurrency: Int

    public init(prober: MediaProber = MediaProber(), concurrency: Int = 4) {
        self.prober = prober
        self.concurrency = max(1, concurrency)
    }

    public func importMedia(from urls: [URL], into binID: UUID?, existingPaths: Set<String>) async -> ImportResult {
        let (files, unsupported) = expand(urls)
        var failures = unsupported.map { ImportFailure(url: $0, reason: "Unsupported file type (.\($0.pathExtension)).") }
        var duplicates: [URL] = []
        var seen = existingPaths
        var toProbe: [URL] = []
        for file in files {
            let path = file.standardizedFileURL.path
            if seen.contains(path) {
                duplicates.append(file)
            } else {
                seen.insert(path)
                toProbe.append(file)
            }
        }

        let outcomes = await probeAll(toProbe)
        var items: [MediaItem] = []
        for (url, outcome) in zip(toProbe, outcomes) {
            switch outcome {
            case .success(let info):
                if let blocking = MediaSupport.warnings(for: info).first(where: \.isBlocking) {
                    failures.append(ImportFailure(url: url, reason: blocking.message))
                    continue
                }
                items.append(MediaItem(
                    name: url.deletingPathExtension().lastPathComponent,
                    filePath: url.standardizedFileURL.path,
                    bookmark: try? url.bookmarkData(),
                    info: info,
                    binID: binID
                ))
            case .failure(let error):
                failures.append(ImportFailure(url: url, reason: error.localizedDescription))
            }
        }
        return ImportResult(items: items, failures: failures, duplicates: duplicates)
    }

    /// Probes files with bounded concurrency, returning results in input order.
    private func probeAll(_ urls: [URL]) async -> [Result<MediaInfo, Error>] {
        var results = [Result<MediaInfo, Error>?](repeating: nil, count: urls.count)
        let prober = self.prober
        await withTaskGroup(of: (Int, Result<MediaInfo, Error>).self) { group in
            var next = 0
            func addNext() {
                guard next < urls.count else { return }
                let index = next
                let url = urls[index]
                next += 1
                group.addTask {
                    do { return (index, .success(try await prober.probe(url))) } catch { return (index, .failure(error)) }
                }
            }
            for _ in 0..<min(concurrency, urls.count) { addNext() }
            while let (index, result) = await group.next() {
                results[index] = result
                addNext()
            }
        }
        return results.map { $0 ?? .failure(CocoaError(.fileReadUnknown)) }
    }

    /// Splits URLs into importable files (folders expanded) and rejected files.
    func expand(_ urls: [URL]) -> (files: [URL], unsupported: [URL]) {
        var files: [URL] = []
        var unsupported: [URL] = []
        let fileManager = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                unsupported.append(url)
                continue
            }
            if isDirectory.boolValue {
                let enumerator = fileManager.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let child = enumerator?.nextObject() as? URL {
                    if ImportPolicy.isImportable(child) { files.append(child) }
                }
            } else if ImportPolicy.isImportable(url) {
                files.append(url)
            } else {
                unsupported.append(url)
            }
        }
        return (files, unsupported)
    }
}

/// Finds media that moved since the project was saved, using stored bookmarks.
public enum MediaLocator {
    public struct Relocation: Sendable {
        public var id: UUID
        public var path: String
        public var refreshedBookmark: Data?
    }

    public static func isOnline(_ item: MediaItem) -> Bool {
        FileManager.default.fileExists(atPath: item.filePath)
    }

    /// New locations for offline items whose bookmarks still resolve.
    public static func relocatedItems(in project: Project) -> [Relocation] {
        var moved: [Relocation] = []
        for item in project.media where !isOnline(item) {
            guard let bookmark = item.bookmark else { continue }
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            let refreshed = isStale ? (try? url.bookmarkData()) : nil
            moved.append(Relocation(id: item.id, path: url.standardizedFileURL.path, refreshedBookmark: refreshed))
        }
        return moved
    }
}
