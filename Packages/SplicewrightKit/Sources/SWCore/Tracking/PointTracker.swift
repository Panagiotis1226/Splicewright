import Foundation

/// Corner points and pyramidal Lucas–Kanade optical flow (Shi–Tomasi corners, Bouguet's
/// coarse-to-fine scheme, a forward–backward check to drop points that slid off their detail).
enum PointTracker {
    /// Half the size of the square patch each point is matched with (15 × 15).
    static let window = 7

    /// The strongest corners inside `outline`, at least `spacing` pixels apart.
    static func corners(in image: TrackingImage, outline: Outline, maximum: Int = 300,
                        spacing: Double = 6) -> [(x: Double, y: Double)] {
        guard let level = image.levels.first else { return [] }
        let (width, height) = (level.image.width, level.image.height)
        // Integral images of the structure tensor's terms, for 7 × 7 window sums.
        let side = width + 1
        var sxx = [Double](repeating: 0, count: side * (height + 1))
        var sxy = sxx
        var syy = sxx
        for y in 0..<height {
            var rowXX = 0.0, rowXY = 0.0, rowYY = 0.0
            for x in 0..<width {
                let gx = Double(level.gx.values[y * width + x])
                let gy = Double(level.gy.values[y * width + x])
                rowXX += gx * gx
                rowXY += gx * gy
                rowYY += gy * gy
                let index = (y + 1) * side + x + 1
                sxx[index] = sxx[index - side] + rowXX
                sxy[index] = sxy[index - side] + rowXY
                syy[index] = syy[index - side] + rowYY
            }
        }
        func box(_ table: [Double], _ x: Int, _ y: Int, _ r: Int) -> Double {
            let (x0, y0, x1, y1) = (x - r, y - r, x + r + 1, y + r + 1)
            return table[y1 * side + x1] - table[y0 * side + x1] - table[y1 * side + x0] + table[y0 * side + x0]
        }
        let margin = window + 2
        var candidates: [(score: Double, x: Int, y: Int)] = []
        for pixel in outline.pixels(step: 2, width: width, height: height)
        where pixel.x >= margin && pixel.y >= margin && pixel.x < width - margin && pixel.y < height - margin {
            let a = box(sxx, pixel.x, pixel.y, 3)
            let b = box(sxy, pixel.x, pixel.y, 3)
            let c = box(syy, pixel.x, pixel.y, 3)
            let smallest = (a + c) / 2 - (((a - c) / 2) * ((a - c) / 2) + b * b).squareRoot()
            if smallest > 1e-4 { candidates.append((smallest, pixel.x, pixel.y)) }
        }
        guard let strongest = candidates.map(\.score).max() else { return [] }
        candidates = candidates.filter { $0.score >= strongest * 0.02 }.sorted { $0.score > $1.score }
        // Keep corners apart, so a few strong details don't take every point.
        var taken = Set<Int>()
        let cell = max(1, Int(spacing))
        let columns = width / cell + 1
        var result: [(x: Double, y: Double)] = []
        for candidate in candidates {
            let key = (candidate.y / cell) * columns + candidate.x / cell
            guard !taken.contains(key) else { continue }
            taken.insert(key)
            result.append((Double(candidate.x), Double(candidate.y)))
            if result.count >= maximum { break }
        }
        return result
    }

    /// Where each point of `from` went in `to`, starting from `guesses` (same count), or nil
    /// where it couldn't be followed.
    static func track(_ points: [(x: Double, y: Double)], guesses: [(x: Double, y: Double)], from: TrackingImage,
                      to: TrackingImage, levels: Int) -> [(x: Double, y: Double)?] {
        let used = max(1, min(levels, from.levels.count, to.levels.count))
        return zip(points, guesses).map { point, guess in
            follow(point, guess: guess, from: from, to: to, levels: used)
        }
    }

    /// `track`, then back again: points that don't return within `tolerance` pixels are dropped.
    static func trackChecked(_ points: [(x: Double, y: Double)], guesses: [(x: Double, y: Double)],
                             from: TrackingImage, to: TrackingImage, levels: Int,
                             tolerance: Double = 1) -> [(x: Double, y: Double)?] {
        let forward = track(points, guesses: guesses, from: from, to: to, levels: levels)
        return forward.indices.map { index in
            guard let ahead = forward[index] else { return nil }
            let back = follow(ahead, guess: points[index], from: to, to: from,
                              levels: max(1, min(2, levels, from.levels.count)))
            guard let back, hypot(back.x - points[index].x, back.y - points[index].y) <= tolerance else { return nil }
            return ahead
        }
    }

    private static func follow(_ point: (x: Double, y: Double), guess: (x: Double, y: Double), from: TrackingImage,
                               to: TrackingImage, levels: Int) -> (x: Double, y: Double)? {
        var dx = guess.x - point.x
        var dy = guess.y - point.y
        for level in stride(from: levels - 1, through: 0, by: -1) {
            let scale = Double(1 << level)
            let a = from.levels[level]
            let b = to.levels[level]
            let px = point.x / scale
            let py = point.y / scale
            // The patch around the point in the first image, and its 2 × 2 gradient matrix.
            var template: [Float] = []
            var gxs: [Float] = []
            var gys: [Float] = []
            var g11 = 0.0, g12 = 0.0, g22 = 0.0
            for oy in -window...window {
                for ox in -window...window {
                    let x = px + Double(ox)
                    let y = py + Double(oy)
                    let gx = a.gx.sample(x, y)
                    let gy = a.gy.sample(x, y)
                    template.append(a.image.sample(x, y))
                    gxs.append(gx)
                    gys.append(gy)
                    g11 += Double(gx * gx)
                    g12 += Double(gx * gy)
                    g22 += Double(gy * gy)
                }
            }
            let determinant = g11 * g22 - g12 * g12
            let smallest = (g11 + g22) / 2 - (((g11 - g22) / 2) * ((g11 - g22) / 2) + g12 * g12).squareRoot()
            guard determinant > 1e-12, smallest / Double(template.count) > 1e-6 else { return nil }
            var vx = dx / scale
            var vy = dy / scale
            for _ in 0..<20 {
                var b1 = 0.0, b2 = 0.0
                var index = 0
                for oy in -window...window {
                    for ox in -window...window {
                        let difference = Double(template[index]
                            - b.image.sample(px + vx + Double(ox), py + vy + Double(oy)))
                        b1 += difference * Double(gxs[index])
                        b2 += difference * Double(gys[index])
                        index += 1
                    }
                }
                let ex = (g22 * b1 - g12 * b2) / determinant
                let ey = (g11 * b2 - g12 * b1) / determinant
                vx += ex
                vy += ey
                if ex * ex + ey * ey < 1e-4 { break }
            }
            dx = vx * scale
            dy = vy * scale
        }
        let x = point.x + dx
        let y = point.y + dy
        guard x >= 0, y >= 0, x <= Double(to.width - 1), y <= Double(to.height - 1), x.isFinite, y.isFinite else {
            return nil
        }
        return (x, y)
    }
}
