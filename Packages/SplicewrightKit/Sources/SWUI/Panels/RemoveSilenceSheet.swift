import SwiftUI
import SWCore

/// Sequence ▸ Remove Silence…: how quiet and how long a pause is, then find, and remove or cut.
struct RemoveSilenceSheet: View {
    @ObservedObject var workspace: WorkspaceController
    @AppStorage("silenceThreshold") private var threshold = SilenceSettings().thresholdDB
    @AppStorage("silenceMinimum") private var minimum = SilenceSettings().minimumSeconds
    @AppStorage("silencePadding") private var padding = SilenceSettings().paddingSeconds
    @State private var pauses: [FrameRange]?
    @State private var progress: Double?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    private var settings: SilenceSettings {
        SilenceSettings(thresholdDB: threshold, minimumSeconds: minimum, paddingSeconds: padding)
    }
    private var rate: FrameRate { workspace.activeSequence?.rate ?? .fps30 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove Silence").font(.headline)
            if let scope = workspace.silenceScope() {
                Text("Looks at \(scope.name), as it plays (faders and audio effects included).")
                    .font(.caption).foregroundStyle(.secondary)
                Form {
                    slider("Quieter than", value: $threshold, in: SilenceSettings.thresholdRange, step: 1,
                           text: (String(format: "%.0f dB", threshold),
                                  "Raise it if pauses with room noise aren't found; lower it if quiet speech is"))
                    slider("For at least", value: $minimum, in: SilenceSettings.minimumRange, step: 0.05,
                           text: (String(format: "%.2f s", minimum), "Shorter pauses stay"))
                    slider("Keep around words", value: $padding, in: SilenceSettings.paddingRange, step: 0.05,
                           text: (String(format: "%.2f s", padding),
                                  "Left on each side of a pause so speech doesn't sound clipped"))
                }
                .onChange(of: settings) { _, _ in pauses = nil }
                status
                HStack {
                    Spacer()
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                    if let pauses, !pauses.isEmpty {
                        Button("Cut Only") { apply(pauses, cutOnly: true) }
                            .help("Splits every track around each pause and selects the pauses, to review")
                        Button("Remove \(pauses.count) Pauses") { apply(pauses, cutOnly: false) }
                            .keyboardShortcut(.defaultAction)
                            .help("Takes the pauses out of every unlocked track and closes the gaps")
                    } else {
                        Button("Find Pauses") { find(scope.range) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(progress != nil)
                    }
                }
            } else {
                Text("Open a sequence with clips first.")
                Button("OK") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder private var status: some View {
        if let progress {
            ProgressView("Listening…", value: progress)
        } else if let failure {
            Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
        } else if let pauses {
            let seconds = Double(pauses.map(\.length).reduce(0, +)) / rate.framesPerSecond
            Text(pauses.isEmpty ? "No pauses found. Try a higher level or a shorter minimum."
                                : "\(pauses.count) pauses, \(String(format: "%.1f", seconds)) s in all.")
                .font(.caption)
        }
    }

    /// A labelled slider: `text` is the value as shown, and the tooltip.
    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                        text: (label: String, help: String)) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(text.label).monospacedDigit().frame(width: 56, alignment: .trailing)
            }
        }
        .help(text.help)
    }

    private func find(_ range: FrameRange) {
        failure = nil
        progress = 0
        let settings = settings
        task = Task { @MainActor in
            do {
                pauses = try await workspace.findSilences(settings, in: range) { fraction in
                    Task { @MainActor in if progress != nil { progress = fraction } }
                }
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
            progress = nil
        }
    }

    private func apply(_ pauses: [FrameRange], cutOnly: Bool) {
        workspace.removeSilences(pauses, cutOnly: cutOnly)
        close()
    }

    private func close() {
        task?.cancel()
        workspace.isRemoveSilencePresented = false
    }
}
