import SwiftUI
import SWCore

/// Menu bar additions. Items act on the frontmost project window's workspace.
public struct SplicewrightCommands: Commands {
    @FocusedObject private var workspace: WorkspaceController?
    @ObservedObject private var keys = KeyBindingsStore.shared
    @ObservedObject private var workspaces = WorkspaceStore.shared

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Import…") { workspace?.isImporterPresented = true }
                .shortcut(.importMedia, keys)
                .disabled(workspace == nil)
            Button("Import Timeline from Premiere Pro, Resolve or Final Cut…") { workspace?.chooseTimelineToImport() }
                .disabled(workspace == nil)
            Button("New Bin") { workspace?.newBin() }
                .shortcut(.newBin, keys)
                .disabled(workspace == nil)
            Button("Link Media…") { workspace?.linkMedia() }
                .disabled(workspace?.offlineMediaIDs.isEmpty ?? true)
            Button("Open Auto-Save…") { AutoSaver.chooseVersionToOpen() }
            Button("Import Captions…") { workspace?.importCaptions() }
                .disabled(workspace?.activeSequenceID == nil)
            Divider()
            Menu("Export") {
                // Not Premiere's ⌘M: that's Window ▸ Minimize on the Mac.
                Button("Media…") { workspace?.requestExport() }
                    .shortcut(.exportMedia, keys)
                Divider()
                Button("Timeline for Premiere Pro (Final Cut Pro 7 XML)…") { workspace?.exportTimeline(.fcp7XML) }
                Button("Timeline for DaVinci Resolve or Final Cut Pro (FCPXML)…") { workspace?.exportTimeline(.fcpxml) }
                Button("Timeline for DaVinci Resolve (OpenTimelineIO)…") { workspace?.exportTimeline(.otio) }
                Divider()
                Button("Markers as YouTube Chapters…") { workspace?.exportChapters() }
                    .disabled(workspace?.activeSequence?.markers.isEmpty ?? true)
                Button("Markers as CSV…") { workspace?.exportMarkersCSV() }
                    .disabled(workspace?.activeSequence?.markers.isEmpty ?? true)
                if let track = workspace?.captionTrack {
                    ForEach(SubRip.Format.allCases, id: \.self) { format in
                        Button("Captions as \(format.displayName)…") { workspace?.exportCaptions(track.id, format: format) }
                    }
                }
            }
            .disabled(workspace?.activeSequenceID == nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("Paste Attributes") { workspace?.pasteAttributes() }
                .shortcut(.pasteAttributes, keys)
                .disabled(workspace?.activeSequenceID == nil)
        }
        CommandMenu("Sequence") {
            Button("New Sequence…") { workspace?.requestNewSequence() }
                .shortcut(.newSequence, keys)
            Button("Sequence Settings…") { workspace?.requestSequenceSettings() }
                .disabled(workspace?.activeSequenceID == nil)
            Button("Transcribe & Create Captions…") { workspace?.isTranscribeSheetPresented = true }
                .disabled(workspace?.activeSequenceID == nil)
            Button("Add Subtitle Track") { workspace?.addCaptionTrack() }
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
        CommandGroup(after: .toolbar) {
            Toggle("Use Proxies", isOn: Binding(get: { workspace?.useProxies ?? false },
                                                set: { workspace?.useProxies = $0 }))
                .shortcut(.toggleProxies, keys)
                .disabled(workspace == nil)
            Button("Program Monitor Background…") { workspace?.isMonitorBackgroundPickerShown = true }
                .disabled(workspace == nil)
            Toggle("Show Video Keyframes", isOn: Binding(get: { workspace?.timeline.showsVideoKeyframes ?? true },
                                                         set: { workspace?.timeline.showsVideoKeyframes = $0 }))
                .disabled(workspace == nil)
            Toggle("Show Audio Keyframes", isOn: Binding(get: { workspace?.timeline.showsAudioKeyframes ?? true },
                                                         set: { workspace?.timeline.showsAudioKeyframes = $0 }))
                .disabled(workspace == nil)
            Divider()
        }
        CommandMenu("Clip") {
            Button("Speed/Duration…") { workspace?.requestSpeedDuration() }
                .shortcut(.speedDuration, keys)
                .disabled(workspace?.activeSequenceID == nil)
        }
        CommandMenu("Graphics") {
            Button("New Title") { workspace?.newTitle() }
                .shortcut(.newTitle, keys)
                .disabled(workspace == nil)
            Button("New Adjustment Layer") { workspace?.newAdjustmentLayer() }
                .disabled(workspace == nil)
        }
        CommandMenu("Marker") {
            Button("Add Marker") { workspace?.handle(.addMarker) }
            Button("Go to Next Marker") { workspace?.handle(.nextMarker) }
            Button("Go to Previous Marker") { workspace?.handle(.previousMarker) }
            Button("Clear All Markers") { workspace?.clearAllMarkers() }
                .disabled(workspace?.activeSequence?.markers.isEmpty ?? true)
            Divider()
            Button("Mark In") { workspace?.handle(.markIn) }
            Button("Mark Out") { workspace?.handle(.markOut) }
            Button("Clear In and Out") { workspace?.handle(.clearInAndOut) }
            Divider()
            Button("Go to In") { workspace?.handle(.goToIn) }
            Button("Go to Out") { workspace?.handle(.goToOut) }
        }
        CommandGroup(before: .windowArrangement) {
            Menu("Workspaces") {
                ForEach(Array(workspaces.library.saved.enumerated()), id: \.element.id) { index, layout in
                    Toggle(layout.name, isOn: Binding(get: { workspaces.library.currentID == layout.id },
                                                      set: { _ in workspaces.select(layout.id) }))
                        .modifier(WorkspaceShortcut(index: index, keys: keys))
                }
                Divider()
                Button("Save Changes to This Workspace") { workspaces.saveChanges() }
                    .disabled(!workspaces.library.hasUnsavedChanges(workspaces.library.currentID))
                Button("Save as New Workspace…") { workspaces.promptSaveAsNew() }
                Button("Reset to Saved Layout") { workspaces.resetToSaved() }
                    .disabled(!workspaces.library.hasUnsavedChanges(workspaces.library.currentID))
                Divider()
                OpenSettingsButton(title: "Edit Workspaces…", tab: .workspaces)
            }
            Divider()
        }
        CommandGroup(after: .help) {
            Divider()
            OpenSettingsButton(title: "Keyboard Shortcuts…", tab: .keyboard)
            Button("Show Logs in Finder") { AppLogMenu.reveal() }
        }
    }
}

/// ⌥⇧1…9 (or the user's shortcuts) for the first nine workspaces.
private struct WorkspaceShortcut: ViewModifier {
    let index: Int
    let keys: KeyBindingsStore

    func body(content: Content) -> some View {
        if index < CommandID.workspaceCommands.count {
            content.shortcut(CommandID.workspaceCommands[index], keys)
        } else {
            content
        }
    }
}
