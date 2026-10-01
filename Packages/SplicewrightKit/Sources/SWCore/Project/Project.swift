import Foundation

/// The whole editable state of a `.splicewright` document.
///
/// `Project` is a value type: undo is implemented by keeping previous values,
/// and every mutation below is a pure function that can be unit-tested.
public struct Project: Sendable, Hashable, Codable {
    /// 2: adds `sequences`. 3: adds track transitions and title clips. 4: keyframeable clip
    /// motion, opacity and volume. 5: caption tracks. 6: clip speed, reverse and Time
    /// Remapping. 7: markers. Older files load unchanged.
    public static let currentSchemaVersion = 8

    public var schemaVersion: Int
    public var bins: [Bin]
    public var media: [MediaItem]
    public var sequences: [EditSequence]

    public init(bins: [Bin] = [], media: [MediaItem] = [], sequences: [EditSequence] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.bins = bins
        self.media = media
        self.sequences = sequences
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        bins = try container.decodeIfPresent([Bin].self, forKey: .bins) ?? []
        media = try container.decodeIfPresent([MediaItem].self, forKey: .media) ?? []
        sequences = try container.decodeIfPresent([EditSequence].self, forKey: .sequences) ?? []
        schemaVersion = Self.currentSchemaVersion
    }

    // MARK: - Lookup

    public func item(_ id: UUID) -> MediaItem? {
        media.first { $0.id == id }
    }

    public func bin(_ id: UUID) -> Bin? {
        bins.first { $0.id == id }
    }

    /// Items directly in `binID` (nil is the project root).
    public func items(inBin binID: UUID?) -> [MediaItem] {
        media.filter { $0.binID == binID }
    }

    public func containsMedia(atPath path: String) -> Bool {
        media.contains { $0.filePath == path }
    }

    // MARK: - Bins

