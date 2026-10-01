import Foundation

/// The keyboard shortcuts in effect: Premiere Pro–style defaults plus the user's changes.
///
/// No default uses a shortcut macOS reserves (see `ReservedShortcuts`), and the editor
/// refuses to bind one, so a shortcut never minimizes, hides or quits by surprise.
public struct KeyBindings: Sendable, Hashable, Codable {
    /// Commands the user has changed. A command missing here uses its default; an empty
    /// array means the user removed every shortcut for it.
    public private(set) var overrides: [CommandID: [KeyInput]]

    public init(overrides: [CommandID: [KeyInput]] = [:]) {
        self.overrides = overrides
    }

    public static let standard = KeyBindings()

    public func inputs(for command: CommandID) -> [KeyInput] {
        overrides[command] ?? Self.defaults[command] ?? []
    }

    public func isCustomized(_ command: CommandID) -> Bool {
        overrides[command].map { $0 != Self.defaults[command] ?? [] } ?? false
    }

    /// The command bound to `input`, if any.
    public func command(for input: KeyInput) -> CommandID? {
        let input = input.normalized
        return CommandID.allCases.first { inputs(for: $0).contains(input) }
    }

    /// The panel action for a key press, or nil if the key belongs to a menu item or the focused control.
    public func action(for input: KeyInput) -> ShortcutAction? {
        command(for: input)?.shortcutAction
    }

    public enum Validation: Equatable, Sendable {
        case ok
        /// macOS uses this shortcut; the name says for what.
        case reserved(String)
        /// Another command already has this shortcut.
        case conflict(CommandID)
    }

    public func validate(_ input: KeyInput, for command: CommandID) -> Validation {
        let input = input.normalized
        if let name = ReservedShortcuts.name(for: input) { return .reserved(name) }
        if let other = self.command(for: input), other != command { return .conflict(other) }
        return .ok
    }

    /// Adds `input` to `command`, removing it from any other command that had it.
    /// Returns false (and changes nothing) for a shortcut macOS reserves.
    @discardableResult
    public mutating func assign(_ input: KeyInput, to command: CommandID) -> Bool {
        let input = input.normalized
        guard ReservedShortcuts.name(for: input) == nil else { return false }
        if let other = self.command(for: input), other != command {
            overrides[other] = inputs(for: other).filter { $0 != input }
        }
        var current = inputs(for: command)
        if !current.contains(input) { current.append(input) }
        overrides[command] = current
        return true
    }

    public mutating func remove(_ input: KeyInput, from command: CommandID) {
        overrides[command] = inputs(for: command).filter { $0 != input.normalized }
    }

    /// Restores `command`'s defaults, taking them back from any command that was given one.
    public mutating func reset(_ command: CommandID) {
        overrides[command] = nil
        for input in Self.defaults[command] ?? [] {
            for other in CommandID.allCases where other != command && inputs(for: other).contains(input) {
                overrides[other] = inputs(for: other).filter { $0 != input }
            }
        }
    }

    public mutating func resetAll() {
        overrides = [:]
    }

    /// Premiere Pro's defaults where they don't collide with macOS. Export Media is ⇧⌘E
    /// rather than Premiere's ⌘M, which is Window ▸ Minimize.
    public static let defaults: [CommandID: [KeyInput]] = {
        var map: [CommandID: [KeyInput]] = [
            .togglePlay: [KeyInput(.space)],
            .shuttleReverse: [.character("j")], .shuttleStop: [.character("k")], .shuttleForward: [.character("l")],
            .stepBackward1: [KeyInput(.leftArrow)], .stepForward1: [KeyInput(.rightArrow)],
            .stepBackward5: [KeyInput(.leftArrow, .shift)], .stepForward5: [KeyInput(.rightArrow, .shift)],
            .goToStart: [KeyInput(.home)], .goToEnd: [KeyInput(.end)],
            .previousEditPoint: [KeyInput(.upArrow)], .nextEditPoint: [KeyInput(.downArrow)],
            .markIn: [.character("i")], .markOut: [.character("o")],
            .clearIn: [.character("i", .option)], .clearOut: [.character("o", .option)],
            .clearInAndOut: [.character("x", .option)],
            .goToIn: [.character("i", .shift)], .goToOut: [.character("o", .shift)],
            .insertEdit: [.character(",")], .overwriteEdit: [.character(".")],
            .liftEdit: [.character(";")], .extractEdit: [.character("'")],
            .deleteSelection: [KeyInput(.delete)],
            .rippleDelete: [KeyInput(.delete, .shift), KeyInput(.delete, .option)],
            .addEdit: [.character("k", .command)], .addEditAllTracks: [.character("k", [.command, .shift])],
            .openInSource: [KeyInput(.returnKey)],
            .applyVideoTransition: [.character("d", .command)],
            .applyAudioTransition: [.character("d", [.command, .shift])],
            .zoomIn: [.character("="), .character("+", .shift)], .zoomOut: [.character("-")],
            .zoomToFit: [.character("\\")], .toggleSnapping: [.character("s")],
            .importMedia: [.character("i", .command)], .newBin: [.character("b", .command)],
            .exportMedia: [.character("e", [.command, .shift])],
            .newSequence: [.character("n", [.command, .option])],
            .newTitle: [.character("t", [.command, .shift])],
        ]
        for tool in EditTool.allCases {
            map[CommandID.command(for: tool)] = [.character(tool.shortcut)]
        }
        // Workspaces: ⌥⇧1…9, as in Premiere.
        for (index, command) in CommandID.workspaceCommands.enumerated() {
            map[command] = [.character(Character(String(index + 1)), [.option, .shift])]
        }
        return map
    }()
}

