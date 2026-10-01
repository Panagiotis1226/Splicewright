import AppKit
import SWCore
import SWMedia
import UniformTypeIdentifiers

/// A message after a timeline import or export.
public struct InterchangeMessage: Identifiable {
    public let id = UUID()
    public var title: String
    public var text: String
}

/// Timelines to and from Premiere Pro (FCP7 XML), DaVinci Resolve (FCPXML, FCP7 XML, OTIO) and
/// Final Cut Pro (FCPXML). Project files themselves (.prproj, .drp) are closed formats; these
/// are the files those apps export for exactly this.
extension WorkspaceController {
    static let interchangeTypes: [UTType] = [
        .xml,
        UTType(filenameExtension: "fcpxml") ?? .xml,
        UTType(filenameExtension: "fcpxmld", conformingTo: .package) ?? .package,
        UTType(filenameExtension: "otio") ?? .json,
    ]

    /// File ▸ Import ▸ Timeline…
    public func chooseTimelineToImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Timeline"
        panel.message = "Choose a Final Cut Pro XML (from Premiere Pro or Resolve), an FCPXML (Final Cut Pro, Resolve) "
            + "or an OpenTimelineIO file (Resolve)."
        panel.allowedContentTypes = Self.interchangeTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importTimeline(from: url) }
    }

    /// Reads the timeline, imports the media it uses (missing files come in offline, ready for
    /// Link Media), and opens it as a new sequence.
    func importTimeline(from url: URL) async {
        guard let document else { return }
        // Final Cut Pro 10.6+ writes a bundle with the XML inside.
        let file = url.pathExtension.lowercased() == "fcpxmld" ? url.appending(path: "Info.fcpxml") : url
        let timeline: InterchangeTimeline
        do {
            timeline = try InterchangeFormat.read(try Data(contentsOf: file))
        } catch let error as InterchangeFormat.ReadError {
            interchangeMessage = InterchangeMessage(title: "Couldn't import the timeline", text: error.message)
            return
        } catch {
            interchangeMessage = InterchangeMessage(title: "Couldn't import the timeline", text: error.localizedDescription)
            return
        }
        // Paths are compared resolved (symlinks, /private), as the importer stores them.
        func key(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        var known: [String: UUID] = [:]
        for item in document.project.media { known[key(item.filePath)] = item.id }
        let files = timeline.mediaFiles.filter { known[key($0.path)] == nil }
        let onDisk = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        isImporting = true
        let result = await MediaImporter().importMedia(from: onDisk.map { URL(fileURLWithPath: $0.path) },
                                                      into: importDestinationBinID,
                                                      existingPaths: Set(document.project.media.map(\.filePath)))
        isImporting = false
        for item in result.items { known[key(item.filePath)] = item.id }
        let offline = files.filter { known[key($0.path)] == nil }.map { Self.offlineItem(for: $0, rate: timeline.rate) }
        for item in offline { known[key(item.filePath)] = item.id }
        // By the paths the timeline uses.
        var mediaIDs: [String: UUID] = [:]
        for media in timeline.mediaFiles { mediaIDs[media.path] = known[key(media.path)] }

        let settings = sequenceSettings(for: timeline, media: result.items)
        var report = InterchangeReport()
        var created: EditSequence?
        document.perform("Import Timeline", undoManager: undoManager) { project in
            project.addMedia(result.items)
            project.addMissingMedia(offline)
            let placeholder = project.addSequence(named: timeline.name, settings: settings)
            var sequence = EditSequence(timeline, settings: settings, mediaIDs: mediaIDs, report: &report)
            sequence.id = placeholder.id
            sequence.name = placeholder.name
            project.updateSequence(sequence.id) { $0 = sequence }
            created = sequence
        }
        guard let created else { return }
        activeSequenceID = created.id
        activePanel = .timeline
        program.update(sequence: activeSequence, project: project)
        let clipCount = created.allTracks.reduce(0) { $0 + $1.clips.count }
        var lines = ["\(clipCount) clip(s) on \(created.videoTracks.count) video and \(created.audioTracks.count) audio "
                     + "tracks, \(result.items.count) file(s) imported."]
        if !offline.isEmpty {
            lines.append("\(offline.count) file(s) weren't found and are offline. Use File ▸ Link Media… to find them.")
        }
        lines += report.notes
        lines.append("Effects, titles and color from the other app don't carry over; cuts, speed, opacity, "
                     + "volume, dissolves and markers do.")
        AppLog.shared.info("Imported timeline \(url.lastPathComponent): \(lines.joined(separator: " "))", category: "interchange")
        interchangeMessage = InterchangeMessage(title: "Imported “\(created.name)”", text: lines.joined(separator: "\n\n"))
    }

    /// The timeline's size and rate; when the file doesn't say (OTIO often doesn't), the first
    /// video clip's size.
    private func sequenceSettings(for timeline: InterchangeTimeline, media: [MediaItem]) -> SequenceSettings {
        let firstVideo = media.first { $0.info.video != nil }
        var settings = firstVideo.map { SequenceSettings.matching($0.info) }
            ?? SequenceSettings(width: 1920, height: 1080, frameRate: timeline.rate, colorSpace: .rec709)
        settings.frameRate = timeline.rate
        if timeline.width > 0 && timeline.height > 0 {
            settings.width = timeline.width
            settings.height = timeline.height
        } else if let video = timeline.mediaFiles.first(where: { $0.width != nil }), let width = video.width,
                  let height = video.height, firstVideo == nil {
            settings.width = width
            settings.height = height
        }
        return settings
    }

    /// A project item for a file that isn't where the timeline says, so its clips still come in.
    static func offlineItem(for media: InterchangeMedia, rate: FrameRate) -> MediaItem {
        let video = media.hasVideo ? VideoStreamInfo(codec: VideoCodec(rawValue: "unknown"), width: media.width ?? 1920,
                                                     height: media.height ?? 1080, frameRate: rate,
                                                     nominalFPS: rate.framesPerSecond, bitDepth: 8, color: .rec709) : nil
        let audio = media.hasAudio ? [AudioStreamInfo(codec: .aac, sampleRate: 48_000, channelCount: 2)] : []
        let info = MediaInfo(container: .quickTime, duration: media.duration ?? RationalTime(seconds: 3600, timescale: 600),
                             video: video, audio: audio)
        return MediaItem(name: media.name, filePath: media.path, info: info)
    }

    /// File ▸ Export ▸ Timeline as …
    public func exportTimeline(_ format: InterchangeFormat) {
        guard let sequence = activeSequence else { return }
        let panel = NSSavePanel()
        panel.title = "Export Timeline"
        panel.message = format.displayName
        panel.nameFieldStringValue = "\(sequence.name).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var report = InterchangeReport()
        let timeline = InterchangeTimeline(sequence, project: project, report: &report)
        do {
            try format.write(timeline).write(to: url, options: .atomic)
        } catch {
            interchangeMessage = InterchangeMessage(title: "Couldn't export the timeline", text: error.localizedDescription)
            return
        }
        AppLog.shared.info("Exported \(format.rawValue) to \(url.path)", category: "interchange")
        let how: String
        switch format {
        case .fcp7XML: how = "In Premiere Pro: File ▸ Import. In Resolve: File ▸ Import ▸ Timeline."
        case .fcpxml: how = "In Final Cut Pro: File ▸ Import ▸ XML. In Resolve: File ▸ Import ▸ Timeline."
        case .otio: how = "In Resolve: File ▸ Import ▸ Timeline."
        }
        interchangeMessage = InterchangeMessage(title: "Exported “\(sequence.name)”",
                                                text: ([how] + report.notes).joined(separator: "\n\n"))
    }
}
