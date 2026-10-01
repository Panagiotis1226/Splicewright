import Combine
import Foundation
import SwiftUI
import SWCore

/// The app-wide keyboard shortcuts, saved in the user's preferences (not in projects).
@MainActor
public final class KeyBindingsStore: ObservableObject {
    public static let shared = KeyBindingsStore()

    private static let defaultsKey = "keyBindings.v1"

    @Published public private(set) var bindings: KeyBindings

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(KeyBindings.self, from: data) {
            bindings = saved
        } else {
            bindings = KeyBindings()
        }
    }

    public func update(_ change: (inout KeyBindings) -> Void) {
        var copy = bindings
        change(&copy)
        guard copy != bindings else { return }
        bindings = copy
        if let data = try? JSONEncoder().encode(copy) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// The menu key equivalent for a command (its first shortcut), or nil if it has none.
    public func keyboardShortcut(for command: CommandID) -> KeyboardShortcut? {
        bindings.inputs(for: command).first.flatMap(KeyboardShortcut.init)
    }

    /// "Razor Tool (C)" style hint for tooltips.
    public func hint(_ title: String, _ command: CommandID) -> String {
        guard let input = bindings.inputs(for: command).first else { return title }
        return "\(title) (\(input.displayString))"
    }
}

extension KeyboardShortcut {
    init?(_ input: KeyInput) {
        let key: KeyEquivalent
        switch input.key {
        case .character(let char): key = KeyEquivalent(char)
        case .space: key = .space
        case .leftArrow: key = .leftArrow
        case .rightArrow: key = .rightArrow
        case .upArrow: key = .upArrow
        case .downArrow: key = .downArrow
        case .home: key = .home
        case .end: key = .end
        case .returnKey: key = .return
        case .delete: key = .delete
        case .escape: key = .escape
        }
        var modifiers: EventModifiers = []
        if input.modifiers.contains(.command) { modifiers.insert(.command) }
        if input.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if input.modifiers.contains(.option) { modifiers.insert(.option) }
        if input.modifiers.contains(.control) { modifiers.insert(.control) }
        self.init(key, modifiers: modifiers)
    }
}

extension View {
    /// Binds a menu item to the user's shortcut for `command`.
    func shortcut(_ command: CommandID, _ store: KeyBindingsStore) -> some View {
        keyboardShortcut(store.keyboardShortcut(for: command))
    }
}
