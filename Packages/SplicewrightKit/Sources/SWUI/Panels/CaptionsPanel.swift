import AppKit
import SwiftUI
import SWCore
import SWExport
import SWPlayback

/// The subtitle list, like Resolve's: every caption with its times and editable text, find
/// and replace, and the track's style. Click a time to jump there.
struct CaptionsPanel: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var engine: PlaybackEngine
    /// Observed so selection changes on the timeline highlight rows here.
    @ObservedObject var timeline: TimelineState
    @State private var find = ""
    @State private var replacement = ""
    @State private var replaceMessage: String?

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        engine = workspace.program
        timeline = workspace.timeline
    }

    var body: some View {
        if let sequence = workspace.activeSequence, let track = workspace.captionTrack {
            VStack(spacing: 0) {
                header(sequence, track: track)
                Divider()
                findBar(track)
                Divider()
                list(track, rate: sequence.rate)
            }
            .font(.system(size: 11))
        } else {
            VStack(spacing: 10) {
                Text("No subtitles yet").foregroundStyle(Theme.textSecondary)
                Button("Transcribe & Create Captions…") { workspace.isTranscribeSheetPresented = true }
                    .disabled(workspace.activeSequence == nil)
                HStack {
                    Button("Add Subtitle Track") { workspace.addCaptionTrack() }
                    Button("Import .srt…") { workspace.importCaptions() }
                }
                .disabled(workspace.activeSequence == nil)
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ sequence: EditSequence, track: CaptionTrack) -> some View {
        HStack(spacing: 6) {
            if sequence.captionTracks.count > 1 {
                Picker("", selection: Binding(get: { track.id }, set: { workspace.activeCaptionTrackID = $0 })) {
                    ForEach(sequence.captionTracks) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
            } else {
                Text(track.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            Text("\(track.captions.count) captions").foregroundStyle(Theme.textSecondary)
            Spacer()
            Button { workspace.addCaption(on: track.id, at: engine.currentFrame) } label: { Image(systemName: "plus") }
                .help("Add a caption at the playhead")
            Button { workspace.isTranscribeSheetPresented = true } label: { Image(systemName: "waveform.badge.mic") }
                .help("Transcribe & Create Captions…")
            Menu {
                Button("Standard (bottom, two lines)") { workspace.applyCaptionStyle(.standard, to: track.id) }
                Button("Social (big, one line)") { workspace.applyCaptionStyle(.social, to: track.id) }
                Divider()
                ForEach(SubRip.Format.allCases, id: \.self) { format in
                    Button("Export \(format.displayName)…") { workspace.exportCaptions(track.id, format: format) }
                }
                Button("Import Captions…") { workspace.importCaptions() }
                Divider()
                Button("Add Subtitle Track") { workspace.addCaptionTrack() }
                Button("Delete Subtitle Track", role: .destructive) { workspace.removeCaptionTrack(track.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private func findBar(_ track: CaptionTrack) -> some View {
        HStack(spacing: 6) {
            TextField("Find", text: $find).textFieldStyle(.roundedBorder)
            TextField("Replace with", text: $replacement).textFieldStyle(.roundedBorder)
            Button("Replace All") {
                let count = workspace.replaceInCaptions(on: track.id, find, with: replacement)
                replaceMessage = "\(count) changed"
            }
            .disabled(find.isEmpty || track.isLocked)
            if let replaceMessage { Text(replaceMessage).foregroundStyle(Theme.textSecondary) }
        }
        .controlSize(.small)
        .padding(6)
        .onChange(of: find) { _, _ in replaceMessage = nil }
    }

    private func list(_ track: CaptionTrack, rate: FrameRate) -> some View {
        let shown = find.isEmpty ? track.captions
            : track.captions.filter { $0.text.localizedCaseInsensitiveContains(find) }
        let current = track.caption(at: engine.currentFrame)?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(shown) { caption in
                        CaptionRowView(workspace: workspace, caption: caption, rate: rate, isLocked: track.isLocked,
                                       isCurrent: caption.id == current,
                                       isSelected: timeline.selection.contains(caption.id),
                                       focusRequest: workspace.focusedCaptionID == caption.id)
                            .id(caption.id)
                    }
                }
                .padding(4)
            }
            .onChange(of: workspace.focusedCaptionID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            .onChange(of: current) { _, id in
                if engine.isPlaying, let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// One caption: its in/out times (click to jump) and its text (⏎ saves, ⌥⏎ adds a line).
private struct CaptionRowView: View {
    @ObservedObject var workspace: WorkspaceController
    let caption: Caption
    let rate: FrameRate
    let isLocked: Bool
    let isCurrent: Bool
    let isSelected: Bool
    let focusRequest: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                workspace.program.seek(toFrame: caption.start)
                workspace.timeline.selection = [caption.id]
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Timecode(frame: caption.start, rate: rate).description)
                    Text(Timecode(frame: caption.end, rate: rate).description).foregroundStyle(Theme.textSecondary)
                }
                .font(Theme.smallTimecodeFont)
                .foregroundStyle(Theme.timecode)
            }
            .buttonStyle(.plain)
            .help("Go to this caption")
            TextField("Caption", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($focused)
                .disabled(isLocked)
                .onSubmit(commit)
                .onChange(of: focused) { _, now in if !now { commit() } }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(background))
        .contextMenu {
            Button("Split at Playhead") { workspace.splitCaption(caption.id, at: workspace.program.currentFrame) }
                .disabled(!caption.range.contains(workspace.program.currentFrame))
            Button("Merge with Next") { workspace.mergeCaptionWithNext(caption.id) }
            Divider()
            Button("Delete") {
                workspace.timeline.selection = [caption.id]
                workspace.deleteSelectedClips(ripple: false)
            }
        }
        .onAppear {
            draft = caption.text
            if focusRequest { focused = true }
        }
        .onChange(of: caption.text) { _, text in if !focused { draft = text } }
        .onChange(of: focusRequest) { _, wanted in if wanted { focused = true } }
    }

    private var background: Color {
        if isSelected { return Theme.accent.opacity(0.35) }
        if isCurrent { return Color.white.opacity(0.08) }
        return Color.clear
    }

    private func commit() {
        workspace.setCaptionText(caption.id, draft)
        if workspace.focusedCaptionID == caption.id { workspace.focusedCaptionID = nil }
    }
}

/// Sequence ▸ Transcribe & Create Captions…: on-device speech recognition into a new
/// subtitle track.
struct TranscribeSheet: View {
    @ObservedObject var workspace: WorkspaceController
    @State private var locales: [Locale] = []
    @State private var localeID = Locale.current.identifier
    @State private var inToOut = false
    @State private var social = false
    @State private var maxCharacters = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcribe & Create Captions").font(.headline)
            if let job = workspace.captionJob {
                JobProgress(job: job, workspace: workspace)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            let found = await Transcriber.supportedLocales()
            locales = found
            let language = Locale.current.language.languageCode
            if !found.contains(where: { $0.identifier == localeID }),
               let match = found.first(where: { $0.language.languageCode == language }) ?? found.first {
                localeID = match.identifier
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Picker("Language", selection: $localeID) {
                    if locales.isEmpty { Text("Loading…").tag(localeID) }
                    ForEach(locales, id: \.identifier) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }
                Picker("Range", selection: $inToOut) {
                    Text("Entire Sequence").tag(false)
                    Text("Sequence In to Out").tag(true)
                }
                Picker("Style", selection: $social) {
                    Text("Standard: bottom, up to two lines").tag(false)
                    Text("Social: big, one short line").tag(true)
                }
                .onChange(of: social) { _, isSocial in maxCharacters = isSocial ? 18 : 42 }
                Stepper("Up to \(maxCharacters) characters per line", value: $maxCharacters, in: 10...60)
            }
            Text("Speech is recognized on this Mac; nothing is uploaded. The first time you use a language, macOS "
                 + "may download it. You can edit, move, split and merge captions afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { workspace.isTranscribeSheetPresented = false }.keyboardShortcut(.cancelAction)
                Button("Create Captions") {
                    var style: CaptionStyle = social ? .social : .standard
                    style.maxCharactersPerLine = maxCharacters
                    workspace.transcribe(TranscriptionRequest(locale: Locale(identifier: localeID), inToOut: inToOut,
                                                              style: style))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(locales.isEmpty || (inToOut && workspace.activeSequence?.marks.range == nil))
            }
        }
    }
}

private struct JobProgress: View {
    @ObservedObject var job: CaptionJob
    @ObservedObject var workspace: WorkspaceController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if job.error == nil {
                if let fraction = job.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Text(job.statusText)
                .foregroundStyle(job.error == nil ? Color.primary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if job.error != nil {
                    Button("Close") {
                        workspace.captionJob = nil
                        workspace.isTranscribeSheetPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") {
                        job.cancel()
                        workspace.captionJob = nil
                        workspace.isTranscribeSheetPresented = false
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}
