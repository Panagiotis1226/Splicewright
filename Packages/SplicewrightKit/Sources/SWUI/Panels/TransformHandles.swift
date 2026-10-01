import AppKit
import SwiftUI
import SWCore

/// Premiere's direct manipulation in the Program monitor: with the Selection tool and a video
/// clip selected, drag inside its box to move it, a corner to scale it, or just outside a
/// corner to rotate it. Animated properties get a keyframe at the playhead.
struct TransformHandles: View {
    @ObservedObject var workspace: WorkspaceController
    let clip: Clip
    /// Where the picture sits in the monitor.
    let pictureRect: CGRect

    private enum Mode { case move, scale, rotate }

    private struct DragState {
        var mode: Mode
        var start: CGPoint
        var position: [Double]
        var scale: [Double]
        var scaleWidth: [Double]
        var rotation: Double
    }

    @State private var drag: DragState?

    private var settings: SequenceSettings? { workspace.activeSequence?.settings }

    var body: some View {
        if let corners = corners(), corners.count == 4 {
            let pivot = pivotPoint()
            ZStack {
                Path { path in
                    path.addLines(corners)
                    path.closeSubpath()
                }
                .stroke(Theme.accent, lineWidth: 1)
                ForEach(0..<4, id: \.self) { index in
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 7, height: 7)
                        .overlay(Rectangle().stroke(Theme.accent, lineWidth: 1))
                        .position(corners[index])
                }
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .position(pivot)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { value in update(value, corners: corners, pivot: pivot) }
                .onEnded { _ in finish() })
            .help("Drag to move, drag a corner to scale, drag just outside a corner to rotate")
        }
    }

    // MARK: - Geometry (sequence pixels → monitor points)

    private var viewScale: CGFloat {
        guard let settings, settings.width > 0 else { return 1 }
        return pictureRect.width / CGFloat(settings.width)
    }

    private func toView(_ point: (x: Double, y: Double)) -> CGPoint {
        CGPoint(x: pictureRect.minX + CGFloat(point.x) * viewScale, y: pictureRect.minY + CGFloat(point.y) * viewScale)
    }

    /// The clip's picture, fitted to the frame, after its motion at the playhead.
    private func corners() -> [CGPoint]? {
        guard let settings else { return nil }
        let width = Double(settings.width)
        let height = Double(settings.height)
        var mediaWidth = width
        var mediaHeight = height
        if !clip.isTitle, let video = workspace.project.item(clip.mediaID)?.info.video, video.width > 0, video.height > 0 {
            mediaWidth = Double(video.width)
            mediaHeight = Double(video.height)
        }
        let fit = min(width / mediaWidth, height / mediaHeight)
        let halfWidth = mediaWidth * fit / 2
        let halfHeight = mediaHeight * fit / 2
        let transform = clip.motion.transform(at: workspace.keyframeTime(in: clip), renderWidth: width,
                                              renderHeight: height, scale: 1)
        return [(-1, -1), (1, -1), (1, 1), (-1, 1)].map { corner in
            toView(transform.apply(x: width / 2 + corner.0 * halfWidth, y: height / 2 + corner.1 * halfHeight))
        }
    }

    /// Where the anchor point lands: the Position.
    private func pivotPoint() -> CGPoint {
        guard let settings else { return .zero }
        let position = clip.motion.position.value(at: workspace.keyframeTime(in: clip))
        return toView((Double(settings.width) / 2 + (position.first ?? 0), Double(settings.height) / 2 + (position.last ?? 0)))
    }

    // MARK: - Dragging

    private func update(_ value: DragGesture.Value, corners: [CGPoint], pivot: CGPoint) {
        let time = workspace.keyframeTime(in: clip)
        if drag == nil {
            let nearCorner = corners.contains { hypot($0.x - value.startLocation.x, $0.y - value.startLocation.y) < 10 }
            let inside = Path { path in
                path.addLines(corners)
                path.closeSubpath()
            }.contains(value.startLocation)
            let mode: Mode = nearCorner ? .scale : inside ? .move : .rotate
            drag = DragState(mode: mode, start: value.startLocation,
                             position: clip.motion.position.value(at: time), scale: clip.motion.scale.value(at: time),
                             scaleWidth: clip.motion.scaleWidth.value(at: time),
                             rotation: clip.motion.rotation.value(at: time).first ?? 0)
        }
        guard let drag else { return }
        switch drag.mode {
        case .move:
            let dx = Double(value.translation.width / viewScale)
            let dy = Double(value.translation.height / viewScale)
            workspace.setProperty(.position, of: clip.id, to: [drag.position[0] + dx, drag.position[1] + dy], live: true)
        case .scale:
            let before = hypot(drag.start.x - pivot.x, drag.start.y - pivot.y)
            let now = hypot(value.location.x - pivot.x, value.location.y - pivot.y)
            guard before > 1 else { return }
            let ratio = Double(now / before)
            workspace.setProperty(.scale, of: clip.id, to: [max(0, drag.scale[0] * ratio)], live: true)
            if !clip.motion.uniformScale {
                workspace.setProperty(.scaleWidth, of: clip.id, to: [max(0, drag.scaleWidth[0] * ratio)], live: true)
            }
        case .rotate:
            let before = atan2(drag.start.y - pivot.y, drag.start.x - pivot.x)
            let now = atan2(value.location.y - pivot.y, value.location.x - pivot.x)
            var degrees = drag.rotation + Double(now - before) * 180 / .pi
            if NSEvent.modifierFlags.contains(.shift) { degrees = (degrees / 15).rounded() * 15 }
            workspace.setProperty(.rotation, of: clip.id, to: [degrees], live: true)
        }
    }

    private func finish() {
        let name: String
        switch drag?.mode {
        case .scale?: name = "Scale"
        case .rotate?: name = "Rotation"
        default: name = "Position"
        }
        drag = nil
        workspace.endLiveEdit(name)
    }
}
