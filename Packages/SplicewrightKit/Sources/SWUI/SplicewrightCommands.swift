import SwiftUI

/// Menu bar additions. Items act on the frontmost project window's workspace.
public struct SplicewrightCommands: Commands {
    @FocusedObject private var workspace: WorkspaceController?

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Import…") { workspace?.isImporterPresented = true }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(workspace == nil)
            Button("New Bin") { workspace?.newBin() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(workspace == nil)
        }
        CommandMenu("Sequence") {
            Button("New Sequence…") { workspace?.requestNewSequence() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Sequence Settings…") { workspace?.requestSequenceSettings() }
                .disabled(workspace?.activeSequenceID == nil)
            Divider()
            Button("Insert") { workspace?.editFromSource(overwrite: false) }
            Button("Overwrite") { workspace?.editFromSource(overwrite: true) }
            Button("Lift") { workspace?.liftOrExtract(extract: false) }
            Button("Extract") { workspace?.liftOrExtract(extract: true) }
            Divider()
            Button("Add Edit") { workspace?.addEdit(allTracks: false) }
                .keyboardShortcut("k", modifiers: .command)
            Button("Add Edit to All Tracks") { workspace?.addEdit(allTracks: true) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Ripple Delete") { workspace?.deleteSelectedClips(ripple: true) }
            Divider()
            Button("Add Video Track") { workspace?.addTrack(.video) }
            Button("Add Audio Track") { workspace?.addTrack(.audio) }
        }
        CommandMenu("Marker") {
            Button("Mark In") { workspace?.handle(.markIn) }
            Button("Mark Out") { workspace?.handle(.markOut) }
            Button("Clear In and Out") { workspace?.handle(.clearInAndOut) }
            Divider()
            Button("Go to In") { workspace?.handle(.goToIn) }
            Button("Go to Out") { workspace?.handle(.goToOut) }
        }
    }
}
