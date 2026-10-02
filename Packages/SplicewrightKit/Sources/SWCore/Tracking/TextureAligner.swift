import Foundation

/// Whole-area tracking: finds the motion that makes the mask's area in the reference frame
/// best match the new frame, pixel for pixel (Gauss–Newton, coarse to fine), allowing for the
/// light getting brighter or darker.
enum TextureAligner {
    /// The reference area: sample positions (normalized around its center) and their values per level.
    struct Template {
        var samples: [(x: Double, y: Double)]
        var values: [[Float]]
        var centerX: Double
        var centerY: Double
        var radius: Double

        /// Level-0 pixels → normalized coordinates (and back), so the motion's numbers are well scaled.
        var normalizer: Homography {
            Homography(m: [1 / radius, 0, -centerX / radius, 0, 1 / radius, -centerY / radius, 0, 0, 1])
        }
    }

    static func template(from image: TrackingImage, outline: Outline, levels: Int) -> Template? {
        let width = Double(outline.maxX - outline.minX)
        let height = Double(outline.maxY - outline.minY)
        let area = max(width * height, 1)
        let step = max(1, Int((area / 3000).squareRoot().rounded(.up)))
        let pixels = outline.pixels(step: step, width: image.width, height: image.height)
        guard pixels.count >= 30 else { return nil }
        let radius = max(width, height, 8) / 2
        let (cx, cy) = (outline.centerX, outline.centerY)
        let samples = pixels.map { ((Double($0.x) - cx) / radius, (Double($0.y) - cy) / radius) }
        let used = max(1, min(levels, image.levels.count))
        let values = (0..<used).map { level -> [Float] in
            let scale = Double(1 << level)
            let plane = image.levels[level].image
            return samples.map { plane.sample((cx + radius * $0.0) / scale, (cy + radius * $0.1) / scale) }
        }
        return Template(samples: samples, values: values, centerX: cx, centerY: cy, radius: radius)
    }

    /// The motion (reference pixels → `image` pixels) and how well the area matches (0...1),
    /// starting from `initial`.
    static func align(_ template: Template, in image: TrackingImage, model: TrackingSettings.Motion,
                      initial: Homography, levels: Int) -> (motion: Homography, match: Double)? {
        let normalize = template.normalizer
        guard let denormalize = normalize.inverse else { return nil }
        var params = Parameters.from(normalize.after(initial).after(denormalize), model: model)
        let used = max(1, min(levels, image.levels.count, template.values.count))
        for level in stride(from: used - 1, through: 0, by: -1) {
            params = refine(params, template: template, level: level, image: image, model: model)
        }
        let warp = Parameters.matrix(params, model: model)
        let motion = denormalize.after(warp).after(normalize)
        let match = similarity(template, image: image, warp: warp, level: 0)
        guard motion.m.allSatisfy(\.isFinite) else { return nil }
        return (motion, match)
    }

    private static func position(_ warp: Homography, _ sample: (x: Double, y: Double), template: Template,
                                 scale: Double) -> (x: Double, y: Double) {
        let n = warp.apply(sample.x, sample.y)
        return ((template.centerX + template.radius * n.x) / scale, (template.centerY + template.radius * n.y) / scale)
    }

