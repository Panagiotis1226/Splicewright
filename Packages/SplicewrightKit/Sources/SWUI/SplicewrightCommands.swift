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
