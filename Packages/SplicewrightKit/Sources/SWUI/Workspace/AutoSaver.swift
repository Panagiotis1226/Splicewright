import AppKit
import Combine
import SWCore
import UniformTypeIdentifiers

/// Saves a timestamped copy of a window's project every few minutes while it has changes,
/// like Premiere's Auto Save. The copies are ordinary projects: open one and Save As.
@MainActor
final class AutoSaver {
    private weak var workspace: WorkspaceController?
    private var timer: Timer?
    private var lastSaved: Project?
    private var cancellables: Set<AnyCancellable> = []
    /// Folder key for a project that hasn't been saved to a file yet.
    private let untitledKey = UUID().uuidString
    private let queue = DispatchQueue(label: "com.splicewright.autosave", qos: .utility)

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        AutoSavePreferences.shared.$policy
            .removeDuplicates()
            .sink { [weak self] policy in self?.schedule(policy) }
            .store(in: &cancellables)
    }

    private func schedule(_ policy: AutoSavePolicy) {
        timer?.invalidate()
        timer = nil
        guard policy.isEnabled else { return }
        let interval = TimeInterval(policy.intervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.saveIfNeeded() }
        }
        timer?.tolerance = min(30, interval * 0.1)
    }

    /// The first time a project is seen, it's the baseline: only later changes are saved.
    func noteOpened(_ project: Project) {
        if lastSaved == nil { lastSaved = project }
    }

    func saveIfNeeded() {
        let policy = AutoSavePreferences.shared.policy
        guard policy.isEnabled, let workspace, let project = workspace.document?.project,
              project != lastSaved, !project.media.isEmpty || !project.sequences.isEmpty else { return }
        lastSaved = project
        let document = workspace.window?.windowController?.document as? NSDocument
        let name = document?.displayName.replacingOccurrences(of: ".\(ProjectFileCoder.packageExtension)", with: "")
            ?? "Untitled"
        let key = AutoSaveStore.key(for: document?.fileURL?.path ?? untitledKey)
        let keep = policy.maximumVersions
        queue.async {
            do {
                let url = try AutoSavePreferences.store.save(project, projectName: name, key: key, keep: keep)
                AppLog.shared.info("Auto-saved \(url.lastPathComponent)", category: "autosave")
            } catch {
                AppLog.shared.error("Auto-save of \(name) failed: \(error.localizedDescription)", category: "autosave")
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Opening versions

    static func revealFolder() {
        let root = AutoSavePreferences.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// Lets the user pick an auto-saved version and opens it as a project.
    static func chooseVersionToOpen() {
        let root = AutoSavePreferences.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let panel = NSOpenPanel()
        panel.directoryURL = root
        panel.allowedContentTypes = [.splicewrightProject]
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose an auto-saved version to open. Use File ▸ Save As to keep it."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    static func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            guard let error else { return }
            AppLog.shared.error("Couldn't open \(url.path): \(error.localizedDescription)", category: "autosave")
            Task { @MainActor in NSAlert(error: error).runModal() }
        }
    }
}

/// Notices when Splicewright didn't quit normally last time and offers the auto-saves.
public enum CrashRecovery {
    private static var markerURL: URL {
        AutoSavePreferences.root.deletingLastPathComponent().appendingPathComponent(".running")
    }

    /// Call when the app finishes launching.
    @MainActor
    public static func appDidLaunch() {
        let fileManager = FileManager.default
        let crashed = fileManager.fileExists(atPath: markerURL.path)
        try? fileManager.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: markerURL)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        AppLog.shared.info("Launched Splicewright \(version) on macOS "
                           + ProcessInfo.processInfo.operatingSystemVersionString)
        guard crashed else { return }
        AppLog.shared.warning("The previous session didn't quit normally")
        // Unattended runs (the smoke test) never show alerts.
        guard ProcessInfo.processInfo.environment["SPLICEWRIGHT_SMOKE_MEDIA"] == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { offerRecovery() }
    }

    /// Call when the app is about to quit normally.
    public static func appWillTerminate() {
        try? FileManager.default.removeItem(at: markerURL)
        AppLog.shared.info("Quit")
        AppLog.shared.flush()
    }

    @MainActor
    private static func offerRecovery() {
        let recent = AutoSavePreferences.store.latestVersions()
            .filter { $0.date > Date().addingTimeInterval(-7 * 24 * 3600) }
            .prefix(5)
        guard !recent.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let alert = NSAlert()
        alert.messageText = "Splicewright quit unexpectedly"
        alert.informativeText = "Projects you had open are normally reopened as you left them. If one is missing "
            + "recent changes, these auto-saved versions may have them:\n\n"
            + recent.map { "• \($0.projectName) — \(formatter.string(from: $0.date))" }.joined(separator: "\n")
        alert.addButton(withTitle: "Open Latest Auto-Saves")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Not Now")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            recent.forEach { AutoSaver.open($0.url) }
        case .alertSecondButtonReturn:
            AutoSaver.revealFolder()
        default:
            break
        }
    }
}
