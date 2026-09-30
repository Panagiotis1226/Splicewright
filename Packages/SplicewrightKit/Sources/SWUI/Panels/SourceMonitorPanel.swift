import AVKit
import SwiftUI
import SWCore

/// Premiere's Source monitor: view a clip, scrub, and set In/Out marks.
struct SourceMonitorPanel: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var monitor: SourceMonitorModel

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        self.monitor = workspace.sourceMonitor
    }

    private var marks: SourceMarks { workspace.sourceItem?.marks ?? .empty }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if monitor.mediaID == nil {
                    Text("Double-click a clip in the Project panel to view it here.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                } else if monitor.hasVideo {
                    PlayerSurface(player: monitor.player)
                } else if let peaks = monitor.waveform {
                    WaveformView(peaks: peaks, duration: monitor.duration.seconds)
                        .padding(.vertical, 24)
                } else {
                    Image(systemName: "waveform").font(.system(size: 32)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            timecodeBar
            ScrubBar(monitor: monitor, marks: marks)
                .frame(height: monitor.waveform == nil ? 22 : 40)
                .padding(.horizontal, 8)
            transport
        }
    }

    private var timecodeBar: some View {
        let rate = monitor.frameRate
        let range = marks.range(duration: monitor.duration, rate: rate)
        return HStack {
            Text(Timecode(time: monitor.currentTime, rate: rate).description)
                .font(Theme.timecodeFont)
                .foregroundStyle(Theme.timecode)
                .help("Playhead position")
            Spacer()
            Text(monitor.mediaName)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
            Text(Timecode(frame: range.duration.frameIndex(at: rate), rate: rate).description)
                .font(Theme.timecodeFont)
                .foregroundStyle(Theme.textPrimary)
                .help("Duration between In and Out")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private var transport: some View {
        HStack(spacing: 14) {
            transportButton("Mark In (I)", text: "{") { workspace.handle(.markIn) }
            transportButton("Mark Out (O)", text: "}") { workspace.handle(.markOut) }
            transportButton("Go to In (⇧I)", systemImage: "arrow.left.to.line") { workspace.handle(.goToIn) }
            transportButton("Step Back 1 Frame (←)", systemImage: "backward.frame.fill") {
                workspace.handle(.stepBackward(frames: 1))
            }
            transportButton(monitor.isPlaying ? "Stop (Space)" : "Play (Space)",
                            systemImage: monitor.isPlaying ? "pause.fill" : "play.fill") {
                workspace.handle(.togglePlay)
            }
            transportButton("Step Forward 1 Frame (→)", systemImage: "forward.frame.fill") {
                workspace.handle(.stepForward(frames: 1))
            }
            transportButton("Go to Out (⇧O)", systemImage: "arrow.right.to.line") { workspace.handle(.goToOut) }
            transportButton("Clear In and Out (⌥X)", systemImage: "xmark.circle") { workspace.handle(.clearInAndOut) }
            Divider().frame(height: 14)
            transportButton("Insert (,)", systemImage: "arrow.down.to.line.compact") {
                workspace.editFromSource(overwrite: false)
            }
            transportButton("Overwrite (.)", systemImage: "square.and.arrow.down.on.square") {
                workspace.editFromSource(overwrite: true)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.textPrimary)
        .disabled(monitor.mediaID == nil)
        .frame(height: 34)
    }

    private func transportButton(_ help: String, systemImage: String? = nil, text: String? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button {
            workspace.activePanel = .source
            action()
        } label: {
            if let systemImage {
                Image(systemName: systemImage)
            } else {
                Text(text ?? "").font(.system(size: 15, weight: .semibold, design: .monospaced))
            }
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Hosts `AVPlayerView` without its built-in controls; HDR presentation comes from AVKit.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFrameSteppingButtons = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// The monitor's time ruler: marked range, optional waveform, and a draggable playhead.
struct ScrubBar: View {
    @ObservedObject var monitor: SourceMonitorModel
    let marks: SourceMarks

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let duration = max(monitor.duration.seconds, 0.001)
            let frameSeconds = monitor.frameRate.frameDuration.seconds
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.09))
                if let peaks = monitor.waveform {
                    WaveformView(peaks: peaks, duration: duration, color: Theme.waveform.opacity(0.6))
                        .padding(.vertical, 3)
                }
                if marks.inPoint != nil || marks.outPoint != nil {
                    let start = (marks.inPoint?.seconds ?? 0) / duration
                    let end = min(1, ((marks.outPoint?.seconds).map { $0 + frameSeconds } ?? duration) / duration)
                    Rectangle()
                        .fill(Theme.markedRange)
                        .frame(width: max(1, (end - start) * width))
                        .offset(x: start * width)
                }
                let playheadX = min(1, monitor.currentTime.seconds / duration) * width
                Rectangle()
                    .fill(Theme.playhead)
                    .frame(width: 1.5)
                    .offset(x: playheadX)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.playhead)
                    .offset(x: playheadX - 4.5, y: -geometry.size.height / 2 + 5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if value.translation == .zero { monitor.beginScrub() }
                        monitor.scrub(toFraction: value.location.x / width, final: false)
                    }
                    .onEnded { value in
                        monitor.scrub(toFraction: value.location.x / width, final: true)
                    }
            )
        }
        .clipped()
        .disabled(monitor.mediaID == nil)
    }
}
