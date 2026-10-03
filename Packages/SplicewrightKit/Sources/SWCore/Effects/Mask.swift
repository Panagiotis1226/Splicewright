import Foundation

/// A mask on a clip's Opacity or on one of its effects, as in Premiere: a closed Bezier path
/// in the clip's own picture (0...1 across, top left origin, so it follows Motion), with
/// feather, opacity and expansion. The path is one keyframeable value of six numbers per vertex
/// (point, incoming handle, outgoing handle), so it animates vertex by vertex.
public struct Mask: Sendable, Hashable, Codable, Identifiable {
    public enum Mode: String, Sendable, Hashable, Codable, CaseIterable {
        case add, subtract
        /// Changes nothing in the picture: a shape to track and to attach titles and clips to.
        case none

        public var displayName: String {
            switch self {
            case .add: return "Add"
            case .subtract: return "Subtract"
            case .none: return "None"
            }
        }

        /// Whether the mask shapes the picture (None only tracks).
        public var isDrawn: Bool { self != .none }
    }

    /// A path point and its handles (offsets from the point), in picture fractions.
    public struct Vertex: Sendable, Hashable {
        public var x: Double
        public var y: Double
        public var inX: Double
        public var inY: Double
        public var outX: Double
        public var outY: Double

        public init(x: Double, y: Double, inX: Double = 0, inY: Double = 0, outX: Double = 0, outY: Double = 0) {
            (self.x, self.y, self.inX, self.inY, self.outX, self.outY) = (x, y, inX, inY, outX, outY)
        }

        var values: [Double] { [x, y, inX, inY, outX, outY] }
    }

    public var id: UUID
    public var name: String
    public var mode: Mode
    public var isInverted: Bool
    /// Six numbers per vertex.
    public var path: AnimatableProperty
    /// Pixels (sequence) of soft edge.
    public var feather: AnimatableProperty
    /// Percent.
    public var opacity: AnimatableProperty
    /// Pixels the edge grows (negative shrinks).
    public var expansion: AnimatableProperty
    /// How Track follows an object with this mask (nil: the defaults).
    public var tracking: TrackingSettings?
    /// Another mask on the clip whose path this one uses (an effect limited to a tracked shape).
    public var pathSource: MaskSource?

    public init(id: UUID = UUID(), name: String = "Mask", vertices: [Vertex], mode: Mode = .add, isInverted: Bool = false,
                feather: Double = 10) {
        self.id = id
        self.name = name
        self.mode = mode
        self.isInverted = isInverted
        path = AnimatableProperty(vertices.flatMap(\.values))
        self.feather = AnimatableProperty([feather])
        opacity = AnimatableProperty([100])
        expansion = AnimatableProperty([0])
    }

    // MARK: - Shapes

    /// The standard cubic approximation of a quarter circle.
    static let kappa = 0.552_284_749_8

    /// An ellipse through four vertices; `aspect` is the picture's width over height, so a
    /// circle in pixels stays round.
    public static func ellipse(centerX: Double = 0.5, centerY: Double = 0.5, radiusX: Double = 0.2,
                               radiusY: Double = 0.2) -> Mask {
        let kx = radiusX * kappa
        let ky = radiusY * kappa
        return Mask(name: "Ellipse", vertices: [
            Vertex(x: centerX, y: centerY - radiusY, inX: -kx, inY: 0, outX: kx, outY: 0),
            Vertex(x: centerX + radiusX, y: centerY, inX: 0, inY: -ky, outX: 0, outY: ky),
            Vertex(x: centerX, y: centerY + radiusY, inX: kx, inY: 0, outX: -kx, outY: 0),
            Vertex(x: centerX - radiusX, y: centerY, inX: 0, inY: ky, outX: 0, outY: -ky),
        ])
    }

    public static func rectangle(left: Double = 0.3, top: Double = 0.3, right: Double = 0.7, bottom: Double = 0.7) -> Mask {
        Mask(name: "Rectangle", vertices: [Vertex(x: left, y: top), Vertex(x: right, y: top), Vertex(x: right, y: bottom),
                                           Vertex(x: left, y: bottom)])
    }

    public static func polygon(_ points: [(x: Double, y: Double)]) -> Mask {
        Mask(name: "Mask", vertices: points.map { Vertex(x: $0.x, y: $0.y) })
    }

    // MARK: - Path

    static func vertices(from values: [Double]) -> [Vertex] {
        stride(from: 0, to: values.count - values.count % 6, by: 6).map { index in
            Vertex(x: values[index], y: values[index + 1], inX: values[index + 2], inY: values[index + 3],
                   outX: values[index + 4], outY: values[index + 5])
        }
    }

    /// The path's vertices at a source time.
    public func vertices(at time: RationalTime) -> [Vertex] {
        Self.vertices(from: path.value(at: time))
    }

    /// Sets the path at `time` (a keyframe if the path is animated).
    public mutating func setVertices(_ vertices: [Vertex], at time: RationalTime, tolerance: RationalTime) {
        path.set(vertices.flatMap(\.values), at: time, tolerance: tolerance)
    }

    /// The cubic segment from vertex `index` to the next (closing back to the first).
    static func segment(_ vertices: [Vertex], _ index: Int) -> [(Double, Double)] {
        let a = vertices[index]
        let b = vertices[(index + 1) % vertices.count]
        return [(a.x, a.y), (a.x + a.outX, a.y + a.outY), (b.x + b.inX, b.y + b.inY), (b.x, b.y)]
    }

