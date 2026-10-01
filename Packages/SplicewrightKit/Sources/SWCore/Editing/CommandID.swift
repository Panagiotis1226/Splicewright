import Foundation

/// Every command a keyboard shortcut can be bound to. Raw values are stored in user
/// preferences, so never rename one; add new cases instead.
public enum CommandID: String, Sendable, Hashable, Codable, CaseIterable, CodingKeyRepresentable, Identifiable {
    // Tools
    case toolSelection, toolTrackSelectForward, toolRippleEdit, toolRollingEdit, toolRateStretch, toolRazor
    case toolSlip, toolSlide, toolPen, toolHand, toolZoom, toolType
    // Transport
    case togglePlay, shuttleReverse, shuttleStop, shuttleForward
    case stepBackward1, stepForward1, stepBackward5, stepForward5
    case goToStart, goToEnd, previousEditPoint, nextEditPoint
    // Marking
    case markIn, markOut, clearIn, clearOut, clearInAndOut, goToIn, goToOut
    case addMarker, nextMarker, previousMarker
    // Editing
    case insertEdit, overwriteEdit, liftEdit, extractEdit, deleteSelection, rippleDelete
    case addEdit, addEditAllTracks, openInSource
    case applyVideoTransition, applyAudioTransition
    case pasteAttributes
    case speedDuration
    // Timeline view
    case zoomIn, zoomOut, zoomToFit, toggleSnapping
    // File
    case importMedia, newBin, exportMedia, newSequence
    // Graphics
    case newTitle
    // View
    case toggleProxies
    // Window ▸ Workspaces: the first nine workspaces in the menu
    case workspace1, workspace2, workspace3, workspace4, workspace5, workspace6, workspace7, workspace8, workspace9

    public var id: String { rawValue }

    public enum Group: String, Sendable, CaseIterable, Identifiable {
        case file = "File"
        case editing = "Editing"
        case marking = "Marking"
        case transport = "Playback"
        case timeline = "Timeline"
        case tools = "Tools"
        case graphics = "Graphics"
        case window = "Window"

        public var id: String { rawValue }
    }

    public var group: Group {
        switch self {
        case .toolSelection, .toolTrackSelectForward, .toolRippleEdit, .toolRollingEdit, .toolRateStretch,
             .toolRazor, .toolSlip, .toolSlide, .toolPen, .toolHand, .toolZoom, .toolType:
            return .tools
        case .togglePlay, .shuttleReverse, .shuttleStop, .shuttleForward, .stepBackward1, .stepForward1,
             .stepBackward5, .stepForward5, .goToStart, .goToEnd, .previousEditPoint, .nextEditPoint:
            return .transport
        case .markIn, .markOut, .clearIn, .clearOut, .clearInAndOut, .goToIn, .goToOut, .addMarker, .nextMarker,
             .previousMarker:
            return .marking
        case .insertEdit, .overwriteEdit, .liftEdit, .extractEdit, .deleteSelection, .rippleDelete, .addEdit,
             .addEditAllTracks, .openInSource, .applyVideoTransition, .applyAudioTransition, .pasteAttributes, .speedDuration:
            return .editing
        case .zoomIn, .zoomOut, .zoomToFit, .toggleSnapping:
            return .timeline
        case .importMedia, .newBin, .exportMedia, .newSequence:
            return .file
        case .newTitle:
            return .graphics
        case .toggleProxies:
            return .transport
        case .workspace1, .workspace2, .workspace3, .workspace4, .workspace5, .workspace6, .workspace7, .workspace8,
             .workspace9:
            return .window
        }
    }

    public var title: String {
        if let tool { return tool.displayName }
        if let index = workspaceIndex { return "Workspace \(index + 1)" }
        return Self.titles[self] ?? rawValue
    }

