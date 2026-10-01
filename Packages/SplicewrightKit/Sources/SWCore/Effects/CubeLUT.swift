import Foundation

/// A `.cube` lookup table (Adobe/Resolve format): a 1D or 3D table of RGB outputs, as camera
/// makers ship for log-to-Rec.709 conversion and colorists use for looks.
public struct CubeLUT: Sendable, Equatable {
    public var title: String
    /// Entries per axis (3D) or in total (1D).
    public var size: Int
    public var is3D: Bool
    public var domainMin: [Float]
    public var domainMax: [Float]
    /// RGB triples. 3D tables are red-fastest: index = r + g·size + b·size².
    public var values: [Float]

    public enum ParseError: Error, Equatable {
        case noSize
        case badSize(Int)
        case wrongCount(expected: Int, found: Int)
        case badLine(Int, String)

        public var message: String {
            switch self {
            case .noSize: return "The file has no LUT_3D_SIZE or LUT_1D_SIZE line."
            case .badSize(let size): return "The LUT size \(size) isn't supported (2–256 for 3D, 2–65536 for 1D)."
            case .wrongCount(let expected, let found): return "The LUT should have \(expected) entries but has \(found)."
            case .badLine(let line, let text): return "Line \(line) isn't a LUT entry: \(text)"
            }
        }
    }

    /// A keyword line: the title, the size, the input domain, or one to ignore.
    private enum Header {
        case title(String)
        case size(Int?, threeD: Bool)
        case domainMin([Float])
        case domainMax([Float])
        /// The same input range on all three channels.
        case range(Float, Float)
        case skip

        init?(parts: [String], line: String) {
            let keyword = parts[0].uppercased()
            let numbers = parts.dropFirst().compactMap { Float($0) }
            switch keyword {
            case "TITLE":
                let text = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                self = .title(text.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            case "LUT_3D_SIZE": self = .size(parts.count > 1 ? Int(parts[1]) : nil, threeD: true)
            case "LUT_1D_SIZE": self = .size(parts.count > 1 ? Int(parts[1]) : nil, threeD: false)
            case "DOMAIN_MIN": self = .domainMin(numbers)
            case "DOMAIN_MAX": self = .domainMax(numbers)
            case "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                self = numbers.count == 2 ? .range(numbers[0], numbers[1]) : .skip
            default:
                // Other keywords (some tools add their own); data lines start with a number.
                guard parts[0].first?.isLetter == true else { return nil }
                self = .skip
            }
        }
    }

    public init(title: String = "", size: Int, is3D: Bool, domainMin: [Float] = [0, 0, 0],
                domainMax: [Float] = [1, 1, 1], values: [Float]) {
        self.title = title
        self.size = size
        self.is3D = is3D
        self.domainMin = domainMin
        self.domainMax = domainMax
        self.values = values
    }

    public init(parsing text: String) throws {
        var title = ""
        var size: Int?
        var is3D = true
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []
        for (number, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if let header = Header(parts: parts, line: line) {
                switch header {
                case .title(let text): title = text
                case .size(let value, let threeD):
                    size = value
                    is3D = threeD
                case .domainMin(let values): domainMin = values
                case .domainMax(let values): domainMax = values
                case .range(let low, let high):
                    domainMin = [low, low, low]
                    domainMax = [high, high, high]
                case .skip: break
                }
                continue
            }
            let numbers = parts.compactMap { Float($0) }
            guard numbers.count == 3, parts.count == 3 else { throw ParseError.badLine(number + 1, line) }
            values += numbers
        }
        guard let size else { throw ParseError.noSize }
        guard is3D ? (2...256).contains(size) : (2...65_536).contains(size) else { throw ParseError.badSize(size) }
        let expected = is3D ? size * size * size : size
        guard values.count == expected * 3 else { throw ParseError.wrongCount(expected: expected, found: values.count / 3) }
        if domainMin.count != 3 { domainMin = [0, 0, 0] }
        if domainMax.count != 3 { domainMax = [1, 1, 1] }
        self.init(title: title, size: size, is3D: is3D, domainMin: domainMin, domainMax: domainMax, values: values)
    }

    /// The table applied to one color (trilinear for 3D, linear for 1D), for tests and previews.
    public func apply(_ rgb: [Float]) -> [Float] {
        let n = Float(size - 1)
        let scaled = (0..<3).map { channel -> Float in
            let span = max(domainMax[channel] - domainMin[channel], 1e-6)
            return min(max((rgb[channel] - domainMin[channel]) / span, 0), 1) * n
        }
        guard is3D else {
            return (0..<3).map { channel in
                let low = Int(scaled[channel].rounded(.down))
                let high = min(low + 1, size - 1)
                let t = scaled[channel] - Float(low)
                return values[low * 3 + channel] * (1 - t) + values[high * 3 + channel] * t
            }
        }
        let low = scaled.map { min(Int($0.rounded(.down)), size - 2) }
        let t = zip(scaled, low).map { $0 - Float($1) }
        func entry(_ r: Int, _ g: Int, _ b: Int, _ channel: Int) -> Float {
            values[(r + g * size + b * size * size) * 3 + channel]
        }
        return (0..<3).map { channel in
            var sum: Float = 0
            for corner in 0..<8 {
                let (dr, dg, db) = (corner & 1, corner >> 1 & 1, corner >> 2 & 1)
                let weight = (dr == 1 ? t[0] : 1 - t[0]) * (dg == 1 ? t[1] : 1 - t[1]) * (db == 1 ? t[2] : 1 - t[2])
                sum += weight * entry(low[0] + dr, low[1] + dg, low[2] + db, channel)
            }
            return sum
        }
    }

