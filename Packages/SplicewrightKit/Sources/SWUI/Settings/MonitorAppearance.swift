import AppKit
import SwiftUI
import SWCore

/// The Program monitor's background color and frame outline, kept for the whole app (not per
/// workspace) so switching workspaces doesn't change it.
@MainActor
final class MonitorAppearance: ObservableObject {
    static let shared = MonitorAppearance()

    private static let backgroundKey = "programMonitorBackground"
    private static let outlineKey = "programMonitorOutline"

    @Published var background: MonitorColor {
        didSet { UserDefaults.standard.set(background.hex, forKey: Self.backgroundKey) }
    }
    /// A thin line around the frame, in a color that contrasts with the background.
    @Published var outlinesFrame: Bool {
        didSet { UserDefaults.standard.set(outlinesFrame, forKey: Self.outlineKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        background = defaults.string(forKey: Self.backgroundKey).flatMap(MonitorColor.init(hex:)) ?? .charcoal
        outlinesFrame = defaults.object(forKey: Self.outlineKey) as? Bool ?? true
    }

    /// A SwiftUI binding for ColorPicker (any color, no transparency).
    var color: Binding<Color> {
        Binding(get: { self.background.swiftUI },
                set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    self.background = MonitorColor(red: rgb.redComponent, green: rgb.greenComponent,
                                                   blue: rgb.blueComponent)
                })
    }
}

extension MonitorColor {
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

/// The background picker: presets, a color well for any other color, and the frame outline.
struct MonitorBackgroundPicker: View {
    @ObservedObject private var appearance = MonitorAppearance.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Program Monitor Background").font(.headline)
            Text("The color around the video frame, so you can see the frame's edges when you move "
                 + "a clip. It isn't part of the video and never appears in exports.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 8), spacing: 8) {
                ForEach(MonitorColor.presets) { preset in
                    Button { appearance.background = preset.color } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(preset.color.swiftUI)
                            .frame(width: 28, height: 28)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(appearance.background == preset.color ? Color.accentColor : Color.gray.opacity(0.6),
                                        lineWidth: appearance.background == preset.color ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
            }
            ColorPicker("Any color:", selection: appearance.color, supportsOpacity: false)
            Toggle("Outline the frame", isOn: $appearance.outlinesFrame)
                .help("A thin line around the frame, in black or white, whichever stands out")
        }
        .padding(14)
        .frame(width: 320)
    }
}