    private static let titles: [CommandID: String] = [
        .togglePlay: "Play/Stop", .shuttleReverse: "Shuttle Left", .shuttleStop: "Shuttle Stop",
        .shuttleForward: "Shuttle Right", .stepBackward1: "Step Back 1 Frame", .stepForward1: "Step Forward 1 Frame",
        .stepBackward5: "Step Back 5 Frames", .stepForward5: "Step Forward 5 Frames", .goToStart: "Go to Start",
        .goToEnd: "Go to End", .previousEditPoint: "Go to Previous Edit Point", .nextEditPoint: "Go to Next Edit Point",
        .markIn: "Mark In", .markOut: "Mark Out", .clearIn: "Clear In", .clearOut: "Clear Out",
        .clearInAndOut: "Clear In and Out", .goToIn: "Go to In", .goToOut: "Go to Out",
        .addMarker: "Add Marker", .nextMarker: "Go to Next Marker", .previousMarker: "Go to Previous Marker",
        .insertEdit: "Insert", .overwriteEdit: "Overwrite", .liftEdit: "Lift", .extractEdit: "Extract",
        .deleteSelection: "Clear (Delete)", .rippleDelete: "Ripple Delete", .addEdit: "Add Edit",
        .addEditAllTracks: "Add Edit to All Tracks", .openInSource: "Open in Source Monitor",
        .applyVideoTransition: "Apply Video Transition", .applyAudioTransition: "Apply Audio Transition",
        .zoomIn: "Zoom In", .zoomOut: "Zoom Out", .zoomToFit: "Zoom to Sequence", .toggleSnapping: "Snap",
        .importMedia: "Import…", .newBin: "New Bin", .exportMedia: "Export Media…", .newSequence: "New Sequence…",
        .newTitle: "New Title", .toggleProxies: "Toggle Proxies", .pasteAttributes: "Paste Attributes",
        .speedDuration: "Speed/Duration…",
    ]

    public var tool: EditTool? {
        switch self {
        case .toolSelection: return .selection
        case .toolTrackSelectForward: return .trackSelectForward
        case .toolRippleEdit: return .rippleEdit
        case .toolRollingEdit: return .rollingEdit
        case .toolRateStretch: return .rateStretch
        case .toolRazor: return .razor
        case .toolSlip: return .slip
        case .toolSlide: return .slide
        case .toolPen: return .pen
        case .toolHand: return .hand
        case .toolZoom: return .zoom
        case .toolType: return .type
        default: return nil
        }
    }

    /// 0...8 for the workspace commands.
    public var workspaceIndex: Int? {
        Self.workspaceCommands.firstIndex(of: self)
    }

    public static let workspaceCommands: [CommandID] = [
        .workspace1, .workspace2, .workspace3, .workspace4, .workspace5, .workspace6, .workspace7, .workspace8, .workspace9,
    ]

    public static func command(for tool: EditTool) -> CommandID {
        allCases.first { $0.tool == tool } ?? .toolSelection
    }

    /// The panel action this command performs, or nil for commands that live in the menu bar
    /// (their shortcuts are menu key equivalents).
    public var shortcutAction: ShortcutAction? {
        if let tool { return .selectTool(tool) }
        return Self.actions[self]
    }

    /// Menu-bar commands: their shortcuts are shown in, and dispatched by, the menus.
    public var isMenuCommand: Bool { shortcutAction == nil }

    private static let actions: [CommandID: ShortcutAction] = [
        .togglePlay: .togglePlay, .shuttleReverse: .shuttleReverse, .shuttleStop: .shuttleStop,
        .shuttleForward: .shuttleForward, .stepBackward1: .stepBackward(frames: 1),
        .stepForward1: .stepForward(frames: 1), .stepBackward5: .stepBackward(frames: 5),
        .stepForward5: .stepForward(frames: 5), .goToStart: .goToStart, .goToEnd: .goToEnd,
        .previousEditPoint: .previousEditPoint, .nextEditPoint: .nextEditPoint, .markIn: .markIn,
        .markOut: .markOut, .clearIn: .clearIn, .clearOut: .clearOut, .clearInAndOut: .clearInAndOut,
        .goToIn: .goToIn, .goToOut: .goToOut, .addMarker: .addMarker, .nextMarker: .nextMarker,
        .previousMarker: .previousMarker, .insertEdit: .insertEdit, .overwriteEdit: .overwriteEdit,
        .liftEdit: .liftEdit, .extractEdit: .extractEdit, .deleteSelection: .deleteSelection,
        .rippleDelete: .rippleDelete, .openInSource: .openInSource, .zoomIn: .zoomIn, .zoomOut: .zoomOut,
        .zoomToFit: .zoomToFit, .toggleSnapping: .toggleSnapping,
    ]
}
