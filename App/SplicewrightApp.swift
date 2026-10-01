import AppKit
import SwiftUI
import SWUI

@main
struct SplicewrightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }, editor: { file in
            WorkspaceView(document: file.document)
                .frame(minWidth: 1100, minHeight: 680)
        })
        .defaultSize(width: 1600, height: 960)
        .commands { SplicewrightCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Smoke tests (scripts/smoke-test.sh) need a project window without user interaction.
        guard ProcessInfo.processInfo.environment["SPLICEWRIGHT_SMOKE_MEDIA"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for window in NSApp.windows where window is NSOpenPanel {
                window.close()
            }
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.newDocument(nil)
            }
        }
    }
}
