import SwiftUI
import SWCore
import SWMedia
import SWPlayback
import UniformTypeIdentifiers

/// The editing workspace, laid out like Premiere Pro's Editing workspace:
///
///     ┌ Source / Effect Controls / Effects ┬ Program ┐
///     ├ Project ────────────┬ Tools │ Timeline │ Meters ┤
public struct WorkspaceView: View {
    @ObservedObject var document: ProjectDocument
    @StateObject private var workspace = WorkspaceController()
    @Environment(\.undoManager) private var undoManager
    @State private var sourceTab: PanelID = .source

    public init(document: ProjectDocument) {
        self.document = document
    }

    public var body: some View {
        SplitPane(.vertical, fraction: 0.52, minFirst: 220, minSecond: 260) {
            SplitPane(.horizontal, fraction: 0.5, minFirst: 320, minSecond: 320) {
                PanelContainer(
                    tabs: [
                        PanelTab(id: .source, title: sourceTitle),
                        PanelTab(id: .effectControls, title: "Effect Controls"),
                        PanelTab(id: .effects, title: "Effects"),
                    ],
                    selectedTab: $sourceTab,
                    workspace: workspace
                ) {
                    switch sourceTab {
                    case .effectControls: EffectControlsPanel(workspace: workspace)
                    case .effects: EffectsPanel(workspace: workspace)
                    default: SourceMonitorPanel(workspace: workspace)
                    }
                }
            } second: {
                PanelContainer(.program, title: programTitle, workspace: workspace) {
                    ProgramMonitorPanel(workspace: workspace)
                }
            }
        } second: {
            SplitPane(.horizontal, fraction: 0.33, minFirst: 300, minSecond: 480) {
                PanelContainer(.project, title: "Project", workspace: workspace) {
                    ProjectPanel(workspace: workspace)
                }
            } second: {
                HStack(spacing: 0) {
                    ToolsPanel(workspace: workspace)
                    PanelContainer(.timeline, title: "Timeline", workspace: workspace) {
                        TimelinePanel(workspace: workspace)
                    }
                    AudioMetersPanel(engine: workspace.program)
                }
            }
        }
        .background(Theme.windowBackground)
        .preferredColorScheme(.dark)
        .background(KeyEventMonitor { workspace.handle(keyInput: $0) })
        .background(WindowAccessor { window in
            workspace.window = window
            SmokeTestDriver.startIfRequested(workspace: workspace)
        })
        .focusedSceneObject(workspace)
        .onAppear { workspace.attach(document: document, undoManager: undoManager) }
        .onChange(of: undoManager) { _, newValue in workspace.undoManager = newValue }
        .onChange(of: workspace.activePanel) { _, panel in
            if panel == .source { sourceTab = .source }
        }
        .fileImporter(
            isPresented: $workspace.isImporterPresented,
            allowedContentTypes: [.movie, .audio, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { workspace.importFiles(urls) }
        }
        .sheet(item: $workspace.sequenceSheet) { request in
            SequenceSettingsSheet(workspace: workspace, request: request)
        }
        .sheet(isPresented: $workspace.isExportSheetPresented) {
            ExportSheet(workspace: workspace)
        }
        .alert(item: $workspace.importReport) { report in
            Alert(
                title: Text("Some files weren't imported"),
                message: Text(report.summary),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var programTitle: String {
        workspace.activeSequence.map { "Program: \($0.name)" } ?? "Program: (no sequence)"
    }

    private var sourceTitle: String {
        workspace.sourceClipName.map { "Source: \($0)" } ?? "Source: (no clips)"
    }
}

extension WorkspaceController {
    /// Entry point for the window's key monitor.
    func handle(keyInput: KeyInput) -> Bool {
        guard let action = KeyBindingsStore.shared.bindings.action(for: keyInput) else { return false }
        return handle(action)
    }
}
