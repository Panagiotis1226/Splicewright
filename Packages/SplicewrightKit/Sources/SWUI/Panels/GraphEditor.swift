import AppKit
import SwiftUI
import SWCore
import SWPlayback

/// Premiere's value graph for one keyframed property, under its row in Effect Controls: the
/// curve across the clip (one line per component), keyframes you drag in time and value
/// (⇧ keeps the time), and Bezier handles on selected keyframes (⌥ breaks the pair).
struct GraphEditor: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var engine: PlaybackEngine
    let clip: Clip
    let property: PropertyRef
    /// Shows values as Effect Controls does (Position and Anchor Point from the top left).
    let display: (Double, Int) -> Double
    let stored: (Double, Int) -> Double
    @Binding var selection: Set<UUID>

    static let height: CGFloat = 130
    private static let colors: [Color] = [Color(red: 0.95, green: 0.75, blue: 0.2), Color(red: 0.35, green: 0.75, blue: 1)]

    /// What a drag started from, so live edits are relative to it.
    private struct DragStart {
        var range: ClosedRange<Double>
    }

    @State private var dragStart: DragStart?

    private var rate: FrameRate { workspace.activeSequence?.rate ?? .fps30 }
    private var animated: AnimatableProperty { clip.animatable(property) ?? AnimatableProperty([0]) }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let range = dragStart?.range ?? valueRange(width: size.width)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(white: 0.09))
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        selection = []
                        engine.seek(toFrame: frame(atX: location.x, width: size.width))
                    }
                grid(size: size, range: range)
                curves(size: size, range: range)
                Rectangle().fill(Theme.playhead).frame(width: 1)
                    .offset(x: x(forFrame: Double(engine.currentFrame), width: size.width))
                    .allowsHitTesting(false)
                ForEach(Array(animated.keyframes.enumerated()), id: \.element.id) { index, keyframe in
                    ForEach(keyframe.values.indices, id: \.self) { component in
                        if selection.contains(keyframe.id) {
                            handles(index: index, component: component, size: size, range: range)
                        }
                        point(keyframe, component: component, size: size, range: range)
                    }
                }
            }
        }
        .frame(height: Self.height)
        .clipped()
    }

    // MARK: - Mapping

    /// Sequence frames (fractional) across the clip ↔ x.
    private func x(forFrame frame: Double, width: CGFloat) -> CGFloat {
        CGFloat((frame - Double(clip.start)) / Double(max(clip.duration, 1))) * width
    }

    private func frame(atX x: CGFloat, width: CGFloat) -> Int64 {
        clip.start + Int64((x / max(width, 1) * CGFloat(clip.duration)).rounded())
    }

    /// The keyframe time (seconds) under x, interpolated between frames for smooth handles.
    private func seconds(atX x: CGFloat, width: CGFloat) -> Double {
        let exact = Double(clip.start) + Double(x / max(width, 1)) * Double(clip.duration)
        let lower = Int64(exact.rounded(.down))
        let fraction = exact - Double(lower)
        let a = clip.keyframeTime(for: property, atSequenceFrame: lower, rate: rate).seconds
        let b = clip.keyframeTime(for: property, atSequenceFrame: lower + 1, rate: rate).seconds
        return a + (b - a) * fraction
    }

    private func x(forSeconds seconds: Double, width: CGFloat) -> CGFloat {
        let time = RationalTime(seconds: seconds, timescale: 96_000)
        let frame = clip.sequenceFrame(ofKeyframeTime: time, for: property, rate: rate)
        // Add back the part of a frame the conversion rounded away.
        let base = clip.keyframeTime(for: property, atSequenceFrame: frame, rate: rate).seconds
        let next = clip.keyframeTime(for: property, atSequenceFrame: frame + 1, rate: rate).seconds
        let fraction = next > base ? (seconds - base) / (next - base) : 0
        return x(forFrame: Double(frame) + min(max(fraction, -1), 1), width: width)
    }

    private func y(_ value: Double, height: CGFloat, range: ClosedRange<Double>) -> CGFloat {
        let span = max(range.upperBound - range.lowerBound, 1e-9)
        return height - CGFloat((value - range.lowerBound) / span) * height
    }

    private func value(atY y: CGFloat, height: CGFloat, range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        return range.lowerBound + Double((height - y) / max(height, 1)) * span
    }

    /// The displayed values the curve covers, with room above and below.
    private func valueRange(width: CGFloat) -> ClosedRange<Double> {
        var values: [Double] = []
        for step in 0...60 {
            let frame = clip.start + Int64(Double(clip.duration - 1) * Double(step) / 60)
            let current = animated.value(at: clip.keyframeTime(for: property, atSequenceFrame: frame, rate: rate))
            values += current.indices.map { display(current[$0], $0) }
        }
        for keyframe in animated.keyframes { values += keyframe.values.indices.map { display(keyframe.values[$0], $0) } }
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let pad = max((high - low) * 0.15, 1)
        return (low - pad)...(high + pad)
    }

    // MARK: - Drawing

    private func grid(size: CGSize, range: ClosedRange<Double>) -> some View {
        Canvas { context, _ in
            for fraction in [0.25, 0.5, 0.75] {
                let y = size.height * fraction
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.white.opacity(0.06)))
                let value = self.value(atY: y, height: size.height, range: range)
                context.draw(Text(ScrubbableNumber.format(value)).font(.system(size: 8)).foregroundColor(.gray),
                             at: CGPoint(x: 3, y: y - 6), anchor: .leading)
            }
        }
        .allowsHitTesting(false)
    }

    private func curves(size: CGSize, range: ClosedRange<Double>) -> some View {
        Canvas { context, _ in
            let samples = max(Int(size.width / 2), 2)
            let components = animated.keyframes.first?.values.count ?? 1
            for component in 0..<components {
                var path = Path()
                for step in 0...samples {
                    let x = size.width * CGFloat(step) / CGFloat(samples)
                    let time = RationalTime(seconds: seconds(atX: x, width: size.width), timescale: 96_000)
                    let values = animated.value(at: time)
                    let value = component < values.count ? display(values[component], component) : 0
                    let point = CGPoint(x: x, y: y(value, height: size.height, range: range))
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(Self.colors[component % Self.colors.count]), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }

    private func position(_ keyframe: Keyframe, component: Int, size: CGSize, range: ClosedRange<Double>) -> CGPoint {
        CGPoint(x: x(forSeconds: keyframe.time.seconds, width: size.width),
                y: y(display(keyframe.values[component], component), height: size.height, range: range))
    }

    // MARK: - Keyframe points

    private func point(_ keyframe: Keyframe, component: Int, size: CGSize, range: ClosedRange<Double>) -> some View {
        let selected = selection.contains(keyframe.id)
        let at = position(keyframe, component: component, size: size, range: range)
        return Image(systemName: keyframe.interpolation.isBezier ? "circle.fill" : "diamond.fill")
            .font(.system(size: 8))
            .foregroundStyle(selected ? Theme.accent : Self.colors[component % Self.colors.count])
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
            .position(at)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { drag in
                    if dragStart == nil { dragStart = DragStart(range: range) }
                    selection = [keyframe.id]
                    let lockTime = NSEvent.modifierFlags.contains(.shift)
                    if !lockTime {
                        workspace.moveKeyframe(keyframe.id, property, of: clip.id,
                                               toFrame: frame(atX: drag.location.x, width: size.width), live: true)
                    }
                    let shown = value(atY: drag.location.y, height: size.height, range: dragStart?.range ?? range)
                    let point = WorkspaceController.KeyframeComponent(id: keyframe.id, property: property,
                                                                      component: component)
                    workspace.setKeyframeValue(stored(shown, component), point, of: clip.id, live: true)
                }
                .onEnded { _ in
                    dragStart = nil
                    workspace.endLiveEdit("Move Keyframe")
                })
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.shift) {
                    selection.formSymmetricDifference([keyframe.id])
                } else {
                    selection = [keyframe.id]
                }
            }
            .contextMenu { interpolationMenu(keyframe) }
            .help("\(keyframe.interpolation.displayName): drag to change it (⇧ keeps its time); right-click for the curve type")
    }

    @ViewBuilder private func interpolationMenu(_ keyframe: Keyframe) -> some View {
        let ids = selection.contains(keyframe.id) ? selection : [keyframe.id]
        ForEach(KeyframeInterpolation.allCases, id: \.self) { interpolation in
            Button(interpolation.displayName) {
                workspace.setInterpolation(interpolation, ids: ids, property, of: clip.id)
            }
        }
        Divider()
        Button("Delete") { workspace.deleteKeyframes(ids, property, of: clip.id) }
    }

    // MARK: - Bezier handles

    /// One handle: which side of which keyframe, towards which neighbour, for which component.
    private struct HandleRef {
        var side: HandleSide
        var index: Int
        var neighbour: Int
        var component: Int
    }

    @ViewBuilder
    private func handles(index: Int, component: Int, size: CGSize, range: ClosedRange<Double>) -> some View {
        let keyframes = animated.keyframes
        let resolved = animated.handles(at: index)
        let origin = position(keyframes[index], component: component, size: size, range: range)
        ForEach([HandleSide.incoming, .outgoing], id: \.self) { side in
            let neighbour = side == .incoming ? index - 1 : index + 1
            if neighbour >= 0 && neighbour < keyframes.count {
                let handle = side == .incoming ? resolved.incoming : resolved.outgoing
                let ref = HandleRef(side: side, index: index, neighbour: neighbour, component: component)
                let end = handleEnd(ref, handle: handle, size: size, range: range)
                Path { path in
                    path.move(to: origin)
                    path.addLine(to: end)
                }
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                .allowsHitTesting(false)
                Circle().fill(Color.white)
                    .frame(width: 7, height: 7)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .position(end)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                        .onChanged { drag in
                            if dragStart == nil { dragStart = DragStart(range: range) }
                            dragHandle(ref, to: drag.location, size: size)
                        }
                        .onEnded { _ in
                            dragStart = nil
                            workspace.endLiveEdit("Keyframe Handle")
                        })
                    .help("Drag to shape the curve; ⌥-drag to move this side on its own")
            }
        }
    }

    /// Where a handle's end sits: `influence` of the way to the neighbour, along its slope.
    private func handleEnd(_ ref: HandleRef, handle: BezierHandle, size: CGSize, range: ClosedRange<Double>) -> CGPoint {
        let (index, neighbour, component) = (ref.index, ref.neighbour, ref.component)
        let keyframes = animated.keyframes
        let time = keyframes[index].time.seconds
        let span = keyframes[neighbour].time.seconds - time
        let reach = span * handle.influence
        let slope = component < handle.slopes.count ? handle.slopes[component] : 0
        let base = keyframes[index].values[component]
        let shown = display(base + slope * reach, component)
        return CGPoint(x: x(forSeconds: time + reach, width: size.width),
                       y: y(shown, height: size.height, range: dragStart?.range ?? range))
    }

    private func dragHandle(_ ref: HandleRef, to location: CGPoint, size: CGSize) {
        let (side, index, neighbour, component) = (ref.side, ref.index, ref.neighbour, ref.component)
        guard let range = dragStart?.range else { return }
        let keyframes = animated.keyframes
        let key = keyframes[index]
        let time = key.time.seconds
        let span = keyframes[neighbour].time.seconds - time
        guard abs(span) > 1e-6 else { return }
        // Keep the handle on its own side of the keyframe.
        var reach = seconds(atX: location.x, width: size.width) - time
        reach = span > 0 ? max(reach, span * 0.01) : min(reach, span * 0.01)
        let influence = min(reach / span, 1)
        let target = stored(value(atY: location.y, height: size.height, range: range), component)
        let current = side == .incoming ? animated.handles(at: index).incoming : animated.handles(at: index).outgoing
        var slopes = current.slopes
        while slopes.count < key.values.count { slopes.append(0) }
        slopes[component] = (target - key.values[component]) / reach
        let edit = WorkspaceController.HandleEdit(side: side, slopes: slopes, influence: influence,
                                                  breaking: NSEvent.modifierFlags.contains(.option))
        workspace.setHandle(edit, of: key.id, property, of: clip.id, live: true)
    }
}
