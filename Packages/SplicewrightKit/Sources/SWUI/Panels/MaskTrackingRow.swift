import SwiftUI
import SWCore

/// Track Mask: buttons to track backward or forward (all the way, or one frame), the tracking
/// options, and while it runs, its progress and a Stop button.
struct MaskTrackingRow: View {
    @ObservedObject var workspace: WorkspaceController
    let selection: MaskSelection

    private var settings: TrackingSettings { workspace.trackingSettings(selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Spacer().frame(width: 34)
                Text("Track Mask").lineLimit(1).frame(width: 82, alignment: .leading)
                if let job = workspace.trackingJob, job.selection == selection {
                    TrackingProgress(job: job)
                } else {
                    buttons
                    optionsMenu
                    Text("\(settings.method.displayName) · \(settings.effectiveMotion.displayName)")
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .frame(height: 24)
            if let message = workspace.trackingMessage, message.selection == selection {
                Label(message.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.leading, 34)
                    .padding(.bottom, 4)
            }
        }
    }

    private var buttons: some View {
        let busy = workspace.trackingJob != nil
        return HStack(spacing: 4) {
            Button { workspace.trackMask(selection, forward: false, oneFrame: false) } label: {
                Image(systemName: "backward.fill")
            }
            .help("Track backward to the start of the clip")
            Button { workspace.trackMask(selection, forward: false, oneFrame: true) } label: {
                Image(systemName: "backward.frame.fill")
            }
            .help("Track back one frame")
            Button { workspace.trackMask(selection, forward: true, oneFrame: true) } label: {
                Image(systemName: "forward.frame.fill")
            }
            .help("Track forward one frame")
            Button { workspace.trackMask(selection, forward: true, oneFrame: false) } label: {
                Image(systemName: "forward.fill")
            }
            .help("Track forward to the end of the clip. Each frame gets a Mask Path keyframe.")
        }
        .font(.system(size: 10))
        .disabled(busy)
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Method", selection: binding(\.method)) {
                ForEach(TrackingSettings.Method.allCases, id: \.self) { method in
                    Text(method.displayName).tag(method).help(method.help)
                }
            }
            Picker("Motion", selection: binding(\.motion)) {
                ForEach(TrackingSettings.Motion.allCases, id: \.self) { motion in
                    Text(motion.displayName).tag(motion)
                }
            }
            if settings.method == .color, settings.motion != settings.effectiveMotion {
                Text("Color follows position, scale and rotation only")
            }
            Divider()
            Picker("Search Range", selection: binding(\.searchRange)) {
                ForEach(TrackingSettings.SearchRange.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Quality", selection: binding(\.quality)) {
                ForEach(TrackingSettings.Quality.allCases, id: \.self) { quality in
                    Text("\(quality.displayName) (\(quality.analysisSize) px)").tag(quality)
                }
            }
            Picker("Compare With", selection: binding(\.reference)) {
                ForEach(TrackingSettings.Reference.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Stop When the Object Is Lost", isOn: binding(\.stopsWhenLost))
            Divider()
            Button("Reset Tracking Options") { workspace.setTrackingSettings(TrackingSettings(), of: selection) }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Tracking options: what to follow (Points, Texture, Color), how the mask may move (position, scale, "
              + "rotation, skew, perspective), how far, how precisely, and what each frame is compared with")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<TrackingSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in
            var updated = settings
            updated[keyPath: keyPath] = value
            workspace.setTrackingSettings(updated, of: selection)
        })
    }
}

/// A running track's progress, how sure it is, and Stop.
private struct TrackingProgress: View {
    @ObservedObject var job: MaskTrackingJob

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
                .frame(width: 90)
            Text("\(job.framesDone)/\(job.frameCount)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            Circle()
                .fill(job.confidence > 0.6 ? Color.green : job.confidence > 0.35 ? Color.yellow : Color.orange)
                .frame(width: 7, height: 7)
                .help("How sure the tracker is on the last frame")
            Button("Stop") { job.cancel() }
                .controlSize(.small)
        }
    }
}
