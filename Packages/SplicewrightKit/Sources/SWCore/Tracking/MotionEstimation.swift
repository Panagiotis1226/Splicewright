import Foundation

/// A 3×3 projective transform of pixel positions; every tracking motion is a special case.
public struct Homography: Sendable, Equatable {
    /// Row-major.
    public var m: [Double]

    public static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    public init(m: [Double]) { self.m = m }

    public static func translation(_ x: Double, _ y: Double) -> Homography {
        Homography(m: [1, 0, x, 0, 1, y, 0, 0, 1])
    }

    public func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let w: Double = m[6] * x + m[7] * y + m[8]
        let scale: Double = abs(w) < 1e-12 ? 1 : 1 / w
        let px: Double = m[0] * x + m[1] * y + m[2]
        let py: Double = m[3] * x + m[4] * y + m[5]
        return (px * scale, py * scale)
    }

    /// `self` after `other`: applies `other` first.
    public func after(_ other: Homography) -> Homography {
        var result = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                var sum = 0.0
                for k in 0..<3 { sum += m[row * 3 + k] * other.m[k * 3 + column] }
                result[row * 3 + column] = sum
            }
        }
        return Homography(m: result).normalized
    }

    public var inverse: Homography? {
        let a = m
        let c0 = a[4] * a[8] - a[5] * a[7]
        let c1 = a[5] * a[6] - a[3] * a[8]
        let c2 = a[3] * a[7] - a[4] * a[6]
        let determinant = a[0] * c0 + a[1] * c1 + a[2] * c2
        guard abs(determinant) > 1e-12 else { return nil }
        let inv = [c0, a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
                   c1, a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
                   c2, a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3]]
        return Homography(m: inv.map { $0 / determinant }).normalized
    }

    var normalized: Homography {
        guard abs(m[8]) > 1e-12 else { return self }
        return Homography(m: m.map { $0 / m[8] })
    }
}

/// A point and where it went.
struct Correspondence {
    var from: (x: Double, y: Double)
    var to: (x: Double, y: Double)
}

enum MotionFit {
    /// The least-squares motion of `model` taking each `from` to its `to`.
    static func fit(_ model: TrackingSettings.Motion, _ pairs: [Correspondence]) -> Homography? {
        guard pairs.count >= model.minimumPoints else { return nil }
        let n = Double(pairs.count)
        let fx = pairs.reduce(0) { $0 + $1.from.x } / n
        let fy = pairs.reduce(0) { $0 + $1.from.y } / n
        let tx = pairs.reduce(0) { $0 + $1.to.x } / n
        let ty = pairs.reduce(0) { $0 + $1.to.y } / n
        switch model {
        case .position:
            return .translation(tx - fx, ty - fy)
        case .positionScale, .positionScaleRotation:
            var dot = 0.0, cross = 0.0, norm = 0.0
            for pair in pairs {
                let (px, py) = (pair.from.x - fx, pair.from.y - fy)
                let (qx, qy) = (pair.to.x - tx, pair.to.y - ty)
                dot += px * qx + py * qy
                cross += px * qy - py * qx
                norm += px * px + py * py
            }
            guard norm > 1e-9 else { return .translation(tx - fx, ty - fy) }
            // q − t̄ = [a −b; b a](p − f̄): a and b by least squares (b = 0 without rotation).
            let a = dot / norm
            let b = model == .positionScale ? 0 : cross / norm
            return Homography(m: [a, -b, tx - (a * fx - b * fy), b, a, ty - (b * fx + a * fy), 0, 0, 1])
        case .affine:
            return affine(pairs)
        case .perspective:
            return perspective(pairs)
        }
    }

    private static func affine(_ pairs: [Correspondence]) -> Homography? {
        var normal = [Double](repeating: 0, count: 9)
        var bx = [Double](repeating: 0, count: 3)
        var by = [Double](repeating: 0, count: 3)
        for pair in pairs {
            let row = [pair.from.x, pair.from.y, 1]
            for i in 0..<3 {
                for j in 0..<3 { normal[i * 3 + j] += row[i] * row[j] }
                bx[i] += row[i] * pair.to.x
                by[i] += row[i] * pair.to.y
            }
        }
        guard let first = LinearSolve.solve(normal, bx, size: 3), let second = LinearSolve.solve(normal, by, size: 3) else {
            return nil
        }
        return Homography(m: [first[0], first[1], first[2], second[0], second[1], second[2], 0, 0, 1])
    }

