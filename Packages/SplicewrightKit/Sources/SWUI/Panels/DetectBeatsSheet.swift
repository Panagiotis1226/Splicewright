import SwiftUI
import SWCore

/// Sequence ▸ Detect Beats…: find the beat, then add markers on it or cut the selected video on it.
struct DetectBeatsSheet: View {
    @ObservedObject var workspace: WorkspaceController
    @AppStorage("beatsMinimumBPM") private var minimumBPM = BeatSettings().minimumBPM
    @AppStorage("beatsMaximumBPM") private var maximumBPM = BeatSettings().maximumBPM
    @AppStorage("beatsEvery") private var every = 1
    @AppStorage("beatsOffset") private var offset = 0
    @State private var found: (bpm: Double, frames: [Int64])?
    @State private var progress: Double?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    private var settings: BeatSettings {
        BeatSettings(minimumBPM: min(minimumBPM, maximumBPM - 10), maximumBPM: maximumBPM, every: every,
                     offset: offset)
    }
    private var rate: FrameRate { workspace.activeSequence?.rate ?? .fps30 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Detect Beats").font(.headline)
            if let scope = workspace.silenceScope() {
                let selection = workspace.beatSelection()
                Text(selection.audio.isEmpty
                     ? "Listens to \(scope.name) as it plays. Select the music clip to hear only that."
                     : "Listens to the selected audio clips over \(scope.name).")
                    .font(.caption).foregroundStyle(.secondary)
                Form {
                    LabeledContent("Tempo between") {
                        HStack {
                            TextField("", value: $minimumBPM, format: .number).frame(width: 48)
                            Text("and")
                            TextField("", value: $maximumBPM, format: .number).frame(width: 48)
                            Text("BPM")
                        }
                    }
                    .help("Narrow it if the tempo comes out at half or double what you hear")
                    Picker("Use", selection: $every) {
                        Text("Every beat").tag(1)
                        Text("Every 2nd beat").tag(2)
                        Text("Every 4th beat (a bar of 4/4)").tag(4)
                        Text("Every 8th beat").tag(8)
                    }
                    if every > 1 {
                        Stepper("Starting at beat \(offset + 1)", value: $offset, in: 0...(every - 1))
                    }
                }
                .onChange(of: settings.minimumBPM) { _, _ in found = nil }
                .onChange(of: settings.maximumBPM) { _, _ in found = nil }
                status
                buttons(scope.range, canCut: !selection.video.isEmpty)
            } else {
                Text("Open a sequence with clips first.")
                Button("OK") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { task?.cancel() }
    }

    private var picked: [Int64] {
        settings.picked(found?.frames ?? [])
    }

    @ViewBuilder private var status: some View {
        if let progress {
            ProgressView("Listening…", value: progress)
        } else if let failure {
            Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
        } else if let found {
            Text(found.frames.isEmpty ? "No steady beat found."
                                      : "\(String(format: "%.1f", found.bpm)) BPM: \(found.frames.count) beats, "
                                        + "\(picked.count) used.")
                .font(.caption)
        }
    }

    private func buttons(_ range: FrameRange, canCut: Bool) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
            if found != nil, !picked.isEmpty {
                Button("Cut Selected Video") {
                    workspace.cutSelectedVideoOnBeats(picked)
                    close()
                }
                .disabled(!canCut)
                .help(canCut ? "Adds an edit to each selected video clip on the beats"
                             : "Select video clips in the timeline to cut them on the beat")
                Button("Add \(picked.count) Markers") {
                    workspace.addBeatMarkers(picked)
                    close()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Find Beats") { find(range) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(progress != nil)
            }
        }
    }

    private func find(_ range: FrameRange) {
        failure = nil
        progress = 0
        let settings = settings
        task = Task { @MainActor in
            do {
                found = try await workspace.findBeats(settings, in: range) { fraction in
                    Task { @MainActor in if progress != nil { progress = fraction } }
                }
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
            progress = nil
        }
    }

    private func close() {
        task?.cancel()
        workspace.isDetectBeatsPresented = false
    }
}
