import AppKit
import SwiftUI
import SWCore
import SWPlayback

/// Effect Controls for a clip, laid out like Premiere's: properties on the left with a
/// stopwatch, values you can drag or type, keyframe navigation and reset; a keyframe lane on
/// the right spanning the clip, with the playhead.
struct MotionControls: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var engine: PlaybackEngine
    let clip: Clip
    let isVideo: Bool
    @State private var selectedKeyframes: Set<UUID> = []

    init(workspace: WorkspaceController, clip: Clip, isVideo: Bool) {
        self.workspace = workspace
        engine = workspace.program
        self.clip = clip
        self.isVideo = isVideo
    }

    private var sequence: EditSequence? { workspace.activeSequence }
    private var rate: FrameRate { sequence?.rate ?? .fps30 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isVideo {
                        sectionTitle("Motion")
                        row(.position)
                        row(.scale)
                        row(.scaleWidth, disabled: clip.motion.uniformScale)
                        uniformScaleRow
                        row(.rotation)
                        row(.anchorPoint)
                        sectionTitle("Opacity")
                        row(.opacity)
                        if !clip.isTitle {
                            sectionTitle(clip.speed.isAnimated ? "Time Remapping" : "Speed")
                            row(.speed)
                            speedNote
                        }
                    } else {
                        sectionTitle("Volume")
                        row(.volume)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textPrimary)
        .onDeleteCommand { deleteSelected() }
    }

    private var header: some View {
        HStack {
            Text(clip.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Spacer()
            Button { workspace.goToKeyframe(next: false, nil, of: clip) } label: { Image(systemName: "chevron.left") }
                .help("Previous keyframe")
            Button { workspace.goToKeyframe(next: true, nil, of: clip) } label: { Image(systemName: "chevron.right") }
                .help("Next keyframe")
            Text(Timecode(frame: engine.currentFrame, rate: rate).description)
                .font(Theme.smallTimecodeFont)
                .foregroundStyle(Theme.timecode)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 24)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    /// What the Speed row does, which differs from Premiere's other properties.
    private var speedNote: some View {
        Text(clip.speed.isAnimated
             ? "Speed keyframes ramp the playback; 0% holds a frame. The clip keeps its length."
             : clip.isReversed ? "Reversed. Change the speed here or with Clip ▸ Speed/Duration (⌘R)."
             : "Changes the clip's length. Click the stopwatch to ramp the speed with keyframes.")
            .font(.system(size: 10))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 34)
            .padding(.bottom, 4)
    }

    private var uniformScaleRow: some View {
        HStack {
            Spacer().frame(width: 26)
            Toggle("Uniform Scale", isOn: Binding(get: { clip.motion.uniformScale },
                                                  set: { workspace.setUniformScale($0, of: clip.id) }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    // MARK: - Property rows

    private func row(_ property: ClipProperty, disabled: Bool = false) -> some View {
        let animated = clip.property(property)
        let time = workspace.keyframeTime(in: clip, for: property)
        let values = animated.value(at: time)
        let onKeyframe = animated.keyframe(at: time, tolerance: rate.frameDuration) != nil
        return HStack(spacing: 6) {
            Button { workspace.setAnimated(!animated.isAnimated, property, of: clip) } label: {
                Image(systemName: "stopwatch")
                    .foregroundStyle(animated.isAnimated ? Theme.accent : Theme.textSecondary)
            }
            .buttonStyle(.borderless)
            .help(animated.isAnimated ? "Turn off animation (removes keyframes)" : "Animate \(property.displayName)")
            Text(property.displayName).frame(width: 82, alignment: .leading)
            ForEach(values.indices, id: \.self) { index in
                ScrubbableNumber(label: property.components[index], value: display(values[index], property, index),
                                 step: property.dragStep, unit: property.unit) { newValue, live in
                    var updated = values
                    updated[index] = stored(newValue, property, index)
                    workspace.setProperty(property, of: clip.id, to: updated, live: live)
                } onEnd: {
                    workspace.endLiveEdit(property.displayName)
                }
            }
            Spacer(minLength: 4)
            if animated.isAnimated {
                Button { workspace.goToKeyframe(next: false, property, of: clip) } label: {
                    Image(systemName: "arrowtriangle.left.fill").font(.system(size: 7))
                }
                .help("Previous keyframe")
                Button { workspace.toggleKeyframe(property, of: clip) } label: {
                    Image(systemName: onKeyframe ? "diamond.fill" : "diamond").font(.system(size: 9))
                        .foregroundStyle(onKeyframe ? Theme.accent : Theme.textPrimary)
                }
                .help(onKeyframe ? "Remove keyframe" : "Add keyframe")
                Button { workspace.goToKeyframe(next: true, property, of: clip) } label: {
                    Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7))
                }
                .help("Next keyframe")
            }
            Button { workspace.resetProperty(property, of: clip.id) } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 9))
            }
            .help("Reset \(property.displayName)")
            KeyframeLane(workspace: workspace, engine: engine, clip: clip, property: property,
                         selection: $selectedKeyframes)
                .frame(minWidth: 120, maxWidth: .infinity)
                .frame(height: 20)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
    }

    /// Effect Controls shows Position and Anchor Point as frame coordinates (0,0 is the top left).
    private func display(_ value: Double, _ property: ClipProperty, _ index: Int) -> Double {
        guard property == .position || property == .anchorPoint, let settings = sequence?.settings else { return value }
        return value + Double(index == 0 ? settings.width : settings.height) / 2
    }

    private func stored(_ value: Double, _ property: ClipProperty, _ index: Int) -> Double {
        guard property == .position || property == .anchorPoint, let settings = sequence?.settings else { return value }
        return value - Double(index == 0 ? settings.width : settings.height) / 2
    }

    private func deleteSelected() {
        for property in ClipProperty.allCases {
            let ids = Set(clip.property(property).keyframes.map(\.id)).intersection(selectedKeyframes)
            if !ids.isEmpty { workspace.deleteKeyframes(ids, property, of: clip.id) }
        }
        selectedKeyframes = []
    }
}

