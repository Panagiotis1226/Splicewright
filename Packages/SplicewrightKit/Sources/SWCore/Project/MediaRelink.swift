import Foundation

/// What a file on disk looks like right now (for spotting media that changed).
public struct FileFingerprint: Sendable, Hashable {
    public var size: Int64?
    public var modified: Date?

    public init(size: Int64?, modified: Date?) {
        self.size = size
        self.modified = modified
    }

    public static func of(path: String) -> FileFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return FileFingerprint(size: (attributes[.size] as? NSNumber)?.int64Value,
                               modified: attributes[.modificationDate] as? Date)
    }
}

public extension MediaItem {
    /// Whether the file at `filePath` differs from what was imported: a different size, or a
    /// different modification date when one was recorded.
    func hasChanged(comparedTo current: FileFingerprint) -> Bool {
        if let known = info.fileSize, let size = current.size, known != size { return true }
        if let known = fileModifiedAt, let modified = current.modified,
           abs(known.timeIntervalSince(modified)) > 1 { return true }
        return false
    }
}

/// A file that might be the missing media.
public struct RelinkCandidate: Sendable, Hashable {
    public var path: String
    public var size: Int64?

    public init(path: String, size: Int64?) {
        self.path = path
        self.size = size
    }

    var fileName: String { (path as NSString).lastPathComponent.lowercased() }
}

/// Matches offline media to files, the way Premiere's Link Media searches a folder: same
/// file name (ignoring case), preferring a file of the same size when several match.
public enum RelinkMatcher {
    /// Offline item ID → path of its match. A file is used for at most one item.
    public static func matches(for items: [MediaItem], in candidates: [RelinkCandidate]) -> [UUID: String] {
        let byName = Dictionary(grouping: candidates, by: \.fileName)
        var used = Set<String>()
        var result: [UUID: String] = [:]
        for item in items {
            let name = (item.filePath as NSString).lastPathComponent.lowercased()
            let options = (byName[name] ?? []).filter { !used.contains($0.path) }
            guard !options.isEmpty else { continue }
            let pick: RelinkCandidate?
            if let size = item.info.fileSize, let sameSize = options.first(where: { $0.size == size }) {
                pick = sameSize
            } else if item.info.fileSize != nil, options.contains(where: { $0.size != nil }) {
                // Every same-named file has a different size: it's probably a different file.
                pick = nil
            } else {
                pick = options.min { $0.path < $1.path }
            }
            if let pick {
                result[item.id] = pick.path
                used.insert(pick.path)
            }
        }
        return result
    }

    /// Files under `folder`, at most `depth` levels down, skipping hidden files and packages.
    public static func candidates(in folder: URL, depth: Int = 3, limit: Int = 20_000) -> [RelinkCandidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [RelinkCandidate] = []
        let baseDepth = folder.standardizedFileURL.pathComponents.count
        for case let url as URL in enumerator {
            if url.standardizedFileURL.pathComponents.count - baseDepth > depth {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            found.append(RelinkCandidate(path: url.standardizedFileURL.path, size: values.fileSize.map(Int64.init)))
            if found.count >= limit { break }
        }
        return found
    }
}
