import Foundation

/// A platform-neutral key press, translated from `NSEvent` by the UI layer.
public struct KeyInput: Sendable, Hashable {
    public enum Key: Sendable, Hashable {
        case character(Character)
        case space, leftArrow, rightArrow, upArrow, downArrow, home, end, returnKey, delete, escape
    }

    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var key: Key
    public var modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Letters are matched case-insensitively; shift is carried in `modifiers`.
    public static func character(_ character: Character, _ modifiers: Modifiers = []) -> KeyInput {
        KeyInput(.character(Character(character.lowercased())), modifiers)
    }
}

/// Commands that single-key shortcuts trigger, following Premiere Pro's defaults.
public enum ShortcutAction: Sendable, Hashable {
    case selectTool(EditTool)
    case togglePlay
    case shuttleForward
    case shuttleReverse
    case shuttleStop
    case stepForward(frames: Int)
    case stepBackward(frames: Int)
    case goToStart
    case goToEnd
    case markIn
    case markOut
    case clearIn
    case clearOut
    case clearInAndOut
    case goToIn
    case goToOut
    case openInSource
}

public enum KeyMap {
    /// The action for a key press, or nil if the key should go to the focused control.
    /// Command-key combinations are left to the menu bar.
    public static func action(for input: KeyInput) -> ShortcutAction? {
        let mods = input.modifiers
        if mods.contains(.command) || mods.contains(.control) { return nil }

        switch input.key {
        case .space where mods.isEmpty: return .togglePlay
        case .leftArrow where mods.isEmpty: return .stepBackward(frames: 1)
        case .rightArrow where mods.isEmpty: return .stepForward(frames: 1)
        case .leftArrow where mods == .shift: return .stepBackward(frames: 5)
        case .rightArrow where mods == .shift: return .stepForward(frames: 5)
        case .home where mods.isEmpty: return .goToStart
        case .end where mods.isEmpty: return .goToEnd
        case .returnKey where mods.isEmpty: return .openInSource
        case .character(let char):
            return characterAction(char, mods)
        default:
            return nil
        }
    }

    private static func characterAction(_ char: Character, _ mods: KeyInput.Modifiers) -> ShortcutAction? {
        switch (char, mods) {
        case ("j", []): return .shuttleReverse
        case ("k", []): return .shuttleStop
        case ("l", []): return .shuttleForward
        case ("i", []): return .markIn
        case ("o", []): return .markOut
        case ("i", .shift): return .goToIn
        case ("o", .shift): return .goToOut
        case ("i", .option): return .clearIn
        case ("o", .option): return .clearOut
        case ("x", .option): return .clearInAndOut
        default:
            break
        }
        guard mods.isEmpty else { return nil }
        if let tool = EditTool.allCases.first(where: { $0.shortcut == char }) {
            return .selectTool(tool)
        }
        return nil
    }
}

/// JKL shuttle: each press in the same direction doubles speed, up to 8×.
public enum Shuttle {
    public static let maximumRate: Float = 8

    public static func rate(afterForwardFrom current: Float) -> Float {
        current <= 0 ? 1 : min(current * 2, maximumRate)
    }

    public static func rate(afterReverseFrom current: Float) -> Float {
        current >= 0 ? -1 : max(current * 2, -maximumRate)
    }
}
