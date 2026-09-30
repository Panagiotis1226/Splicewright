import SwiftUI
import SWUI

@main
struct SplicewrightApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }, editor: { file in
            WorkspaceView(document: file.document)
                .frame(minWidth: 1100, minHeight: 680)
        })
        .defaultSize(width: 1600, height: 960)
        .commands { SplicewrightCommands() }
    }
}
