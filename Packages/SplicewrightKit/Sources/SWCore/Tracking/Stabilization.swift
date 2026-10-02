import Foundation

/// How the Stabilizer smooths a shot.
public struct StabilizationSettings: Sendable, Hashable, Codable {
    public enum Result: String, Sendable, Hashable, Codable, CaseIterable {
        /// Keeps the camera's intended moves, minus the shake.
        case smoothMotion
        /// Holds the camera still, as on a tripod.
        case noMotion

        public var displayName: String { self == .smoothMotion ? "Smooth Motion" : "No Motion" }
    }

    public enum Method: String, Sendable, Hashable, Codable, CaseIterable {
        case position
        case positionScaleRotation

        public var displayName: String { self == .position ? "Position" : "Position, Scale & Rotation" }

        var motion: TrackingSettings.Motion { self == .position ? .position : .positionScaleRotation }
    }

    public enum Framing: String, Sendable, Hashable, Codable, CaseIterable {
        /// Moves the picture only; its edges show where it moved.
        case stabilizeOnly
        /// Zooms in just enough that no edge ever shows.
        case autoScale

        public var displayName: String { self == .stabilizeOnly ? "Stabilize Only" : "Stabilize, Crop & Auto-Scale" }
    }

    public var result: Result = .smoothMotion
    public var method: Method = .positionScaleRotation
    public var framing: Framing = .autoScale
    /// 0...100: how much of the camera's motion counts as shake.
    public var smoothness = 50.0
    /// The most Auto-Scale may zoom (100...200 %).
    public var maximumScale = 150.0

    public init() {}
}

/// A stabilized shot: the camera's path through the analysed frames, and the correction that
/// smooths it. In the picture's own pixels as shown (`pictureWidth` × `pictureHeight`).
public struct StabilizationData: Sendable, Hashable, Codable {
    public var settings = StabilizationSettings()
    public var pictureWidth: Double
    public var pictureHeight: Double
    /// Source times (seconds) of the analysed frames, in order.
    public var times: [Double] = []
    /// Where the first frame's content is on each frame: a, b, c, d, tx, ty.
    public var path: [[Double]] = []
    /// What each frame is moved by, the same way, before the zoom.
    public var corrections: [[Double]] = []
    /// The Auto-Scale zoom (1 = none).
    public var zoom = 1.0
    /// Analysis ran to the end (false while it's running or if it was stopped).
    public var isComplete = false

    public init(pictureWidth: Double, pictureHeight: Double) {
        self.pictureWidth = pictureWidth
        self.pictureHeight = pictureHeight
    }

    public var frameCount: Int { times.count }

    /// Recomputes the corrections and zoom from the path and settings.
    public mutating func update() {
        guard !path.isEmpty else {
            corrections = []
            zoom = 1
            return
        }
        let cameras = path.map(Self.affine)
        let center = (pictureWidth / 2, pictureHeight / 2)
        let targets: [Affine2D]
        switch settings.result {
        case .noMotion:
            targets = cameras.map { _ in .identity }
        case .smoothMotion:
            targets = Self.smoothed(cameras, center: center, times: times, smoothness: settings.smoothness)
        }
        let fixes = zip(cameras, targets).map { camera, target in (camera.inverted ?? .identity).concatenating(target) }
        corrections = fixes.map(Self.numbers)
        zoom = settings.framing == .autoScale ? Self.coveringZoom(fixes, width: pictureWidth, height: pictureHeight,
                                                                  limit: settings.maximumScale / 100) : 1
    }

