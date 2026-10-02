import SwiftUI
import SWCore

/// The Stabilizer in Effect Controls: analysis status (Analyze, progress, Cancel), and how the
/// shot is smoothed: Result, Method, Smoothness, Framing and the most it may zoom.
struct StabilizerControls: View {
    @ObservedObject var workspace: WorkspaceController
    let clip: Clip
    let effect: ClipEffect

    private var data: StabilizationData? { effect.stabilization }
    private var settings: StabilizationSettings { data?.settings ?? StabilizationSettings() }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            status
            if data != nil {
                picker("Result", \.result, TrackingOptions.results)
                picker("Method", \.method, TrackingOptions.methods, reanalyses: true)
                slider("Smoothness", \.smoothness, 0...100, unit: "%")
                    .disabled(settings.result == .noMotion)
                picker("Framing", \.framing, TrackingOptions.framings)
                if settings.framing == .autoScale {
                    slider("Maximum Scale", \.maximumScale, 100...200, unit: "%")
                    Text("Zooms \(Int(((data?.zoom ?? 1) * 100).rounded()))% to hide the moving edges.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.leading, 34)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 26)
            if let job = workspace.stabilizationJob, job.effectID == effect.id {
                AnalysisProgress(job: job)
            } else if let data, data.isComplete {
                Text("Analysed \(data.frameCount) frames").foregroundStyle(Theme.textSecondary)
                if workspace.stabilizationNeedsAnalysis(clip, effect: effect) {
                    Label("The clip now shows frames that weren't analysed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 10))
                }
                Spacer()
                Button("Analyze Again") { analyze() }.controlSize(.small)
            } else {
                Text(clip.isGenerated ? "Stabilizes video clips only" : "Not analysed yet")
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Analyze") { analyze() }
                    .controlSize(.small)
                    .disabled(clip.isGenerated || workspace.stabilizationJob != nil)
            }
        }
        .frame(height: 24)
    }

    private func analyze() {
        workspace.analyzeStabilization(clipID: clip.id, effectID: effect.id)
    }

    private func picker<Value: Hashable>(_ title: String, _ keyPath: WritableKeyPath<StabilizationSettings, Value>,
                                         _ options: [(Value, String)], reanalyses: Bool = false) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 26)
            Text(title).frame(width: 82, alignment: .leading)
            Picker("", selection: Binding(get: { settings[keyPath: keyPath] }, set: { value in
                var updated = settings
                updated[keyPath: keyPath] = value
                workspace.setStabilizationSettings(updated, effectID: effect.id, of: clip.id)
                // The method decides what the analysis measures.
                if reanalyses { analyze() }
            })) {
                ForEach(options.indices, id: \.self) { index in Text(options[index].1).tag(options[index].0) }
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            Spacer()
        }
        .frame(height: 22)
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<StabilizationSettings, Double>,
                        _ range: ClosedRange<Double>, unit: String) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 26)
            Text(title).frame(width: 82, alignment: .leading)
            Slider(value: Binding(get: { settings[keyPath: keyPath] }, set: { value in
                var updated = settings
                updated[keyPath: keyPath] = value.rounded()
                workspace.setStabilizationSettings(updated, effectID: effect.id, of: clip.id, live: true)
            }), in: range) { editing in
                if !editing { workspace.endLiveEdit(title) }
            }
            .controlSize(.small)
            .frame(maxWidth: 180)
            Text("\(Int(settings[keyPath: keyPath]))\(unit)")
                .font(.system(size: 10).monospacedDigit())
                .frame(width: 40, alignment: .trailing)
            Spacer()
        }
        .frame(height: 22)
    }
}

/// The Stabilizer's choices with their names, for the pickers.
private enum TrackingOptions {
    static let results = StabilizationSettings.Result.allCases.map { ($0, $0.displayName) }
    static let methods = StabilizationSettings.Method.allCases.map { ($0, $0.displayName) }
    static let framings = StabilizationSettings.Framing.allCases.map { ($0, $0.displayName) }
}

private struct AnalysisProgress: View {
    @ObservedObject var job: StabilizationJob

    var body: some View {
        HStack(spacing: 6) {
            Text("Analysing…").foregroundStyle(Theme.textSecondary)
            ProgressView(value: job.progress).progressViewStyle(.linear).frame(width: 110)
            Text("\(job.framesDone)/\(job.frameCount)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            Button("Cancel") { job.cancel() }.controlSize(.small)
        }
    }
}
