import SwiftUI
import SWCore

/// Program monitor shell. Sequence playback (Metal compositor, EDR output) arrives in M3.
struct ProgramMonitorPanel: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                Text("No sequence")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack {
                Text("00:00:00:00").font(Theme.timecodeFont).foregroundStyle(Theme.timecode)
                Spacer()
                Text("Full").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("00:00:00:00").font(Theme.timecodeFont).foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            Rectangle().fill(Color(white: 0.09)).frame(height: 22).padding(.horizontal, 8)
            HStack(spacing: 14) {
                ForEach(["arrow.left.to.line", "backward.frame.fill", "play.fill", "forward.frame.fill",
                         "arrow.right.to.line"], id: \.self) { symbol in
                    Image(systemName: symbol)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .frame(height: 34)
        }
    }
}

/// Timeline shell showing the track layout. Editing arrives in M2.
struct TimelinePanel: View {
    private let videoTracks = ["V3", "V2", "V1"]
    private let audioTracks = ["A1", "A2", "A3"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("00:00:00:00")
                    .font(Theme.timecodeFont)
                    .foregroundStyle(Theme.timecode)
                    .frame(width: 150, alignment: .leading)
                    .padding(.leading, 8)
                TimeRuler()
            }
            .frame(height: 28)
            .background(Theme.panelHeader)
            ScrollView(.vertical) {
                VStack(spacing: 1) {
                    ForEach(videoTracks, id: \.self) { TrackRow(name: $0, isVideo: true) }
                    Rectangle().fill(Theme.divider).frame(height: 3)
                    ForEach(audioTracks, id: \.self) { TrackRow(name: $0, isVideo: false) }
                }
            }
            .overlay {
                Text("Create a sequence to start editing. Timeline editing comes in the next milestone.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct TrackRow: View {
    let name: String
    let isVideo: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.open").help("Toggle Track Lock")
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24)
                    .padding(.vertical, 2)
                    .background(isVideo ? Theme.videoTrack.opacity(0.5) : Theme.audioTrack.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 2))
                if isVideo {
                    Image(systemName: "eye").help("Toggle Track Output")
                } else {
                    Text("M").help("Mute Track")
                    Text("S").help("Solo Track")
                }
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(width: 158)
            .frame(maxHeight: .infinity)
            .background(Theme.panelHeader)
            Rectangle().fill(Color(white: 0.12))
        }
        .frame(height: isVideo ? 34 : 40)
    }
}

private struct TimeRuler: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 12
            var x: CGFloat = 0
            var index = 0
            while x < size.width {
                let tall = index % 10 == 0
                let rect = CGRect(x: x, y: size.height - (tall ? 10 : 5), width: 1, height: tall ? 10 : 5)
                context.fill(Path(rect), with: .color(Theme.textSecondary.opacity(0.6)))
                x += spacing
                index += 1
            }
        }
    }
}

/// Premiere's vertical Tools panel. Shortcuts switch tools even before the timeline exists.
struct ToolsPanel: View {
    @ObservedObject var workspace: WorkspaceController

    private let groups: [[EditTool]] = [
        [.selection, .trackSelectForward],
        [.rippleEdit, .rollingEdit, .rateStretch],
        [.razor],
        [.slip, .slide],
        [.pen],
        [.hand, .zoom],
        [.type],
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(groups.indices, id: \.self) { index in
                VStack(spacing: 2) {
                    ForEach(groups[index]) { tool in
                        Button { workspace.activeTool = tool } label: {
                            Image(systemName: symbol(for: tool))
                                .frame(width: 26, height: 24)
                                .background(workspace.activeTool == tool ? Theme.accent.opacity(0.6) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 3))
                        }
                        .buttonStyle(.plain)
                        .help("\(tool.displayName) (\(String(tool.shortcut).uppercased()))")
                    }
                }
            }
            Spacer()
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.textPrimary)
        .padding(.vertical, 8)
        .frame(width: 34)
        .background(Theme.panelBackground)
    }

    private func symbol(for tool: EditTool) -> String {
        switch tool {
        case .selection: return "cursorarrow"
        case .trackSelectForward: return "arrow.right.to.line.compact"
        case .rippleEdit: return "arrow.left.and.right.square"
        case .rollingEdit: return "arrow.left.arrow.right"
        case .rateStretch: return "timer"
        case .razor: return "scissors"
        case .slip: return "arrow.left.and.right"
        case .slide: return "rectangle.portrait.arrowtriangle.2.outward"
        case .pen: return "pencil.tip"
        case .hand: return "hand.raised"
        case .zoom: return "plus.magnifyingglass"
        case .type: return "textformat"
        }
    }
}

/// Stereo peak meters. They read live levels once the audio engine exists (M3).
struct AudioMetersPanel: View {
    private let marks = [0, -6, -12, -18, -24, -30, -36, -42, -48, -54]

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            ForEach(0..<2, id: \.self) { _ in
                Rectangle().fill(Color(white: 0.08)).frame(width: 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(marks, id: \.self) { mark in
                    Text("\(mark)").font(.system(size: 8)).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }
                Text("dB").font(.system(size: 8)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(6)
        .frame(width: 48)
        .background(Theme.panelBackground)
    }
}

/// Effects browser. Transitions and titles are implemented in M6.
struct EffectsPanel: View {
    var body: some View {
        List {
            Section("Video Transitions") {
                Label("Cross Dissolve", systemImage: "square.on.square")
                Label("Dip to Black", systemImage: "square.fill")
                Label("Dip to White", systemImage: "square")
                Label("Film Dissolve", systemImage: "square.on.square.dashed")
            }
            Section("Graphics") {
                Label("Title", systemImage: "textformat")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textSecondary)
        .scrollContentBackground(.hidden)
        .disabled(true)
        .overlay(alignment: .bottom) {
            Text("Available in a later milestone").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                .padding(8)
        }
    }
}

/// Effect Controls for the selected timeline clip (Motion, Opacity, …) — later milestones.
struct EffectControlsPanel: View {
    var body: some View {
        Text("(no clip selected)")
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