    /// An identity table, for tests and as a neutral default.
    public static func identity(size: Int) -> CubeLUT {
        var values: [Float] = []
        let n = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size { values += [Float(r) / n, Float(g) / n, Float(b) / n] }
            }
        }
        return CubeLUT(size: size, is3D: true, values: values)
    }
}

/// RGB curves (Lumetri's): one curve for all channels and one per channel, each a list of points from
/// (0, 0) to (1, 1). Not keyframeable, as in Premiere.
public struct ColorCurves: Sendable, Hashable, Codable {
    public struct Point: Sendable, Hashable, Codable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) {
            self.x = min(max(x, 0), 1)
            self.y = min(max(y, 0), 1)
        }
    }

    public enum Channel: String, Sendable, CaseIterable, Codable {
        case rgb, red, green, blue

        public var displayName: String { self == .rgb ? "RGB" : rawValue.capitalized }
    }

    public static let straight = [Point(0, 0), Point(1, 1)]

    public var rgb = ColorCurves.straight
    public var red = ColorCurves.straight
    public var green = ColorCurves.straight
    public var blue = ColorCurves.straight

    public init() {}

    public subscript(_ channel: Channel) -> [Point] {
        get {
            switch channel {
            case .rgb: return rgb
            case .red: return red
            case .green: return green
            case .blue: return blue
            }
        }
        set {
            let sorted = newValue.sorted { $0.x < $1.x }
            switch channel {
            case .rgb: rgb = sorted
            case .red: red = sorted
            case .green: green = sorted
            case .blue: blue = sorted
            }
        }
    }

    public var isIdentity: Bool { Channel.allCases.allSatisfy { Self.isStraight(self[$0]) } }

    private static func isStraight(_ points: [Point]) -> Bool {
        points.allSatisfy { abs($0.x - $0.y) < 1e-9 }
    }

    /// One curve's value at `x`, through its points with a monotone cubic (Fritsch–Carlson), so
    /// it never overshoots between points.
    public static func evaluate(_ points: [Point], at x: Double) -> Double {
        let sorted = points.sorted { $0.x < $1.x }
        guard let first = sorted.first, let last = sorted.last, sorted.count > 1 else { return x }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        let count = sorted.count
        var slopes = [Double](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            let dx = sorted[index + 1].x - sorted[index].x
            slopes[index] = dx > 0 ? (sorted[index + 1].y - sorted[index].y) / dx : 0
        }
        var tangents = [Double](repeating: 0, count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]
        for index in 1..<(count - 1) {
            tangents[index] = slopes[index - 1] * slopes[index] <= 0 ? 0 : (slopes[index - 1] + slopes[index]) / 2
        }
        for index in 0..<(count - 1) where slopes[index] == 0 {
            tangents[index] = 0
            tangents[index + 1] = 0
        }
        for index in 0..<(count - 1) where slopes[index] != 0 {
            let a = tangents[index] / slopes[index]
            let b = tangents[index + 1] / slopes[index]
            let length = a * a + b * b
            if length > 9 {
                let scale = 3 / length.squareRoot()
                tangents[index] = scale * a * slopes[index]
                tangents[index + 1] = scale * b * slopes[index]
            }
        }
        let segment = (0..<(count - 1)).last { sorted[$0].x <= x } ?? 0
        let p0 = sorted[segment]
        let p1 = sorted[segment + 1]
        let h = p1.x - p0.x
        let t = (x - p0.x) / h
        let t2 = t * t
        let t3 = t2 * t
        let value = (2 * t3 - 3 * t2 + 1) * p0.y + (t3 - 2 * t2 + t) * h * tangents[segment]
            + (-2 * t3 + 3 * t2) * p1.y + (t3 - t2) * h * tangents[segment + 1]
        return min(max(value, 0), 1)
    }

    /// Lookup tables for the renderer: `samples` entries per channel, red, green and blue, each
    /// the channel's own curve followed by the all-channel curve.
    public func table(samples: Int = 256) -> [Float] {
        var table: [Float] = []
        table.reserveCapacity(samples * 3)
        for channel in [Channel.red, .green, .blue] {
            for index in 0..<samples {
                let x = Double(index) / Double(samples - 1)
                table.append(Float(Self.evaluate(rgb, at: Self.evaluate(self[channel], at: x))))
            }
        }
        return table
    }
}
