import Foundation

/// Premiere's marker colors.
public enum MarkerColor: String, Sendable, Hashable, Codable, CaseIterable {
    case green, red, purple, orange, yellow, white, blue, cyan

    public var displayName: String { rawValue.capitalized }

    /// sRGB components for drawing.
    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .green: return (0.38, 0.78, 0.33)
        case .red: return (0.89, 0.25, 0.25)
        case .purple: return (0.66, 0.42, 0.85)
        case .orange: return (0.95, 0.56, 0.18)
        case .yellow: return (0.93, 0.84, 0.25)
        case .white: return (0.92, 0.92, 0.92)
        case .blue: return (0.29, 0.55, 0.95)
        case .cyan: return (0.27, 0.82, 0.86)
        }
    }
}

/// A sequence marker: a point (duration 0) or a range, with a name and notes. Chapter
/// markers become YouTube chapters and chapter marks in exported files.
public struct Marker: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var frame: Int64
    public var duration: Int64
    public var name: String
    public var comment: String
    public var color: MarkerColor
    public var isChapter: Bool

    public init(id: UUID = UUID(), frame: Int64, duration: Int64 = 0, name: String = "", comment: String = "",
                color: MarkerColor = .green, isChapter: Bool = false) {
        self.id = id
        self.frame = max(0, frame)
        self.duration = max(0, duration)
        self.name = name
        self.comment = comment
        self.color = color
        self.isChapter = isChapter
    }

    public var end: Int64 { frame + duration }

    /// The name, or a placeholder for drawing and lists.
    public var title: String { name.isEmpty ? "Marker" : name }
}

/// A marker on source media (added in the Source monitor). It's in source time, so it appears
/// on every clip that uses that part of the file.
public struct SourceMarker: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var time: RationalTime
    public var name: String
    public var comment: String
    public var color: MarkerColor

    public init(id: UUID = UUID(), time: RationalTime, name: String = "", comment: String = "", color: MarkerColor = .green) {
        self.id = id
        self.time = time
        self.name = name
        self.comment = comment
        self.color = color
    }
}

public extension EditSequence {
    /// Adds a marker at `frame` (replacing nothing: two markers can share a frame, as in Premiere).
    @discardableResult
    mutating func addMarker(at frame: Int64, name: String = "", color: MarkerColor = .green) -> UUID {
        let marker = Marker(frame: frame, name: name, color: color)
        markers.append(marker)
        sortMarkers()
        return marker.id
    }

    mutating func updateMarker(_ id: UUID, _ change: (inout Marker) -> Void) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        change(&markers[index])
        markers[index].frame = max(0, markers[index].frame)
        markers[index].duration = max(0, markers[index].duration)
        sortMarkers()
    }

    mutating func deleteMarkers(_ ids: Set<UUID>) {
        markers.removeAll { ids.contains($0.id) }
    }

    func marker(_ id: UUID) -> Marker? {
        markers.first { $0.id == id }
    }

    /// The first marker after `frame`, if any.
    func nextMarker(after frame: Int64) -> Marker? {
        markers.first { $0.frame > frame }
    }

    func previousMarker(before frame: Int64) -> Marker? {
        markers.last { $0.frame < frame }
    }

    /// Markers covering `frame` (points exactly on it, ranges containing it).
    func markers(at frame: Int64) -> [Marker] {
        markers.filter { $0.duration == 0 ? $0.frame == frame : ($0.frame..<$0.end).contains(frame) }
    }

    private mutating func sortMarkers() {
        markers.sort { $0.frame == $1.frame ? $0.id.uuidString < $1.id.uuidString : $0.frame < $1.frame }
    }
}

public extension Clip {
    /// Source markers that fall inside this clip, with the sequence frame each lands on.
    func sourceMarkers(_ markers: [SourceMarker], rate: FrameRate) -> [(frame: Int64, marker: SourceMarker)] {
        markers.compactMap { marker in
            let frame = sequenceFrame(atSourceTime: marker.time, rate: rate)
            return range.contains(frame) ? (frame, marker) : nil
        }
        .sorted { $0.frame < $1.frame }
    }
}
