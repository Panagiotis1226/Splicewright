import AppKit
import SwiftUI
import SWCore

/// The selected mask's path in the Program monitor, edited as in Premiere: drag a point to
/// move it, a handle to curve the path (⌥ moves that side only), or inside the mask to move
/// all of it. Click the path to add a point, ⌘-click a point to delete it, ⌥-click a point to
/// switch it between a corner and a curve. With the Pen, click to place the points of a new
/// mask (drag to curve them) and click the first point to close it. The path follows the
/// clip's motion; with Mask Path animated, edits add or update a keyframe at the playhead.
struct MaskHandles: View {
    @ObservedObject var workspace: WorkspaceController
    let clip: Clip
    let pictureRect: CGRect
    /// Drawing with the Tools panel's Pen, rather than a Pen chosen in Effect Controls: the shape
    /// becomes a None-mode mask on the clip's Opacity (`addPenToolMask`).
    var drawsWithPenTool = false

    private enum Part: Equatable {
        case vertex(Int)
        case handle(Int, outgoing: Bool)
        case edge(segment: Int, t: Double)
        case inside
        case none
    }

    private struct DragState {
        var part: Part
        var vertices: [Mask.Vertex]
        var start: (u: Double, v: Double)
        var moved = false
    }

    @State private var drag: DragState?
    @State private var selectedVertex: Int?
    /// The Pen's points so far, in picture coordinates.
    @State private var penPoints: [Mask.Vertex] = []
    @State private var isPenDragging = false
    @State private var isClosing = false

    var body: some View {
        if let mapping = PictureMapping(workspace: workspace, clip: clip, pictureRect: pictureRect) {
            if workspace.maskPen?.clipID == clip.id || drawsWithPenTool {
                pen(mapping)
            } else if let selection = workspace.selectedMask, selection.target.clipID == clip.id {
                // A mask using a tracked shape edits the shape.
                editor(workspace.pathSelection(selection), mapping: mapping)
            }
        }
    }

    // MARK: - Drawing

    private static func outline(_ vertices: [Mask.Vertex], closed: Bool, mapping: PictureMapping) -> Path {
        Path { path in
            guard let first = vertices.first else { return }
            path.move(to: mapping.point(u: first.x, v: first.y))
            let segments = closed ? vertices.count : vertices.count - 1
            for index in 0..<max(segments, 0) {
                let a = vertices[index]
                let b = vertices[(index + 1) % vertices.count]
                path.addCurve(to: mapping.point(u: b.x, v: b.y),
                              control1: mapping.point(u: a.x + a.outX, v: a.y + a.outY),
                              control2: mapping.point(u: b.x + b.inX, v: b.y + b.inY))
            }
            if closed { path.closeSubpath() }
        }
    }

    private static func hasHandles(_ vertex: Mask.Vertex) -> Bool {
        [vertex.inX, vertex.inY, vertex.outX, vertex.outY].contains { abs($0) > 1e-6 }
    }

    private func pointMarker(at point: CGPoint, selected: Bool, size: CGFloat = 7) -> some View {
        Rectangle()
            .fill(selected ? Theme.accent : Color.white)
            .frame(width: size, height: size)
            .overlay(Rectangle().stroke(Theme.accent, lineWidth: 1))
            .position(point)
            .allowsHitTesting(false)
    }

