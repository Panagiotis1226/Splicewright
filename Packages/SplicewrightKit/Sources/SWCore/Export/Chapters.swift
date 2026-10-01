import Foundation

/// Markers as YouTube chapters and as CSV.
public enum Chapters {
    /// YouTube needs at least three chapters, the first at 0:00, each at least 10 seconds long.
    public static let minimumCount = 3
    public static let minimumSeconds = 10.0

    public struct Chapter: Sendable, Hashable {
        public var seconds: Double
        public var title: String
    }

    /// Chapters from the markers flagged as chapters, or every marker when none are. Times are
    /// from `range.start` (the exported range); the first chapter is moved to 0:00 and ones
    /// closer than 10 s to the previous are dropped.
    public static func chapters(from markers: [Marker], rate: FrameRate, range: FrameRange? = nil) -> [Chapter] {
        let flagged = markers.filter(\.isChapter)
        let source = (flagged.isEmpty ? markers : flagged).sorted { $0.frame < $1.frame }
        let offset = range?.start ?? 0
        var chapters: [Chapter] = []
        for marker in source {
            if let range, !(range.start..<range.end).contains(marker.frame) { continue }
            let seconds = RationalTime(frames: marker.frame - offset, rate: rate).seconds
            if let last = chapters.last, seconds - last.seconds < minimumSeconds { continue }
            chapters.append(Chapter(seconds: chapters.isEmpty ? 0 : seconds, title: marker.title))
        }
        return chapters
    }

    /// Why the chapters won't show as chapters on YouTube, or nil if they will.
    public static func youTubeWarning(for chapters: [Chapter]) -> String? {
        if chapters.count < minimumCount {
            return "YouTube shows chapters only when there are at least \(minimumCount), each at least 10 seconds long."
        }
        return nil
    }

    /// `0:00 Intro` lines, for pasting into a YouTube description.
    public static func youTubeText(_ chapters: [Chapter]) -> String {
        let hours = (chapters.last?.seconds ?? 0) >= 3600
        return chapters.map { "\(timestamp($0.seconds, hours: hours)) \($0.title)" }.joined(separator: "\n") + "\n"
    }

    /// `m:ss`, or `h:mm:ss` when the video is an hour or longer.
    static func timestamp(_ seconds: Double, hours: Bool) -> String {
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return hours ? "\(h):\(two(m)):\(two(s))" : "\(total / 60):\(two(s))"
    }

    /// Name, In, Out, Duration, Comment, Color as CSV, with timecodes at `rate`.
    public static func csv(_ markers: [Marker], rate: FrameRate) -> String {
        func field(_ text: String) -> String {
            guard text.contains(where: { ",\"\n".contains($0) }) else { return text }
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["Name,In,Out,Duration,Comment,Color,Chapter"]
        for marker in markers.sorted(by: { $0.frame < $1.frame }) {
            lines.append([field(marker.name), Timecode(frame: marker.frame, rate: rate).description,
                          Timecode(frame: marker.end, rate: rate).description,
                          Timecode(frame: marker.duration, rate: rate).description, field(marker.comment),
                          marker.color.rawValue, marker.isChapter ? "yes" : ""].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
