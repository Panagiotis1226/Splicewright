import SwiftUI
import SWCore

/// Clip ▸ Scene Edit Detection…: how sensitive, then cut or mark at each shot change.
struct SceneDetectionSheet: View {
    @ObservedObject var workspace: WorkspaceController
    @AppStorage("sceneSensitivity") private var sensitivity = SceneSettings().sensitivity
    @AppStorage("sceneMinimum") private var minimum = SceneSettings().minimumSeconds
    @State private var action: WorkspaceController.SceneAction = .edits
    @State private var progress: Double?
    @State private var result: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        let clips = workspace.sceneDetectionClips()
        VStack(alignment: .leading, spacing: 14) {
            Text("Scene Edit Detection").font(.headline)
            if clips.isEmpty {
                Text("Select a video clip, or put the playhead over one.")
                Button("OK") { close() }.keyboardShortcut(.defaultAction)
            } else {
                Text(clips.count == 1 ? "Looks for shot changes in “\(clips[0].name)”."
                                      : "Looks for shot changes in \(clips.count) clips.")
                    .font(.caption).foregroundStyle(.secondary)
                Form {
                    LabeledContent("Sensitivity") {
                        HStack {
                            Slider(value: $sensitivity, in: 0...100, step: 5)
                            Text("\(Int(sensitivity))").monospacedDigit().frame(width: 32, alignment: .trailing)
                        }
                    }
                    .help("Higher finds softer cuts between similar shots, and more false ones")
                    LabeledContent("Shortest shot") {
                        HStack {
                            Slider(value: $minimum, in: 0.1...3, step: 0.1)
                            Text(String(format: "%.1f s", minimum)).monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                    Picker("Then", selection: $action) {
                        ForEach(WorkspaceController.SceneAction.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                }
                if let progress {
                    ProgressView("Watching…", value: progress)
                } else if let result {
                    Text(result).font(.caption)
                }
                Text("Finds hard cuts; dissolves and fades aren't split.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    if result == nil {
                        Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                        Button("Detect") { detect(clips) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(progress != nil)
                    } else {
                        Button("Done") { close() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear { task?.cancel() }
    }

    private func detect(_ clips: [Clip]) {
        progress = 0
        let settings = SceneSettings(sensitivity: sensitivity, minimumSeconds: minimum)
        let action = action
        task = Task { @MainActor in
            do {
                let count = try await workspace.detectScenes(in: clips, settings: settings, action: action) { fraction in
                    Task { @MainActor in if progress != nil { progress = fraction } }
                }
                let what = action == .edits ? "edits" : "markers"
                result = count == 0 ? "No cuts found. Try a higher sensitivity." : "Added \(count) \(what) (⌘Z undoes)."
            } catch is CancellationError {
            } catch {
                result = "Couldn't read the clip: \(error.localizedDescription)"
            }
            progress = nil
        }
    }

    private func close() {
        task?.cancel()
        workspace.isSceneDetectionPresented = false
    }
}
