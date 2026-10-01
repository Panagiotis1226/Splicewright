import SwiftUI
import SWCore

/// Settings ▸ Workspaces: rename, duplicate, reorder and delete workspaces.
struct WorkspaceSettingsView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var selection: UUID?
    @State private var editingName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A workspace remembers panel sizes, which tab is in front, the Project panel's view and thumbnail "
                 + "size, timeline zoom and snapping, Program monitor options and the window's size and position. "
                 + "Changes are kept automatically; Reset to Saved Layout returns to the saved version.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(store.library.saved) { layout in
                    HStack {
                        Text(layout.name)
                        if layout.id == store.library.currentID {
                            Text("current").font(.caption).foregroundStyle(Color.accentColor)
                        }
                        if store.library.hasUnsavedChanges(layout.id) {
                            Text("modified").font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        if let index = store.library.saved.firstIndex(of: layout), index < 9 {
                            Text("⌥⇧\\(index + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(layout.id)
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            .frame(minHeight: 200)
            HStack {
                TextField("Name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(rename)
                    .disabled(selection == nil)
                Button("Rename", action: rename).disabled(selection == nil || editingName.isEmpty)
                Button("Duplicate") { if let selection { store.duplicate(selection) } }.disabled(selection == nil)
                Button("Delete", role: .destructive) {
                    if let selection { store.delete(selection) }
                    selection = nil
                }
                .disabled(selection == nil || store.library.saved.count <= 1)
                Spacer()
                Button("Use") { if let selection { store.select(selection) } }.disabled(selection == nil)
            }
            HStack {
                Button("Save as New Workspace…") { store.promptSaveAsNew() }
                Button("Save Changes to Current") { store.saveChanges() }
                    .disabled(!store.library.hasUnsavedChanges(store.library.currentID))
                Button("Reset Current to Saved") { store.resetToSaved() }
                    .disabled(!store.library.hasUnsavedChanges(store.library.currentID))
                Spacer()
                Button("Restore Built-in Workspaces") { store.restoreBuiltIns() }
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 420)
        .onChange(of: selection) { _, id in
            editingName = id.flatMap { store.library.layout($0)?.name } ?? ""
        }
    }

    private func rename() {
        guard let selection, !editingName.isEmpty else { return }
        store.rename(selection, to: editingName)
    }
}
