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
    /// Properties showing their value graph under the row.
    @State private var graphs: Set<PropertyRef> = []

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
                    if clip.isAdjustment {
                        // Adjustment layers: their effects, blended in with Opacity.
                        sectionTitle("Opacity")
                        row(.opacity)
                        masks(.opacity)
                        effectSections
                    } else if isVideo {
                        sectionTitle("Motion")
                        row(.position)
                        row(.scale)
                        row(.scaleWidth, disabled: clip.motion.uniformScale)
                        uniformScaleRow
                        row(.rotation)
                        row(.anchorPoint)
                        sectionTitle("Opacity")
                        row(.opacity)
                        masks(.opacity)
                        if !clip.isGenerated {
                            sectionTitle(clip.speed.isAnimated ? "Time Remapping" : "Speed")
                            row(.speed)
                            speedNote
                        }
                        effectSections
                    } else {
                        sectionTitle("Volume")
                        row(.volume)
                        effectSections
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
        valueRow(.clip(property), title: property.displayName, components: property.components, unit: property.unit,
                 step: property.dragStep, disabled: disabled,
                 display: { display($0, property, $1) }, stored: { stored($0, property, $1) })
    }

    /// One keyframeable number (or pair): stopwatch, values, keyframe buttons, reset and lane.
    private func valueRow(_ ref: PropertyRef, title: String, components: [String], unit: String, step: Double,
                          disabled: Bool = false, display: @escaping (Double, Int) -> Double = { value, _ in value },
                          stored: @escaping (Double, Int) -> Double = { value, _ in value }) -> some View {
        let animated = clip.animatable(ref) ?? AnimatableProperty([0])
        let time = workspace.keyframeTime(in: clip, for: ref)
        let values = animated.value(at: time)
        let onKeyframe = animated.keyframe(at: time, tolerance: rate.frameDuration) != nil
        let showsGraph = graphs.contains(ref) && animated.isAnimated
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    if graphs.contains(ref) { graphs.remove(ref) } else { graphs.insert(ref) }
                } label: {
                    Image(systemName: showsGraph ? "chevron.down" : "chevron.right").font(.system(size: 8))
                }
                .disabled(!animated.isAnimated)
                .opacity(animated.isAnimated ? 1 : 0.25)
                .help(animated.isAnimated ? "Show the value graph to shape the curve between keyframes"
                                          : "Turn on the stopwatch to animate, then open the graph here")
                Button { workspace.setAnimated(!animated.isAnimated, ref, of: clip) } label: {
                    Image(systemName: "stopwatch")
                        .foregroundStyle(animated.isAnimated ? Theme.accent : Theme.textSecondary)
                }
                .buttonStyle(.borderless)
                .help(animated.isAnimated ? "Turn off animation (removes keyframes)" : "Animate \(title)")
                Text(title).lineLimit(1).frame(width: 82, alignment: .leading)
                ForEach(values.indices, id: \.self) { index in
                    ScrubbableNumber(label: index < components.count ? components[index] : "",
                                     value: display(values[index], index), step: step, unit: unit) { newValue, live in
                        var updated = values
                        updated[index] = stored(newValue, index)
                        workspace.setValue(ref, of: clip.id, to: updated, actionName: title, live: live)
                    } onEnd: {
                        workspace.endLiveEdit(title)
                    }
                }
                Spacer(minLength: 4)
                if animated.isAnimated {
                    Button { workspace.goToKeyframe(next: false, ref, of: clip) } label: {
                        Image(systemName: "arrowtriangle.left.fill").font(.system(size: 7))
                    }
                    .help("Previous keyframe")
                    Button { workspace.toggleKeyframe(ref, of: clip) } label: {
                        Image(systemName: onKeyframe ? "diamond.fill" : "diamond").font(.system(size: 9))
                            .foregroundStyle(onKeyframe ? Theme.accent : Theme.textPrimary)
                    }
                    .help(onKeyframe ? "Remove keyframe" : "Add keyframe")
                    Button { workspace.goToKeyframe(next: true, ref, of: clip) } label: {
                        Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7))
                    }
                    .help("Next keyframe")
                }
                Button { workspace.resetValue(ref, of: clip.id, actionName: "Reset \(title)") } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 9))
                }
                .help("Reset \(title)")
                KeyframeLane(workspace: workspace, engine: engine, clip: clip, property: ref, selection: $selectedKeyframes)
                    .frame(minWidth: 120, maxWidth: .infinity)
                    .frame(height: 20)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .frame(height: 24)
            if showsGraph {
                GraphEditor(workspace: workspace, engine: engine, clip: clip, property: ref, display: display, stored: stored,
                            selection: $selectedKeyframes)
                    .padding(.leading, 34)
                    .padding(.trailing, 8)
                    .padding(.bottom, 4)
            }
        }
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
    }

    /// The masks on Opacity or on an effect, with rows like the others.
    private func masks(_ owner: MaskOwner) -> some View {
        MaskControls(workspace: workspace, engine: engine, clip: clip, owner: owner,
                     selectedKeyframes: $selectedKeyframes) { ref, title, unit, step in
            valueRow(ref, title: title, components: [""], unit: unit, step: step)
        }
    }

    // MARK: - Effects

    @ViewBuilder private var effectSections: some View {
        ForEach(Array(clip.effects.enumerated()), id: \.element.id) { index, effect in
            effectHeader(effect, index: index)
            if effect.isEnabled {
                if effect.kind == .lut { LUTChooser(workspace: workspace, clipID: clip.id, effect: effect) }
                ForEach(effect.kind.parameters, id: \.key) { parameter in
                    valueRow(.effect(effect.id, parameter.key), title: parameter.displayName, components: [""],
                             unit: parameter.unit, step: parameter.dragStep)
                }
                if effect.kind == .colorCorrection { CurvesEditor(workspace: workspace, clipID: clip.id, effect: effect) }
                if effect.kind.supportsMasks { masks(.effect(effect.id)) }
            }
        }
        if clip.effects.isEmpty {
            Text("Drag \(isVideo ? "a video" : "an audio") effect onto the clip from the Effects panel, or double-click one "
                 + "to add it.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.top, 10)
        }
    }

    private func effectHeader(_ effect: ClipEffect, index: Int) -> some View {
        HStack(spacing: 6) {
            Button { workspace.updateEffect(effect.id, of: clip.id, effect.isEnabled ? "Disable Effect" : "Enable Effect") {
                $0.isEnabled.toggle()
            } } label: {
                Text("fx").font(.system(size: 10, weight: .bold, design: .serif))
                    .foregroundStyle(effect.isEnabled ? Theme.accent : Theme.textSecondary)
                    .strikethrough(!effect.isEnabled)
            }
            .help(effect.isEnabled ? "Turn the effect off" : "Turn the effect on")
            Text(effect.kind.displayName).font(.system(size: 10, weight: .semibold))
            Spacer()
            Button { workspace.moveEffect(effect.id, of: clip.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("Move up (applied earlier)")
            Button { workspace.moveEffect(effect.id, of: clip.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == clip.effects.count - 1)
                .help("Move down")
            Button { workspace.resetEffect(effect.id, of: clip.id) } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 9))
            }
            .help("Reset \(effect.kind.displayName)")
            Button { workspace.removeEffect(effect.id, from: clip.id) } label: { Image(systemName: "trash") }
                .help("Remove \(effect.kind.displayName)")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(height: 24)
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
        for ref in workspace.allRefs(of: clip) {
            let ids = Set((clip.animatable(ref)?.keyframes ?? []).map(\.id)).intersection(selectedKeyframes)
            if !ids.isEmpty { workspace.deleteKeyframes(ids, ref, of: clip.id) }
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
    let property: PropertyRef
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
                ForEach(clip.animatable(property)?.keyframes ?? []) { keyframe in
                    diamond(keyframe, width: width)
                }
            }
        }
        .clipped()
    }

    /// Premiere-like keyframe icons: diamond (linear), hourglass (Bezier), circle (ease), square (hold).
    static func symbol(_ interpolation: KeyframeInterpolation) -> String {
        switch interpolation {
        case .hold: return "square.fill"
        case .linear: return "diamond.fill"
        case .autoBezier, .continuousBezier, .bezier: return "hourglass"
        case .easeIn, .easeOut, .easeInOut: return "circle.fill"
        }
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
        return Image(systemName: Self.symbol(keyframe.interpolation))
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
