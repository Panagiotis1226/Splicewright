import SwiftUI
import SWCore

/// Sequence ▸ Auto Reframe Sequence…: the new shape and how closely to follow the subject.
struct AutoReframeSheet: View {
    @ObservedObject var workspace: WorkspaceController
    @AppStorage("reframeAspect") private var aspect = ReframeSettings.Aspect.vertical
    @AppStorage("reframePace") private var pace = ReframeSettings.Pace.standard
    @State private var progress: Double?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Auto Reframe Sequence").font(.headline)
            if let sequence = workspace.activeSequence {
                Text("Makes a copy of \(sequence.name) at the new shape. Each clip is scaled to fill it and "
                     + "panned to keep faces, people or the main subject in frame (found with macOS's built-in "
                     + "Vision; nothing is downloaded). Titles and captions stay where they are.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Form {
                    Picker("Aspect ratio", selection: $aspect) {
                        ForEach(ReframeSettings.Aspect.allCases) { Text($0.displayName).tag($0) }
                    }
                    let size = ReframeSettings(aspect: aspect).frameSize(from: sequence.settings)
                    LabeledContent("Frame size", value: "\(size.width) × \(size.height)")
                    Picker("Motion tracking", selection: $pace) {
                        ForEach(ReframeSettings.Pace.allCases) { Text($0.displayName).tag($0) }
                    }
                    .help("Slower keeps the frame steady; faster follows quick movement")
                }
                if let progress {
                    ProgressView("Finding the subject…", value: progress)
                } else if let failure {
                    Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                    Button("Create") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(progress != nil)
                }
            } else {
                Text("Open a sequence first.")
                Button("OK") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { task?.cancel() }
    }

    private func create() {
        failure = nil
        progress = 0
        let settings = ReframeSettings(aspect: aspect, pace: pace)
        task = Task { @MainActor in
            do {
                try await workspace.autoReframe(settings) { fraction in
                    if progress != nil { progress = fraction }
                }
                progress = nil
                close()
            } catch is CancellationError {
                progress = nil
            } catch {
                failure = error.localizedDescription
                progress = nil
            }
        }
    }

    private func close() {
        task?.cancel()
        workspace.isAutoReframePresented = false
    }
}
