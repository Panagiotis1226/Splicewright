import AppKit
import SwiftUI
import SWCore

/// Effect Controls for a title clip: text, font, colors, stroke, shadow, box and position.
struct TitleControls: View {
    @ObservedObject var workspace: WorkspaceController
    let clipID: UUID
    let spec: TitleSpec
    let opacity: Double
    @State private var text = ""
    @State private var size = 0.08
    @State private var positionX = 0.5
    @State private var positionY = 0.5
    @FocusState private var editingText: Bool

    private static let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        Form {
            Section("Text") {
                TextField("Text", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($editingText)
                    .onSubmit(commitText)
                    .onChange(of: editingText) { _, editing in if !editing { commitText() } }
                Picker("Font", selection: binding(\.fontFamily, "Title Font")) {
                    ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Toggle("Bold", isOn: binding(\.isBold, "Title Style"))
                    Toggle("Italic", isOn: binding(\.isItalic, "Title Style"))
                    Spacer()
                    Picker("Align", selection: binding(\.alignment, "Title Alignment")) {
                        Image(systemName: "text.alignleft").tag(TitleAlignment.left)
                        Image(systemName: "text.aligncenter").tag(TitleAlignment.center)
                        Image(systemName: "text.alignright").tag(TitleAlignment.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                LabeledContent("Size") {
                    Slider(value: $size, in: TitleSpec.sizeRange) { editing in
                        if !editing { update("Title Size") { $0.size = size } }
                    }
                    Text("\(Int((size * 100).rounded()))%").monospacedDigit().frame(width: 36, alignment: .trailing)
                }
                ColorPicker("Color", selection: colorBinding(\.color, "Title Color"))
            }
            Section("Position") {
                LabeledContent("Horizontal") {
                    Slider(value: $positionX, in: 0...1) { editing in
                        if !editing { update("Title Position") { $0.positionX = positionX } }
                    }
                }
                LabeledContent("Vertical") {
                    Slider(value: $positionY, in: 0...1) { editing in
                        if !editing { update("Title Position") { $0.positionY = positionY } }
                    }
                }
                Button("Center") {
                    update("Title Position") { spec in
                        spec.positionX = 0.5
                        spec.positionY = 0.5
                    }
                }
                Text("With the Type tool (T), click the Program monitor to move the selected title.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Section("Appearance") {
                Toggle("Stroke", isOn: optionalBinding(\.stroke, TitleStroke(), "Title Stroke"))
                if spec.stroke != nil {
                    ColorPicker("Stroke Color", selection: colorBinding(\.stroke!.color, "Stroke Color"))
                }
                Toggle("Shadow", isOn: optionalBinding(\.shadow, TitleShadow(), "Title Shadow"))
                Toggle("Background Box", isOn: optionalBinding(\.background, TitleColor(red: 0, green: 0, blue: 0, alpha: 0.6),
                                                               "Title Background"))
                if spec.background != nil {
                    ColorPicker("Box Color", selection: colorBinding(\.background!, "Box Color"))
                }
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 11))
        .onAppear(perform: load)
        .onChange(of: spec) { _, _ in load() }
        .onChange(of: clipID) { _, _ in load() }
    }

    private func load() {
        if !editingText { text = spec.text }
        size = spec.size
        positionX = spec.positionX
        positionY = spec.positionY
    }

    private func commitText() {
        guard text != spec.text else { return }
        update("Title Text") { $0.text = text }
    }

    private func update(_ name: String, _ change: @escaping (inout TitleSpec) -> Void) {
        workspace.updateTitle(clipID, name, change)
    }

    private func binding<Value: Equatable>(_ path: WritableKeyPath<TitleSpec, Value>, _ name: String) -> Binding<Value> {
        Binding(get: { spec[keyPath: path] }, set: { value in
            guard value != spec[keyPath: path] else { return }
            update(name) { $0[keyPath: path] = value }
        })
    }

    private func optionalBinding<Value>(_ path: WritableKeyPath<TitleSpec, Value?>, _ initial: Value,
                                        _ name: String) -> Binding<Bool> {
        Binding(get: { spec[keyPath: path] != nil }, set: { on in
            update(name) { $0[keyPath: path] = on ? initial : nil }
        })
    }

    private func colorBinding(_ path: WritableKeyPath<TitleSpec, TitleColor>, _ name: String) -> Binding<Color> {
        Binding(get: {
            let value = spec[keyPath: path]
            return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
        }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let value = TitleColor(red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
                                   blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
            guard value != spec[keyPath: path] else { return }
            update(name) { $0[keyPath: path] = value }
        })
    }
}