    /// The selected point's handles: a line to each, with a dot at the end.
    private func handleLines(_ vertex: Mask.Vertex, mapping: PictureMapping) -> some View {
        let center = mapping.point(u: vertex.x, v: vertex.y)
        let ends = [mapping.point(u: vertex.x + vertex.inX, v: vertex.y + vertex.inY),
                    mapping.point(u: vertex.x + vertex.outX, v: vertex.y + vertex.outY)]
        return ZStack {
            Path { path in
                for end in ends {
                    path.move(to: center)
                    path.addLine(to: end)
                }
            }
            .stroke(Theme.accent.opacity(0.8), lineWidth: 1)
            ForEach(0..<2, id: \.self) { index in
                Circle().fill(Theme.accent).frame(width: 6, height: 6).position(ends[index])
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Editing

    private func editor(_ selection: MaskSelection, mapping: PictureMapping) -> some View {
        let vertices = workspace.maskVertices(selection)
        let outline = Self.outline(vertices, closed: true, mapping: mapping)
        return ZStack {
            outline.stroke(Theme.accent, lineWidth: 1.5).allowsHitTesting(false)
            if let index = selectedVertex, vertices.indices.contains(index), Self.hasHandles(vertices[index]) {
                handleLines(vertices[index], mapping: mapping)
            }
            ForEach(vertices.indices, id: \.self) { index in
                pointMarker(at: mapping.point(u: vertices[index].x, v: vertices[index].y), selected: selectedVertex == index)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                dragChanged(value, selection: selection, vertices: vertices, outline: outline, mapping: mapping)
            }
            .onEnded { _ in dragEnded(selection: selection, vertices: vertices) })
        .help("Drag a point or handle to reshape the mask, or inside it to move it. Click the path to add a point, "
              + "⌘-click a point to delete it, ⌥-click to make it a corner or a curve.")
    }

    private func part(at point: CGPoint, vertices: [Mask.Vertex], outline: Path, mapping: PictureMapping) -> Part {
        func near(_ other: CGPoint, within radius: CGFloat = 6) -> Bool {
            hypot(other.x - point.x, other.y - point.y) <= radius
        }
        if let index = selectedVertex, vertices.indices.contains(index), Self.hasHandles(vertices[index]) {
            let vertex = vertices[index]
            if near(mapping.point(u: vertex.x + vertex.outX, v: vertex.y + vertex.outY)) {
                return .handle(index, outgoing: true)
            }
            if near(mapping.point(u: vertex.x + vertex.inX, v: vertex.y + vertex.inY)) {
                return .handle(index, outgoing: false)
            }
        }
        if let index = vertices.indices.first(where: { near(mapping.point(u: vertices[$0].x, v: vertices[$0].y)) }) {
            return .vertex(index)
        }
        // The nearest point on the path, sampled along each segment.
        var best: (distance: CGFloat, segment: Int, t: Double)?
        for segment in vertices.indices where vertices.count >= 2 {
            for step in 0...32 {
                let t = Double(step) / 32
                let on = Mask.point(on: vertices, segment: segment, t: t)
                let monitor = mapping.point(u: on.x, v: on.y)
                let distance = hypot(monitor.x - point.x, monitor.y - point.y)
                if distance < best?.distance ?? .infinity { best = (distance, segment, t) }
            }
        }
        if let best, best.distance <= 5, best.t > 0.02, best.t < 0.98 { return .edge(segment: best.segment, t: best.t) }
        return outline.contains(point) ? .inside : .none
    }

    private func dragChanged(_ value: DragGesture.Value, selection: MaskSelection, vertices: [Mask.Vertex], outline: Path,
                             mapping: PictureMapping) {
        if drag == nil {
            guard let start = mapping.uv(at: value.startLocation) else { return }
            drag = DragState(part: part(at: value.startLocation, vertices: vertices, outline: outline, mapping: mapping),
                             vertices: vertices, start: start)
        }
        guard var state = drag else { return }
        if !state.moved {
            guard hypot(value.translation.width, value.translation.height) >= 2 else { return }
            state.moved = true
            drag = state
        }
        guard let now = mapping.uv(at: value.location) else { return }
        let (du, dv) = (now.u - state.start.u, now.v - state.start.v)
        var edited = state.vertices
        switch state.part {
        case .vertex(let index):
            edited[index].x += du
            edited[index].y += dv
            selectedVertex = index
        case .handle(let index, let outgoing):
            let original = state.vertices[index]
            edited[index] = Self.setting(original, handle: (now.u - original.x, now.v - original.y), outgoing: outgoing,
                                         independent: NSEvent.modifierFlags.contains(.option))
        case .inside, .edge:
            for index in edited.indices {
                edited[index].x += du
                edited[index].y += dv
            }
        case .none:
            return
        }
        workspace.setMaskVertices(edited, of: selection, live: true)
    }

    private func dragEnded(selection: MaskSelection, vertices: [Mask.Vertex]) {
        guard let state = drag else { return }
        drag = nil
        if state.moved {
            workspace.endLiveEdit("Mask Path")
            return
        }
        let flags = NSEvent.modifierFlags
        switch state.part {
        case .vertex(let index):
            if flags.contains(.command) {
                workspace.removeMaskVertex(selection, at: index)
                selectedVertex = nil
            } else if flags.contains(.option) {
                workspace.setMaskVertices(Self.togglingCorner(vertices, at: index), of: selection, live: false)
                selectedVertex = index
            } else {
                selectedVertex = index
            }
        case .edge(let segment, let t):
            workspace.insertMaskVertex(selection, segment: segment, t: t)
            selectedVertex = segment + 1
        case .handle:
            break
        case .inside, .none:
            selectedVertex = nil
        }
    }

    /// Sets one handle; unless `independent`, the other turns to point the opposite way (a smooth
    /// curve), keeping its length.
    private static func setting(_ vertex: Mask.Vertex, handle offset: (Double, Double), outgoing: Bool,
                                independent: Bool) -> Mask.Vertex {
        var result = vertex
        if outgoing {
            (result.outX, result.outY) = offset
        } else {
            (result.inX, result.inY) = offset
        }
        let length = hypot(offset.0, offset.1)
        guard !independent, length > 1e-9 else { return result }
        let other = outgoing ? (vertex.inX, vertex.inY) : (vertex.outX, vertex.outY)
        let otherLength = hypot(other.0, other.1) > 1e-9 ? hypot(other.0, other.1) : length
        let mirrored = (-offset.0 / length * otherLength, -offset.1 / length * otherLength)
        if outgoing {
            (result.inX, result.inY) = mirrored
        } else {
            (result.outX, result.outY) = mirrored
        }
        return result
    }

    /// A curve becomes a corner; a corner gets handles along the line between its neighbours.
    private static func togglingCorner(_ vertices: [Mask.Vertex], at index: Int) -> [Mask.Vertex] {
        guard vertices.indices.contains(index) else { return vertices }
        var vertex = vertices[index]
        var (dx, dy) = (0.0, 0.0)
        if !hasHandles(vertex) {
            let previous = vertices[(index + vertices.count - 1) % vertices.count]
            let next = vertices[(index + 1) % vertices.count]
            (dx, dy) = ((next.x - previous.x) / 6, (next.y - previous.y) / 6)
        }
        vertex.inX = -dx
        vertex.inY = -dy
        vertex.outX = dx
        vertex.outY = dy
        var result = vertices
        result[index] = vertex
        return result
    }

    // MARK: - Pen

    private func pen(_ mapping: PictureMapping) -> some View {
        ZStack {
            Self.outline(penPoints, closed: false, mapping: mapping)
                .stroke(Theme.accent, lineWidth: 1.5)
                .allowsHitTesting(false)
            ForEach(penPoints.indices, id: \.self) { index in
                // The first point grows once the path can be closed there.
                pointMarker(at: mapping.point(u: penPoints[index].x, v: penPoints[index].y), selected: index == 0,
                            size: index == 0 && penPoints.count >= 3 ? 10 : 7)
            }
            penBar
                .position(x: pictureRect.midX, y: pictureRect.minY + 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in penChanged(value, mapping: mapping) }
            .onEnded { _ in penEnded() })
        .onChange(of: workspace.maskPen) { _, _ in penPoints = [] }
    }

    private var penHint: String {
        if penPoints.count >= 3 { return "Click the first point to close the shape" }
        if drawsWithPenTool && penPoints.isEmpty {
            return "Pen: click around what to track on \(clip.name) (drag to curve). The shape doesn't change the picture."
        }
        return "Click to place points; drag to curve"
    }

    private var penBar: some View {
        HStack(spacing: 8) {
            Text(penHint).font(.system(size: 10))
            if penPoints.count >= 3 {
                Button("Close Mask") { finishPen() }.controlSize(.small)
            }
            Button("Cancel") {
                penPoints = []
                workspace.maskPen = nil
                if drawsWithPenTool { workspace.activeTool = .selection }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(.white)
    }

    private func penChanged(_ value: DragGesture.Value, mapping: PictureMapping) {
        if !isPenDragging {
            isPenDragging = true
            guard let start = mapping.uv(at: value.startLocation) else { return }
            if penPoints.count >= 3, let first = penPoints.first {
                let point = mapping.point(u: first.x, v: first.y)
                if hypot(point.x - value.startLocation.x, point.y - value.startLocation.y) <= 8 {
                    isClosing = true
                    return
                }
            }
            penPoints.append(Mask.Vertex(x: start.u, y: start.v))
        }
        // Dragging while placing a point pulls out its handles.
        guard !isClosing, var last = penPoints.last, hypot(value.translation.width, value.translation.height) > 3,
              let now = mapping.uv(at: value.location) else { return }
        (last.outX, last.outY) = (now.u - last.x, now.v - last.y)
        (last.inX, last.inY) = (-last.outX, -last.outY)
        penPoints[penPoints.count - 1] = last
    }

    private func penEnded() {
        isPenDragging = false
        if isClosing {
            isClosing = false
            finishPen()
        }
    }

    private func finishPen() {
        guard penPoints.count >= 3 else { return }
        if let target = workspace.maskPen, target.clipID == clip.id {
            workspace.addMask(Mask(name: "Mask", vertices: penPoints), to: target)
        } else if drawsWithPenTool {
            workspace.addPenToolMask(penPoints, to: clip.id)
        }
        penPoints = []
    }
}
