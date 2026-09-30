import AppKit
import Combine
import SwiftUI
import SWCore
import SWMedia

/// The panels of the Premiere-style workspace. The active panel receives transport shortcuts.
public enum PanelID: String, Sendable {
    case project, source, program, timeline, effects, effectControls
}

public enum ProjectViewMode: String, Sendable {
    case list, icons
}

/// Per-window state and the actions that menus, shortcuts and panels invoke.
@MainActor
public final class WorkspaceController: ObservableObject {
    @Published public var activePanel: PanelID = .project
    @Published public var activeTool: EditTool = .selection
    @Published public var selectedBinID: UUID?
    @Published public var showsAllMedia = true
    @Published public var selectedMediaIDs: Set<UUID> = []
    @Published public var projectViewMode: ProjectViewMode = .list
    @Published public var searchText = ""
    @Published public var isImporterPresented = false
    @Published public private(set) var isImporting = false
    @Published public var importReport: ImportReport?
    @Published public var renamingBinID: UUID?
    /// Name shown on the Source monitor tab. Kept here rather than read from the monitor so
    /// the workspace doesn't re-render on every playback frame.
    @Published public private(set) var sourceClipName: String?

    public let sourceMonitor = SourceMonitorModel()

    public private(set) weak var document: ProjectDocument?
    public var undoManager: UndoManager?

    private var importTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    public init() {}