    /// Normalized DLT with h33 = 1, solved by least squares.
    private static func perspective(_ pairs: [Correspondence]) -> Homography? {
        func normalizer(_ points: [(x: Double, y: Double)]) -> Homography {
            let n = Double(points.count)
            let cx = points.reduce(0) { $0 + $1.x } / n
            let cy = points.reduce(0) { $0 + $1.y } / n
            let spread = points.reduce(0) { $0 + hypot($1.x - cx, $1.y - cy) } / n
            let scale = spread > 1e-9 ? 2.squareRoot() / spread : 1
            return Homography(m: [scale, 0, -scale * cx, 0, scale, -scale * cy, 0, 0, 1])
        }
        let fromNorm = normalizer(pairs.map(\.from))
        let toNorm = normalizer(pairs.map(\.to))
        var normal = [Double](repeating: 0, count: 64)
        var rhs = [Double](repeating: 0, count: 8)
        for pair in pairs {
            let (x, y) = fromNorm.apply(pair.from.x, pair.from.y)
            let (u, v) = toNorm.apply(pair.to.x, pair.to.y)
            let rows: [([Double], Double)] = [([x, y, 1, 0, 0, 0, -u * x, -u * y], u),
                                              ([0, 0, 0, x, y, 1, -v * x, -v * y], v)]
            for (row, target) in rows {
                for i in 0..<8 {
                    for j in 0..<8 { normal[i * 8 + j] += row[i] * row[j] }
                    rhs[i] += row[i] * target
                }
            }
        }
        guard let h = LinearSolve.solve(normal, rhs, size: 8),
              let undo = toNorm.inverse else { return nil }
        return undo.after(Homography(m: h + [1])).after(fromNorm)
    }

    /// RANSAC: the motion most point pairs agree on within `threshold` pixels, refit on those.
    /// Returns the motion and which pairs agreed.
    static func robust(_ model: TrackingSettings.Motion, _ pairs: [Correspondence],
                       threshold: Double) -> (motion: Homography, inliers: [Bool])? {
        let sample = model.minimumPoints
        guard pairs.count >= sample else { return nil }
        var generator = SeededGenerator(seed: UInt64(pairs.count) &* 2_654_435_761)
        var best: [Bool] = []
        var bestCount = 0
        let iterations = pairs.count == sample ? 1 : 200
        for _ in 0..<iterations {
            var picked = Set<Int>()
            while picked.count < sample { picked.insert(Int.random(in: 0..<pairs.count, using: &generator)) }
            guard let candidate = fit(model, picked.map { pairs[$0] }) else { continue }
            let agrees = pairs.map { error(candidate, $0) <= threshold }
            let count = agrees.filter { $0 }.count
            if count > bestCount {
                bestCount = count
                best = agrees
                if count == pairs.count { break }
            }
        }
        guard bestCount >= sample else { return nil }
        let inlierPairs = zip(pairs, best).filter(\.1).map(\.0)
        guard let refined = fit(model, inlierPairs) else { return nil }
        // One more pass with the refined motion's own inliers.
        let final = pairs.map { error(refined, $0) <= threshold }
        let finalPairs = zip(pairs, final).filter(\.1).map(\.0)
        guard finalPairs.count >= sample, let motion = fit(model, finalPairs) else { return (refined, best) }
        return (motion, final)
    }

    static func error(_ motion: Homography, _ pair: Correspondence) -> Double {
        let mapped = motion.apply(pair.from.x, pair.from.y)
        return hypot(mapped.x - pair.to.x, mapped.y - pair.to.y)
    }
}

/// Gaussian elimination with partial pivoting on a small dense system (row-major `matrix`).
enum LinearSolve {
    static func solve(_ matrix: [Double], _ rhs: [Double], size n: Int) -> [Double]? {
        var a = matrix
        var b = rhs
        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<max(n, column + 1) where abs(a[row * n + column]) > abs(a[pivot * n + column]) {
                pivot = row
            }
            guard abs(a[pivot * n + column]) > 1e-12 else { return nil }
            if pivot != column {
                for k in 0..<n { a.swapAt(column * n + k, pivot * n + k) }
                b.swapAt(column, pivot)
            }
            for row in (column + 1)..<max(n, column + 1) {
                let factor = a[row * n + column] / a[column * n + column]
                guard factor != 0 else { continue }
                for k in column..<n { a[row * n + k] -= factor * a[column * n + k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<max(n, row + 1) { sum -= a[row * n + k] * x[k] }
            x[row] = sum / a[row * n + row]
        }
        return x
    }
}

/// A small deterministic random source, so the same clip always tracks the same way.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