extension KeyInput {
    /// Letters are stored lowercased so ⇧I and ⇧i match.
    var normalized: KeyInput {
        if case .character(let char) = key { return KeyInput(.character(Character(char.lowercased())), modifiers) }
        return self
    }
}

/// Shortcuts macOS (or every standard Mac app) already uses. Bindings may never use them.
public enum ReservedShortcuts {
    public static func name(for input: KeyInput) -> String? {
        let input = input.normalized
        return all.first { $0.input == input }?.name
    }

    public static let all: [(input: KeyInput, name: String)] = {
        let cmd = KeyInput.Modifiers.command
        func char(_ key: Character, _ mods: KeyInput.Modifiers, _ name: String) -> (KeyInput, String) {
            (KeyInput.character(key, mods), name)
        }
        return [
            char("q", cmd, "Quit"), char("w", cmd, "Close Window"), char("h", cmd, "Hide Splicewright"),
            char("h", [.command, .option], "Hide Others"), char("m", cmd, "Minimize"),
            char("m", [.command, .option], "Minimize All"), char(",", cmd, "Settings"),
            char("`", cmd, "Cycle Through Windows"), char("f", [.command, .control], "Full Screen"),
            char("d", [.command, .option], "Show/Hide the Dock"), char("q", [.command, .control], "Lock Screen"),
            char("q", [.command, .shift], "Log Out"), char("/", [.command, .shift], "Help"),
            char("?", [.command, .shift], "Help"), char("t", [.command, .option], "Show/Hide Toolbar"),
            // With ⇧ held, AppKit reports the shifted symbol, so list both spellings.
            char("3", [.command, .shift], "Screenshot"), char("#", [.command, .shift], "Screenshot"),
            char("4", [.command, .shift], "Screenshot of Selection"),
            char("$", [.command, .shift], "Screenshot of Selection"),
            char("5", [.command, .shift], "Screenshot and Recording Options"),
            char("%", [.command, .shift], "Screenshot and Recording Options"),
            char("n", cmd, "New Project"), char("o", cmd, "Open"), char("s", cmd, "Save"),
            char("s", [.command, .shift], "Duplicate / Save As"), char("p", cmd, "Print"),
            char("z", cmd, "Undo"), char("z", [.command, .shift], "Redo"), char("x", cmd, "Cut"),
            char("c", cmd, "Copy"), char("v", cmd, "Paste"), char("a", cmd, "Select All"),
            char("f", cmd, "Find"), char("g", cmd, "Find Next"), char("e", cmd, "Use Selection for Find"),
            (KeyInput(.space, cmd), "Spotlight"), (KeyInput(.space, .control), "Switch Input Source"),
            (KeyInput(.space, [.command, .control]), "Emoji & Symbols"),
            (KeyInput(.escape, [.command, .option]), "Force Quit"),
            (KeyInput(.leftArrow, .control), "Move Left a Space"), (KeyInput(.rightArrow, .control), "Move Right a Space"),
            (KeyInput(.upArrow, .control), "Mission Control"), (KeyInput(.downArrow, .control), "App Windows"),
        ]
    }()
}