    /// A point along segment `index` at `t` (0...1).
    public static func point(on vertices: [Vertex], segment index: Int, t: Double) -> (x: Double, y: Double) {
        let p = segment(vertices, index)
        let u = 1 - t
        let x = u * u * u * p[0].0 + 3 * u * u * t * p[1].0 + 3 * u * t * t * p[2].0 + t * t * t * p[3].0
        let y = u * u * u * p[0].1 + 3 * u * u * t * p[1].1 + 3 * u * t * t * p[2].1 + t * t * t * p[3].1
        return (x, y)
    }

    /// Splits segment `index` at `t` with de Casteljau's construction, so the shape doesn't change.
    static func insertingVertex(into vertices: [Vertex], segment index: Int, t: Double) -> [Vertex] {
        guard !vertices.isEmpty else { return vertices }
        let p = segment(vertices, index)
        func lerp(_ a: (Double, Double), _ b: (Double, Double)) -> (Double, Double) {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
        }
        let p01 = lerp(p[0], p[1])
        let p12 = lerp(p[1], p[2])
        let p23 = lerp(p[2], p[3])
        let left = lerp(p01, p12)
        let right = lerp(p12, p23)
        let middle = lerp(left, right)
        var result = vertices
        let next = (index + 1) % vertices.count
        result[index].outX = p01.0 - p[0].0
        result[index].outY = p01.1 - p[0].1
        result[next].inX = p23.0 - p[3].0
        result[next].inY = p23.1 - p[3].1
        let added = Vertex(x: middle.0, y: middle.1, inX: left.0 - middle.0, inY: left.1 - middle.1,
                           outX: right.0 - middle.0, outY: right.1 - middle.1)
        result.insert(added, at: index + 1)
        return result
    }

    /// Adds a vertex on segment `index` at `t` in the path and in every keyframe of it, so an
    /// animated path keeps the same number of points throughout.
    public mutating func insertVertex(segment index: Int, t: Double) {
        path.values = Self.insertingVertex(into: Self.vertices(from: path.values), segment: index, t: t).flatMap(\.values)
        for keyframe in path.keyframes.indices {
            let values = Self.insertingVertex(into: Self.vertices(from: path.keyframes[keyframe].values), segment: index, t: t)
            path.keyframes[keyframe].values = values.flatMap(\.values)
        }
    }

    /// Removes vertex `index` from the path and every keyframe of it; a mask keeps at least three.
    public mutating func removeVertex(at index: Int) {
        func removing(_ values: [Double]) -> [Double] {
            var vertices = Self.vertices(from: values)
            guard vertices.count > 3, vertices.indices.contains(index) else { return values }
            vertices.remove(at: index)
            return vertices.flatMap(\.values)
        }
        path.values = removing(path.values)
        for keyframe in path.keyframes.indices {
            path.keyframes[keyframe].values = removing(path.keyframes[keyframe].values)
        }
    }

    /// Moves the whole mask by a picture offset at `time`.
    public mutating func offset(dx: Double, dy: Double, at time: RationalTime, tolerance: RationalTime) {
        let moved = vertices(at: time).map { vertex -> Vertex in
            var vertex = vertex
            vertex.x += dx
            vertex.y += dy
            return vertex
        }
        setVertices(moved, at: time, tolerance: tolerance)
    }

    /// Everything the renderer needs at one moment.
    public func resolved(at time: RationalTime) -> ResolvedMask {
        ResolvedMask(vertices: vertices(at: time), mode: mode, isInverted: isInverted,
                     feather: max(feather.value(at: time).first ?? 0, 0),
                     opacity: min(max((opacity.value(at: time).first ?? 100) / 100, 0), 1),
                     expansion: expansion.value(at: time).first ?? 0)
    }

    public var isAnimated: Bool { [path, feather, opacity, expansion].contains(where: \.isAnimated) }

    /// The same mask with its keyframes shifted and a new identity (Paste Attributes).
    func retimed(by offset: RationalTime) -> Mask {
        var copy = self
        copy.id = UUID()
        copy.path = path.retimed(by: offset)
        copy.feather = feather.retimed(by: offset)
        copy.opacity = opacity.retimed(by: offset)
        copy.expansion = expansion.retimed(by: offset)
        return copy
    }
}

/// A mask at one frame.
public struct ResolvedMask: Sendable, Hashable {
    public var vertices: [Mask.Vertex]
    public var mode: Mask.Mode
    public var isInverted: Bool
    public var feather: Double
    public var opacity: Double
    public var expansion: Double
}

/// The keyframeable numbers of a mask, for Effect Controls rows.
public enum MaskProperty: String, Sendable, Hashable, Codable, CaseIterable {
    case path, feather, opacity, expansion

    public var displayName: String {
        switch self {
        case .path: return "Mask Path"
        case .feather: return "Mask Feather"
        case .opacity: return "Mask Opacity"
        case .expansion: return "Mask Expansion"
        }
    }

    public var unit: String {
        switch self {
        case .path: return ""
        case .feather, .expansion: return "px"
        case .opacity: return "%"
        }
    }

    public var range: ClosedRange<Double> {
        switch self {
        case .path: return -10...10
        case .feather: return 0...1000
        case .opacity: return 0...100
        case .expansion: return -1000...1000
        }
    }
}

public extension Mask {
    subscript(property: MaskProperty) -> AnimatableProperty {
        get {
            switch property {
            case .path: return path
            case .feather: return feather
            case .opacity: return opacity
            case .expansion: return expansion
            }
        }
        set {
            switch property {
            case .path: path = newValue
            case .feather: feather = newValue
            case .opacity: opacity = newValue
            case .expansion: expansion = newValue
            }
        }
    }
}
