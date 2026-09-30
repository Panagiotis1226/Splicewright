import AppKit
import SwiftUI
import SWCore
import SWExport
import UniformTypeIdentifiers

/// File ▸ Export ▸ Media…: choose a preset, range, size and destination, then follow progress.
struct ExportSheet: View {
    @ObservedObject var workspace: WorkspaceController

    var body: some View {
        Group {
            if let session = workspace.exportSession {
                ExportProgressView(workspace: workspace, session: session)
            } else if let sequence = workspace.activeSequence {
                ExportSettingsForm(workspace: workspace, sequence: sequence)
            } else {
                Text("Open a sequence to export it.").padding(30)
            }
        }
        .frame(width: 500)
    }
}

private struct ExportSettingsForm: View {
    @ObservedObject var workspace: WorkspaceController
    let sequence: EditSequence

    @State private var presetID = ""
    @State private var range: ExportRange = .entireSequence
    @State private var size: ExportSize = .matchSequence
    @State private var quality: ExportQuality = .standard
    @State private var folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    @State private var fileName = ""

    private var presets: [ExportPreset] { ExportPreset.builtIn(for: sequence) }
    private var preset: ExportPreset { presets.first { $0.id == presetID } ?? presets[0] }
    private var settings: ExportSettings { ExportSettings(preset: preset, range: range, size: size, quality: quality) }
    private var destination: URL {
        let base = (fileName as NSString).deletingPathExtension
        return folder.appending(path: "\(base.isEmpty ? "Sequence" : base).\(preset.container.fileExtension)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export “\(sequence.name)”").font(.headline)
            Form {
                Picker("Preset", selection: $presetID) {
                    ForEach(presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                LabeledContent("Format") {
                    Text("\(preset.codec.displayName) · \(preset.container.displayName) · \(preset.audio.displayName)")
                        .foregroundStyle(.secondary)
                }
                Picker("Range", selection: $range) {
                    Text("Entire Sequence").tag(ExportRange.entireSequence)
                    Text("Sequence In to Out").tag(ExportRange.inToOut)
                }
                Picker("Frame Size", selection: $size) {
                    Text("Match Sequence (\(sequence.settings.width)×\(sequence.settings.height))")
                        .tag(ExportSize.matchSequence)
                    Text("1080p").tag(ExportSize.hd1080)
                }
                if preset.codec.usesBitRate {
                    Picker("Quality", selection: $quality) {
                        ForEach(ExportQuality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                LabeledContent("Save As") {
                    HStack {
                        TextField("File name", text: $fileName).textFieldStyle(.roundedBorder)
                        Button("Choose…", action: chooseDestination)
                    }
                }
                Text(destination.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            summary
            HStack {
                Spacer()
                Button("Cancel") { workspace.dismissExport() }.keyboardShortcut(.cancelAction)
                Button("Export") { workspace.startExport(settings, to: destination) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!settings.validate(for: sequence).isEmpty)
            }
        }
        .padding(20)
        .onAppear(perform: load)
    }

    @ViewBuilder private var summary: some View {
        let errors = settings.validate(for: sequence)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(errors, id: \.self) { error in
                Label(error.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            if errors.isEmpty {
                Text(summaryText).font(.caption)
                if preset.colorSpace != sequence.settings.colorSpace {
                    Label(colorChangeNote, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var summaryText: String {
        guard let frames = settings.frameRange(for: sequence) else { return "" }
        let output = settings.outputSize(for: sequence)
        let duration = Timecode(frame: frames.length, rate: sequence.rate).description
        let bytes = ByteCountFormatter.string(fromByteCount: settings.estimatedBytes(for: sequence), countStyle: .file)
        return "\(output.width)×\(output.height) · \(sequence.rate.displayName) fps · \(duration) · about \(bytes)"
    }

    private var colorChangeNote: String {
        if sequence.settings.colorSpace.isHDR && !preset.colorSpace.isHDR {
            return "This HDR sequence will be tone-mapped to SDR (Rec.709) for this file."
        }
        return "The sequence is \(sequence.settings.colorSpace.displayName); the file will be " +
            "\(preset.colorSpace.displayName)."
    }

    private func load() {
        if let last = workspace.lastExportSettings, presets.contains(where: { $0.id == last.preset.id }) {
            presetID = last.preset.id
            size = last.size
            quality = last.quality
        } else {
            presetID = presets[0].id
        }
        range = sequence.marks.range == nil ? .entireSequence : .inToOut
        fileName = ExportSettings.defaultFileName(for: sequence, preset: preset)
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.nameFieldStringValue = destination.lastPathComponent
        panel.allowedContentTypes = [preset.container == .mp4 ? .mpeg4Movie : .quickTimeMovie]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.deletingLastPathComponent()
        fileName = url.lastPathComponent
    }
}

private struct ExportProgressView: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject var session: ExportSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Exporting “\(session.sequenceName)”").font(.headline)
            Text(session.outputURL.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            switch session.state {
            case .idle, .preparing:
                ProgressView("Preparing…").progressViewStyle(.linear)
            case .exporting:
                ProgressView(value: session.progress) {
                    Text("\(Int(session.progress * 100))%")
                } currentValueLabel: {
                    Text(remaining)
                }
            case .finished(let url):
                Label("Export finished.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            case .failed(let message):
                Label("Export failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text(message).font(.caption).textSelection(.enabled)
            case .cancelled:
                Label("Export cancelled.", systemImage: "stop.circle").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if session.state.isRunning {
                    Button("Cancel Export") { workspace.cancelExport() }
                    Button("Hide") { workspace.isExportSheetPresented = false }
                        .help("Keep editing; the export continues")
                } else {
                    if case .finished(let url) = session.state {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Button("Done") { workspace.dismissExport() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
    }

    private var remaining: String {
        guard let seconds = session.estimatedSecondsRemaining else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return "\(formatter.string(from: seconds) ?? "") left"
    }
}