    private static func refine(_ start: [Double], template: Template, level: Int, image: TrackingImage,
                               model: TrackingSettings.Motion) -> [Double] {
        let scale = Double(1 << level)
        let plane = image.levels[level]
        let reference = template.values[level]
        var params = start
        let count = params.count
        for _ in 0..<15 {
            let warp = Parameters.matrix(params, model: model)
            var warped = [Float](repeating: 0, count: template.samples.count)
            for (index, sample) in template.samples.enumerated() {
                let at = position(warp, sample, template: template, scale: scale)
                warped[index] = plane.image.sample(at.x, at.y)
            }
            // Brightness: fit warped ≈ gain × reference + offset, then match the rest.
            let (gain, offset) = lightFit(reference, warped)
            var normal = [Double](repeating: 0, count: count * count)
            var rhs = [Double](repeating: 0, count: count)
            let epsilon = 1e-4
            let nudged = (0..<count).map { j -> Homography in
                var p = params
                p[j] += epsilon
                return Parameters.matrix(p, model: model)
            }
            for (index, sample) in template.samples.enumerated() {
                let at = position(warp, sample, template: template, scale: scale)
                let gx = Double(plane.gx.sample(at.x, at.y))
                let gy = Double(plane.gy.sample(at.x, at.y))
                guard gx != 0 || gy != 0 else { continue }
                let residual = Double(warped[index]) - (gain * Double(reference[index]) + offset)
                var row = [Double](repeating: 0, count: count)
                for j in 0..<count {
                    let moved = position(nudged[j], sample, template: template, scale: scale)
                    row[j] = (gx * (moved.x - at.x) + gy * (moved.y - at.y)) / epsilon
                }
                for i in 0..<count {
                    for j in 0..<count { normal[i * count + j] += row[i] * row[j] }
                    rhs[i] -= row[i] * residual
                }
            }
            // A little damping keeps a flat area from sending the motion flying.
            let trace = (0..<count).reduce(0) { $0 + normal[$1 * count + $1] }
            for i in 0..<count { normal[i * count + i] += 1e-6 * trace + 1e-12 }
            guard let step = LinearSolve.solve(normal, rhs, size: count), step.allSatisfy(\.isFinite) else { break }
            for j in 0..<count { params[j] += step[j] }
            if step.reduce(0, { $0 + $1 * $1 }) < 1e-10 { break }
        }
        return params
    }

    /// Least-squares gain and offset taking `reference` to `warped`.
    static func lightFit(_ reference: [Float], _ warped: [Float]) -> (gain: Double, offset: Double) {
        let n = Double(reference.count)
        guard n > 1 else { return (1, 0) }
        let meanR = reference.reduce(0) { $0 + Double($1) } / n
        let meanW = warped.reduce(0) { $0 + Double($1) } / n
        var covariance = 0.0, variance = 0.0
        for (r, w) in zip(reference, warped) {
            covariance += (Double(r) - meanR) * (Double(w) - meanW)
            variance += (Double(r) - meanR) * (Double(r) - meanR)
        }
        let gain = variance > 1e-9 ? min(max(covariance / variance, 0.5), 2) : 1
        return (gain, meanW - gain * meanR)
    }

    /// Zero-mean normalized cross-correlation of the area and where the motion puts it, 0...1.
    static func similarity(_ template: Template, image: TrackingImage, warp: Homography, level: Int) -> Double {
        let scale = Double(1 << level)
        let plane = image.levels[level].image
        let reference = template.values[level]
        let warped = template.samples.map { sample -> Float in
            let at = position(warp, sample, template: template, scale: scale)
            return plane.sample(at.x, at.y)
        }
        let n = Double(reference.count)
        let meanR = reference.reduce(0) { $0 + Double($1) } / n
        let meanW = warped.reduce(0) { $0 + Double($1) } / n
        var covariance = 0.0, varR = 0.0, varW = 0.0
        for (r, w) in zip(reference, warped) {
            covariance += (Double(r) - meanR) * (Double(w) - meanW)
            varR += (Double(r) - meanR) * (Double(r) - meanR)
            varW += (Double(w) - meanW) * (Double(w) - meanW)
        }
        guard varR > 1e-9, varW > 1e-9 else { return 0 }
        return max(0, covariance / (varR * varW).squareRoot())
    }
}

/// A motion's free numbers, for each kind of motion.
enum Parameters {
    static func from(_ h: Homography, model: TrackingSettings.Motion) -> [Double] {
        let m = h.normalized.m
        switch model {
        case .position: return [m[2], m[5]]
        case .positionScale: return [(m[0] + m[4]) / 2, m[2], m[5]]
        case .positionScaleRotation: return [(m[0] + m[4]) / 2, (m[3] - m[1]) / 2, m[2], m[5]]
        case .affine: return [m[0], m[1], m[2], m[3], m[4], m[5]]
        case .perspective: return Array(m[0..<8])
        }
    }

    static func matrix(_ p: [Double], model: TrackingSettings.Motion) -> Homography {
        switch model {
        case .position: return .translation(p[0], p[1])
        case .positionScale: return Homography(m: [p[0], 0, p[1], 0, p[0], p[2], 0, 0, 1])
        case .positionScaleRotation: return Homography(m: [p[0], -p[1], p[2], p[1], p[0], p[3], 0, 0, 1])
        case .affine: return Homography(m: [p[0], p[1], p[2], p[3], p[4], p[5], 0, 0, 1])
        case .perspective: return Homography(m: p + [1])
        }
    }
}
