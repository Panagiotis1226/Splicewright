import AppKit
import SWCore
import SWExport
import UniformTypeIdentifiers

/// A transcription in progress (shown in the Transcribe sheet).
@MainActor
public final class CaptionJob: ObservableObject {
    @Published public var stage: Transcriber.Stage = .mixingAudio
    @Published public var error: String?
    @Published public var isFinished = false
    var task: Task<Void, Never>?

    public func cancel() {
        task?.cancel()
    }

    public var statusText: String {
        if let error { return error }
        switch stage {
        case .mixingAudio: return "Mixing the sequence's audio…"
        case .downloadingLanguage(let fraction): return "Downloading the language model… \(Int(fraction * 100))%"
        case .transcribing(let fraction): return "Transcribing… \(Int(fraction * 100))%"
        }
    }

    public var fraction: Double? {
        switch stage {
        case .mixingAudio: return nil
        case .downloadingLanguage(let value), .transcribing(let value): return value
        }
    }
}

/// What the Transcribe sheet asks for.
public struct TranscriptionRequest: Sendable {
    public var locale: Locale
    public var inToOut: Bool
    public var style: CaptionStyle
}

extension WorkspaceController {
    /// The caption track the Captions panel shows: the last one clicked, else the first.
    var captionTrack: CaptionTrack? {
        guard let sequence = activeSequence else { return nil }
        return activeCaptionTrackID.flatMap { sequence.captionTrack($0) } ?? sequence.captionTracks.first
    }

    // MARK: - Transcription

    func transcribe(_ request: TranscriptionRequest) {
        guard let sequence = activeSequence, let sequenceID = activeSequenceID else { return }
        let range = request.inToOut ? sequence.marks.range ?? FrameRange(start: 0, end: sequence.durationFrames)
            : FrameRange(start: 0, end: sequence.durationFrames)
        guard !range.isEmpty else { return }
        let job = CaptionJob()
        captionJob = job
        let project = self.project
        let rate = sequence.rate
        AppLog.shared.info("Transcribing \(sequence.name) (\(request.locale.identifier), frames \(range.start)-\(range.end))",
                           category: "captions")
        job.task = Task { [weak self, weak job] in
            do {
                let mix = try await AudioMixdown.render(sequence, project: project, range: range)
                defer { try? FileManager.default.removeItem(at: mix) }
                let offset = RationalTime(frames: range.start, rate: rate).seconds
                let words = try await Transcriber.words(in: mix, locale: request.locale) { stage in
                    Task { @MainActor in job?.stage = stage }
                }.map { TimedWord(text: $0.text, start: $0.start + offset, duration: $0.duration) }
                try Task.checkCancellation()
                let captions = CaptionSegmenter.captions(from: words, rate: rate, style: request.style)
                guard let self else { return }
                guard !captions.isEmpty else {
                    job?.error = "No speech was found."
                    return
                }
                let language = Locale.current.localizedString(forIdentifier: request.locale.identifier)
                    ?? request.locale.identifier
                var newTrack: UUID?
                self.document?.perform("Create Captions", undoManager: self.undoManager) { project in
                    project.updateSequence(sequenceID) {
                        newTrack = $0.addCaptionTrack(name: "Subtitles (\(language))", language: request.locale.identifier,
                                                      style: request.style, captions: captions)
                    }
                }
                self.activeCaptionTrackID = newTrack
                self.activePanel = .captions
                job?.isFinished = true
                self.isTranscribeSheetPresented = false
                self.captionJob = nil
                AppLog.shared.info("Created \(captions.count) captions from \(words.count) words", category: "captions")
            } catch is CancellationError {
                self?.captionJob = nil
            } catch {
                job?.error = error.localizedDescription
                AppLog.shared.error("Transcription failed: \(error.localizedDescription)", category: "captions")
            }
        }
    }

    // MARK: - Tracks

    func addCaptionTrack() {
        var created: UUID?
        editSequence("Add Subtitle Track") { sequence, _ in
            created = sequence.addCaptionTrack(name: "Subtitles", language: Locale.current.identifier)
        }
        activeCaptionTrackID = created
    }

    func updateCaptionTrack(_ id: UUID, _ actionName: String, _ change: (inout CaptionTrack) -> Void) {
        editSequence(actionName) { sequence, _ in sequence.updateCaptionTrack(id, change) }
    }

    func removeCaptionTrack(_ id: UUID) {
        editSequence("Delete Subtitle Track") { sequence, _ in sequence.removeCaptionTrack(id) }
    }