    /// The correction at a source time (picture pixels → picture pixels), zoom included.
    public func correction(at seconds: Double) -> Affine2D? {
        guard !corrections.isEmpty, corrections.count == times.count else { return nil }
        let index = times.firstIndex { $0 >= seconds } ?? times.count - 1
        let fix: Affine2D
        if index == 0 || times[index] <= seconds {
            fix = Self.affine(corrections[index])
        } else {
            let span = max(times[index] - times[index - 1], 1e-9)
            let t = min(max((seconds - times[index - 1]) / span, 0), 1)
            let mixed = zip(corrections[index - 1], corrections[index]).map { $0 + ($1 - $0) * t }
            fix = Self.affine(mixed)
        }
        let center = (pictureWidth / 2, pictureHeight / 2)
        let scale = Affine2D.translation(-center.0, -center.1).concatenating(.scale(zoom, zoom))
            .concatenating(.translation(center.0, center.1))
        return fix.concatenating(scale)
    }

    // MARK: - Smoothing

    static func affine(_ n: [Double]) -> Affine2D {
        n.count == 6 ? Affine2D(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]) : .identity
    }

    static func numbers(_ t: Affine2D) -> [Double] { [t.a, t.b, t.c, t.d, t.tx, t.ty] }

    /// A camera as position (of the picture's center), turn and log zoom, so each can be averaged.
    private static func decompose(_ t: Affine2D, center: (Double, Double)) -> [Double] {
        let moved = t.apply(x: center.0, y: center.1)
        let angle = atan2(t.b, t.a)
        let scale = max(hypot(t.a, t.b), 1e-6)
        return [moved.x - center.0, moved.y - center.1, angle, log(scale)]
    }

    private static func compose(_ p: [Double], center: (Double, Double)) -> Affine2D {
        let scale = exp(p[3])
        let (cosine, sine) = (cos(p[2]) * scale, sin(p[2]) * scale)
        // Turn and zoom about the center, then move.
        let linear = Affine2D(a: cosine, b: sine, c: -sine, d: cosine, tx: 0, ty: 0)
        return Affine2D.translation(-center.0, -center.1).concatenating(linear)
            .concatenating(.translation(center.0 + p[0], center.1 + p[1]))
    }

    /// The camera path with its shake removed: at each frame, a straight line fitted to the path
    /// nearby, weighted by a Gaussian over time (wider with more smoothness, up to about two
    /// seconds either side). A line, not a plain average, so steady pans survive up to the
    /// clip's ends.
    static func smoothed(_ cameras: [Affine2D], center: (Double, Double), times: [Double],
                         smoothness: Double) -> [Affine2D] {
        let parts = cameras.map { decompose($0, center: center) }
        // Unwrap the turn so averaging doesn't jump at ±180°.
        var unwrapped = parts
        for index in unwrapped.indices.dropFirst() {
            var angle = unwrapped[index][2]
            while angle - unwrapped[index - 1][2] > .pi { angle -= 2 * .pi }
            while angle - unwrapped[index - 1][2] < -.pi { angle += 2 * .pi }
            unwrapped[index][2] = angle
        }
        let sigma = 0.05 + min(max(smoothness, 0), 100) / 100 * 0.95
        return unwrapped.indices.map { index in
            // Weighted least squares of value = level + slope × (time − this time); keep the level.
            var (sw, st, stt) = (0.0, 0.0, 0.0)
            var sy = [0.0, 0, 0, 0]
            var sty = [0.0, 0, 0, 0]
            for other in unwrapped.indices where abs(times[other] - times[index]) <= 3 * sigma {
                let dt = times[other] - times[index]
                let weight = exp(-0.5 * dt * dt / (sigma * sigma))
                sw += weight
                st += weight * dt
                stt += weight * dt * dt
                for k in 0..<4 {
                    sy[k] += weight * unwrapped[other][k]
                    sty[k] += weight * dt * unwrapped[other][k]
                }
            }
            let determinant = sw * stt - st * st
            let level = (0..<4).map { k -> Double in
                guard abs(determinant) > 1e-12 else { return sy[k] / max(sw, 1e-12) }
                return (stt * sy[k] - st * sty[k]) / determinant
            }
            return compose(level, center: center)
        }
    }

    /// The smallest zoom (up to `limit`) that keeps every corrected frame covering the picture.
    static func coveringZoom(_ fixes: [Affine2D], width: Double, height: Double, limit: Double) -> Double {
        let corners = [(0.0, 0.0), (width, 0), (width, height), (0, height)]
        func covers(_ fix: Affine2D, zoom: Double) -> Bool {
            let scale = Affine2D.translation(-width / 2, -height / 2).concatenating(.scale(zoom, zoom))
                .concatenating(.translation(width / 2, height / 2))
            guard let back = fix.concatenating(scale).inverted else { return false }
            // Each corner of the frame must show a point of the picture.
            return corners.allSatisfy { corner in
                let source = back.apply(x: corner.0, y: corner.1)
                return source.x >= -0.5 && source.y >= -0.5 && source.x <= width + 0.5 && source.y <= height + 0.5
            }
        }
        var needed = 1.0
        for fix in fixes where !covers(fix, zoom: needed) {
            var (low, high) = (needed, max(limit, 1))
            guard covers(fix, zoom: high) else {
                needed = high
                continue
            }
            for _ in 0..<30 {
                let middle = (low + high) / 2
                if covers(fix, zoom: middle) { high = middle } else { low = middle }
            }
            needed = high
        }
        return min(needed, max(limit, 1))
    }
}

