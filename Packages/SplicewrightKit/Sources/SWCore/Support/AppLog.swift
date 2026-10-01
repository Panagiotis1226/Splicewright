import Foundation

/// A plain-text log file (Help ▸ Reveal Logs) for things worth knowing after the fact:
/// imports, proxies, exports, auto-saves, relinks and errors. It rolls over to
/// `<name>.1.log` at `maximumBytes`, so it never grows without bound.
public final class AppLog: @unchecked Sendable {
    public enum Level: String, Sendable {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    public static let shared = AppLog(directory: AppLog.defaultDirectory)

    public static var defaultDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return library.appendingPathComponent("Logs/Splicewright", isDirectory: true)
    }

    public let directory: URL
    public let maximumBytes: Int
    private let queue = DispatchQueue(label: "com.splicewright.log")
    private let formatter: ISO8601DateFormatter

    public init(directory: URL, name: String = "Splicewright", maximumBytes: Int = 2_000_000) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        fileURL = directory.appendingPathComponent("\(name).log")
        previousURL = directory.appendingPathComponent("\(name).1.log")
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public let fileURL: URL
    public let previousURL: URL

    public func info(_ message: @autoclosure () -> String, category: String = "app") {
        write(.info, message(), category: category)
    }

    public func warning(_ message: @autoclosure () -> String, category: String = "app") {
        write(.warning, message(), category: category)
    }

    public func error(_ message: @autoclosure () -> String, category: String = "app") {
        write(.error, message(), category: category)
    }

    public func write(_ level: Level, _ message: String, category: String, date: Date = Date()) {
        let line = "\(formatter.string(from: date)) [\(level.rawValue)] [\(category)] "
            + message.replacingOccurrences(of: "\n", with: " ") + "\n"
        queue.async { [self] in append(line) }
    }

    /// Waits for pending writes (tests, and before quitting).
    public func flush() {
        queue.sync {}
    }

    /// The current log's lines (for tests and diagnostics).
    public func lines() -> [String] {
        flush()
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    private func append(_ line: String) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + line.utf8.count > maximumBytes, size > 0 {
            try? fileManager.removeItem(at: previousURL)
            try? fileManager.moveItem(at: fileURL, to: previousURL)
        }
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
