import AppKit
import Combine
import Foundation
import SWCore

/// The app-wide workspaces (Window ▸ Workspaces), saved in preferences. Every change to the
/// current workspace is kept automatically; saving writes it as the workspace's saved version.
@MainActor
public final class WorkspaceStore: ObservableObject {
    public static let shared = WorkspaceStore()

    private static let defaultsKey = "workspaces.v1"

    @Published public private(set) var library: WorkspaceLibrary
    /// Changes when a different layout must be applied to windows (switching workspaces,
    /// resetting, restoring), as opposed to the user adjusting the current one.
    @Published public private(set) var applyRevision = 0

    private let defaults: UserDefaults
    private var saveTask: Task<Void, Never>?
    private var terminationObserver: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(WorkspaceLibrary.self, from: data) {
            library = saved
        } else {
            library = WorkspaceLibrary()
        }
        // Don't lose a change made just before quitting to the save delay.
        terminationObserver = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.saveNow() } }
    }

    public var current: WorkspaceLayout { library.current }

    /// Records a change made in a window (a divider drag, a view option). Saved shortly after.
    public func update(_ change: (inout WorkspaceLayout) -> Void) {
        var copy = library
        copy.update(change)
        guard copy != library else { return }
        library = copy
        scheduleSave()
    }

    public func select(_ id: UUID) {
        guard id != library.currentID else { return }
        library.select(id)
        appliedChange()
    }

    public func select(index: Int) {
        guard library.saved.indices.contains(index) else { return }
        select(library.saved[index].id)
    }

    public func saveAsNew(named name: String) {
        library.saveAsNew(named: name)
        appliedChange()
    }

    public func saveChanges() {
        library.saveChanges()
        saveNow()
    }

    public func resetToSaved() {
        library.resetToSaved()
        appliedChange()
    }

    public func rename(_ id: UUID, to name: String) {
        library.rename(id, to: name)
        saveNow()
    }

    public func duplicate(_ id: UUID) {
        library.duplicate(id)
        saveNow()
    }

    public func delete(_ id: UUID) {
        let wasCurrent = id == library.currentID
        library.delete(id)
        if wasCurrent { appliedChange() } else { saveNow() }
    }

    public func move(from source: IndexSet, to destination: Int) {
        library.move(from: source, to: destination)
        saveNow()
    }

    public func restoreBuiltIns() {
        library.restoreBuiltIns()
        appliedChange()
    }

    /// Asks for a name and saves the current layout as a new workspace.
    public func promptSaveAsNew() {
        let alert = NSAlert()
        alert.messageText = "New Workspace"
        alert.informativeText = "Saves the current panel layout, view options and window size."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "\(library.current.name) Copy"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        saveAsNew(named: name.isEmpty ? "Workspace" : name)
    }

    private func appliedChange() {
        applyRevision += 1
        saveNow()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        if let data = try? JSONEncoder().encode(library) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
