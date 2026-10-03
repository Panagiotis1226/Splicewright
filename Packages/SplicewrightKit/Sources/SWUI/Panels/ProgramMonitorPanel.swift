import SwiftUI
import SWCore
import SWPlayback

/// Premiere's Program monitor: plays the active sequence through the Metal compositor.
struct ProgramMonitorPanel: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject private var keys = KeyBindingsStore.shared
    @ObservedObject private var appearance = MonitorAppearance.shared

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        self.engine = workspace.program
    }

    private var rate: FrameRate { workspace.activeSequence?.rate ?? .fps30 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                appearance.background.swiftUI
                if workspace.activeSequence == nil {
                    Text("No sequence").font(.system(size: 11))
                        .foregroundStyle(appearance.background.contrasting.swiftUI.opacity(0.6))
                } else {
                    // The player fills exactly the sequence frame, so the background shows
                    // around it at any frame size or aspect ratio (vertical included).
                    GeometryReader { geometry in
                        let rect = fittedRect(geometry.size)
                        PlayerSurface(player: engine.player)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        if appearance.outlinesFrame {
                            Rectangle()
                                .stroke(appearance.background.contrasting.swiftUI.opacity(0.55), lineWidth: 1)
                                .frame(width: rect.width + 2, height: rect.height + 2)
                                .position(x: rect.midX, y: rect.midY)
                                .allowsHitTesting(false)
                        }
                    }
                    if workspace.showsSafeMargins || workspace.activeTool == .type {
                        GeometryReader { geometry in
                            frameOverlay(in: fittedRect(geometry.size))
                        }
                    }
                    if workspace.activeTool == .pen {
                        // The Tools panel's Pen draws a shape on the clip to track and attach things to.
                        if let clip = workspace.footageClip(at: engine.currentFrame) {
                            GeometryReader { geometry in
                                MaskHandles(workspace: workspace, clip: clip, pictureRect: fittedRect(geometry.size),
                                            drawsWithPenTool: true)
                            }
                        }
                    } else if workspace.activeTool == .selection, let selected = maskTarget {
                        // A selected mask (or the Pen drawing one) takes over from the transform box.
                        GeometryReader { geometry in
                            MaskHandles(workspace: workspace, clip: selected, pictureRect: fittedRect(geometry.size))
                        }
                    } else if workspace.activeTool == .selection, let selected = transformTarget {
                        GeometryReader { geometry in
                            TransformHandles(workspace: workspace, clip: selected, pictureRect: fittedRect(geometry.size))
                            if let crop = selected.effects.first(where: { $0.kind == .crop && $0.isEnabled }) {
                                CropHandles(workspace: workspace, clip: selected, crop: crop,
                                            pictureRect: fittedRect(geometry.size))
                            }
                        }
                    }
                    if engine.isBuilding {
                        ProgressView().controlSize(.small).padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu { backgroundMenu }
            timecodeBar
            ProgramScrubBar(workspace: workspace, engine: engine)
                .frame(height: 16)
                .padding(.horizontal, 8)
            transport
        }
    }

    private var timecodeBar: some View {
        HStack {
            Text(Timecode(frame: engine.currentFrame, rate: rate).description)
                .font(Theme.timecodeFont)
                .foregroundStyle(Theme.timecode)
            Spacer()
            Toggle(isOn: $workspace.useProxies) { Image(systemName: "p.square") }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(keys.hint("Toggle Proxies", .toggleProxies)
                      + ": play proxies where clips have them (export always uses originals)")
            Button { workspace.isMonitorBackgroundPickerShown.toggle() } label: {
                Image(systemName: "square.fill")
                    .foregroundStyle(appearance.background.swiftUI)
                    .overlay(Image(systemName: "square").foregroundStyle(Theme.textSecondary))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Monitor background: the color around the video frame (not exported)")
            .popover(isPresented: $workspace.isMonitorBackgroundPickerShown, arrowEdge: .bottom) {
                MonitorBackgroundPicker()
            }
            Toggle(isOn: $workspace.showsSafeMargins) { Image(systemName: "rectangle.dashed") }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Safe margins: action safe (90%) and title safe (80%)")
            Toggle(isOn: $engine.showsClipping) { Image(systemName: "exclamationmark.triangle") }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Show clipping: magenta above SDR white or 1000 nits, blue below black or out of gamut")
            Picker("Playback Resolution", selection: $engine.renderScale) {
                Text("Full").tag(1.0)
                Text("1/2").tag(0.5)
                Text("1/4").tag(0.25)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help("Playback Resolution")
            if engine.droppedFrames > 0 {
                Text("\(engine.droppedFrames) dropped")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
                    .help("Frames dropped during playback")
            }
            Spacer()
            Text(Timecode(frame: engine.durationFrames, rate: rate).description)
                .font(Theme.timecodeFont)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    /// Right-click on the monitor: background presets and the full picker.
    @ViewBuilder private var backgroundMenu: some View {
        Menu("Background") {
            ForEach(MonitorColor.presets) { preset in
                Button(preset.name) { appearance.background = preset.color }
            }
            Divider()
            Button("Choose Any Color…") { workspace.isMonitorBackgroundPickerShown = true }
        }
        Toggle("Outline the Frame", isOn: $appearance.outlinesFrame)
    }

    /// The selected video clip, if it's on screen at the playhead (for the transform box).
    private var transformTarget: Clip? {
        // Adjustment layers have nothing to move (Premiere ignores their Motion).
        guard let selected = workspace.effectControlsClip, selected.isVideo, !selected.clip.isAdjustment,
              selected.clip.range.contains(engine.currentFrame) else { return nil }
        return selected.clip
    }

    /// The selected video clip (adjustment layers included) when one of its masks is selected
    /// or the Pen is drawing one, if it's on screen at the playhead.
    private var maskTarget: Clip? {
        guard let selected = workspace.effectControlsClip, selected.isVideo,
              selected.clip.range.contains(engine.currentFrame) else { return nil }
        let clip = selected.clip
        if workspace.maskPen?.clipID == clip.id { return clip }
        guard let mask = workspace.selectedMask, mask.target.clipID == clip.id,
              clip.masks(of: mask.target.owner).contains(where: { $0.id == mask.maskID }) else { return nil }
        return clip
    }

    /// Where the picture sits inside the monitor (aspect fit).
    private func fittedRect(_ size: CGSize) -> CGRect {
        guard let settings = workspace.activeSequence?.settings, settings.width > 0, settings.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / CGFloat(settings.width), size.height / CGFloat(settings.height))
        let width = CGFloat(settings.width) * scale
        let height = CGFloat(settings.height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    @ViewBuilder
    private func frameOverlay(in rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            // The marker under the playhead, as Premiere shows it.
            if let marker = workspace.activeSequence?.markers(at: engine.currentFrame).first {
                HStack(spacing: 4) {
                    Circle().fill(marker.color.swatch).frame(width: 8, height: 8)
                    Text(marker.title).font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .position(x: rect.minX + 70, y: rect.minY + 14)
                .allowsHitTesting(false)
            }
            if workspace.showsSafeMargins {
                ForEach([0.9, 0.8], id: \.self) { fraction in
                    Rectangle()
                        .stroke(Color.white.opacity(0.55), lineWidth: 1)
                        .frame(width: rect.width * fraction, height: rect.height * fraction)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            if workspace.activeTool == .type {
                // Type tool: click to place a new title there, or to move the selected one.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .onTapGesture(coordinateSpace: .local) { location in
                        let point = CGPoint(x: min(max(location.x / max(rect.width, 1), 0), 1),
                                            y: min(max(location.y / max(rect.height, 1), 0), 1))
                        placeTitle(at: point)
                    }
                    .help("Type tool: click to add a title, or to move the selected title")
            }
        }
        .allowsHitTesting(workspace.activeTool == .type)
    }

    private func placeTitle(at point: CGPoint) {
        if let title = workspace.selectedTitleClip {
            workspace.updateTitle(title.id, "Move Title") { spec in
                spec.positionX = Double(point.x)
                spec.positionY = Double(point.y)
            }
        } else {
            workspace.newTitle(at: point)
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            button(keys.hint("Mark In", .markIn), text: "{", .markIn)
            button(keys.hint("Mark Out", .markOut), text: "}", .markOut)
            button(keys.hint("Go to Previous Edit", .previousEditPoint), symbol: "arrow.left.to.line", .previousEditPoint)
            button(keys.hint("Step Back 1 Frame", .stepBackward1), symbol: "backward.frame.fill", .stepBackward(frames: 1))
            button(engine.isPlaying ? keys.hint("Stop", .togglePlay) : keys.hint("Play", .togglePlay),
                   symbol: engine.isPlaying ? "pause.fill" : "play.fill", .togglePlay)
            button(keys.hint("Step Forward 1 Frame", .stepForward1), symbol: "forward.frame.fill", .stepForward(frames: 1))
            button(keys.hint("Go to Next Edit", .nextEditPoint), symbol: "arrow.right.to.line", .nextEditPoint)
            Divider().frame(height: 14)
            Button { workspace.liftOrExtract(extract: false) } label: { Image(systemName: "square.and.arrow.up") }
                .help(keys.hint("Lift", .liftEdit))
            Button { workspace.liftOrExtract(extract: true) } label: { Image(systemName: "rectangle.compress.vertical") }
                .help(keys.hint("Extract", .extractEdit))
            Divider().frame(height: 14)
            Button { workspace.requestExport() } label: { Image(systemName: "square.and.arrow.up.on.square") }
                .help(keys.hint("Export Media…", .exportMedia))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
        .foregroundStyle(Theme.textPrimary)
        .disabled(workspace.activeSequence == nil)
        .frame(height: 34)
    }

    private func button(_ help: String, symbol: String? = nil, text: String? = nil,
                        _ action: ShortcutAction) -> some View {
        Button {
            workspace.activePanel = .program
            workspace.handle(action)
        } label: {
            if let symbol {
                Image(systemName: symbol)
            } else {
                Text(text ?? "").font(.system(size: 15, weight: .semibold, design: .monospaced))
            }
        }
        .help(help)
    }
}

/// Mini ruler under the Program monitor showing the playhead and In/Out range.
struct ProgramScrubBar: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var engine: PlaybackEngine

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let total = CGFloat(max(engine.durationFrames, 1))
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.09))
                if let range = workspace.activeSequence?.marks.range {
                    Rectangle()
                        .fill(Theme.markedRange)
                        .frame(width: max(1, CGFloat(range.length) / total * width))
                        .offset(x: CGFloat(range.start) / total * width)
                }
                Rectangle()
                    .fill(Theme.playhead)
                    .frame(width: 1.5)
                    .offset(x: min(1, CGFloat(engine.currentFrame) / total) * width)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        engine.pause()
                        engine.scrub(toFrame: Int64(max(0, value.location.x) / width * total))
                    }
                    .onEnded { value in
                        engine.seek(toFrame: Int64(max(0, value.location.x) / width * total))
                    }
            )
        }
        .disabled(workspace.activeSequence == nil)
    }
}

/// Stereo peak meters driven by the playback engine.
struct AudioMetersPanel: View {
    @ObservedObject var engine: PlaybackEngine
    private let marks = [0, -6, -12, -18, -24, -30, -36, -42, -48, -54]

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            ForEach(0..<2, id: \.self) { channel in
                GeometryReader { geometry in
                    let level = channel < engine.meterLevels.count ? engine.meterLevels[channel] : 0
                    let fraction = Self.fraction(forLevel: level)
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(Color(white: 0.08))
                        Rectangle()
                            .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .bottom,
                                                 endPoint: .top))
                            .frame(height: geometry.size.height * fraction)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .frame(width: 8)
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

    /// Maps a linear peak to meter height on a -60…0 dB scale.
    static func fraction(forLevel level: Float) -> CGFloat {
        guard level > 0 else { return 0 }
        let dB = 20 * log10(Double(level))
        return CGFloat(min(max((dB + 60) / 60, 0), 1))
    }
}
