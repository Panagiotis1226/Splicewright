import SwiftUI

/// Menu bar additions. Items act on the frontmost project window's workspace.
public struct SplicewrightCommands: Commands {
    @FocusedObject private var workspace: WorkspaceController?
    @ObservedObject private var keys = KeyBindingsStore.shared

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Import…") { workspace?.isImporterPresented = true }
                .shortcut(.importMedia, keys)
                .disabled(workspace == nil)
            Button("New Bin") { workspace?.newBin() }
                .shortcut(.newBin, keys)
                .disabled(workspace == nil)
            Divider()
            Menu("Export") {
                // Not Premiere's ⌘M: that's Window ▸ Minimize on the Mac.
                Button("Media…") { workspace?.requestExport() }
                    .shortcut(.exportMedia, keys)
            }
            .disabled(workspace?.activeSequenceID == nil)
        }
        CommandMenu("Sequence") {
            Button("New Sequence…") { workspace?.requestNewSequence() }
                .shortcut(.newSequence, keys)
            Button("Sequence Settings…") { workspace?.requestSequenceSettings() }
                .disabled(workspace?.activeSequenceID == nil)
            Divider()
            Button("Insert") { workspace?.editFromSource(overwrite: false) }
            Button("Overwrite") { workspace?.editFromSource(overwrite: true) }
            Button("Lift") { workspace?.liftOrExtract(extract: false) }
            Button("Extract") { workspace?.liftOrExtract(extract: true) }
            Divider()
            Button("Add Edit") { workspace?.addEdit(allTracks: false) }
                .shortcut(.addEdit, keys)
            Button("Add Edit to All Tracks") { workspace?.addEdit(allTracks: true) }
                .shortcut(.addEditAllTracks, keys)
            Button("Ripple Delete") { workspace?.deleteSelectedClips(ripple: true) }
            Divider()
            Button("Apply Video Transition") { workspace?.applyDefaultTransition(audio: false) }
                .shortcut(.applyVideoTransition, keys)
                .disabled(workspace?.activeSequenceID == nil)
            Button("Apply Audio Transition") { workspace?.applyDefaultTransition(audio: true) }
                .shortcut(.applyAudioTransition, keys)
                .disabled(workspace?.activeSequenceID == nil)
            Divider()
            Button("Add Video Track") { workspace?.addTrack(.video) }
            Button("Add Audio Track") { workspace?.addTrack(.audio) }
        }
        CommandMenu("Graphics") {
            Button("New Title") { workspace?.newTitle() }
                .shortcut(.newTitle, keys)
                .disabled(workspace == nil)
        }
        CommandMenu("Marker") {
            Button("Mark In") { workspace?.handle(.markIn) }
            Button("Mark Out") { workspace?.handle(.markOut) }
            Button("Clear In and Out") { workspace?.handle(.clearInAndOut) }
            Divider()
            Button("Go to In") { workspace?.handle(.goToIn) }
            Button("Go to Out") { workspace?.handle(.goToOut) }
        }
        CommandGroup(after: .help) {
            Divider()
            SettingsLink { Text("Keyboard Shortcuts…") }
        }
    }
}
