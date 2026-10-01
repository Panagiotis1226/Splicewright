import Foundation

/// A timeline as interchange files describe it (FCP7 XML from Premiere, FCPXML from Final Cut
/// and Resolve, OpenTimelineIO from Resolve): tracks of clips that refer to media files by
/// path. Every format converts to and from this, and it converts to and from an `EditSequence`.
public struct InterchangeTimeline: Sendable, Equatable {
    public var name: String
    public var width: Int
    public var height: Int
    public var rate: FrameRate
    /// Index 0 is V1 (the bottom); each track's clips are sorted and don't overlap.
    public var videoTracks: [[InterchangeClip]]
    public var audioTracks: [[InterchangeClip]]
    public var transitions: [InterchangeTransition]
    public var markers: [Marker]

    public init(name: String, width: Int, height: Int, rate: FrameRate, videoTracks: [[InterchangeClip]] = [],
                audioTracks: [[InterchangeClip]] = [], transitions: [InterchangeTransition] = [],
                markers: [Marker] = []) {
        self.name = name
        self.width = width
        self.height = height
        self.rate = rate
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.transitions = transitions
        self.markers = markers
    }

    /// Every media file the timeline uses, once each, in order of first use.
    public var mediaFiles: [InterchangeMedia] {
        var seen: Set<String> = []
        var files: [InterchangeMedia] = []
        for clip in (videoTracks + audioTracks).flatMap({ $0 }) {
            guard let media = clip.media, seen.insert(media.path).inserted else { continue }
            files.append(media)
        }
        return files
    }

    public var durationFrames: Int64 {
        (videoTracks + audioTracks).flatMap { $0 }.map(\.end).max() ?? 0
    }
}

/// A media file a clip uses. `path` is a local file path.
public struct InterchangeMedia: Sendable, Hashable {
    public var path: String
    public var name: String
    /// The whole file's length, when the interchange file says.
    public var duration: RationalTime?
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// Picture size and rate, when known (for files that turn out to be missing).
    public var width: Int?
    public var height: Int?

    public init(path: String, name: String? = nil, duration: RationalTime? = nil, hasVideo: Bool = true,
                hasAudio: Bool = true, width: Int? = nil, height: Int? = nil) {
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.duration = duration
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.width = width
        self.height = height
    }

    /// A path from a `file://` URL (as FCP7 XML, FCPXML and OTIO write them) or a plain path.
    public static func path(fromURL text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.isFileURL { return url.path }
        if trimmed.hasPrefix("file://") {
            let rest = String(trimmed.dropFirst("file://".count))
            let path = rest.hasPrefix("localhost") ? String(rest.dropFirst("localhost".count)) : rest
            return path.removingPercentEncoding ?? path
        }
        return trimmed.hasPrefix("/") ? trimmed : nil
    }

    /// A `file://` URL for writing.
    public var url: String { URL(fileURLWithPath: path).absoluteString }
}

/// One clip on a track. Times are in timeline frames; `sourceStart` is in the media's own time.
public struct InterchangeClip: Sendable, Equatable {
    public var name: String
    public var media: InterchangeMedia?
    public var start: Int64
    public var duration: Int64
    public var sourceStart: RationalTime
    /// Percent; negative plays backwards.
    public var speed: Double
    public var isEnabled: Bool
    /// 0...1
    public var opacity: Double
    public var gainDB: Double

    public init(name: String, media: InterchangeMedia?, start: Int64, duration: Int64, sourceStart: RationalTime,
                speed: Double = 100, isEnabled: Bool = true, opacity: Double = 1, gainDB: Double = 0) {
        self.name = name
        self.media = media
        self.start = start
        self.duration = duration
        self.sourceStart = sourceStart
        self.speed = speed
        self.isEnabled = isEnabled
        self.opacity = opacity
        self.gainDB = gainDB
    }

    public var end: Int64 { start + duration }
}

/// A transition at a cut (or a clip's free edge, a fade): `before` frames before the cut and
/// `after` frames after it.
public struct InterchangeTransition: Sendable, Equatable {
    public var isAudio: Bool
    public var track: Int
    public var frame: Int64
    public var before: Int64
    public var after: Int64
    public var kind: TransitionKind

    public init(isAudio: Bool, track: Int, frame: Int64, before: Int64, after: Int64, kind: TransitionKind) {
        self.isAudio = isAudio
        self.track = track
        self.frame = frame
        self.before = max(before, 0)
        self.after = max(after, 0)
        self.kind = kind
    }

    public var duration: Int64 { before + after }
    public var start: Int64 { frame - before }
    public var end: Int64 { frame + after }

    public var alignment: TransitionAlignment {
        before == 0 ? .startAtCut : after == 0 ? .endAtCut : .center
    }
}

/// Which interchange format a file is, from its contents.
public enum InterchangeFormat: String, Sendable, CaseIterable {
    /// Final Cut Pro 7 XML (`xmeml`): Premiere Pro's File ▸ Export ▸ Final Cut Pro XML; Resolve reads and writes it.
    case fcp7XML
    /// FCPXML: Final Cut Pro X; Resolve reads and writes it.
    case fcpxml
    /// OpenTimelineIO JSON: Resolve 18.5+ reads and writes it.
    case otio

    public var displayName: String {
        switch self {
        case .fcp7XML: return "Final Cut Pro 7 XML (Premiere Pro, Resolve)"
        case .fcpxml: return "FCPXML (Final Cut Pro, Resolve)"
        case .otio: return "OpenTimelineIO (Resolve)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .fcp7XML: return "xml"
        case .fcpxml: return "fcpxml"
        case .otio: return "otio"
        }
    }

    public static func detect(_ data: Data) -> InterchangeFormat? {
        // The first few KB, read byte for byte so a character the cut splits doesn't matter.
        let head = String(bytes: data.prefix(4096), encoding: .isoLatin1) ?? ""
        if head.contains("<xmeml") { return .fcp7XML }
        if head.contains("<fcpxml") { return .fcpxml }
        if head.contains("\"OTIO_SCHEMA\"") { return .otio }
        return nil
    }

    public enum ReadError: Error, Equatable {
        case unknownFormat
        case noTimeline
        case invalid(String)

        public var message: String {
            switch self {
            case .unknownFormat: return "This isn't an FCP7 XML, FCPXML or OpenTimelineIO file."
            case .noTimeline: return "The file has no sequence or timeline in it."
            case .invalid(let reason): return "The file couldn't be read: \(reason)"
            }
        }
    }

    /// Reads the first timeline in an interchange file of any supported format.
    public static func read(_ data: Data) throws -> InterchangeTimeline {
        switch detect(data) {
        case .fcp7XML: return try FCP7XML.read(data)
        case .fcpxml: return try FCPXML.read(data)
        case .otio: return try OTIO.read(data)
        case nil: throw ReadError.unknownFormat
        }
    }

    public func write(_ timeline: InterchangeTimeline) -> Data {
        switch self {
        case .fcp7XML: return Data(FCP7XML.write(timeline).utf8)
        case .fcpxml: return Data(FCPXML.write(timeline).utf8)
        case .otio: return OTIO.write(timeline)
        }
    }
}
