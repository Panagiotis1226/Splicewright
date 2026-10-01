import Foundation

/// Auto-save settings, as in Premiere's Auto Save preferences.
public struct AutoSavePolicy: Sendable, Hashable, Codable {
    public var isEnabled: Bool
    /// Minutes between auto-saves (only taken when the project changed).
    public var intervalMinutes: Int
    /// Versions kept per project; older ones are deleted.
    public var maximumVersions: Int

    public init(isEnabled: Bool = true, intervalMinutes: Int = 5, maximumVersions: Int = 20) {
        self.isEnabled = isEnabled
        self.intervalMinutes = intervalMinutes
        self.maximumVersions = maximumVersions
    }

    public static let intervalRange = 1...60
    public static let versionsRange = 1...200

    public func clamped() -> AutoSavePolicy {
        AutoSavePolicy(isEnabled: isEnabled,
                       intervalMinutes: min(max(intervalMinutes, Self.intervalRange.lowerBound), Self.intervalRange.upperBound),
                       maximumVersions: min(max(maximumVersions, Self.versionsRange.lowerBound), Self.versionsRange.upperBound))
    }
}

/// One saved version: a normal `.splicewright` package, so it opens like any project.
public struct AutoSaveVersion: Sendable, Hashable {
    public var url: URL
    public var date: Date
    public var projectName: String
}

/// Writes timestamped copies of projects into `<root>/<project name> <key>/`, keeping the
/// newest `maximumVersions` of each.
public struct AutoSaveStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// A short, stable folder key for a project: from its file path, or from a per-window ID
    /// for a project that hasn't been saved yet.
    public static func key(for identity: String) -> String {
        // FNV-1a: stable across launches and platforms, unlike `hashValue`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(String(hash, radix: 16).suffix(8))
    }

    public static func folderName(projectName: String, key: String) -> String {
        "\(sanitized(projectName)) \(key)"
    }

    /// `Name 2026-10-01 at 14.05.09.splicewright` (local time, sortable).
    public static func fileName(projectName: String, date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        let stamp = "\(parts.year ?? 0)-\(two(parts.month))-\(two(parts.day)) at "
            + "\(two(parts.hour)).\(two(parts.minute)).\(two(parts.second))"
        return "\(sanitized(projectName)) \(stamp).\(ProjectFileCoder.packageExtension)"
    }

    static func sanitized(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "-" : $0 }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(80))
    }

    public func folder(projectName: String, key: String) -> URL {
        root.appendingPathComponent(Self.folderName(projectName: projectName, key: key), isDirectory: true)
    }

    /// Saves a version and deletes the oldest beyond `keep`. Returns the new version's URL.
    @discardableResult
    public func save(_ project: Project, projectName: String, key: String, date: Date = Date(),
                     keep: Int) throws -> URL {
        let folder = folder(projectName: projectName, key: key)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var package = folder.appendingPathComponent(Self.fileName(projectName: projectName, date: date), isDirectory: true)
        // Two saves within a second (rare) get a suffix rather than overwriting.
        var suffix = 2
        while fileManager.fileExists(atPath: package.path) {
            let base = Self.fileName(projectName: projectName, date: date)
                .replacingOccurrences(of: ".\(ProjectFileCoder.packageExtension)", with: "")
            package = folder.appendingPathComponent("\(base) \(suffix).\(ProjectFileCoder.packageExtension)",
                                                    isDirectory: true)
            suffix += 1
        }
        let data = try ProjectFileCoder.encode(project)
        // Write into a hidden temporary package, then rename it, so a crash mid-write never
        // leaves a half-written version.
        let temporary = folder.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        do {
            try data.write(to: temporary.appendingPathComponent(ProjectFileCoder.projectFileName), options: .atomic)
            try fileManager.moveItem(at: temporary, to: package)
            // The version's date is the time it was taken (versions are ordered by it).
            try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: package.path)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        prune(folder: folder, keep: keep)
        return package
    }

    /// Versions in one project's folder, newest first.
    public func versions(in folder: URL) -> [AutoSaveVersion] {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        let name = folder.lastPathComponent.split(separator: " ").dropLast().joined(separator: " ")
        return contents
            .filter { $0.pathExtension == ProjectFileCoder.packageExtension }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                return AutoSaveVersion(url: url, date: date, projectName: name)
            }
            .sorted { $0.date == $1.date ? $0.url.lastPathComponent > $1.url.lastPathComponent : $0.date > $1.date }
    }

    /// The newest version of every project, newest first.
    public func latestVersions() -> [AutoSaveVersion] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { versions(in: $0).first }.sorted { $0.date > $1.date }
    }

    /// Deletes all but the newest `keep` versions in `folder`.
    public func prune(folder: URL, keep: Int) {
        for version in versions(in: folder).dropFirst(max(1, keep)) {
            try? FileManager.default.removeItem(at: version.url)
        }
    }

    /// Total bytes used by auto-saves.
    public func totalSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
