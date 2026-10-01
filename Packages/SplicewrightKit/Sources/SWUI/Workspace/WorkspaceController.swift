import AppKit
import Combine
import SwiftUI
import SWCore
import SWMedia
import SWExport
import SWPlayback

/// The panels of the Premiere-style workspace. The active panel receives transport shortcuts.
public enum PanelID: String, Sendable {
    case project, source, program, timeline, effects, effectControls, captions, markers, audioMixer
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
    /// Icon view tile width.
    @Published public var iconSize: Double = 150
    @Published public var showsSafeMargins = false
    @Published public var searchText = ""
    @Published public var isImporterPresented = false
    @Published public private(set) var isImporting = false
    @Published public var importReport: ImportReport?
    @Published public var renamingBinID: UUID?
    /// Name shown on the Source monitor tab. Kept here rather than read from the monitor so
    /// the workspace doesn't re-render on every playback frame.
    @Published public private(set) var sourceClipName: String?

    /// The sequence open in the Timeline and Program monitor.
    @Published public var activeSequenceID: UUID?
    /// Non-nil while the New Sequence / Sequence Settings sheet is shown.
    @Published public var sequenceSheet: SequenceSheetRequest?
    /// Shows the Export sheet; the session appears once an export starts.
    @Published public var isExportSheetPresented = false
    @Published public internal(set) var exportSession: ExportSession?
    /// Settings from the last export in this window, reused as the sheet's defaults.
    public var lastExportSettings: ExportSettings?

    public let sourceMonitor = SourceMonitorModel()
    public let timeline = TimelineState()
    public let program = PlaybackEngine()
    /// Both monitors play proxies, where clips have them. Export always uses originals.
    @Published public var useProxies = false {
        didSet {
            program.useProxies = useProxies
            sourceMonitor.useProxies = useProxies
        }
    }
    /// The window hosting this workspace (set by the view; used by smoke tests).
    public weak var window: NSWindow?

    public private(set) weak var document: ProjectDocument?
    public var undoManager: UndoManager?

    private var importTask: Task<Void, Never>?
    var cancellables: Set<AnyCancellable> = []
    /// Set while a workspace is being applied, so applying it isn't recorded as a change.
    var isApplyingLayout = false
    /// The project before a live edit (a drag in Effect Controls or the Program monitor) began.
    var liveEditOriginal: Project?
    /// A short message about media (relinked, reloaded) shown at the bottom of the Project panel.
    @Published public var mediaNotice: String?
    /// Captions: the track the Captions panel shows, the caption being edited, and transcription.
    @Published public var activeCaptionTrackID: UUID?
    @Published public var focusedCaptionID: UUID?
    @Published public var isTranscribeSheetPresented = false
    /// The Program monitor's background picker (its swatch button, View menu, right-click).
    @Published public var isMonitorBackgroundPickerShown = false
    @Published public var captionJob: CaptionJob?
    /// Non-nil while the Speed/Duration sheet is shown, for these clips.
    @Published public var speedSheetClipIDs: Set<UUID>?
    /// The marker highlighted in the ruler and Markers panel, and the one open in the Marker sheet.
    @Published public var selectedMarkerID: UUID?
    @Published public var editingMarkerID: UUID?
    /// Media whose file is missing.
    @Published public internal(set) var offlineMediaIDs: Set<UUID> = []
    var checkedMediaPaths: [String] = []
    var isCheckingMedia = false
    private var autoSaver: AutoSaver?
    private var lastMediaCheck = Date.distantPast

