import AppKit
import AVFoundation
import SWCore
import SWExport
import SWMedia
import SWPlayback

/// Drives the real app end to end for CI (`scripts/smoke-test.sh`): imports media, builds a
/// sequence, plays it, then writes a window snapshot, a Program-monitor frame and a JSON
/// report, and exits. Runs only when `SPLICEWRIGHT_SMOKE_MEDIA` and
/// `SPLICEWRIGHT_SMOKE_OUTPUT` are set.
@MainActor
enum SmokeTestDriver {
    private static var started = false

    struct Report: Codable {
        var importedMedia = 0
        var importFailures: [String] = []
        var sequenceName = ""
        var sequenceSettings = ""
        var durationFrames: Int64 = 0
        var clipCount = 0
        var playheadBefore: Int64 = 0
        var playheadAfter: Int64 = 0
        var droppedFrames = 0
        var programFrameRendered = false
        var windowSnapshot = false
        var exportSucceeded = false
        var exportedFrames: Int64 = 0
        var exportedCodec = ""
        var transitionsApplied = 0
        var titleAdded = false
        var proxyCreated = false
        var proxyPlayback = false
        var cacheBytes: Int64 = 0
        var thumbnailCacheCleared = false
        var workspaceApplied = false
        var exportedWidth = 0
        var sequenceWidth = 0
        var undoWorks = false
        var undoDiagnostics = ""
        var errors: [String] = []
    }

    static func startIfRequested(workspace: WorkspaceController) {
        let environment = ProcessInfo.processInfo.environment
        guard !started, let media = environment["SPLICEWRIGHT_SMOKE_MEDIA"],
              let output = environment["SPLICEWRIGHT_SMOKE_OUTPUT"] else { return }
        started = true
        Task { @MainActor in
            await run(workspace: workspace, mediaDirectory: URL(fileURLWithPath: media),
                      outputDirectory: URL(fileURLWithPath: output))
        }
    }

    private static func run(workspace: WorkspaceController, mediaDirectory: URL, outputDirectory: URL) async {
        var report = Report()
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { finish(report, to: outputDirectory) }

        guard await waitFor(seconds: 20, { workspace.document != nil }) else {
            report.errors.append("No document attached")
            return
        }
        workspace.importFiles([mediaDirectory])
        _ = await waitFor(seconds: 60) { !workspace.isImporting && !workspace.project.media.isEmpty }
        report.importedMedia = workspace.project.media.count
        report.importFailures = workspace.importReport?.failures.map { "\($0.url.lastPathComponent): \($0.reason)" } ?? []
        workspace.importReport = nil

        let videos = workspace.project.media.filter { $0.info.video != nil }.sorted { $0.name < $1.name }
        let audio = workspace.project.media.filter { $0.info.video == nil }
        guard let first = videos.first else {
            report.errors.append("No video media imported")
            return
        }
        workspace.createSequence(named: "Smoke Test", settings: .matching(first.info), adding: videos.map(\.id))
        if let tone = audio.first, let sequence = workspace.activeSequence {
            workspace.dropMedia([tone.id], atFrame: 0, trackID: sequence.audioTracks[1].id, insert: false)
        }
        workspace.openInSource(first.id)
        guard let sequence = workspace.activeSequence else {
            report.errors.append("Sequence wasn't created")
            return
        }
        report.sequenceName = sequence.name
        report.sequenceSettings = sequence.settings.summary
        report.durationFrames = sequence.durationFrames
        report.clipCount = sequence.allTracks.reduce(0) { $0 + $1.clips.count }

        (report.undoWorks, report.undoDiagnostics) = await checkUndo(workspace)
        addTransitionAndTitle(workspace, report: &report)
        await checkProxies(workspace, video: first, report: &report)
        checkCache(&report)
        await checkWorkspaces(workspace, report: &report)
        workspace.activePanel = .timeline
        workspace.timeline.zoomToFit(durationFrames: sequence.durationFrames, laneWidth: TimelineLayout.lastLaneWidth)
        if let clip = sequence.videoTracks[0].clips.first { workspace.timeline.selection = [clip.id] }

        _ = await waitFor(seconds: 30) { !workspace.program.isBuilding && workspace.program.player.currentItem != nil }
        report.playheadBefore = workspace.program.currentFrame
        workspace.program.togglePlay()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        workspace.program.pause()
        report.playheadAfter = workspace.program.currentFrame
        report.droppedFrames = workspace.program.droppedFrames
        workspace.program.seek(toFrame: min(15, max(0, sequence.durationFrames - 1)))
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        report.programFrameRendered = await saveProgramFrame(workspace, to: outputDirectory.appending(path: "program.png"),
                                                              errors: &report.errors)
        report.windowSnapshot = saveWindowSnapshot(workspace.window, to: outputDirectory.appending(path: "window.png"))
        await exportClip(workspace, to: outputDirectory.appending(path: "export.mp4"), report: &report)
        // Give the script time to take a real screenshot while the window is still up.
        FileManager.default.createFile(atPath: outputDirectory.appending(path: "snapshot.ready").path, contents: nil)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }

    /// A cross dissolve at V1's first cut and a title at the start, as a user would add them.
    private static func addTransitionAndTitle(_ workspace: WorkspaceController, report: inout Report) {
        if let cut = workspace.activeSequence?.videoTracks[0].clips.first?.end {
            workspace.editSequence("Add Cross Dissolve") { sequence, _ in
                sequence.addTransition(.crossDissolve, trackID: sequence.videoTracks[0].id, at: cut, duration: 10)
            }
        }
        workspace.program.seek(toFrame: 0)
        workspace.newTitle()
        let sequence = workspace.activeSequence
        report.transitionsApplied = sequence?.videoTracks.reduce(0) { $0 + $1.resolvedTransitions.count } ?? 0
        report.titleAdded = sequence?.videoTracks.contains { $0.clips.contains(where: \.isTitle) } ?? false
        if report.transitionsApplied == 0 { report.errors.append("No transition was applied") }
        if !report.titleAdded { report.errors.append("No title was added") }
    }

