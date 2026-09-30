import SwiftUI
import SWCore

/// New Sequence / Sequence Settings: frame size, frame rate and color space (SDR or HDR).
struct SequenceSettingsSheet: View {
    @ObservedObject var workspace: WorkspaceController
    let request: SequenceSheetRequest

    @State private var name = "Sequence"
    @State private var width = 3840
    @State private var height = 2160
    @State private var frameRate: FrameRate = .fps29_97
    @State private var colorSpace: SequenceColorSpace = .rec709
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool {
        if case .new = request { return true }
        return false
    }

    private var resolutionBinding: Binding<String> {
        Binding(
            get: {
                SequenceSettings.resolutions.first { $0.width == width && $0.height == height }?.id ?? "custom"
            },
            set: { id in
                if let resolution = SequenceSettings.resolutions.first(where: { $0.id == id }) {
                    width = resolution.width
                    height = resolution.height
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Sequence" : "Sequence Settings").font(.headline)
            Form {
                TextField("Name", text: $name)
                Picker("Frame Size", selection: resolutionBinding) {
                    ForEach(SequenceSettings.resolutions) { Text($0.name).tag($0.id) }
                    if !SequenceSettings.resolutions.contains(where: { $0.width == width && $0.height == height }) {
                        Text("Custom (\(width)×\(height))").tag("custom")
                    }
                }
                Picker("Frame Rate", selection: $frameRate) {
                    ForEach(FrameRate.standard, id: \.self) { Text("\($0.displayName) fps").tag($0) }
                }
                Picker("Color Space", selection: $colorSpace) {
                    ForEach(SequenceColorSpace.allCases) { Text($0.displayName).tag($0) }
                }
                Text(colorSpaceHelp).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let clip = workspace.selectedMediaIDs.first.flatMap({ workspace.project.item($0) }) {
                    Button("Match “\(clip.name)”") { apply(.matching(clip.info)) }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private var colorSpaceHelp: String {
        switch colorSpace {
        case .rec709: return "SDR. HDR clips are tone-mapped to fit."
        case .rec2100HLG: return "HDR, backwards-compatible with SDR displays. SDR clips sit at HDR reference white."
        case .rec2100PQ: return "HDR10-style PQ. SDR clips sit at HDR reference white (203 nits)."
        }
    }

    private func load() {
        switch request {
        case .new(let settings, let suggestedName, _):
            name = suggestedName
            apply(settings)
        case .edit(let id):
            guard let sequence = workspace.project.sequence(id) else { return }
            name = sequence.name
            apply(sequence.settings)
        }
    }

    private func apply(_ settings: SequenceSettings) {
        width = settings.width
        height = settings.height
        frameRate = settings.frameRate
        colorSpace = settings.colorSpace
    }

    private func save() {
        let settings = SequenceSettings(width: width, height: height, frameRate: frameRate, colorSpace: colorSpace)
        switch request {
        case .new(_, _, let mediaIDs):
            workspace.createSequence(named: name, settings: settings, adding: mediaIDs)
        case .edit(let id):
            workspace.updateSequenceSettings(id, name: name, settings: settings)
        }
        dismiss()
    }
}
