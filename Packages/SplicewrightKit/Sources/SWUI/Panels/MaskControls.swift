import SwiftUI
import SWCore
import SWPlayback

/// The masks on a clip's Opacity or on one of its effects, in Effect Controls: buttons that
/// make an ellipse, a rectangle or a Pen mask, and for each mask its path (keyframeable),
/// feather, opacity, expansion, mode and Inverted. Selecting a mask shows its path in the
/// Program monitor for editing.
struct MaskControls<Row: View>: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var engine: PlaybackEngine
    let clip: Clip
    let owner: MaskOwner
    @Binding var selectedKeyframes: Set<UUID>
    /// A keyframeable number row, as Effect Controls draws its others: ref, title, unit, drag step.
    let row: (PropertyRef, String, String, Double) -> Row

    private var target: MaskTarget { MaskTarget(clipID: clip.id, owner: owner) }
    private var rate: FrameRate { workspace.activeSequence?.rate ?? .fps30 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            if workspace.maskPen == target {
                Text("Click in the Program monitor to place points, drag to curve them, and click the first point "
                     + "to close the mask.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 34)
                    .padding(.bottom, 4)
            }
            ForEach(clip.masks(of: owner)) { mask in
                let selection = MaskSelection(target: target, maskID: mask.id)
                header(mask, selection)
                pathRow(selection)
                row(selection.ref(.feather), "Mask Feather", "px", 1)
                row(selection.ref(.opacity), "Mask Opacity", "%", 1)
                row(selection.ref(.expansion), "Mask Expansion", "px", 1)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 26)
            Text("Masks").foregroundStyle(Theme.textSecondary).frame(width: 82, alignment: .leading)
            Button { workspace.addMask(.ellipse, to: target) } label: { Image(systemName: "circle") }
                .help("Add an ellipse mask")
            Button { workspace.addMask(.rectangle, to: target) } label: { Image(systemName: "square") }
                .help("Add a rectangle mask")
            Button {
                if workspace.maskPen == target { workspace.maskPen = nil } else { workspace.startMaskPen(target) }
            } label: {
                Image(systemName: "pencil.tip")
                    .foregroundStyle(workspace.maskPen == target ? Theme.accent : Theme.textPrimary)
            }
            .help(workspace.maskPen == target ? "Stop drawing" : "Draw a mask with the Pen in the Program monitor")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 24)
    }

    private func header(_ mask: Mask, _ selection: MaskSelection) -> some View {
        let isSelected = workspace.selectedMask == selection
        return HStack(spacing: 6) {
            Spacer().frame(width: 26)
            Button {
                workspace.maskPen = nil
                workspace.selectedMask = isSelected ? nil : selection
            } label: {
                Label(mask.name, systemImage: "pentagon")
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textPrimary)
            }
            .help(isSelected ? "Hide the mask's path in the Program monitor"
                             : "Show the mask's path in the Program monitor to edit it")
            Spacer(minLength: 4)
            Picker("", selection: Binding(get: { mask.mode }, set: { mode in
                workspace.updateMask(selection, "Mask Mode") { $0.mode = mode }
            })) {
                ForEach(Mask.Mode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            Toggle("Inverted", isOn: Binding(get: { mask.isInverted }, set: { inverted in
                workspace.updateMask(selection, inverted ? "Invert Mask" : "Uninvert Mask") { $0.isInverted = inverted }
            }))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            Button { workspace.removeMask(selection) } label: { Image(systemName: "trash") }
                .help("Delete \(mask.name)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(isSelected ? Theme.accent.opacity(0.08) : Color.clear)
    }

    /// Mask Path: a stopwatch and keyframes, but no numbers (the shape is edited in the monitor).
    private func pathRow(_ selection: MaskSelection) -> some View {
        let ref = selection.ref(.path)
        let animated = clip.animatable(ref) ?? AnimatableProperty([])
        let onKeyframe = animated.keyframe(at: workspace.keyframeTime(in: clip, for: ref),
                                           tolerance: rate.frameDuration) != nil
        return HStack(spacing: 6) {
            Spacer().frame(width: 14)
            Button { workspace.setAnimated(!animated.isAnimated, ref, of: clip) } label: {
                Image(systemName: "stopwatch")
                    .foregroundStyle(animated.isAnimated ? Theme.accent : Theme.textSecondary)
            }
            .help(animated.isAnimated ? "Turn off animation (removes keyframes)"
                                      : "Animate the path: each edit at a new time adds a keyframe")
            Text("Mask Path").lineLimit(1).frame(width: 82, alignment: .leading)
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
            KeyframeLane(workspace: workspace, engine: engine, clip: clip, property: ref, selection: $selectedKeyframes)
                .frame(minWidth: 120, maxWidth: .infinity)
                .frame(height: 20)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 24)
    }
}
