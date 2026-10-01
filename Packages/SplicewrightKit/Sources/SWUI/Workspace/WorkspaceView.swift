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
    @ObservedObject private var layouts = WorkspaceStore.shared

    public init(document: ProjectDocument) {
        self.document = document
    }

    public var body: some View {
        SplitPane(.vertical, fraction: split(\.rootSplit), minFirst: 220, minSecond: 260) {
            SplitPane(.horizontal, fraction: split(\.topSplit), minFirst: 320, minSecond: 320) {
                PanelContainer(
                    tabs: [
                        PanelTab(id: .source, title: sourceTitle),
                        PanelTab(id: .effectControls, title: "Effect Controls"),
                        PanelTab(id: .effects, title: "Effects"),
                        PanelTab(id: .captions, title: "Captions"),
                    ],
                    selectedTab: sourceTab,
                    workspace: workspace
                ) {
                    switch sourceTab.wrappedValue {
                    case .effectControls: EffectControlsPanel(workspace: workspace)
                    case .effects: EffectsPanel(workspace: workspace)
                    case .captions: CaptionsPanel(workspace: workspace)
                    default: SourceMonitorPanel(workspace: workspace)
                    }
                }
            } second: {
                PanelContainer(.program, title: programTitle, workspace: workspace) {
                    ProgramMonitorPanel(workspace: workspace)
                }
            }
        } second: {
            SplitPane(.horizontal, fraction: split(\.bottomSplit), minFirst: 300, minSecond: 480) {
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
            workspace.attachWindow(window)
            SmokeTestDriver.startIfRequested(workspace: workspace)
        })
        .focusedSceneObject(workspace)
        .onAppear { workspace.attach(document: document, undoManager: undoManager) }
        .onChange(of: undoManager) { _, newValue in workspace.undoManager = newValue }
        .onChange(of: workspace.activePanel) { _, panel in
            if [.source, .effectControls, .effects, .captions].contains(panel) { sourceTab.wrappedValue = panel }
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
        .sheet(isPresented: $workspace.isTranscribeSheetPresented) {
            TranscribeSheet(workspace: workspace)
        }
        .sheet(isPresented: Binding(get: { workspace.speedSheetClipIDs != nil },
                                    set: { if !$0 { workspace.speedSheetClipIDs = nil } })) {
            if let ids = workspace.speedSheetClipIDs { SpeedDurationSheet(workspace: workspace, ids: ids) }
        }
        .alert(item: $workspace.importReport) { report in
            Alert(
                title: Text("Some files weren't imported"),
                message: Text(report.summary),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    /// A divider position stored in the current workspace.
    private func split(_ key: WritableKeyPath<WorkspaceLayout, Double>) -> Binding<CGFloat> {
        Binding(get: { CGFloat(layouts.current[keyPath: key]) },
                set: { value in layouts.update { $0[keyPath: key] = Double(value) } })
    }

    /// The front tab of the Source panel group, stored in the current workspace.
    private var sourceTab: Binding<PanelID> {
        Binding(get: { PanelID(rawValue: layouts.current.sourceTab) ?? .source },
                set: { panel in layouts.update { $0.sourceTab = panel.rawValue } })
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