/// A number you change by dragging left/right (⇧ for ×10, ⌥ for ×0.1) or by clicking and typing.
struct ScrubbableNumber: View {
    let label: String
    let value: Double
    let step: Double
    let unit: String
    /// Called with the new value; `live` is true while dragging.
    let onChange: (Double, Bool) -> Void
    let onEnd: () -> Void
    @State private var dragStart: Double?
    @State private var isEditing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            if !label.isEmpty { Text(label).foregroundStyle(Theme.textSecondary) }
            if isEditing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .frame(width: 54)
                    .focused($focused)
                    .onSubmit(commitText)
                    .onChange(of: focused) { _, now in if !now { commitText() } }
            } else {
                Text(Self.format(value))
                    .monospacedDigit()
                    .foregroundStyle(Theme.timecode)
                    .frame(minWidth: 40, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { drag in
                            let start = dragStart ?? value
                            dragStart = start
                            let flags = NSEvent.modifierFlags
                            let factor = flags.contains(.shift) ? 10 : flags.contains(.option) ? 0.1 : 1
                            onChange(start + Double(drag.translation.width) * step * factor, true)
                        }
                        .onEnded { _ in
                            dragStart = nil
                            onEnd()
                        })
                    .onTapGesture {
                        text = Self.format(value)
                        isEditing = true
                        focused = true
                    }
            }
            if !unit.isEmpty && unit != "px" { Text(unit).foregroundStyle(Theme.textSecondary) }
        }
        .help("Drag to change (⇧ faster, ⌥ finer) or click to type")
    }

    private func commitText() {
        guard isEditing else { return }
        isEditing = false
        if let number = Double(text.replacingOccurrences(of: ",", with: ".")) {
            onChange(number, false)
        }
    }

    static func format(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.05 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }
}

/// The keyframes of one property across the clip, with the playhead. Click a diamond to select
/// it (⇧ to add), drag to move it, right-click for interpolation; click the lane to move the playhead.
struct KeyframeLane: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var engine: PlaybackEngine
    let clip: Clip
    let property: ClipProperty
    @Binding var selection: Set<UUID>
    /// The keyframe being dragged and where it started (live edits move it under the drag).
    @State private var dragging: (id: UUID, startFrame: Int64)?

    private var rate: FrameRate { workspace.activeSequence?.rate ?? .fps30 }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(white: 0.1))
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        engine.seek(toFrame: frame(atX: location.x, width: width))
                    }
                Rectangle().fill(Theme.playhead)
                    .frame(width: 1)
                    .offset(x: x(for: engine.currentFrame, width: width))
                    .allowsHitTesting(false)
                ForEach(clip.property(property).keyframes) { keyframe in
                    diamond(keyframe, width: width)
                }
            }
        }
        .clipped()
    }

    private func x(for frame: Int64, width: CGFloat) -> CGFloat {
        CGFloat(frame - clip.start) / CGFloat(max(clip.duration, 1)) * width
    }

    private func frame(atX x: CGFloat, width: CGFloat) -> Int64 {
        clip.start + Int64((x / width * CGFloat(clip.duration)).rounded())
    }

    private func diamond(_ keyframe: Keyframe, width: CGFloat) -> some View {
        let frame = clip.sequenceFrame(ofKeyframeTime: keyframe.time, for: property, rate: rate)
        let selected = selection.contains(keyframe.id)
        return Image(systemName: keyframe.interpolation == .hold ? "square.fill"
                     : keyframe.interpolation == .linear ? "diamond.fill" : "circle.fill")
            .font(.system(size: 9))
            .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
            .frame(width: 14, height: 18)
            .contentShape(Rectangle())
            .offset(x: x(for: frame, width: width) - 7)
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    selection = [keyframe.id]
                    if dragging?.id != keyframe.id { dragging = (keyframe.id, frame) }
                    let start = dragging?.startFrame ?? frame
                    let target = self.frame(atX: x(for: start, width: width) + drag.translation.width, width: width)
                    workspace.moveKeyframe(keyframe.id, property, of: clip.id, toFrame: target, live: true)
                }
                .onEnded { _ in
                    dragging = nil
                    workspace.endLiveEdit("Move Keyframe")
                })
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.shift) {
                    selection.formSymmetricDifference([keyframe.id])
                } else {
                    selection = [keyframe.id]
                    engine.seek(toFrame: frame)
                }
            }
            .contextMenu {
                let ids = selection.contains(keyframe.id) ? selection : [keyframe.id]
                ForEach(KeyframeInterpolation.allCases, id: \.self) { interpolation in
                    Button(interpolation.displayName) {
                        workspace.setInterpolation(interpolation, ids: ids, property, of: clip.id)
                    }
                }
                Divider()
                Button("Delete") { workspace.deleteKeyframes(ids, property, of: clip.id) }
            }
            .help("\(keyframe.interpolation.displayName) keyframe: drag to move, right-click for options")
    }
}