    /// A new look for a track; captions with word timings are re-split for its line limits.
    func applyCaptionStyle(_ style: CaptionStyle, to trackID: UUID) {
        guard let rate = activeSequence?.rate else { return }
        editSequence("Caption Style") { sequence, _ in
            guard let track = sequence.captionTrack(trackID), !track.isLocked else { return }
            let captions = CaptionSegmenter.resplit(track.captions, rate: rate, style: style)
            sequence.updateCaptionTrack(trackID) { $0.style = style }
            sequence.setCaptions(captions, on: trackID)
        }
    }

    /// Track items shared by the timeline header menu and the Captions panel.
    func addCaptionTrackItems(to menu: NSMenu, track: CaptionTrack) {
        let styles = NSMenu()
        let options: [(String, CaptionStyle)] = [("Standard (bottom, two lines)", .standard),
                                                 ("Social (big, one line)", .social)]
        for (name, style) in options {
            let item = ActionMenuItem(name) { [weak self] in self?.applyCaptionStyle(style, to: track.id) }
            item.state = track.style == style ? .on : .off
            styles.addItem(item)
        }
        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        styleItem.submenu = styles
        menu.addItem(styleItem)
        for format in SubRip.Format.allCases {
            menu.addItem(ActionMenuItem("Export \(format.displayName)…") { [weak self] in
                self?.exportCaptions(track.id, format: format)
            })
        }
        menu.addItem(ActionMenuItem("Import Captions…") { [weak self] in self?.importCaptions() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Add Subtitle Track") { [weak self] in self?.addCaptionTrack() })
        menu.addItem(ActionMenuItem("Delete Subtitle Track") { [weak self] in self?.removeCaptionTrack(track.id) })
    }

    // MARK: - Captions

    /// Shows a caption's text for editing in the Captions panel.
    func editCaption(_ id: UUID) {
        if let trackID = activeSequence?.caption(id)?.trackID { activeCaptionTrackID = trackID }
        focusedCaptionID = id
        activePanel = .captions
    }

    func setCaptionText(_ id: UUID, _ text: String) {
        guard activeSequence?.caption(id)?.caption.text != text else { return }
        editSequence("Edit Caption") { sequence, _ in sequence.setCaptionText(id, text) }
    }

    func splitCaption(_ id: UUID, at frame: Int64) {
        var created: UUID?
        editSequence("Split Caption") { sequence, _ in created = sequence.splitCaption(id, at: frame) }
        if let created { timeline.selection = [created] }
    }

    func mergeCaptionWithNext(_ id: UUID) {
        editSequence("Merge Captions") { sequence, _ in sequence.mergeCaptionWithNext(id) }
    }

    /// Adds a caption at `frame` (2 s, or up to the next caption) and opens it for typing.
    func addCaption(on trackID: UUID, at frame: Int64) {
        guard let rate = activeSequence?.rate else { return }
        var created: UUID?
        editSequence("Add Caption") { sequence, _ in
            created = sequence.addCaption(on: trackID, at: frame, duration: Int64((2 * rate.framesPerSecond).rounded()))
        }
        if let created {
            timeline.selection = [created]
            editCaption(created)
        }
    }

    @discardableResult
    func replaceInCaptions(on trackID: UUID, _ find: String, with replacement: String) -> Int {
        var count = 0
        editSequence("Replace in Captions") { sequence, _ in
            count = sequence.replaceInCaptions(on: trackID, find, with: replacement)
        }
        return count
    }

    /// Caption IDs among `ids` (the timeline selection mixes clips and captions).
    func captionIDs(in ids: Set<UUID>) -> Set<UUID> {
        guard let sequence = activeSequence else { return [] }
        return ids.filter { sequence.caption($0) != nil }
    }

    // MARK: - Files

    func importCaptions() {
        guard let sequence = activeSequence else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt")].compactMap { $0 }
        panel.message = "Choose a SubRip (.srt) or WebVTT (.vtt) file. Its times start at the beginning of the sequence."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let captions = try SubRip.parse(text, rate: sequence.rate)
            var created: UUID?
            editSequence("Import Captions") { sequence, _ in
                created = sequence.addCaptionTrack(name: url.deletingPathExtension().lastPathComponent,
                                                   language: Locale.current.identifier, captions: captions)
            }
            activeCaptionTrackID = created
            AppLog.shared.info("Imported \(captions.count) captions from \(url.lastPathComponent)", category: "captions")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func exportCaptions(_ trackID: UUID, format: SubRip.Format) {
        guard let sequence = activeSequence, let track = sequence.captionTrack(trackID) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sequence.name).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension)].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SubRip.write(track.captions, rate: sequence.rate, format: format).write(to: url, atomically: true,
                                                                                       encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
