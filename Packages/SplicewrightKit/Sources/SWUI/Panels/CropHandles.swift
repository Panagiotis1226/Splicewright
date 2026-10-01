import SwiftUI
import SWCore

/// Handles on the edges of a clip's Crop in the Program monitor: drag one to crop that side.
/// The outline follows the clip's motion; animated crops get a keyframe at the playhead.
struct CropHandles: View {
    @ObservedObject var workspace: WorkspaceController
    let clip: Clip
    let crop: ClipEffect
    let pictureRect: CGRect

    /// Each side: its parameter, and where its handle sits in picture coordinates.
    private struct Side: Identifiable {
        var key: String
        var vertical: Bool
        var id: String { key }
    }

    private static let sides = [Side(key: "left", vertical: true), Side(key: "right", vertical: true),
                                Side(key: "top", vertical: false), Side(key: "bottom", vertical: false)]

    /// The crop on each side, 0 to 1.
    private struct Insets {
        var left: Double
        var top: Double
        var right: Double
        var bottom: Double
    }

    @State private var dragging: String?

    var body: some View {
        if let mapping = PictureMapping(workspace: workspace, clip: clip, pictureRect: pictureRect) {
            let inset = insets()
            let corners = [(inset.left, inset.top), (1 - inset.right, inset.top), (1 - inset.right, 1 - inset.bottom),
                           (inset.left, 1 - inset.bottom)].map { mapping.point(u: $0.0, v: $0.1) }
            ZStack {
                Path { path in
                    path.addLines(corners)
                    path.closeSubpath()
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .allowsHitTesting(false)
                ForEach(Self.sides) { side in
                    handle(side, mapping: mapping, inset: inset)
                }
            }
        }
    }

    private func insets() -> Insets {
        let time = workspace.keyframeTime(in: clip, for: .effect(crop.id, "left"))
        func value(_ key: String) -> Double { min(max(crop.value(key, at: time) / 100, 0), 1) }
        return Insets(left: value("left"), top: value("top"), right: value("right"), bottom: value("bottom"))
    }

    /// Where a side's handle sits (the middle of that edge, in picture coordinates).
    private func anchor(_ side: Side, _ inset: Insets) -> (u: Double, v: Double) {
        let middleU = (inset.left + 1 - inset.right) / 2
        let middleV = (inset.top + 1 - inset.bottom) / 2
        switch side.key {
        case "left": return (inset.left, middleV)
        case "right": return (1 - inset.right, middleV)
        case "top": return (middleU, inset.top)
        default: return (middleU, 1 - inset.bottom)
        }
    }

    private func handle(_ side: Side, mapping: PictureMapping, inset: Insets) -> some View {
        let at = anchor(side, inset)
        return Rectangle()
            .fill(dragging == side.key ? Theme.accent : Color.white)
            .frame(width: side.vertical ? 5 : 14, height: side.vertical ? 14 : 5)
            .overlay(Rectangle().stroke(Theme.accent, lineWidth: 1))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .position(mapping.point(u: at.u, v: at.v))
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { value in drag(side, to: value.location, mapping: mapping, at: at) }
                .onEnded { _ in
                    dragging = nil
                    workspace.endLiveEdit("Crop")
                })
            .help("Drag to crop the \(side.key)")
    }

    /// Projects the drag onto the side's axis through the picture (so it works on rotated clips).
    private func drag(_ side: Side, to location: CGPoint, mapping: PictureMapping, at: (u: Double, v: Double)) {
        dragging = side.key
        let origin = side.vertical ? mapping.point(u: 0, v: at.v) : mapping.point(u: at.u, v: 0)
        let end = side.vertical ? mapping.point(u: 1, v: at.v) : mapping.point(u: at.u, v: 1)
        let axis = CGPoint(x: end.x - origin.x, y: end.y - origin.y)
        let length = axis.x * axis.x + axis.y * axis.y
        guard length > 1 else { return }
        let along = Double(((location.x - origin.x) * axis.x + (location.y - origin.y) * axis.y) / length)
        let fraction = min(max(along, 0), 1)
        let percent = side.key == "left" || side.key == "top" ? fraction * 100 : (1 - fraction) * 100
        workspace.setValue(.effect(crop.id, side.key), of: clip.id, to: [percent], actionName: "Crop", live: true)
    }
}
