import AppKit
import SWCore
import SWMedia

/// Offline media (Link Media), files that changed on disk, and clip copy/paste.
extension WorkspaceController {
    // MARK: - Offline media

    /// Re-checks which files are missing (after the project's media changes, and when the app
    /// comes to the front).
    func updateOfflineMedia(force: Bool = false) {
        let paths = project.media.map(\.filePath)
        guard force || paths != checkedMediaPaths else { return }
        checkedMediaPaths = paths
        let offline = Set(project.media.filter { !MediaLocator.isOnline($0) }.map(\.id))
        if offline != offlineMediaIDs { offlineMediaIDs = offline }
    }

    /// Premiere's Link Media: asks where the first missing file is, then links every other
    /// missing file with the same name found in that folder (and its subfolders).
    public func linkMedia(_ ids: Set<UUID>? = nil) {
        let wanted = ids ?? offlineMediaIDs
        let offline = project.media.filter { wanted.contains($0.id) && !MediaLocator.isOnline($0) }
        guard let first = offline.first else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Where is “\((first.filePath as NSString).lastPathComponent)”?"
            + (offline.count > 1 ? " Other missing files in the same folder are linked too." : "")
        panel.prompt = "Link"
        let lastFolder = URL(fileURLWithPath: first.filePath).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: lastFolder.path) { panel.directoryURL = lastFolder }
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.link(first, to: url, others: Array(offline.dropFirst()))
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    private func link(_ item: MediaItem, to url: URL, others: [MediaItem]) {
        let folder = url.deletingLastPathComponent()
        Task { [weak self] in
            let matches = await Task.detached {
                RelinkMatcher.matches(for: others, in: RelinkMatcher.candidates(in: folder))
            }.value
            var paths = matches
            paths[item.id] = url.standardizedFileURL.path
            var updates: [LinkUpdate] = []
            for (id, path) in paths {
                let fileURL = URL(fileURLWithPath: path)
                do {
                    let info = try await MediaProber().probe(fileURL)
                    updates.append(LinkUpdate(id: id, path: path, info: info, modified: FileFingerprint.of(path: path)?.modified))
                } catch {
                    AppLog.shared.warning("Couldn't link \(path): \(error.localizedDescription)", category: "relink")
                }
            }
            guard let self else { return }
            let count = updates.count
            let actionName = count == 1 ? "Link Media" : "Link \(count) Clips"
            self.document?.perform(actionName, undoManager: self.undoManager) { project in
                for update in updates {
                    let bookmark = try? URL(fileURLWithPath: update.path).bookmarkData()
                    project.relink(update.id, toPath: update.path, bookmark: bookmark)
                    project.updateMediaInfo(update.id, info: update.info, modified: update.modified)
                }
            }
            self.updateOfflineMedia(force: true)
            let remaining = self.offlineMediaIDs.count
            AppLog.shared.info("Linked \(count) file(s) from \(folder.path); \(remaining) still offline", category: "relink")
            self.mediaNotice = remaining == 0 ? "Linked \(count) file\(count == 1 ? "" : "s")."
                : "Linked \(count) file\(count == 1 ? "" : "s"); \(remaining) still offline."
        }
    }

    // MARK: - Files that changed on disk

    /// Re-reads media whose file changed size or date since it was imported (re-exported,
    /// replaced or trimmed by another app), so playback and export use the new file.
    func refreshChangedMedia() {
        guard document != nil, !isCheckingMedia else { return }
        isCheckingMedia = true
        let items = project.media
        Task { [weak self] in
            let results = await Task.detached { () -> [(MediaItem, FileFingerprint, MediaInfo?)] in
                var found: [(MediaItem, FileFingerprint, MediaInfo?)] = []
                for item in items {
                    guard let current = FileFingerprint.of(path: item.filePath) else { continue }
                    if item.hasChanged(comparedTo: current) {
                        found.append((item, current, try? await MediaProber().probe(item.url)))
                    } else if item.fileModifiedAt == nil, current.modified != nil {
                        found.append((item, current, nil))  // just record the date
                    }
                }
                return found
            }.value
            guard let self else { return }
            self.isCheckingMedia = false
            guard !results.isEmpty else { return }
            let changed = results.filter { $0.2 != nil }
            self.document?.performWithoutUndo { project in
                for (item, fingerprint, info) in results {
                    project.updateMediaInfo(item.id, info: info ?? item.info, modified: fingerprint.modified)
                }
            }
            guard !changed.isEmpty else { return }
            let names = changed.map(\.0.name)
            AppLog.shared.info("Reloaded changed files: \(names.joined(separator: ", "))", category: "media")
            self.mediaNotice = changed.count == 1 ? "“\(names[0])” changed on disk and was reloaded."
                : "\(changed.count) files changed on disk and were reloaded."
            await ThumbnailProvider.shared.clearMemory()
            await WaveformProvider.shared.clearMemory()
            self.timeline.clearArtwork(thumbnails: true, waveforms: true)
        }
    }