    /// Makes a proxy for one clip, then plays with proxies on (export later must still use originals).
    private static func checkProxies(_ workspace: WorkspaceController, video: MediaItem, report: inout Report) async {
        ProxyQueue.shared.enqueue([video], preset: ProxyPreset(resolution: .half))
        _ = await waitFor(seconds: 90) { ProxyQueue.shared.jobs.isEmpty }
        if case .failed(let reason)? = ProxyQueue.shared.jobs[video.id] { report.errors.append("Proxy: \(reason)") }
        report.proxyCreated = ProxyStore.shared.proxy(for: video) != nil
        workspace.useProxies = true
        try? await Task.sleep(nanoseconds: 500_000_000)
        report.proxyPlayback = await waitFor(seconds: 30) {
            !workspace.program.isBuilding && workspace.program.player.currentItem != nil
        } && workspace.program.useProxies
    }

    private static func checkCache(_ report: inout Report) {
        let manager = CacheManager.shared
        report.cacheBytes = manager.usage().values.reduce(0) { $0 + $1.bytes }
        manager.delete([.thumbnails])
        report.thumbnailCacheCleared = manager.usage()[.thumbnails]?.files == 0
    }

    /// Switches to the Assembly workspace (icon view) and back.
    private static func checkWorkspaces(_ workspace: WorkspaceController, report: inout Report) async {
        let store = WorkspaceStore.shared
        let original = store.library.currentID
        store.select(WorkspaceLayout.assembly.id)
        report.workspaceApplied = await waitFor(seconds: 5) { workspace.projectViewMode == .icons }
        store.select(original)
        _ = await waitFor(seconds: 5) { workspace.projectViewMode == ProjectViewMode(rawValue: store.current.projectViewMode) }
    }

    /// Exports frames 10...39 as H.264 SDR and probes the result.
    private static func exportClip(_ workspace: WorkspaceController, to url: URL, report: inout Report) async {
        guard var sequence = workspace.activeSequence else { return }
        sequence.marks = SequenceMarks(inFrame: 10, outFrame: 39)
        let session = ExportSession(sequence: sequence, project: workspace.project,
                                    settings: ExportSettings(preset: .h264SDR, range: .inToOut), outputURL: url)
        // Cancel rather than hang the smoke test if the export stalls.
        let watchdog = Task { @MainActor in
            try await Task.sleep(nanoseconds: 90_000_000_000)
            session.cancel()
        }
        let state = await session.run()
        watchdog.cancel()
        if state == .cancelled {
            report.errors.append("Export stalled at \(Int(session.progress * 100))% and was cancelled after 90 s")
            return
        }
        guard state == .finished(url) else {
            report.errors.append("Export: \(state)")
            return
        }
        do {
            let info = try await MediaProber().probe(url)
            report.exportSucceeded = true
            report.exportedFrames = info.duration.frameIndex(at: sequence.rate)
            report.exportedCodec = info.video?.codec.displayName ?? "none"
            report.exportedWidth = info.video?.width ?? 0
            report.sequenceWidth = sequence.settings.width
        } catch {
            report.errors.append("Probing export: \(error.localizedDescription)")
        }
    }

    /// Makes an edit, then sends Edit ▸ Undo through the responder chain, as ⌘Z does.
    private static func checkUndo(_ workspace: WorkspaceController) async -> (Bool, String) {
        guard let before = workspace.activeSequence else { return (false, "no sequence") }
        NSApp.activate(ignoringOtherApps: true)
        workspace.window?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        workspace.addTrack(.video)
        let added = workspace.activeSequence?.videoTracks.count == before.videoTracks.count + 1
        // Let the run loop close the automatic undo group before undoing.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let manager = workspace.undoManager
        var diagnostics = "added=\(added) env=\(manager != nil) canUndo=\(manager?.canUndo ?? false) "
            + "level=\(manager?.groupingLevel ?? -1) windowUndo=\(workspace.window?.undoManager === manager)"
        let sent = NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let undone = workspace.activeSequence?.videoTracks.count == before.videoTracks.count
        diagnostics += " sent=\(sent) undone=\(undone)"
        return (added && undone, diagnostics)
    }

    private static func saveProgramFrame(_ workspace: WorkspaceController, to url: URL,
                                         errors: inout [String]) async -> Bool {
        guard let item = workspace.program.player.currentItem else {
            errors.append("Program monitor has no player item")
            return false
        }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let image = try await generator.image(at: item.currentTime()).image
            return write(NSBitmapImageRep(cgImage: image), to: url)
        } catch {
            errors.append("Program frame: \(error.localizedDescription)")
            return false
        }
    }

    private static func saveWindowSnapshot(_ window: NSWindow?, to url: URL) -> Bool {
        guard let view = window?.contentView, let layer = view.layer,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Layer rendering captures SwiftUI content that `cacheDisplay` can miss.
        if layer.isGeometryFlipped {
            context.cgContext.translateBy(x: 0, y: view.bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return write(rep, to: url)
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) -> Bool {
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private static func waitFor(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    private static func finish(_ report: Report, to directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: directory.appending(path: "report.json"))
        }
        // Exit directly: quitting normally could stop on a save prompt for the untitled project.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }
}
