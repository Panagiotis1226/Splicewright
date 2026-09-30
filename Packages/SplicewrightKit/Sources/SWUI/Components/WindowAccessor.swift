import AppKit
import SwiftUI

/// Reports the NSWindow hosting a SwiftUI view once it's in a window.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        private var reported = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !reported else { return }
            reported = true
            onWindow?(window)
        }
    }
}
