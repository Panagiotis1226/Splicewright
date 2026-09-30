import Foundation
import SWCore

/// Locations of regenerable per-file caches (thumbnails, waveforms).
///
/// Cache keys include the file's size and modification date, so replacing a
/// file on disk invalidates its cached entries automatically.
public enum MediaCache {
    public static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "com.splicewright.Splicewright", directoryHint: .isDirectory)
    }

    public static func directory(_ name: String) -> URL {
        let url = rootDirectory.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A key that changes whenever the file at `url` changes.
    public static func fingerprint(of url: URL, extra: String = "") -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return StableHash.hex("\(url.standardizedFileURL.path)|\(size)|\(modified)|\(extra)")
    }
}
