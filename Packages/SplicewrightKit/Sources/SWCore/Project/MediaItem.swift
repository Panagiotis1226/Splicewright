import Foundation

/// In and out marks on a source clip. The out point is inclusive, as in Premiere:
/// marking in and out on the same frame selects exactly one frame.
public struct SourceMarks: Sendable, Hashable, Codable {
    public var inPoint: RationalTime?
    public var outPoint: RationalTime?

    public init(inPoint: RationalTime? = nil, outPoint: RationalTime? = nil) {
        self.inPoint = inPoint
        self.outPoint = outPoint
    }

    public static let empty = SourceMarks()

    /// Sets the in point. An existing out point before the new in point is cleared.
    public mutating func setIn(_ time: RationalTime) {
        inPoint = time
        if let out = outPoint, out < time { outPoint = nil }
    }

    /// Sets the out point. An existing in point after the new out point is cleared.
    public mutating func setOut(_ time: RationalTime) {
        outPoint = time
        if let inTime = inPoint, inTime > time { inPoint = nil }
    }

    /// The marked range for media of `duration` at `rate`, defaulting to the whole clip.
    public func range(duration: RationalTime, rate: FrameRate) -> TimeRange {
        let start = inPoint ?? .zero
        let end: RationalTime
        if let out = outPoint {
            end = min(out + rate.frameDuration, duration)
        } else {
            end = duration
        }
        return TimeRange(start: start, end: max(start, end))
    }
}

/// A file imported into the project. Media is always referenced, never copied.
public struct MediaItem: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// Absolute path at import time. `bookmark` is used to find the file if it moves.
    public var filePath: String
    public var bookmark: Data?
    public var info: MediaInfo
    public var binID: UUID?
    public var marks: SourceMarks
    public var importedAt: Date
    /// "Interpret Footage": replaces the file's color tags when set. Optional, so older
    /// projects decode without it.
    public var colorOverride: ColorDescription?
    /// The file's modification date when it was last read, for spotting files that changed.
    public var fileModifiedAt: Date?
    /// Clip markers added in the Source monitor (schema 7).
    public var markers: [SourceMarker]

    public init(id: UUID = UUID(), name: String, filePath: String, bookmark: Data? = nil,
                info: MediaInfo, binID: UUID? = nil, marks: SourceMarks = .empty, importedAt: Date = Date(),
                fileModifiedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.filePath = filePath
        self.bookmark = bookmark
        self.info = info
        self.binID = binID
        self.marks = marks
        self.importedAt = importedAt
        self.fileModifiedAt = fileModifiedAt
        markers = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, filePath, bookmark, info, binID, marks, importedAt, colorOverride, fileModifiedAt, markers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        filePath = try container.decode(String.self, forKey: .filePath)
        bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
        info = try container.decode(MediaInfo.self, forKey: .info)
        binID = try container.decodeIfPresent(UUID.self, forKey: .binID)
        marks = try container.decodeIfPresent(SourceMarks.self, forKey: .marks) ?? .empty
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date(timeIntervalSince1970: 0)
        colorOverride = try container.decodeIfPresent(ColorDescription.self, forKey: .colorOverride)
        fileModifiedAt = try container.decodeIfPresent(Date.self, forKey: .fileModifiedAt)
        markers = try container.decodeIfPresent([SourceMarker].self, forKey: .markers) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(filePath, forKey: .filePath)
        try container.encodeIfPresent(bookmark, forKey: .bookmark)
        try container.encode(info, forKey: .info)
        try container.encodeIfPresent(binID, forKey: .binID)
        try container.encode(marks, forKey: .marks)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encodeIfPresent(colorOverride, forKey: .colorOverride)
        try container.encodeIfPresent(fileModifiedAt, forKey: .fileModifiedAt)
        if !markers.isEmpty { try container.encode(markers, forKey: .markers) }
    }

    public var url: URL { URL(fileURLWithPath: filePath) }

    public var warnings: [MediaWarning] { MediaSupport.warnings(for: info) }

    /// The color interpretation used for rendering: the override, else the file's tags.
    public var effectiveColor: ColorDescription? {
        colorOverride ?? info.video?.color
    }
}

/// A folder in the Project panel. Bins are flat in v1.
public struct Bin: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
