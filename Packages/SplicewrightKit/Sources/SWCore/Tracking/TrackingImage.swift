import Foundation

/// One plane of floats (0...1), row-major, top row first.
public struct Plane: Sendable {
    public let width: Int
    public let height: Int
    public var values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        self.width = width
        self.height = height
        self.values = values
    }

    init(width: Int, height: Int, fill: Float = 0) {
        self.init(width: width, height: height, values: [Float](repeating: fill, count: width * height))
    }

    @inline(__always) func at(_ x: Int, _ y: Int) -> Float {
        values[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
    }

    /// Bilinear sample at a pixel position (pixel centers at integers), clamped to the edges.
    @inline(__always) func sample(_ x: Double, _ y: Double) -> Float {
        let fx = min(max(x, 0), Double(width - 1))
        let fy = min(max(y, 0), Double(height - 1))
        let x0 = Int(fx)
        let y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let tx = Float(fx - Double(x0))
        let ty = Float(fy - Double(y0))
        let top = values[y0 * width + x0] * (1 - tx) + values[y0 * width + x1] * tx
        let bottom = values[y1 * width + x0] * (1 - tx) + values[y1 * width + x1] * tx
        return top * (1 - ty) + bottom * ty
    }

    /// Half the size, after a 1-2-1 blur (one level of a Gaussian pyramid).
    func halved() -> Plane {
        let w = max(1, width / 2)
        let h = max(1, height / 2)
        var out = Plane(width: w, height: h)
        out.values.withUnsafeMutableBufferPointer { result in
            for y in 0..<h {
                for x in 0..<w {
                    let cx = 2 * x
                    let cy = 2 * y
                    var sum: Float = 0
                    for dy in -1...1 {
                        let wy: Float = dy == 0 ? 2 : 1
                        sum += wy * (at(cx - 1, cy + dy) + 2 * at(cx, cy + dy) + at(cx + 1, cy + dy))
                    }
                    result[y * w + x] = sum / 16
                }
            }
        }
        return out
    }

    /// Horizontal and vertical derivatives (central differences, Scharr-weighted).
    func gradients() -> (x: Plane, y: Plane) {
        var gx = Plane(width: width, height: height)
        var gy = Plane(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let dx = 3 * (at(x + 1, y - 1) - at(x - 1, y - 1)) + 10 * (at(x + 1, y) - at(x - 1, y))
                    + 3 * (at(x + 1, y + 1) - at(x - 1, y + 1))
                let dy = 3 * (at(x - 1, y + 1) - at(x - 1, y - 1)) + 10 * (at(x, y + 1) - at(x, y - 1))
                    + 3 * (at(x + 1, y + 1) - at(x + 1, y - 1))
                gx.values[y * width + x] = dx / 32
                gy.values[y * width + x] = dy / 32
            }
        }
        return (gx, gy)
    }
}

/// A frame prepared for tracking: luma, chroma, and a luma pyramid with gradients.
public struct TrackingImage: Sendable {
    public let width: Int
    public let height: Int
    public let luma: Plane
    /// Blue-difference and red-difference chroma (for the Color method), centred on 0.5.
    public let cb: Plane
    public let cr: Plane

    struct Level: Sendable {
        var image: Plane
        var gx: Plane
        var gy: Plane
    }

    /// Level 0 is full size; each next level is half the size.
    let levels: [Level]

    /// From 8-bit RGBA pixels (top row first), with `pyramidLevels` levels.
    public init(width: Int, height: Int, rgba: [UInt8], pyramidLevels: Int = 4) {
        var y = Plane(width: width, height: height)
        var b = Plane(width: width, height: height)
        var r = Plane(width: width, height: height)
        for index in 0..<(width * height) {
            let red = Float(rgba[index * 4]) / 255
            let green = Float(rgba[index * 4 + 1]) / 255
            let blue = Float(rgba[index * 4 + 2]) / 255
            let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            y.values[index] = luma
            b.values[index] = (blue - luma) / 1.8556 + 0.5
            r.values[index] = (red - luma) / 1.5748 + 0.5
        }
        self.init(luma: y, cb: b, cr: r, pyramidLevels: pyramidLevels)
    }

    /// From planes directly (tests build images this way).
    public init(luma: Plane, cb: Plane? = nil, cr: Plane? = nil, pyramidLevels: Int = 4) {
        width = luma.width
        height = luma.height
        self.luma = luma
        self.cb = cb ?? Plane(width: luma.width, height: luma.height, fill: 0.5)
        self.cr = cr ?? Plane(width: luma.width, height: luma.height, fill: 0.5)
        var levels: [Level] = []
        var current = luma
        for index in 0..<max(1, pyramidLevels) {
            if index > 0 {
                guard current.width >= 16, current.height >= 16 else { break }
                current = current.halved()
            }
            let (gx, gy) = current.gradients()
            levels.append(Level(image: current, gx: gx, gy: gy))
        }
        self.levels = levels
    }
}

/// A closed outline in pixels, for "is this pixel inside the mask".
struct Outline {
    let points: [(x: Double, y: Double)]
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    /// The mask's Bezier path sampled into a polygon, in an image's pixels.
    init(_ vertices: [Mask.Vertex], width: Int, height: Int) {
        var points: [(x: Double, y: Double)] = []
        for segment in vertices.indices where vertices.count >= 2 {
            for step in 0..<12 {
                let point = Mask.point(on: vertices, segment: segment, t: Double(step) / 12)
                points.append((point.x * Double(width), point.y * Double(height)))
            }
        }
        self.points = points
        minX = points.map(\.x).min() ?? 0
        minY = points.map(\.y).min() ?? 0
        maxX = points.map(\.x).max() ?? 0
        maxY = points.map(\.y).max() ?? 0
    }

    var centerX: Double { (minX + maxX) / 2 }
    var centerY: Double { (minY + maxY) / 2 }

    /// Even-odd ray casting.
    func contains(_ x: Double, _ y: Double) -> Bool {
        guard x >= minX, x <= maxX, y >= minY, y <= maxY, points.count >= 3 else { return false }
        var inside = false
        var previous = points[points.count - 1]
        for point in points {
            if (point.y > y) != (previous.y > y),
               x < (previous.x - point.x) * (y - point.y) / (previous.y - point.y) + point.x {
                inside.toggle()
            }
            previous = point
        }
        return inside
    }

    /// Pixels inside, on a grid `step` apart, clipped to the image.
    func pixels(step: Int, width: Int, height: Int) -> [(x: Int, y: Int)] {
        var result: [(x: Int, y: Int)] = []
        let x0 = max(0, Int(minX.rounded(.down)))
        let x1 = min(width - 1, Int(maxX.rounded(.up)))
        let y0 = max(0, Int(minY.rounded(.down)))
        let y1 = min(height - 1, Int(maxY.rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return [] }
        for y in stride(from: y0, through: y1, by: max(1, step)) {
            for x in stride(from: x0, through: x1, by: max(1, step)) where contains(Double(x), Double(y)) {
                result.append((x, y))
            }
        }
        return result
    }
}
