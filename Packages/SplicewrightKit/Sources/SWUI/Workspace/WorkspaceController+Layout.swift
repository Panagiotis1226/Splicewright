import AppKit
import Combine
import SWCore

/// Keeps this window in step with the current workspace (Window ▸ Workspaces): view options
/// changed here are saved to it, and switching or resetting workspaces applies them here.
extension WorkspaceController {
    func observeWorkspace() {
        let store = WorkspaceStore.shared
        apply(store.current, includingWindow: false)
        store.$applyRevision.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Only the window the user is working in moves; others keep their frames.
                self.apply(WorkspaceStore.shared.current, includingWindow: self.window?.isKeyWindow ?? false)
            }
            .store(in: &cancellables)

        record($projectViewMode) { $0.projectViewMode = $1.rawValue }
        record($iconSize) { $0.iconSize = $1 }
        record($showsSafeMargins) { $0.showsSafeMargins = $1 }
        record($useProxies) { $0.useProxies = $1 }
        record(program.$renderScale) { $0.programResolution = $1 }
        record(program.$showsClipping) { $0.showsClipping = $1 }
        record(timeline.$isSnapping) { $0.snapping = $1 }
        // Zoom changes continuously while pinching; save it once it settles.
        timeline.$pixelsPerFrame.dropFirst()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] zoom in
                guard self?.isApplyingLayout == false else { return }
                WorkspaceStore.shared.update { $0.timelineZoom = Double(zoom) }
            }
            .store(in: &cancellables)
    }

    private func record<Value: Equatable>(_ publisher: Published<Value>.Publisher,
                                          _ write: @escaping (inout WorkspaceLayout, Value) -> Void) {
        publisher.dropFirst().removeDuplicates()
            .sink { [weak self] value in
                guard let self, !self.isApplyingLayout else { return }
                WorkspaceStore.shared.update { write(&$0, value) }
            }
            .store(in: &cancellables)
    }

    /// Applies a workspace's view options (and, if asked, its window frame) to this window.
    func apply(_ layout: WorkspaceLayout, includingWindow: Bool) {
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        projectViewMode = ProjectViewMode(rawValue: layout.projectViewMode) ?? .list
        iconSize = layout.iconSize
        showsSafeMargins = layout.showsSafeMargins
        useProxies = layout.useProxies
        program.renderScale = layout.programResolution
        program.showsClipping = layout.showsClipping
        timeline.isSnapping = layout.snapping
        timeline.pixelsPerFrame = CGFloat(layout.timelineZoom)
        if includingWindow, let window, let frame = layout.windowFrame { Self.place(window, at: frame) }
    }

    /// Called once the window exists: restores the workspace's frame and starts saving changes to it.
    func attachWindow(_ window: NSWindow) {
        self.window = window
        if let frame = WorkspaceStore.shared.current.windowFrame { Self.place(window, at: frame) }
        let center = NotificationCenter.default
        for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification] {
            center.publisher(for: name, object: window)
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self, weak window] _ in
                    guard let self, let window, !self.isApplyingLayout, !window.isMiniaturized,
                          !window.styleMask.contains(.fullScreen) else { return }
                    let frame = window.frame
                    WorkspaceStore.shared.update {
                        $0.windowFrame = .init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
                    }
                }
                .store(in: &cancellables)
        }
    }

    /// Moves the window to a saved frame if it's still on a connected screen.
    private static func place(_ window: NSWindow, at saved: WorkspaceLayout.Rect) {
        let frame = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
        guard !window.styleMask.contains(.fullScreen),
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        window.setFrame(frame, display: true, animate: false)
    }
}
