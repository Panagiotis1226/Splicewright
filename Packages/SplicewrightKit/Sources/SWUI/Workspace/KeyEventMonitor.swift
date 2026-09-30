import AppKit
import SwiftUI
import SWCore

/// Routes unmodified keys (J/K/L, I/O, tool letters, arrows) to the workspace, Premiere-style.
///
/// SwiftUI menu shortcuts need a modifier, and `onKeyPress` needs focus, so the workspace
/// installs a local event monitor for its own window instead. Keys typed into text
/// fields are never intercepted.
struct KeyEventMonitor: NSViewRepresentable {
    let handler: @MainActor (KeyInput) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handler = handler
    }

    final class MonitorView: NSView {
        var handler: (@MainActor (KeyInput) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if window.firstResponder is NSText { return event }
                guard let input = KeyEventMonitor.keyInput(from: event), let handler = self.handler else { return event }
                return MainActor.assumeIsolated { handler(input) } ? nil : event
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }

    /// Hardware key codes for the non-character keys the workspace uses.
    private static let specialKeys: [UInt16: KeyInput.Key] = [
        49: .space, 123: .leftArrow, 124: .rightArrow, 125: .downArrow, 126: .upArrow,
        115: .home, 119: .end, 36: .returnKey, 76: .returnKey, 51: .delete, 53: .escape,
    ]

    private static let modifierMap: [(NSEvent.ModifierFlags, KeyInput.Modifiers)] = [
        (.shift, .shift), (.option, .option), (.control, .control), (.command, .command),
    ]

    static func keyInput(from event: NSEvent) -> KeyInput? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyInput.Modifiers = []
        for (flag, modifier) in modifierMap where flags.contains(flag) {
            modifiers.insert(modifier)
        }
        if let key = specialKeys[event.keyCode] {
            return KeyInput(key, modifiers)
        }
        guard let character = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
        return .character(character, modifiers)
    }
}