    public func attach(document: ProjectDocument, undoManager: UndoManager?) {
        self.undoManager = undoManager
        guard self.document !== document else { return }
        self.document = document
        relinkMovedMedia()
        // Forward document changes so views observing the controller refresh too.
        document.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    public var project: Project { document?.project ?? Project() }

    // MARK: - Project panel

    /// Media shown in the Project panel for the current bin and search text.
    public var visibleMedia: [MediaItem] {
        let base = showsAllMedia ? project.media : project.items(inBin: selectedBinID)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    public func selectAllMedia() {
        showsAllMedia = true
        selectedBinID = nil
    }

    public func selectBin(_ id: UUID?) {
        showsAllMedia = false
        selectedBinID = id
    }

    public func newBin() {
        var created: Bin?
        document?.perform("New Bin", undoManager: undoManager) { created = $0.addBin() }
        if let created {
            selectBin(created.id)
            renamingBinID = created.id
        }
    }

    public func renameBin(_ id: UUID, to name: String) {
        document?.perform("Rename Bin", undoManager: undoManager) { $0.renameBin(id, to: name) }
        renamingBinID = nil
    }

    public func deleteBin(_ id: UUID) {
        document?.perform("Delete Bin", undoManager: undoManager) { $0.deleteBin(id) }
        if selectedBinID == id { selectAllMedia() }
    }

    public func moveMedia(_ ids: Set<UUID>, toBin binID: UUID?) {
        document?.perform("Move to Bin", undoManager: undoManager) { $0.moveMedia(ids, toBin: binID) }
    }

    public func removeMedia(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if let shown = sourceMonitor.mediaID, ids.contains(shown) {
            sourceMonitor.unload()
            sourceClipName = nil
        }
        document?.perform(ids.count == 1 ? "Remove Clip" : "Remove Clips", undoManager: undoManager) {
            $0.removeMedia(ids)
        }
        selectedMediaIDs.subtract(ids)
    }

    public func renameMedia(_ id: UUID, to name: String) {
        document?.perform("Rename Clip", undoManager: undoManager) { $0.renameMedia(id, to: name) }
        if sourceMonitor.mediaID == id { sourceClipName = project.item(id)?.name }
    }

    public func revealInFinder(_ ids: Set<UUID>) {
        let urls = ids.compactMap { project.item($0)?.url }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    // MARK: - Import

    /// The bin new imports land in: the selected bin, or the project root.
    public var importDestinationBinID: UUID? { showsAllMedia ? nil : selectedBinID }

    public func importFiles(_ urls: [URL]) {
        guard let document, !urls.isEmpty else { return }
        let destination = importDestinationBinID
        let existing = Set(document.project.media.map(\.filePath))
        isImporting = true
        importTask = Task { [weak self] in
            let result = await MediaImporter().importMedia(from: urls, into: destination, existingPaths: existing)
            guard let self else { return }
            self.isImporting = false
            if !result.items.isEmpty {
                let name = result.items.count == 1 ? "Import Clip" : "Import \(result.items.count) Clips"
                self.document?.perform(name, undoManager: self.undoManager) { $0.addMedia(result.items) }
                self.selectedMediaIDs = Set(result.items.map(\.id))
            }
            if !result.failures.isEmpty || !result.duplicates.isEmpty {
                self.importReport = ImportReport(failures: result.failures, duplicates: result.duplicates)
            }
        }
    }

    private func relinkMovedMedia() {
        guard let document else { return }
        let moved = MediaLocator.relocatedItems(in: document.project)
        guard !moved.isEmpty else { return }
        document.performWithoutUndo { project in
            for relocation in moved {
                project.relink(relocation.id, toPath: relocation.path, bookmark: relocation.refreshedBookmark)
            }
        }
    }

    // MARK: - Source monitor

    public func openInSource(_ id: UUID) {
        guard let item = project.item(id) else { return }
        sourceMonitor.load(item)
        sourceClipName = item.name
        activePanel = .source
    }

    public var sourceItem: MediaItem? {
        sourceMonitor.mediaID.flatMap { project.item($0) }
    }

    private func updateSourceMarks(_ actionName: String, _ change: (inout SourceMarks) -> Void) {
        guard let id = sourceMonitor.mediaID else { return }
        document?.perform(actionName, undoManager: undoManager) { $0.updateMarks(of: id, change) }
    }

    // MARK: - Shortcuts

    /// Handles a single-key shortcut. Returns false to let the key through.
    @discardableResult
    public func handle(_ action: ShortcutAction) -> Bool {
        if case .selectTool(let tool) = action {
            activeTool = tool
            return true
        }
        if case .openInSource = action {
            guard activePanel == .project, let id = selectedMediaIDs.first else { return false }
            openInSource(id)
            return true
        }
        // Transport keys drive the Source monitor from the Source and Project panels.
        // The Program monitor gets its own transport with the playback engine (M3).
        guard activePanel == .source || activePanel == .project, sourceMonitor.mediaID != nil else { return false }
        return handleTransport(action) || handleMarks(action)
    }

    private func handleTransport(_ action: ShortcutAction) -> Bool {
        let monitor = sourceMonitor
        switch action {
        case .togglePlay: monitor.togglePlay()
        case .shuttleForward: monitor.shuttleForward()
        case .shuttleReverse: monitor.shuttleReverse()
        case .shuttleStop: monitor.pause()
        case .stepForward(let frames): monitor.step(by: frames)
        case .stepBackward(let frames): monitor.step(by: -frames)
        case .goToStart: monitor.seek(to: .zero)
        case .goToEnd: monitor.seekToLastFrame()
        case .goToIn:
            if let time = sourceItem?.marks.inPoint { monitor.seek(to: time) }
        case .goToOut:
            if let time = sourceItem?.marks.outPoint { monitor.seek(to: time) }
        default:
            return false
        }
        return true
    }

    private func handleMarks(_ action: ShortcutAction) -> Bool {
        let time = sourceMonitor.currentFrameTime
        switch action {
        case .markIn: updateSourceMarks("Mark In") { $0.setIn(time) }
        case .markOut: updateSourceMarks("Mark Out") { $0.setOut(time) }
        case .clearIn: updateSourceMarks("Clear In") { $0.inPoint = nil }
        case .clearOut: updateSourceMarks("Clear Out") { $0.outPoint = nil }
        case .clearInAndOut: updateSourceMarks("Clear In and Out") { $0 = .empty }
        default: return false
        }
        return true
    }
}

public struct ImportReport: Identifiable {
    public let id = UUID()
    public var failures: [ImportFailure]
    public var duplicates: [URL]

    public var summary: String {
        var lines: [String] = failures.map { "\($0.url.lastPathComponent): \($0.reason)" }
        if !duplicates.isEmpty {
            lines.append("\(duplicates.count) file(s) already in the project were skipped.")
        }
        return lines.joined(separator: "\n")
    }
}
