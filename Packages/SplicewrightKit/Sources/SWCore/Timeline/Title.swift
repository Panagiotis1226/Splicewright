import Foundation

/// An sRGB color with alpha, components 0...1.
public struct TitleColor: Sendable, Hashable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = TitleColor(red: 1, green: 1, blue: 1)
    public static let black = TitleColor(red: 0, green: 0, blue: 0)
}

public enum TitleAlignment: String, Sendable, Hashable, Codable, CaseIterable {
    case left, center, right
}

public struct TitleStroke: Sendable, Hashable, Codable {
    public var color: TitleColor
    /// Width as a fraction of the font size.
    public var width: Double

    public init(color: TitleColor = .black, width: Double = 0.06) {
        self.color = color
        self.width = width
    }
}

public struct TitleShadow: Sendable, Hashable, Codable {
    public var color: TitleColor
    /// Offset and blur as fractions of the font size.
    public var offset: Double
    public var blur: Double

    public init(color: TitleColor = TitleColor(red: 0, green: 0, blue: 0, alpha: 0.75), offset: Double = 0.06,
                blur: Double = 0.12) {
        self.color = color
        self.offset = offset
        self.blur = blur
    }
}

/// What a title clip draws. Sizes are fractions of the frame height and positions are
/// fractions of the frame, so a title looks the same at any resolution.
public struct TitleSpec: Sendable, Hashable, Codable {
    public var text: String
    public var fontFamily: String
    public var isBold: Bool
    public var isItalic: Bool
    /// Font size as a fraction of the frame height.
    public var size: Double
    public var color: TitleColor
    public var alignment: TitleAlignment
    /// Center of the text block: (0, 0) is the top left, (1, 1) the bottom right.
    public var positionX: Double
    public var positionY: Double
    public var stroke: TitleStroke?
    public var shadow: TitleShadow?
    /// A box behind the text.
    public var background: TitleColor?
    /// A color filling the whole frame behind the text (a color matte).
    public var backdrop: TitleColor?

    public init(text: String = "Title", fontFamily: String = "Helvetica Neue", isBold: Bool = true,
                isItalic: Bool = false, size: Double = 0.08, color: TitleColor = .white,
                alignment: TitleAlignment = .center, positionX: Double = 0.5, positionY: Double = 0.5,
                stroke: TitleStroke? = nil, shadow: TitleShadow? = TitleShadow(), background: TitleColor? = nil,
                backdrop: TitleColor? = nil) {
        self.text = text
        self.fontFamily = fontFamily
        self.isBold = isBold
        self.isItalic = isItalic
        self.size = size
        self.color = color
        self.alignment = alignment
        self.positionX = positionX
        self.positionY = positionY
        self.stroke = stroke
        self.shadow = shadow
        self.background = background
        self.backdrop = backdrop
    }

    /// The clip name shown in the timeline: the first line of text.
    public var displayName: String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces).isEmpty ? "Title" : line
    }

    public static let sizeRange: ClosedRange<Double> = 0.02...0.4

    /// What a clip whose file is missing shows, like Premiere's red Media Offline frame.
    public static func mediaOffline(_ name: String) -> TitleSpec {
        TitleSpec(text: "Media Offline\n\(name)", size: 0.06, color: .white, shadow: nil,
                  backdrop: TitleColor(red: 0.75, green: 0.08, blue: 0.08))
    }
}

public extension Clip {
    /// The media ID every title clip uses. No media item has it, so media lookups find nothing
    /// and trims treat a title as having unlimited handles.
    static let generatedMediaID = UUID(uuidString: "5F1CE000-0000-4000-8000-000000000001")!

    var isTitle: Bool { title != nil }
}

public extension EditSequence {
    /// The default title length: five seconds.
    var defaultTitleDuration: Int64 { Int64(rate.timecodeBase * 5) }

    /// Places a title at `frame` on `trackID`, or else on the lowest video track above V1
    /// that's free there (adding a track if none is). Returns the new clip's ID.
    @discardableResult
    mutating func addTitle(_ spec: TitleSpec = TitleSpec(), at frame: Int64, duration: Int64? = nil,
                           trackID: UUID? = nil) -> UUID? {
        let length = max(1, duration ?? defaultTitleDuration)
        let range = FrameRange(start: max(0, frame), end: max(0, frame) + length)
        var target = trackID.flatMap { id in videoTracks.first { $0.id == id && !$0.isLocked } }?.id
        if target == nil {
            target = videoTracks.dropFirst().first { !$0.isLocked && $0.isEmpty(in: range) }?.id
        }
        if target == nil {
            addTrack(.video)
            target = videoTracks.last?.id
        }
        guard let target else { return nil }
        let clip = Clip(mediaID: Clip.generatedMediaID, name: spec.displayName, start: range.start, duration: length,
                        sourceStart: .zero, title: spec)
        overwrite([TrackPlacement(trackID: target, clip: clip)])
        return clip.id
    }

    /// Changes a title clip's text and style (and its name to match).
    mutating func updateTitle(_ clipID: UUID, _ change: (inout TitleSpec) -> Void) {
        updateClipProperties([clipID]) { clip in
            guard var spec = clip.title else { return }
            change(&spec)
            spec.size = min(max(spec.size, TitleSpec.sizeRange.lowerBound), TitleSpec.sizeRange.upperBound)
            spec.positionX = min(max(spec.positionX, 0), 1)
            spec.positionY = min(max(spec.positionY, 0), 1)
            clip.title = spec
            clip.name = spec.displayName
        }
    }
}
