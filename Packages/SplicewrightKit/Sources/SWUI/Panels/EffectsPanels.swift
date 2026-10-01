import SwiftUI
import SWCore

/// The Effects browser: drag a transition onto a cut or clip edge in the timeline, or
/// double-click it to apply it at the edit point nearest the playhead.
struct EffectsPanel: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject private var defaults = EffectDefaults.shared
    @State private var search = ""

    /// Pasteboard prefix for transition drags (the rest is the kind's raw value).
    static let transitionPrefix = "splicewright.transition:"
    /// Pasteboard string for dragging a new title.
    static let titlePayload = "splicewright.title"

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search effects", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(6)
            // A plain scroll view rather than a List: in a List the row's double-click
            // recognizer swallows the mouse-down, so drags never start.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    section("Video Transitions", TransitionKind.video)
                    section("Audio Transitions", TransitionKind.audio)
                    if search.isEmpty || "title".localizedCaseInsensitiveContains(search) {
                        header("Graphics")
                        EffectRow(symbol: "textformat", title: "Title", isDefault: false, payload: Self.titlePayload,
                                  onDoubleClick: { workspace.newTitle() })
                            .help("Drag onto a video track, or double-click to add a title at the playhead")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            Text("Drag onto a clip or cut, or double-click to apply at the playhead. Right-click to set the default "
                 + "(⌘D, ⇧⌘D).")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .padding(6)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func section(_ title: String, _ kinds: [TransitionKind]) -> some View {
        let matching = kinds.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
        if !matching.isEmpty {
            header(title)
            ForEach(matching) { kind in
                EffectRow(symbol: Self.symbol(for: kind), title: kind.displayName, isDefault: defaults.isDefault(kind),
                          payload: Self.transitionPrefix + kind.rawValue, onDoubleClick: { apply(kind) })
                    .contextMenu {
                        Button("Set as Default \(kind.isAudio ? "Audio" : "Video") Transition") { defaults.makeDefault(kind) }
                        Button("Apply at Playhead") { apply(kind) }
                    }
            }
        }
    }

    private func apply(_ kind: TransitionKind) {
        let previous = defaults.isDefault(kind) ? nil : (kind.isAudio ? defaults.audioTransition : defaults.videoTransition)
        defaults.makeDefault(kind)
        workspace.applyDefaultTransition(audio: kind.isAudio)
        if let previous { defaults.makeDefault(previous) }
    }

    static func symbol(for kind: TransitionKind) -> String {
        switch kind {
        case .crossDissolve: return "square.on.square"
        case .dipToBlack: return "square.fill"
        case .dipToWhite: return "square"
        case .filmDissolve: return "square.on.square.dashed"
        case .wipeRight: return "arrow.right.square"
        case .wipeLeft: return "arrow.left.square"
        case .wipeDown: return "arrow.down.square"
        case .wipeUp: return "arrow.up.square"
        case .constantPower: return "waveform.path"
        case .constantGain: return "waveform"
        }
    }
}

/// One draggable effect. The drag is the outermost modifier and the double-click is a
/// simultaneous gesture, so neither blocks the other.
private struct EffectRow: View {
    let symbol: String
    let title: String
    let isDefault: Bool
    let payload: String
    let onDoubleClick: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Image(systemName: symbol).frame(width: 18)
            Text(title)
            Spacer()
            if isDefault {
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                    .help("Default transition")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 3).fill(hovering ? Color.white.opacity(0.08) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded(onDoubleClick))
        .draggable(payload) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11))
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.accent.opacity(0.8)))
        }
    }
}

/// Effect Controls: settings for the selected transition, or the selected clip's opacity/gain.
struct EffectControlsPanel: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var timeline: TimelineState

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        timeline = workspace.timeline
    }

    var body: some View {
        Group {
            if let selected = workspace.selectedTransition, let sequence = workspace.activeSequence {
                TransitionControls(workspace: workspace, transition: selected.transition, rate: sequence.rate)
            } else if let title = workspace.selectedTitleClip, let spec = title.title {
                TitleControls(workspace: workspace, clipID: title.id, spec: spec, opacity: title.opacity)
            } else if let clip = selectedClip {
                ClipControls(workspace: workspace, clip: clip, isVideo: isVideo(clip))
            } else {
                Text("Select a clip or transition in the timeline")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var selectedClip: Clip? {
        guard let sequence = workspace.activeSequence else { return nil }
        let clips = timeline.selection.compactMap { sequence.clip($0) }
        // With linked clips selected, show the video one.
        return clips.first { isVideo($0) } ?? clips.first
    }

    private func isVideo(_ clip: Clip) -> Bool {
        workspace.activeSequence?.videoTracks.contains { $0.clips.contains { $0.id == clip.id } } ?? false
    }
}

private struct TransitionControls: View {
    @ObservedObject var workspace: WorkspaceController
    let transition: ResolvedTransition
    let rate: FrameRate
    @State private var frames: Int = 0

    var body: some View {
        Form {
            Section(transition.left == nil || transition.right == nil ? "Fade" : "Transition") {
                Picker("Type", selection: Binding(get: { transition.kind }, set: { kind in
                    workspace.updateTransition(transition.id, "Change Transition") { $0.kind = kind }
                })) {
                    ForEach(transition.kind.isAudio ? TransitionKind.audio : TransitionKind.video) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                LabeledContent("Duration") {
                    HStack {
                        TextField("Frames", value: $frames, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .onSubmit(commitDuration)
                        Stepper("", value: $frames, in: 1...10_000) { editing in
                            if !editing { commitDuration() }
                        }
                        .labelsHidden()
                        Text(Timecode(frame: Int64(frames), rate: rate).description)
                            .font(Theme.smallTimecodeFont)
                            .foregroundStyle(Theme.timecode)
                    }
                }
                if transition.left != nil && transition.right != nil {
                    Picker("Alignment", selection: Binding(get: { transition.transition.alignment }, set: { alignment in
                        workspace.updateTransition(transition.id, "Transition Alignment") { $0.alignment = alignment }
                    })) {
                        ForEach(TransitionAlignment.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                if transition.duration < transition.transition.duration {
                    Text("Shortened to \(transition.duration) frames to fit the clips.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Delete Transition", role: .destructive) { workspace.deleteTransition(transition.id) }
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 11))
        .onAppear { frames = Int(transition.transition.duration) }
        .onChange(of: transition) { _, newValue in frames = Int(newValue.transition.duration) }
    }

    private func commitDuration() {
        let value = Int64(max(1, frames))
        guard value != transition.transition.duration else { return }
        workspace.updateTransition(transition.id, "Transition Duration") { $0.duration = value }
    }
}

private struct ClipControls: View {
    @ObservedObject var workspace: WorkspaceController
    let clip: Clip
    let isVideo: Bool
    @State private var value: Double = 0

    var body: some View {
        Form {
            Section(clip.name) {
                if isVideo {
                    LabeledContent("Opacity") {
                        Slider(value: $value, in: 0...100) { editing in
                            if !editing { workspace.setClipOpacity([clip.id], value / 100) }
                        }
                        Text("\(Int(value.rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                } else {
                    LabeledContent("Gain") {
                        Slider(value: $value, in: -60...24) { editing in
                            if !editing { workspace.setClipGain([clip.id], value) }
                        }
                        Text(String(format: "%+.1f dB", value)).monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 11))
        .onAppear(perform: load)
        .onChange(of: clip) { _, _ in load() }
    }

    private func load() {
        value = isVideo ? clip.opacity * 100 : clip.gainDB
    }
}
