import SwiftUI
import SWCore
import SWPlayback

/// Timeline panel: sequence picker and tools on top, the AppKit timeline canvas below.
struct TimelinePanel: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var timeline: TimelineState

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        self.timeline = workspace.timeline
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TimelineCanvasView(workspace: workspace)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(workspace.project.sequences) { sequence in
                    Button(sequence.name) { workspace.openSequence(sequence.id) }
                }
                if !workspace.project.sequences.isEmpty { Divider() }
                Button("New Sequence…") { workspace.requestNewSequence() }
            } label: {
                Text(workspace.activeSequence?.name ?? "No Sequence")
                    .font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.button)
            .fixedSize()
            if let sequence = workspace.activeSequence {
                Text(sequence.settings.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Button { workspace.requestSequenceSettings() } label: { Image(systemName: "gearshape") }
                    .help("Sequence Settings")
            }
            Spacer()
            Toggle(isOn: $timeline.isSnapping) { Image(systemName: "arrow.left.and.line.vertical.and.arrow.right") }
                .toggleStyle(.button)
                .help("Snap in Timeline (S)")
            Menu {
                Toggle("Show Video Keyframes", isOn: $timeline.showsVideoKeyframes)
                Toggle("Show Audio Keyframes", isOn: $timeline.showsAudioKeyframes)
            } label: {
                Image(systemName: "wrench.adjustable")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Timeline Display Settings: keyframes and the Opacity/Volume line on clips")
            Button { zoom(1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom Out (-)")
            Button { zoom(1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom In (=)")
            Button {
                timeline.zoomToFit(durationFrames: workspace.activeSequence?.durationFrames ?? 0,
                                   laneWidth: TimelineLayout.lastLaneWidth)
            } label: { Image(systemName: "arrow.left.and.right.square") }
                .help("Zoom to Sequence (\\)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Theme.panelHeader.opacity(0.6))
    }

    private func zoom(_ factor: CGFloat) {
        let anchor = TimelineLayout.headerWidth + CGFloat(workspace.program.currentFrame) * timeline.pixelsPerFrame
            - timeline.scrollX
        timeline.zoom(by: factor, anchorX: anchor, headerWidth: TimelineLayout.headerWidth)
    }
}

struct TimelineCanvasView: NSViewRepresentable {
    let workspace: WorkspaceController

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimelineCanvas, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 200))
    }

    func makeNSView(context: Context) -> TimelineCanvas {
        TimelineCanvas(workspace: workspace)
    }

    func updateNSView(_ view: TimelineCanvas, context: Context) {
        view.needsDisplay = true
    }
}
