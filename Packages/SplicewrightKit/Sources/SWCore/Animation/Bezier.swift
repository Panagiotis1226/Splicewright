import Foundation

/// One side of a Bezier keyframe, as Premiere and After Effects store it: how steeply the
/// value leaves (or arrives), and how far along the segment that pull reaches. Stored this way
/// rather than as points, the curve keeps its shape when keyframes move or clips are trimmed.
public struct BezierHandle: Sendable, Hashable, Codable {
    /// Value units per second, one per component.
    public var slopes: [Double]
    /// 0...1: the share of the neighbouring segment's duration the handle reaches across.
    public var influence: Double

    public static let defaultInfluence = 1.0 / 3

    public init(slopes: [Double], influence: Double = BezierHandle.defaultInfluence) {
        self.slopes = slopes
        self.influence = min(max(influence, 0.01), 1)
    }
}

public enum HandleSide: String, Sendable, Hashable, Codable {
    case incoming, outgoing
}

extension KeyframeInterpolation {
    /// Shapes its segments with cubic Bezier curves (with automatic or dragged handles).
    public var isBezier: Bool { self == .bezier || self == .continuousBezier || self == .autoBezier }
}

extension AnimatableProperty {
    /// The handles keyframe `index` uses on each side: its own for Bezier and Continuous Bezier,
    /// computed for Auto Bezier (smooth through its neighbours, flat at the ends), and the
    /// tangents its other interpolations imply (a straight line for Linear, flat for an ease).
    public func handles(at index: Int) -> (incoming: BezierHandle, outgoing: BezierHandle) {
        let key = keyframes[index]
        let automatic = BezierHandle(slopes: autoSlopes(at: index))
        switch key.interpolation {
        case .bezier, .continuousBezier:
            return (key.inHandle ?? automatic, key.outHandle ?? automatic)
        case .autoBezier:
            return (automatic, automatic)
        case .linear, .hold, .easeIn, .easeOut, .easeInOut:
            let flat = BezierHandle(slopes: key.values.map { _ in 0 })
            let incoming = key.interpolation.easesIn ? flat : BezierHandle(slopes: straightSlopes(from: index - 1, to: index))
            let outgoing = key.interpolation.easesOut ? flat : BezierHandle(slopes: straightSlopes(from: index, to: index + 1))
            return (incoming, outgoing)
        }
    }

    /// Catmull-Rom slopes: along the line through the neighbours, flat at the first and last keyframe.
    func autoSlopes(at index: Int) -> [Double] {
        guard index > 0, index + 1 < keyframes.count else { return keyframes[index].values.map { _ in 0 } }
        return straightSlopes(from: index - 1, to: index + 1)
    }

    /// Value per second along the straight line between two keyframes (zero if either is missing).
    func straightSlopes(from first: Int, to second: Int) -> [Double] {
        guard first >= 0, second < keyframes.count, first < second else {
            return keyframes[min(max(first, 0), keyframes.count - 1)].values.map { _ in 0 }
        }
        let span = max((keyframes[second].time - keyframes[first].time).seconds, 1e-9)
        return zip(keyframes[first].values, keyframes[second].values).map { ($1 - $0) / span }
    }

    /// The value between keyframes `index` and `index + 1` at `seconds` from the first, along
    /// the cubic Bezier their handles describe.
    func bezierValue(segment index: Int, seconds: Double) -> [Double] {
        let from = keyframes[index]
        let to = keyframes[index + 1]
        let span = max((to.time - from.time).seconds, 1e-9)
        let out = handles(at: index).outgoing
        let into = handles(at: index + 1).incoming
        // Influences that add up past the whole segment would make time run backwards.
        var outReach = out.influence
        var inReach = into.influence
        if outReach + inReach > 1 {
            let scale = 1 / (outReach + inReach)
            outReach *= scale
            inReach *= scale
        }
        let s = Self.solveBezier(x1: outReach, x2: 1 - inReach, x: min(max(seconds / span, 0), 1))
        return from.values.indices.map { component in
            let start = from.values[component]
            let end = component < to.values.count ? to.values[component] : start
            let outSlope = component < out.slopes.count ? out.slopes[component] : 0
            let inSlope = component < into.slopes.count ? into.slopes[component] : 0
            let p1 = start + outSlope * outReach * span
            let p2 = end - inSlope * inReach * span
            return Self.cubic(start, p1, p2, end, s)
        }
    }

    static func cubic(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ s: Double) -> Double {
        let u = 1 - s
        return u * u * u * p0 + 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s * p3
    }

    /// The curve parameter where the (monotonic) time curve 0, x1, x2, 1 reaches `x`.
    static func solveBezier(x1: Double, x2: Double, x: Double) -> Double {
        var s = x
        // Newton's method converges in a few steps on these curves; bisection catches the rest.
        for _ in 0..<8 {
            let error = cubic(0, x1, x2, 1, s) - x
            if abs(error) < 1e-9 { return s }
            let u = 1 - s
            let slope = 3 * u * u * x1 + 6 * u * s * (x2 - x1) + 3 * s * s * (1 - x2)
            guard abs(slope) > 1e-9 else { break }
            s = min(max(s - error / slope, 0), 1)
        }
        var low = 0.0
        var high = 1.0
        s = x
        for _ in 0..<60 {
            let value = cubic(0, x1, x2, 1, s)
            if abs(value - x) < 1e-10 { break }
            if value < x { low = s } else { high = s }
            s = (low + high) / 2
        }
        return s
    }

    // MARK: - Editing handles

    /// Drags a handle of keyframe `id`. Auto Bezier keyframes become Continuous Bezier, as in
    /// Premiere; a Continuous Bezier keyframe mirrors the slope on its other side unless
    /// `breaking` (⌥-drag), which makes it a plain Bezier with independent sides.
    public mutating func setHandle(_ side: HandleSide, of id: UUID, slopes: [Double], influence: Double,
                                   breaking: Bool = false) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        let current = handles(at: index)
        var key = keyframes[index]
        key.inHandle = current.incoming
        key.outHandle = current.outgoing
        let handle = BezierHandle(slopes: slopes, influence: influence)
        if side == .incoming { key.inHandle = handle } else { key.outHandle = handle }
        if breaking || key.interpolation == .bezier {
            key.interpolation = .bezier
        } else {
            key.interpolation = .continuousBezier
            if side == .incoming {
                key.outHandle?.slopes = slopes
            } else {
                key.inHandle?.slopes = slopes
            }
        }
        keyframes[index] = key
    }

    /// Changes interpolation, keeping the curve's current shape when switching to a Bezier kind
    /// with handles (so it doesn't jump).
    public mutating func setInterpolationKeepingShape(_ interpolation: KeyframeInterpolation, for ids: Set<UUID>) {
        let resolved = keyframes.indices.map { handles(at: $0) }
        for index in keyframes.indices where ids.contains(keyframes[index].id) {
            keyframes[index].interpolation = interpolation
            if interpolation == .bezier || interpolation == .continuousBezier {
                keyframes[index].inHandle = resolved[index].incoming
                keyframes[index].outHandle = interpolation == .continuousBezier
                    ? BezierHandle(slopes: resolved[index].incoming.slopes, influence: resolved[index].outgoing.influence)
                    : resolved[index].outgoing
            } else {
                keyframes[index].inHandle = nil
                keyframes[index].outHandle = nil
            }
        }
    }

    /// Sets one component of a keyframe's value (dragging a point in the graph editor).
    public mutating func setValue(_ value: Double, component: Int, of id: UUID) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }),
              component < keyframes[index].values.count else { return }
        keyframes[index].values[component] = value
    }
}
