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
        VSplitView {
            HSplitView {
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
                    case .effectControls: EffectControlsPanel()
                    case .effects: EffectsPanel()
                    default: SourceMonitorPanel(workspace: workspace)
                    }
                }
                .frame(minWidth: 360, idealWidth: 640)

                PanelContainer(.program, title: programTitle, workspace: workspace) {
                    ProgramMonitorPanel(workspace: workspace)
                }
                .frame(minWidth: 360, idealWidth: 640)
            }
            .frame(minHeight: 300, idealHeight: 460)

            HSplitView {
                PanelContainer(.project, title: "Project", workspace: workspace) {
                    ProjectPanel(workspace: workspace)
                }
                .frame(minWidth: 380, idealWidth: 520)

                HStack(spacing: 0) {
                    ToolsPanel(workspace: workspace)
                    PanelContainer(.timeline, title: "Timeline", workspace: workspace) {
                        TimelinePanel(workspace: workspace)
                    }
                    AudioMetersPanel(engine: workspace.program)
                }
                .frame(minWidth: 480)
            }
            .frame(minHeight: 240, idealHeight: 340)
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
        guard let action = KeyMap.action(for: keyInput) else { return false }
        return handle(action)
    }
}