    // MARK: - Copy and paste

    private static let clipboardType = NSPasteboard.PasteboardType(ClipboardContent.pasteboardType)

    public var canCopyClips: Bool { activeSequence != nil && !timeline.selection.isEmpty }

    public var canPasteClips: Bool {
        activeSequence != nil && NSPasteboard.general.availableType(from: [Self.clipboardType]) != nil
    }

    public func copySelectedClips() {
        guard let sequence = activeSequence, !timeline.selection.isEmpty else { return }
        let ids = sequence.expandingLinks(timeline.selection)
        guard let content = sequence.copyClips(ids, project: project),
              let data = try? JSONEncoder().encode(content) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.clipboardType)
        pasteboard.setString(content.items.map(\.clip.name).joined(separator: "\n"), forType: .string)
    }

    public func cutSelectedClips() {
        copySelectedClips()
        guard let sequence = activeSequence, !timeline.selection.isEmpty else { return }
        let ids = sequence.expandingLinks(timeline.selection)
        editSequence("Cut") { sequence, _ in sequence.delete(ids, ripple: false) }
        timeline.selection = []
    }

    private var clipboard: ClipboardContent? {
        NSPasteboard.general.data(forType: Self.clipboardType)
            .flatMap { try? JSONDecoder().decode(ClipboardContent.self, from: $0) }
    }

    /// Pastes at the playhead on the targeted tracks, overwriting, then moves the playhead
    /// to the end of the pasted clips (as Premiere does).
    public func pasteClips() {
        guard let content = clipboard, let id = activeSequenceID, let rate = activeSequence?.rate else { return }
        let frame = playheadFrame
        var pasted: Set<UUID> = []
        document?.perform("Paste", undoManager: undoManager) { project in
            project.addMissingMedia(content.media)
            project.updateSequence(id) { pasted = $0.paste(content, at: frame) }
        }
        timeline.selection = pasted
        let length = RationalTime(frames: content.duration, rate: content.rate).frameIndex(at: rate)
        program.seek(toFrame: frame + length)
    }

    /// Paste Attributes: the copied clip's motion, opacity and keyframes onto the selected
    /// video clips, and its volume onto the selected audio clips.
    public func pasteAttributes() {
        guard let content = clipboard, let sequence = activeSequence, !timeline.selection.isEmpty else { return }
        let videoIDs = Set(sequence.videoTracks.flatMap { $0.clips.map(\.id) }).intersection(timeline.selection)
        let audioIDs = Set(sequence.audioTracks.flatMap { $0.clips.map(\.id) }).intersection(timeline.selection)
        let videoSource = content.items.first { $0.kind == .video }?.clip
        let audioSource = content.items.first { $0.kind == .audio }?.clip
        guard videoSource != nil && !videoIDs.isEmpty || audioSource != nil && !audioIDs.isEmpty else { return }
        editSequence("Paste Attributes") { sequence, _ in
            if let videoSource { sequence.pasteAttributes(from: videoSource, to: videoIDs, motion: true, volume: false) }
            if let audioSource { sequence.pasteAttributes(from: audioSource, to: audioIDs, motion: false, volume: true) }
        }
    }
}

/// A missing file found by Link Media, read and ready to apply.
private struct LinkUpdate {
    var id: UUID
    var path: String
    var info: MediaInfo
    var modified: Date?
}
