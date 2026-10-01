import Foundation

/// A word as speech recognition heard it, in seconds from the start of the sequence.
public struct TimedWord: Sendable, Hashable, Codable {
    public var text: String
    public var start: Double
    public var duration: Double

    public init(text: String, start: Double, duration: Double) {
        self.text = text
        self.start = start
        self.duration = duration
    }

    public var end: Double { start + duration }
}

/// A word inside a caption, in sequence frames. Kept so captions can be split at a word and
/// re-split after a style change.
public struct CaptionWord: Sendable, Hashable, Codable {
    public var text: String
    public var start: Int64
    public var duration: Int64

    public init(text: String, start: Int64, duration: Int64) {
        self.text = text
        self.start = start
        self.duration = duration
    }

    public var end: Int64 { start + duration }
}

/// One subtitle: text on screen from `start` for `duration` frames. Line breaks in `text`
/// are kept as written.
public struct Caption: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var start: Int64
    public var duration: Int64
    public var text: String
    public var words: [CaptionWord]

    public init(id: UUID = UUID(), start: Int64, duration: Int64, text: String, words: [CaptionWord] = []) {
        self.id = id
        self.start = start
        self.duration = max(1, duration)
        self.text = text
        self.words = words
    }

    public var end: Int64 { start + duration }
    public var range: FrameRange { FrameRange(start: start, end: end) }
}

/// How a caption track looks when shown or burned in: a title style plus line limits.
public struct CaptionStyle: Sendable, Hashable, Codable {
    /// Font, colors, outline, box and position. Its text is ignored.
    public var title: TitleSpec
    public var maxCharactersPerLine: Int
    public var maxLines: Int

    public init(title: TitleSpec, maxCharactersPerLine: Int = 42, maxLines: Int = 2) {
        self.title = title
        self.maxCharactersPerLine = maxCharactersPerLine
        self.maxLines = maxLines
    }

    /// Broadcast-style subtitles: two lines at the bottom on a dark box.
    public static let standard = CaptionStyle(
        title: TitleSpec(text: "", fontFamily: "Helvetica Neue", isBold: false, size: 0.05, color: .white,
                         alignment: .center, positionX: 0.5, positionY: 0.86, stroke: nil, shadow: nil,
                         background: TitleColor(red: 0, green: 0, blue: 0, alpha: 0.6)),
        maxCharactersPerLine: 42, maxLines: 2)

    /// Social-video style: big, bold, outlined, one short line a little below the middle.
    public static let social = CaptionStyle(
        title: TitleSpec(text: "", fontFamily: "Helvetica Neue", isBold: true, size: 0.085, color: .white,
                         alignment: .center, positionX: 0.5, positionY: 0.7,
                         stroke: TitleStroke(color: .black, width: 0.12), shadow: TitleShadow(), background: nil),
        maxCharactersPerLine: 18, maxLines: 1)

    public func titleSpec(text: String) -> TitleSpec {
        var spec = title
        spec.text = text
        return spec
    }

    public var maxCharacters: Int { max(1, maxCharactersPerLine) * max(1, maxLines) }
}

/// A subtitle track. Caption tracks sit above the video tracks; while `isOutputEnabled` is on
/// they show in the Program monitor (and are burned in when chosen at export).
public struct CaptionTrack: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// BCP 47 language, e.g. "en-US".
    public var language: String
    public var isOutputEnabled: Bool
    public var isLocked: Bool
    public var style: CaptionStyle
    /// Sorted by start; captions never overlap.
    public var captions: [Caption]

    public init(id: UUID = UUID(), name: String, language: String, isOutputEnabled: Bool = true,
                isLocked: Bool = false, style: CaptionStyle = .standard, captions: [Caption] = []) {
        self.id = id
        self.name = name
        self.language = language
        self.isOutputEnabled = isOutputEnabled
        self.isLocked = isLocked
        self.style = style
        self.captions = captions
    }

    public var end: Int64 { captions.last?.end ?? 0 }

    public func caption(at frame: Int64) -> Caption? {
        captions.first { $0.range.contains(frame) }
    }

    /// Keeps captions sorted and non-overlapping: each one ends no later than the next starts.
    mutating func normalize() {
        captions.sort { $0.start < $1.start }
        for index in captions.indices.dropLast() where captions[index].end > captions[index + 1].start {
            captions[index].duration = max(1, captions[index + 1].start - captions[index].start)
        }
    }
}
