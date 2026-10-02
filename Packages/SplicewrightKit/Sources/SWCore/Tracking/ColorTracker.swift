import Foundation

/// Color tracking: learns which colors belong to the mask's object rather than the background
/// around it, then follows the blob of those colors with mean shift (as CAMShift does), its
/// size from the blob's spread and its turn from the blob's axis.
enum ColorTracker {
    static let bins = 16

    struct Model {
        /// Chance each (Cb, Cr) bin belongs to the object, 0...1.
        var likelihood: [Float]
        var center: (x: Double, y: Double)
        var halfWidth: Double
        var halfHeight: Double
        /// Mean likelihood inside the window at the start, for spotting a lost object.
        var density: Double
        var spread: Double
        var angle: Double
        var isElongated: Bool
    }

    struct State {
        var center: (x: Double, y: Double)
        var scale: Double
        var angle: Double
    }

    @inline(__always) static func bin(_ cb: Float, _ cr: Float) -> Int {
        let b = min(max(Int(cb * Float(bins)), 0), bins - 1)
        let r = min(max(Int(cr * Float(bins)), 0), bins - 1)
        return b * bins + r
    }

    static func model(from image: TrackingImage, outline: Outline) -> Model? {
        var object = [Double](repeating: 0, count: bins * bins)
        var background = object
        let halfWidth = max((outline.maxX - outline.minX) / 2, 4)
        let halfHeight = max((outline.maxY - outline.minY) / 2, 4)
        let step = max(1, Int((halfWidth * halfHeight / 2000).squareRoot()))
        // The object is inside the mask; the background is a band around it twice as wide.
        let x0 = max(0, Int(outline.centerX - 2 * halfWidth))
        let x1 = min(image.width - 1, Int(outline.centerX + 2 * halfWidth))
        let y0 = max(0, Int(outline.centerY - 2 * halfHeight))
        let y1 = min(image.height - 1, Int(outline.centerY + 2 * halfHeight))
        guard x0 < x1, y0 < y1 else { return nil }
        for y in stride(from: y0, through: y1, by: step) {
            for x in stride(from: x0, through: x1, by: step) {
                let index = bin(image.cb.values[y * image.width + x], image.cr.values[y * image.width + x])
                if outline.contains(Double(x), Double(y)) { object[index] += 1 } else { background[index] += 1 }
            }
        }
        let objectTotal = max(object.reduce(0, +), 1)
        let backgroundTotal = max(background.reduce(0, +), 1)
        let likelihood = zip(object, background).map { o, b -> Float in
            let po = o / objectTotal
            let pb = b / backgroundTotal
            return po + pb > 0 ? Float(po / (po + pb)) : 0
        }
        var model = Model(likelihood: likelihood, center: (outline.centerX, outline.centerY), halfWidth: halfWidth,
                          halfHeight: halfHeight, density: 0, spread: 0, angle: 0, isElongated: false)
        let moments = Moments(model, image: image, center: model.center, scale: 1)
        guard moments.mass > 1e-6 else { return nil }
        model.center = (moments.meanX, moments.meanY)
        let settled = Moments(model, image: image, center: model.center, scale: 1)
        model.density = settled.density
        model.spread = settled.spread
        model.angle = settled.angle
        model.isElongated = settled.elongation > 1.5
        return model
    }

    /// Follows the blob into `image` from the last state. Returns the new state and how sure (0...1).
    static func track(_ model: Model, image: TrackingImage, from state: State,
                      motion: TrackingSettings.Motion) -> (state: State, confidence: Double) {
        var center = state.center
        var scale = state.scale
        for _ in 0..<20 {
            let moments = Moments(model, image: image, center: center, scale: scale)
            guard moments.mass > 1e-6 else { return (state, 0) }
            let shift = hypot(moments.meanX - center.x, moments.meanY - center.y)
            center = (moments.meanX, moments.meanY)
            if motion != .position, model.spread > 1e-6 {
                let measured = (moments.spread / model.spread).squareRoot()
                scale = min(max(measured, state.scale * 0.9), state.scale * 1.12)
            }
            if shift < 0.3 { break }
        }
        let settled = Moments(model, image: image, center: center, scale: scale)
        var angle = state.angle
        if motion == .positionScaleRotation, model.isElongated, settled.elongation > 1.3 {
            var turn = settled.angle - model.angle
            while turn > .pi / 2 { turn -= .pi }
            while turn < -.pi / 2 { turn += .pi }
            angle = turn
        }
        let confidence = model.density > 1e-9 ? min(1, settled.density / model.density) : 0
        return (State(center: center, scale: scale, angle: angle), confidence)
    }

    /// The motion from the start (model) to `state`.
    static func motion(_ model: Model, _ state: State) -> Homography {
        let (c, s) = (cos(state.angle) * state.scale, sin(state.angle) * state.scale)
        let (fx, fy) = model.center
        return Homography(m: [c, -s, state.center.x - (c * fx - s * fy), s, c, state.center.y - (s * fx + c * fy),
                              0, 0, 1])
    }

    /// Likelihood-weighted moments inside an elliptical window.
    struct Moments {
        var mass = 0.0
        var meanX = 0.0
        var meanY = 0.0
        var density = 0.0
        var spread = 0.0
        var angle = 0.0
        var elongation = 1.0

        init(_ model: Model, image: TrackingImage, center: (x: Double, y: Double), scale: Double) {
            // A window a little larger than the object, so its edges count.
            let rx = model.halfWidth * scale * 1.25
            let ry = model.halfHeight * scale * 1.25
            let step = max(1, Int((rx * ry / 3000).squareRoot()))
            let x0 = max(0, Int(center.x - rx))
            let x1 = min(image.width - 1, Int(center.x + rx))
            let y0 = max(0, Int(center.y - ry))
            let y1 = min(image.height - 1, Int(center.y + ry))
            guard x0 <= x1, y0 <= y1 else { return }
            var m00 = 0.0, m10 = 0.0, m01 = 0.0, m20 = 0.0, m02 = 0.0, m11 = 0.0, area = 0.0
            for y in stride(from: y0, through: y1, by: step) {
                let dy = (Double(y) - center.y) / ry
                for x in stride(from: x0, through: x1, by: step) {
                    let dx = (Double(x) - center.x) / rx
                    guard dx * dx + dy * dy <= 1 else { continue }
                    area += 1
                    let index = y * image.width + x
                    let w = Double(model.likelihood[bin(image.cb.values[index], image.cr.values[index])])
                    guard w > 0 else { continue }
                    let (px, py) = (Double(x), Double(y))
                    m00 += w
                    m10 += w * px
                    m01 += w * py
                    m20 += w * px * px
                    m02 += w * py * py
                    m11 += w * px * py
                }
            }
            guard m00 > 1e-9, area > 0 else { return }
            mass = m00
            meanX = m10 / m00
            meanY = m01 / m00
            density = m00 / area
            let mu20 = m20 / m00 - meanX * meanX
            let mu02 = m02 / m00 - meanY * meanY
            let mu11 = m11 / m00 - meanX * meanY
            spread = max(mu20 + mu02, 0)
            angle = 0.5 * atan2(2 * mu11, mu20 - mu02)
            let root = (((mu20 - mu02) / 2) * ((mu20 - mu02) / 2) + mu11 * mu11).squareRoot()
            let major = (mu20 + mu02) / 2 + root
            let minor = max((mu20 + mu02) / 2 - root, 1e-9)
            elongation = (major / minor).squareRoot()
        }
    }
}
