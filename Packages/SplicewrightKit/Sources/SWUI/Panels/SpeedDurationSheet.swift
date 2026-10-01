import SwiftUI
import SWCore

/// Clip ▸ Speed/Duration… (⌘R), laid out like Premiere's: speed and duration are linked
/// (changing one changes the other), plus Reverse Speed, Maintain Audio Pitch and Ripple Edit.
struct SpeedDurationSheet: View {
    @ObservedObject var workspace: WorkspaceController
    let ids: Set<UUID>
    @State private var percent: Double = 100
    @State private var durationText = ""
    @State private var editingDuration = false
    @State private var reversed = false
    @State private var maintainsPitch = true
    @State private var ripple = false

    private var clips: [Clip] { ids.compactMap { workspace.activeSequence?.clip($0) } }
    private var rate: FrameRate { workspace.activeSequence?.rate ?? .fps30 }
    private var remapped: Bool { clips.contains { $0.speed.isAnimated } }
    /// The longest selected clip's source, for working out the duration a speed gives.
    private var span: Double { clips.map { $0.timing(rate: rate).sourceSpan }.max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clip Speed / Duration").font(.headline)
            if remapped {
                Label("A clip has Time Remapping keyframes. Turn off its Speed stopwatch in Effect Controls first.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                LabeledContent("Speed") {
                    HStack {
                        TextField("Speed", value: Binding(get: { percent }, set: { value in
                            percent = min(max(value, ClipTiming.constantSpeedRange.lowerBound),
                                          ClipTiming.constantSpeedRange.upperBound)
                            editingDuration = false
                            durationText = Timecode(frame: frames(for: percent), rate: rate).description
                        }), format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("%")
                        Picker("", selection: Binding(get: { percent }, set: { value in
                            percent = value
                            editingDuration = false
                            durationText = Timecode(frame: frames(for: value), rate: rate).description
                        })) {
                            ForEach([25.0, 50, 100, 200, 400], id: \.self) { Text("\(Int($0))%").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                    }
                }
                LabeledContent("Duration") {
                    TextField("00:00:00:00", text: $durationText)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.smallTimecodeFont)
                        .frame(width: 120)
                        .onSubmit(applyDurationText)
                }
                Toggle("Reverse Speed", isOn: $reversed)
                Toggle("Maintain Audio Pitch", isOn: $maintainsPitch)
                Toggle("Ripple Edit, Shifting Trailing Clips", isOn: $ripple)
            }
            Text(ids.count > 1 ? "Applies to \(clips.count) clips. Each keeps the part of its source it plays now."
                 : "The clip keeps the part of its source it plays now; its length follows the speed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { workspace.speedSheetClipIDs = nil }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    applyDurationText()
                    let duration = editingDuration ? Timecode(string: durationText, rate: rate)?.frameNumber(rate: rate) : nil
                    workspace.changeSpeed(ids, SpeedChange(percent: duration == nil ? percent : nil, duration: duration,
                                                           isReversed: reversed, maintainsPitch: maintainsPitch,
                                                           ripple: ripple))
                    workspace.speedSheetClipIDs = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(remapped)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: load)
    }

    private func frames(for percent: Double) -> Int64 {
        max(1, Int64((span * rate.framesPerSecond / (percent / 100)).rounded()))
    }

    private func load() {
        let first = clips.first
        percent = first?.speedPercent ?? 100
        reversed = first?.isReversed ?? false
        maintainsPitch = first?.maintainsPitch ?? true
        durationText = Timecode(frame: clips.map(\.duration).max() ?? 0, rate: rate).description
    }

    /// A typed duration sets the speed instead.
    private func applyDurationText() {
        guard let frames = Timecode(string: durationText, rate: rate)?.frameNumber(rate: rate), frames > 0 else { return }
        let current = Timecode(frame: self.frames(for: percent), rate: rate).description
        guard durationText != current else { return }
        editingDuration = true
        percent = min(max(span * rate.framesPerSecond / Double(frames) * 100, ClipTiming.constantSpeedRange.lowerBound),
                      ClipTiming.constantSpeedRange.upperBound)
    }
}
