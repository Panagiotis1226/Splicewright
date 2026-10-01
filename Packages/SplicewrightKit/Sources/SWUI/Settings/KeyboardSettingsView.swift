import AppKit
import SwiftUI
import SWCore

/// Settings ▸ Keyboard: every command with its shortcuts, which can be re-recorded.
struct KeyboardSettingsView: View {
    @ObservedObject var store: KeyBindingsStore
    @State private var search = ""
    @State private var recording: CommandID?
    @State private var message: Message?

    struct Message: Equatable {
        var command: CommandID
        var text: String
        /// Set when the shortcut belongs to another command and can be moved.
        var pending: KeyInput?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search commands or keys", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button("Restore Defaults") {
                    store.update { $0.resetAll() }
                    message = nil
                }
            }
            List {
                ForEach(CommandID.Group.allCases) { group in
                    let commands = filtered(group)
                    if !commands.isEmpty {
                        Section(group.rawValue) {
                            ForEach(commands) { row($0) }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Text("Click + to record a shortcut. Shortcuts macOS uses, such as ⌘M (Minimize) and ⌘H (Hide), "
                 + "can't be assigned. Single-key shortcuts don't fire while you type in a text field.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 520)
        .background(KeyRecorder(isActive: recording != nil, onKey: record))
    }

    private func filtered(_ group: CommandID.Group) -> [CommandID] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return CommandID.allCases.filter { command in
            guard command.group == group else { return false }
            guard !query.isEmpty else { return true }
            return command.title.lowercased().contains(query)
                || store.bindings.inputs(for: command).contains { $0.displayString.lowercased().contains(query) }
        }
    }

    private func row(_ command: CommandID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(command.title)
                    .fontWeight(store.bindings.isCustomized(command) ? .semibold : .regular)
                Spacer()
                ForEach(store.bindings.inputs(for: command), id: \.self) { input in
                    chip(input, command)
                }
                if recording == command {
                    Text("Type a shortcut… (Esc to cancel)")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Button { startRecording(command) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add a shortcut")
                }
                Button { store.update { $0.reset(command) } } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Reset to default")
                    .disabled(!store.bindings.isCustomized(command))
            }
            if let message, message.command == command {
                HStack(spacing: 8) {
                    Text(message.text).font(.caption).foregroundStyle(message.pending == nil ? .red : .orange)
                    if let pending = message.pending {
                        Button("Reassign") {
                            store.update { _ = $0.assign(pending, to: command) }
                            self.message = nil
                        }
                        .controlSize(.small)
                        Button("Cancel") { self.message = nil }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func chip(_ input: KeyInput, _ command: CommandID) -> some View {
        HStack(spacing: 2) {
            Text(input.displayString)
                .font(.system(size: 11, weight: .medium, design: .rounded))
            Button { store.update { $0.remove(input, from: command) } } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Remove this shortcut")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
    }

    private func startRecording(_ command: CommandID) {
        message = nil
        recording = command
    }

    private func record(_ input: KeyInput?) {
        guard let command = recording else { return }
        recording = nil
        guard let input else { return }
        switch store.bindings.validate(input, for: command) {
        case .ok:
            store.update { _ = $0.assign(input, to: command) }
        case .reserved(let name):
            message = Message(command: command, text: "\(input.displayString) is used by macOS for \(name).")
        case .conflict(let other):
            message = Message(command: command, text: "\(input.displayString) is already used by \(other.title).",
                              pending: input)
        }
    }
}

/// Captures the next key press while active. Esc alone cancels (reported as nil).
private struct KeyRecorder: NSViewRepresentable {
    var isActive: Bool
    var onKey: (KeyInput?) -> Void

    func makeNSView(context: Context) -> RecorderView { RecorderView() }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onKey = onKey
        view.setActive(isActive)
    }

    final class RecorderView: NSView {
        var onKey: ((KeyInput?) -> Void)?
        private var monitor: Any?

        func setActive(_ active: Bool) {
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, event.window === self.window else { return event }
                    let input = KeyEventMonitor.keyInput(from: event)
                    let cancelled = input == KeyInput(.escape)
                    MainActor.assumeIsolated { self.onKey?(cancelled ? nil : input) }
                    return nil
                }
            } else if !active, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        override func removeFromSuperview() {
            setActive(false)
            super.removeFromSuperview()
        }
    }
}

/// The Settings window (Splicewright ▸ Settings…, ⌘,).
public struct SettingsView: View {
    enum Tab: String {
        case keyboard, media, cache, workspaces
    }

    /// The tab to show; menu items set it before opening Settings.
    @AppStorage("settingsTab") private var tab = Tab.keyboard.rawValue
    @ObservedObject private var store = KeyBindingsStore.shared

    public init() {}

    public var body: some View {
        TabView(selection: $tab) {
            KeyboardSettingsView(store: store)
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
                .tag(Tab.keyboard.rawValue)
            MediaSettingsView(preferences: MediaPreferences.shared)
                .tabItem { Label("Media", systemImage: "film.stack") }
                .tag(Tab.media.rawValue)
            CacheSettingsView()
                .tabItem { Label("Media Cache", systemImage: "internaldrive") }
                .tag(Tab.cache.rawValue)
            WorkspaceSettingsView(store: WorkspaceStore.shared)
                .tabItem { Label("Workspaces", systemImage: "rectangle.3.group") }
                .tag(Tab.workspaces.rawValue)
        }
    }
}

/// A menu item that opens Settings on a given tab.
struct OpenSettingsButton: View {
    let title: String
    let tab: SettingsView.Tab
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(title) {
            UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab")
            openSettings()
        }
    }
}