    /// Adds a bin, choosing "Bin", "Bin 2", ... when `name` is taken.
    @discardableResult
    public mutating func addBin(named name: String = "Bin") -> Bin {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Bin" : name
        var candidate = base
        var suffix = 2
        let existing = Set(bins.map(\.name))
        while existing.contains(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        let bin = Bin(name: candidate)
        bins.append(bin)
        return bin
    }

    public mutating func renameBin(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = bins.firstIndex(where: { $0.id == id }) else { return }
        bins[index].name = trimmed
    }

    /// Removes a bin. Its media moves to the project root rather than being deleted.
    public mutating func deleteBin(_ id: UUID) {
        bins.removeAll { $0.id == id }
        for index in media.indices where media[index].binID == id {
            media[index].binID = nil
        }
    }

    // MARK: - Media

    /// Adds items, skipping any whose file is already in the project. Returns the items added.
    @discardableResult
    public mutating func addMedia(_ items: [MediaItem]) -> [MediaItem] {
        var paths = Set(media.map(\.filePath))
        var added: [MediaItem] = []
        for var item in items where !paths.contains(item.filePath) {
            if let binID = item.binID, bin(binID) == nil { item.binID = nil }
            paths.insert(item.filePath)
            media.append(item)
            added.append(item)
        }
        return added
    }

    /// Removes media and every timeline clip that uses it.
    public mutating func removeMedia(_ ids: Set<UUID>) {
        media.removeAll { ids.contains($0.id) }
        for index in sequences.indices {
            sequences[index].updateAllTracks { track in track.clips.removeAll { ids.contains($0.mediaID) } }
        }
    }

    /// Clips across all sequences that use `mediaID`.
    public func clipCount(usingMedia mediaID: UUID) -> Int {
        sequences.reduce(0) { total, sequence in
            total + sequence.allTracks.reduce(0) { $0 + $1.clips.filter { $0.mediaID == mediaID }.count }
        }
    }

    /// Source durations for trim/slip bounds.
    public var mediaDurations: MediaDurations {
        Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0.info.duration) })
    }

    // MARK: - Sequences

    public func sequence(_ id: UUID) -> EditSequence? {
        sequences.first { $0.id == id }
    }

    @discardableResult
    public mutating func addSequence(named name: String = "Sequence", settings: SequenceSettings) -> EditSequence {
        let existing = Set(sequences.map(\.name))
        var candidate = name
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(name) \(suffix)"
            suffix += 1
        }
        let sequence = EditSequence(name: candidate, settings: settings)
        sequences.append(sequence)
        return sequence
    }

    public mutating func updateSequence(_ id: UUID, _ change: (inout EditSequence) -> Void) {
        guard let index = sequences.firstIndex(where: { $0.id == id }) else { return }
        change(&sequences[index])
    }

    public mutating func deleteSequence(_ id: UUID) {
        sequences.removeAll { $0.id == id }
    }

    public mutating func renameSequence(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateSequence(id) { $0.name = trimmed }
    }

    public mutating func moveMedia(_ ids: Set<UUID>, toBin binID: UUID?) {
        if let binID, bin(binID) == nil { return }
        for index in media.indices where ids.contains(media[index].id) {
            media[index].binID = binID
        }
    }

    public mutating func renameMedia(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = media.firstIndex(where: { $0.id == id }) else { return }
        media[index].name = trimmed
    }

    /// Updates a clip's marks, clamped to the clip's duration and snapped to its frames.
    public mutating func updateMarks(of id: UUID, _ change: (inout SourceMarks) -> Void) {
        guard let index = media.firstIndex(where: { $0.id == id }) else { return }
        let info = media[index].info
        let rate = info.displayFrameRate
        let lastFrame = max(RationalTime.zero, info.duration - rate.frameDuration).snapped(to: rate)
        var marks = media[index].marks
        change(&marks)
        func clamp(_ time: RationalTime?) -> RationalTime? {
            time.map { min(max($0.snapped(to: rate), .zero), lastFrame) }
        }
        marks.inPoint = clamp(marks.inPoint)
        marks.outPoint = clamp(marks.outPoint)
        media[index].marks = marks
    }

    /// Points a media item at a new location (used when a moved file is found again).
    /// Sets or clears (nil) how a clip's colors are interpreted.
    public mutating func setColorOverride(_ color: ColorDescription?, for ids: Set<UUID>) {
        for index in media.indices where ids.contains(media[index].id) && media[index].info.video != nil {
            media[index].colorOverride = color
        }
    }

    public mutating func relink(_ id: UUID, toPath path: String, bookmark: Data?) {
        guard let index = media.firstIndex(where: { $0.id == id }) else { return }
        media[index].filePath = path
        if let bookmark { media[index].bookmark = bookmark }
    }

    /// Changes a media item's clip markers (Source monitor).
    public mutating func updateSourceMarkers(of id: UUID, _ change: (inout [SourceMarker]) -> Void) {
        guard let index = media.firstIndex(where: { $0.id == id }) else { return }
        change(&media[index].markers)
        media[index].markers.sort { $0.time < $1.time }
    }

    /// Records a file's new properties after it changed on disk (or was relinked).
    public mutating func updateMediaInfo(_ id: UUID, info: MediaInfo, modified: Date?) {
        guard let index = media.firstIndex(where: { $0.id == id }) else { return }
        media[index].info = info
        media[index].fileModifiedAt = modified
    }

    /// Adds media that isn't in the project yet (by ID), e.g. clips pasted from another project.
    public mutating func addMissingMedia(_ items: [MediaItem]) {
        let existing = Set(media.map(\.id))
        for item in items where !existing.contains(item.id) {
            var copy = item
            if let bin = copy.binID, self.bin(bin) == nil { copy.binID = nil }
            media.append(copy)
        }
    }
}

public enum ProjectFileError: Error, Equatable {
    case newerSchema(found: Int, supported: Int)
    case corrupt
}

/// Reads and writes `project.json` inside a `.splicewright` package.
public enum ProjectFileCoder {
    public static let projectFileName = "project.json"
    public static let packageExtension = "splicewright"

    public static func encode(_ project: Project) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return try encoder.encode(project)
    }

    public static func decode(_ data: Data) throws -> Project {
        struct VersionProbe: Decodable { var schemaVersion: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        guard let version = try? decoder.decode(VersionProbe.self, from: data).schemaVersion else {
            throw ProjectFileError.corrupt
        }
        guard version <= Project.currentSchemaVersion else {
            throw ProjectFileError.newerSchema(found: version, supported: Project.currentSchemaVersion)
        }
        return try decoder.decode(Project.self, from: data)
    }
}