public extension Affine2D {
    var inverted: Affine2D? {
        let determinant = a * d - b * c
        guard abs(determinant) > 1e-12 else { return nil }
        let ia = d / determinant
        let ib = -b / determinant
        let ic = -c / determinant
        let id = a / determinant
        return Affine2D(a: ia, b: ib, c: ic, d: id, tx: -(ia * tx + ic * ty), ty: -(ib * tx + id * ty))
    }
}

/// Measures a shot's camera motion frame by frame: corners over the whole picture, followed with
/// optical flow, and the motion most of them agree on (so a person walking through doesn't count).
public final class StabilizationAnalyzer: @unchecked Sendable {
    private let method: StabilizationSettings.Method
    private var previous: TrackingImage
    private var camera = Homography.identity
    private var lastStep = Homography.identity
    private let scale: Double

    /// `pictureWidth` is the full picture's width the path is kept in (frames may be smaller).
    public init(first: TrackingImage, method: StabilizationSettings.Method, pictureWidth: Double) {
        self.method = method
        previous = first
        scale = pictureWidth / Double(max(first.width, 1))
    }

    /// The camera on this frame (the first frame's content → here, in picture pixels) and the
    /// share of points that agreed (0 where the frame couldn't be matched; the motion is then
    /// predicted).
    public func add(_ image: TrackingImage) -> (camera: Affine2D, confidence: Double) {
        let frame = Outline([Mask.Vertex(x: 0.02, y: 0.02), Mask.Vertex(x: 0.98, y: 0.02),
                             Mask.Vertex(x: 0.98, y: 0.98), Mask.Vertex(x: 0.02, y: 0.98)],
                            width: previous.width, height: previous.height)
        let corners = PointTracker.corners(in: previous, outline: frame, maximum: 400, spacing: 12)
        let guesses = corners.map { lastStep.apply($0.x, $0.y) }
        let found = PointTracker.trackChecked(corners, guesses: guesses, from: previous, to: image, levels: 4)
        let pairs = zip(corners, found).compactMap { from, to in to.map { Correspondence(from: from, to: $0) } }
        var confidence = 0.0
        let threshold = max(1, 1.5 * Double(max(image.width, image.height)) / 960)
        if let (step, inliers) = MotionFit.robust(method.motion, pairs, threshold: threshold) {
            lastStep = step
            confidence = Double(inliers.filter { $0 }.count) / Double(max(corners.count, 1))
        }
        camera = lastStep.after(camera)
        previous = image
        return (affine(camera), confidence)
    }

    /// Analysis pixels → picture pixels.
    private func affine(_ h: Homography) -> Affine2D {
        let m = h.normalized.m
        // Linear part keeps its value; the move scales with the picture.
        return Affine2D(a: m[0], b: m[3], c: m[1], d: m[4], tx: m[2] * scale, ty: m[5] * scale)
    }
}
