import Foundation

/// Timeline tools, with Premiere Pro's default single-key shortcuts.
public enum EditTool: String, Sendable, CaseIterable, Identifiable {
    case selection
    case trackSelectForward
    case rippleEdit
    case rollingEdit
    case rateStretch
    case razor
    case slip
    case slide
    case pen
    case hand
    case zoom
    case type

    public var id: String { rawValue }

    public var shortcut: Character {
        switch self {
        case .selection: return "v"
        case .trackSelectForward: return "a"
        case .rippleEdit: return "b"
        case .rollingEdit: return "n"
        case .rateStretch: return "r"
        case .razor: return "c"
        case .slip: return "y"
        case .slide: return "u"
        case .pen: return "p"
        case .hand: return "h"
        case .zoom: return "z"
        case .type: return "t"
        }
    }

    public var displayName: String {
        switch self {
        case .selection: return "Selection Tool"
        case .trackSelectForward: return "Track Select Forward Tool"
        case .rippleEdit: return "Ripple Edit Tool"
        case .rollingEdit: return "Rolling Edit Tool"
        case .rateStretch: return "Rate Stretch Tool"
        case .razor: return "Razor Tool"
        case .slip: return "Slip Tool"
        case .slide: return "Slide Tool"
        case .pen: return "Pen Tool"
        case .hand: return "Hand Tool"
        case .zoom: return "Zoom Tool"
        case .type: return "Type Tool"
        }
    }
}