    public init() {
        NotificationCenter.default.publisher(for: .splicewrightProxiesChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.useProxies else { return }
                self.program.refresh()
                self.sourceMonitor.reloadForProxies()
            }
            .store(in: &cancellables)
        observeWorkspace()
        // Files may have been replaced while another app was in front.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, Date().timeIntervalSince(self.lastMediaCheck) > 5 else { return }
                self.lastMediaCheck = Date()
                self.updateOfflineMedia(force: true)
                self.refreshChangedMedia()
            }
            .store(in: &cancellables)
    }

    public func attach(document: ProjectDocument, undoManager: UndoManager?) {
        self.undoManager = undoManager
        guard self.document !== document else { return }
        self.document = document
        relinkMovedMedia()
        let offline = document.project.media.filter { !MediaLocator.isOnline($0) }
        if !offline.isEmpty {
            AppLog.shared.warning("\(offline.count) offline file(s): "
                                  + offline.map(\.filePath).joined(separator: ", "), category: "media")
            mediaNotice = "\(offline.count) file\(offline.count == 1 ? " is" : "s are") offline. "
                + "Right-click ▸ Link Media… to find \(offline.count == 1 ? "it" : "them")."
        }
        lastMediaCheck = Date()
        refreshChangedMedia()
        let saver = AutoSaver(workspace: self)
        saver.noteOpened(document.project)
        autoSaver = saver
        // Forward document changes so views observing the controller refresh too.
        document.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // `$project` publishes the new value; keep playback and selection in step with it.
        document.$project
            .receive(on: RunLoop.main)
            .sink { [weak self] project in self?.projectDidChange(project) }
            .store(in: &cancellables)
        if activeSequenceID == nil { activeSequenceID = document.project.sequences.first?.id }
        projectDidChange(document.project)
    }

    func projectDidChange(_ project: Project) {
        if let id = activeSequenceID, project.sequence(id) == nil {
            activeSequenceID = project.sequences.first?.id
        }
        let sequence = activeSequenceID.flatMap { project.sequence($0) }
        if let sequence {
            let existing = Set(sequence.allTracks.flatMap { $0.clips.map(\.id) })
            if !timeline.selection.isSubset(of: existing) { timeline.selection.formIntersection(existing) }
        } else {
            timeline.selection = []
        }
        program.update(sequence: sequence, project: project)
        updateOfflineMedia()
    }

    public var project: Project { document?.project ?? Project() }

    /// Takes an auto-save now if the project changed (the timer does this every few minutes).
    func autoSaveNow() {
        autoSaver?.saveIfNeeded()
    }

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
                AppLog.shared.info("Imported \(result.items.count) file(s)", category: "import")
                self.selectedMediaIDs = Set(result.items.map(\.id))
                self.autoCreateProxies(for: result.items)
            }
            for failure in result.failures {
                AppLog.shared.warning("Couldn't import \(failure.url.path): \(failure.reason)", category: "import")
            }
            if !result.failures.isEmpty || !result.duplicates.isEmpty {
                self.importReport = ImportReport(failures: result.failures, duplicates: result.duplicates)
            }
        }
    }

    /// With the preference on, queues proxies for imported video bigger than the proxy size.
    private func autoCreateProxies(for items: [MediaItem]) {
        let preferences = MediaPreferences.shared
        guard preferences.autoCreateProxies else { return }
        let large = items.filter { item in
            guard let video = item.info.video else { return false }
            return preferences.proxyPreset.isUseful(width: video.width, height: video.height)
        }
        ProxyQueue.shared.enqueue(large, preset: preferences.proxyPreset)
    }

    public func createProxies(_ ids: Set<UUID>, preset: ProxyPreset? = nil) {
        let items = project.media.filter { ids.contains($0.id) && $0.info.video != nil }
        ProxyQueue.shared.enqueue(items, preset: preset ?? MediaPreferences.shared.proxyPreset)
    }

    public func deleteProxies(_ ids: Set<UUID>) {
        ProxyQueue.shared.deleteProxies(project.media.filter { ids.contains($0.id) })
    }

    public func revealProxies(_ ids: Set<UUID>) {
        let urls = project.media.filter { ids.contains($0.id) }.compactMap { ProxyQueue.shared.proxyURL($0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
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
        if handleEditingShortcut(action) { return true }
        if handleMarkerShortcut(action) { return true }
        // The Timeline and Program monitor share the sequence's transport; the Source and
        // Project panels drive the Source monitor.
        if activePanel == .timeline || activePanel == .program {
            return handleSequenceTransport(action)
        }
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
