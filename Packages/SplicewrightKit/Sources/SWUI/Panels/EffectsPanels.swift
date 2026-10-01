import SwiftUI
import SWCore

/// The Effects browser: drag a transition onto a cut or clip edge in the timeline, or
/// double-click it to apply it at the edit point nearest the playhead. Video effects drop onto
/// clips (or apply to the selection on a double-click).
struct EffectsPanel: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject private var defaults = EffectDefaults.shared
    @State private var search = ""

    /// Pasteboard prefix for transition drags (the rest is the kind's raw value).
    static let transitionPrefix = "splicewright.transition:"
    /// Pasteboard string for dragging a new title.
    static let titlePayload = "splicewright.title"
    /// Pasteboard prefix for video effect drags (the rest is the kind's raw value).
    static let effectPrefix = "splicewright.effect:"
    /// Pasteboard string for dragging a new adjustment layer.
    static let adjustmentPayload = "splicewright.adjustment"

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
                    effects("Video Effects", EffectKind.video, help: "Drag onto a clip or adjustment layer")
                    effects("Audio Effects", EffectKind.audio, help: "Drag onto an audio clip")
                    graphics
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            Text("Drag onto a clip or cut. Double-click a transition to apply it at the playhead, or an effect to apply "
                 + "it to the selection. Right-click a transition to set the default (⌘D, ⇧⌘D).")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .padding(6)
        }
    }

    @ViewBuilder
    private func effects(_ title: String, _ kinds: [EffectKind], help: String) -> some View {
        let matching = kinds.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
        if !matching.isEmpty {
            header(title)
            ForEach(matching) { kind in
                EffectRow(symbol: kind.symbol, title: kind.displayName, isDefault: false,
                          payload: Self.effectPrefix + kind.rawValue, onDoubleClick: { workspace.addEffect(kind) })
                    .help(help + ", or double-click to apply to the selected clips")
            }
        }
    }

    @ViewBuilder
    private var graphics: some View {
        let title = search.isEmpty || "title".localizedCaseInsensitiveContains(search)
        let adjustment = search.isEmpty || "adjustment layer".localizedCaseInsensitiveContains(search)
        if title || adjustment { header("Graphics") }
        if title {
            EffectRow(symbol: "textformat", title: "Title", isDefault: false, payload: Self.titlePayload,
                      onDoubleClick: { workspace.newTitle() })
                .help("Drag onto a video track, or double-click to add a title at the playhead")
        }
        if adjustment {
            EffectRow(symbol: "square.stack.3d.down.forward", title: "Adjustment Layer", isDefault: false,
                      payload: Self.adjustmentPayload, onDoubleClick: { workspace.newAdjustmentLayer() })
                .help("Drag onto a video track, or double-click to add one at the playhead. Its effects apply to "
                      + "every track below it.")
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

    @State private var titleSplit: CGFloat = 0.55

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        timeline = workspace.timeline
    }

    var body: some View {
        Group {
            if let selected = workspace.selectedTransition, let sequence = workspace.activeSequence {
                TransitionControls(workspace: workspace, transition: selected.transition, rate: sequence.rate)
            } else if let selected = workspace.effectControlsClip {
                if let spec = selected.clip.title {
                    SplitPane(.vertical, fraction: $titleSplit, minFirst: 120, minSecond: 120) {
                        TitleControls(workspace: workspace, clipID: selected.clip.id, spec: spec,
                                      opacity: selected.clip.opacity)
                    } second: {
                        MotionControls(workspace: workspace, clip: selected.clip, isVideo: true)
                    }
                } else {
                    MotionControls(workspace: workspace, clip: selected.clip, isVideo: selected.isVideo)
                }
            } else {
                Text("Select a clip or transition in the timeline")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
