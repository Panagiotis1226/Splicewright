import Foundation

/// A platform-neutral key press, translated from `NSEvent` by the UI layer.
public struct KeyInput: Sendable, Hashable, Codable {
    public enum Key: Sendable, Hashable {
        case character(Character)
        case space, leftArrow, rightArrow, upArrow, downArrow, home, end, returnKey, delete, escape
    }

    public struct Modifiers: OptionSet, Sendable, Hashable, Codable {
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

    /// How the shortcut is written in menus: modifiers in macOS order (⌃⌥⇧⌘), then the key.
    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.displayString
    }

    // MARK: Codable (keys are stored as short strings, e.g. "char:k", "left")

    private enum CodingKeys: String, CodingKey { case key, modifiers }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .key)
        guard let key = Key(storageName: name) else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: container, debugDescription: "Unknown key \(name)")
        }
        self.key = key
        modifiers = try container.decodeIfPresent(Modifiers.self, forKey: .modifiers) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key.storageName, forKey: .key)
        try container.encode(modifiers, forKey: .modifiers)
    }
}

extension KeyInput.Key {
    private static let named: [(String, KeyInput.Key, String)] = [
        ("space", .space, "Space"), ("left", .leftArrow, "←"), ("right", .rightArrow, "→"),
        ("up", .upArrow, "↑"), ("down", .downArrow, "↓"), ("home", .home, "↖"), ("end", .end, "↘"),
        ("return", .returnKey, "↩"), ("delete", .delete, "⌫"), ("escape", .escape, "⎋"),
    ]

    var storageName: String {
        if case .character(let char) = self { return "char:\(char)" }
        return Self.named.first { $0.1 == self }?.0 ?? "space"
    }

    init?(storageName name: String) {
        if name.hasPrefix("char:"), let char = name.dropFirst(5).first {
            self = .character(char)
        } else if let match = Self.named.first(where: { $0.0 == name }) {
            self = match.1
        } else {
            return nil
        }
    }

    public var displayString: String {
        if case .character(let char) = self { return String(char).uppercased() }
        return Self.named.first { $0.1 == self }?.2 ?? ""
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
    // Timeline
    case insertEdit
    case overwriteEdit
    case liftEdit
    case extractEdit
    case deleteSelection
    case rippleDelete
    case previousEditPoint
    case nextEditPoint
    case zoomIn
    case zoomOut
    case zoomToFit
    case toggleSnapping
}

/// The default bindings, for callers that don't have a user's custom set.
public enum KeyMap {
    /// The panel action for a key press, or nil if the key should go to the focused control or a menu.
    public static func action(for input: KeyInput) -> ShortcutAction? {
        KeyBindings.standard.action(for: input)
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
