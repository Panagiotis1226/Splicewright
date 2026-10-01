import AppKit
import SwiftUI
import SWCore
import UniformTypeIdentifiers

/// Lumetri-style RGB curves for a Color Correction effect: click to add a point, drag to move
/// it, double-click to remove it (the end points stay at the edges).
struct CurvesEditor: View {
    @ObservedObject var workspace: WorkspaceController
    let clipID: UUID
    let effect: ClipEffect
    @State private var channel = ColorCurves.Channel.rgb
    @State private var dragging: Int?

    private static let size: CGFloat = 170
    private var curves: ColorCurves { effect.curves ?? ColorCurves() }

    private static func color(_ channel: ColorCurves.Channel) -> Color {
        switch channel {
        case .rgb: return .white
        case .red: return Color(red: 1, green: 0.35, blue: 0.35)
        case .green: return Color(red: 0.35, green: 0.9, blue: 0.4)
        case .blue: return Color(red: 0.4, green: 0.6, blue: 1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RGB Curves").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("", selection: $channel) {
                    ForEach(ColorCurves.Channel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                Button("Reset") { commit("Reset Curves") { $0[channel] = ColorCurves.straight } }
                    .controlSize(.small)
            }
            graph
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 6)
    }

    private var graph: some View {
        let points = curves[channel]
        return ZStack {
            Canvas { context, size in
                var grid = Path()
                for fraction in [0.25, 0.5, 0.75] {
                    grid.move(to: CGPoint(x: size.width * fraction, y: 0))
                    grid.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                    grid.move(to: CGPoint(x: 0, y: size.height * fraction))
                    grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                }
                context.stroke(grid, with: .color(.white.opacity(0.08)))
                var diagonal = Path()
                diagonal.move(to: CGPoint(x: 0, y: size.height))
                diagonal.addLine(to: CGPoint(x: size.width, y: 0))
                context.stroke(diagonal, with: .color(.white.opacity(0.15)))
                var curve = Path()
                for step in 0...80 {
                    let x = Double(step) / 80
                    let point = CGPoint(x: CGFloat(x) * size.width,
                                        y: (1 - CGFloat(ColorCurves.evaluate(points, at: x))) * size.height)
                    if step == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                }
                context.stroke(curve, with: .color(Self.color(channel)), lineWidth: 1.5)
                for point in points {
                    let center = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                                 with: .color(Self.color(channel)))
                }
            }
            .background(Color(white: 0.08))
            .border(Color.white.opacity(0.15))
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { drag in moved(to: drag.location, start: drag.startLocation) }
            .onEnded { _ in
                dragging = nil
                workspace.endLiveEdit("Curves")
            })
        .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .local).onEnded { tap in
            remove(near: tap.location)
        })
        .help("Click to add a point, drag to move it, double-click to remove it")
    }

    private func normalized(_ location: CGPoint) -> ColorCurves.Point {
        ColorCurves.Point(Double(location.x / Self.size), Double(1 - location.y / Self.size))
    }

    private func nearest(_ location: CGPoint, in points: [ColorCurves.Point]) -> Int? {
        points.indices.min { lhs, rhs in
            distance(points[lhs], location) < distance(points[rhs], location)
        }.flatMap { distance(points[$0], location) <= 9 ? $0 : nil }
    }

    private func distance(_ point: ColorCurves.Point, _ location: CGPoint) -> CGFloat {
        hypot(CGFloat(point.x) * Self.size - location.x, CGFloat(1 - point.y) * Self.size - location.y)
    }

    private func moved(to location: CGPoint, start: CGPoint) {
        var points = curves[channel]
        if dragging == nil {
            if let hit = nearest(start, in: points) {
                dragging = hit
            } else {
                points.append(normalized(start))
                points.sort { $0.x < $1.x }
                dragging = points.firstIndex { abs($0.x - normalized(start).x) < 1e-9 }
            }
        }
        guard let index = dragging, index < points.count else { return }
        var point = normalized(location)
        // The ends stay at the edges; inner points stay between their neighbours.
        if index == 0 { point.x = 0 } else if index == points.count - 1 { point.x = 1 } else {
            point.x = min(max(point.x, points[index - 1].x + 0.01), points[index + 1].x - 0.01)
        }
        points[index] = point
        live { $0[channel] = points }
    }

    private func remove(near location: CGPoint) {
        var points = curves[channel]
        guard let index = nearest(location, in: points), index > 0, index < points.count - 1 else { return }
        points.remove(at: index)
        commit("Remove Curve Point") { $0[channel] = points }
    }

    private func live(_ change: @escaping (inout ColorCurves) -> Void) {
        let effectID = effect.id
        let clipID = clipID
        workspace.liveEdit { sequence in
            sequence.updateEffect(effectID, of: clipID) { effect in
                var curves = effect.curves ?? ColorCurves()
                change(&curves)
                effect.curves = curves.isIdentity ? nil : curves
            }
        }
    }

    private func commit(_ actionName: String, _ change: @escaping (inout ColorCurves) -> Void) {
        workspace.updateEffect(effect.id, of: clipID, actionName) { effect in
            var curves = effect.curves ?? ColorCurves()
            change(&curves)
            effect.curves = curves.isIdentity ? nil : curves
        }
    }
}

/// The LUT effect's file: choose a .cube, pick a recent one, or clear it.
struct LUTChooser: View {
    @ObservedObject var workspace: WorkspaceController
    let clipID: UUID
    let effect: ClipEffect

    private static let recentKey = "recentLUTs"

    static var recent: [String] {
        UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    static func remember(_ path: String) {
        let list = [path] + recent.filter { $0 != path }
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: recentKey)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("File").frame(width: 82, alignment: .leading)
            if let path = effect.lutPath {
                Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    .help(path)
                if !FileManager.default.fileExists(atPath: path) {
                    Label("Not found", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help("The clip plays without this LUT until the file is back or you choose another")
                }
            } else {
                Text("None").foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Menu("Choose") {
                Button("Choose a .cube File…") { choose() }
                if !Self.recent.isEmpty {
                    Divider()
                    ForEach(Self.recent, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { set(path) }
                    }
                }
                if effect.lutPath != nil {
                    Divider()
                    Button("None") { set(nil) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 34)
        .frame(height: 24)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose a LUT"
        panel.message = "A .cube file: a camera's log-to-Rec.709 conversion, or a creative look."
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        set(url.path)
    }

    private func set(_ path: String?) {
        if let path { Self.remember(path) }
        workspace.updateEffect(effect.id, of: clipID, path == nil ? "Remove LUT" : "Choose LUT") { $0.lutPath = path }
    }
}
