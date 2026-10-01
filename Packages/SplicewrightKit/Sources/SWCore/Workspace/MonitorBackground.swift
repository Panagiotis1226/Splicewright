import Foundation

/// The color around the picture in the Program monitor, so the frame's edges show even when
/// the video inside is black. It's only for viewing: exports never include it.
public struct MonitorColor: Sendable, Hashable, Codable {
    /// sRGB components, 0...1.
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    public init(white: Double) {
        self.init(red: white, green: white, blue: white)
    }

    /// "#RRGGBB" or "RRGGBB".
    public init?(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    public var hex: String {
        let parts = [red, green, blue].map { component -> String in
            let text = String(Int((component * 255).rounded()), radix: 16, uppercase: true)
            return text.count == 1 ? "0" + text : text
        }
        return "#" + parts.joined()
    }

    /// Relative luminance (WCAG), 0 for black to 1 for white.
    public var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// White on dark backgrounds, black on light ones: for the frame outline and labels drawn
    /// over the background, whatever color it is.
    public var contrasting: MonitorColor {
        luminance > 0.18 ? MonitorColor(white: 0) : MonitorColor(white: 1)
    }

    public static let black = MonitorColor(white: 0)
    /// The default: dark enough to keep attention on the picture, light enough that a black
    /// frame stands out from it.
    public static let charcoal = MonitorColor(white: 0.2)

    public struct Preset: Sendable, Hashable, Identifiable {
        public var name: String
        public var color: MonitorColor
        public var id: String { name }
    }

    public static let presets: [Preset] = [
        Preset(name: "Black", color: .black),
        Preset(name: "Charcoal", color: .charcoal),
        Preset(name: "Grey", color: MonitorColor(white: 0.45)),
        Preset(name: "Light Grey", color: MonitorColor(white: 0.75)),
        Preset(name: "White", color: MonitorColor(white: 1)),
        Preset(name: "Green", color: MonitorColor(red: 0, green: 0.69, blue: 0.25)),
        Preset(name: "Magenta", color: MonitorColor(red: 0.85, green: 0.1, blue: 0.65)),
        Preset(name: "Blue", color: MonitorColor(red: 0.12, green: 0.3, blue: 0.75)),
    ]
}
