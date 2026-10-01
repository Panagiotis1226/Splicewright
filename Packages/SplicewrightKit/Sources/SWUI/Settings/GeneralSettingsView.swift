import AppKit
import Combine
import SwiftUI
import SWCore

/// Auto-save settings, saved in preferences.
@MainActor
public final class AutoSavePreferences: ObservableObject {
    public static let shared = AutoSavePreferences()

    @Published public var policy: AutoSavePolicy {
        didSet {
            let clamped = policy.clamped()
            if clamped != policy { policy = clamped; return }
            if let data = try? JSONEncoder().encode(policy) { defaults.set(data, forKey: Self.key) }
        }
    }

    public nonisolated static let key = "autoSavePolicy"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        policy = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(AutoSavePolicy.self, from: $0) }
            ?? AutoSavePolicy()
    }

    /// `~/Library/Application Support/Splicewright/Auto-Save`.
    public nonisolated static var root: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Splicewright/Auto-Save", isDirectory: true)
    }

    public nonisolated static var store: AutoSaveStore { AutoSaveStore(root: root) }
}

/// Settings ▸ General: auto-save and logs.
struct GeneralSettingsView: View {
    @ObservedObject var preferences: AutoSavePreferences
    @State private var autoSaveSize: Int64?

    var body: some View {
        Form {
            Section {
                Toggle("Automatically save versions of projects", isOn: $preferences.policy.isEnabled)
                Stepper(value: $preferences.policy.intervalMinutes, in: AutoSavePolicy.intervalRange) {
                    let minutes = preferences.policy.intervalMinutes
                    Text("Every \(minutes) minute\(minutes == 1 ? "" : "s")")
                }
                .disabled(!preferences.policy.isEnabled)
                Stepper(value: $preferences.policy.maximumVersions, in: AutoSavePolicy.versionsRange) {
                    Text("Keep \(preferences.policy.maximumVersions) versions per project")
                }
                .disabled(!preferences.policy.isEnabled)
                HStack {
                    Button("Show Auto-Saves in Finder") { AutoSaver.revealFolder() }
                    Button("Open Auto-Save…") { AutoSaver.chooseVersionToOpen() }
                    Spacer()
                    if let autoSaveSize {
                        Text(ByteCountFormatter.string(fromByteCount: autoSaveSize, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Auto-Save")
            } footer: {
                Text("Auto-saves are copies taken only when a project has changed, kept in Application Support. "
                     + "If Splicewright quits unexpectedly, it offers to open them the next time it starts. "
                     + "They don't replace saving your project (⌘S).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Show Logs in Finder") { AppLogMenu.reveal() }
                    Spacer()
                }
            } header: {
                Text("Logs")
            } footer: {
                Text("Imports, proxies, exports, auto-saves, relinks and errors are written to "
                     + "~/Library/Logs/Splicewright. Attach the log when reporting a problem.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 360)
        .task { autoSaveSize = await Task.detached { AutoSavePreferences.store.totalSize() }.value }
    }
}

enum AppLogMenu {
    static func reveal() {
        let log = AppLog.shared
        log.flush()
        if FileManager.default.fileExists(atPath: log.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
        } else {
            try? FileManager.default.createDirectory(at: log.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(log.directory)
        }
    }
}
