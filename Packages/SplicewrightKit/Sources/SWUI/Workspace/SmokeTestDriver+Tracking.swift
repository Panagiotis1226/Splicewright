import Foundation
import SWCore

extension SmokeTestDriver {
    /// Where `mark` records how far the run got (read by scripts/smoke-test.sh after a crash).
    static var progressURL: URL?

    /// Appends a step to progress.txt, flushed at once so it survives a crash.
    static func mark(_ step: String) {
        guard let url = progressURL else { return }
        let line = Data("\(Date().timeIntervalSince1970) \(step)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.synchronize()
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// Tracks the mask added in `addEffects` four frames forward (Texture, not stopping when
    /// unsure, since the fixtures are synthetic); each frame should get a Mask Path keyframe.
    static func checkTracking(_ workspace: WorkspaceController) async -> String {
        guard let clip = workspace.activeSequence?.videoTracks[0].clips.first(where: { !$0.opacityMasks.isEmpty }),
              let mask = clip.opacityMasks.first else { return "no masked clip" }
        if let problem = checkPenShape(workspace, frame: clip.start) { return problem }
        let selection = MaskSelection(target: MaskTarget(clipID: clip.id, owner: .opacity), maskID: mask.id)
        var settings = TrackingSettings()
        settings.method = .texture
        settings.stopsWhenLost = false
        workspace.setTrackingSettings(settings, of: selection)
        workspace.program.seek(toFrame: clip.start)
        _ = await waitFor(seconds: 5) { workspace.program.currentFrame == clip.start }
        workspace.trackMask(selection, forward: true, oneFrame: false, maxFrames: 4)
        let finished = await waitFor(seconds: 60) { workspace.trackingJob == nil }
        let keyframes = workspace.mask(selection)?.path.keyframes.count ?? 0
        if !finished { return "still tracking" }
        if let message = workspace.trackingMessage { return "message: \(message.text)" }
        return keyframes == 5 ? "ok" : "\(keyframes) keyframes"
    }

    /// The Tools panel's Pen with nothing selected: the shape lands on the footage at the playhead
    /// as a selected None mask on its Opacity, and the Selection tool is back. Removed again after.
    static func checkPenShape(_ workspace: WorkspaceController, frame: Int64) -> String? {
        workspace.timeline.selection = []
        workspace.activeTool = .pen
        guard let clip = workspace.penToolClip(at: frame) else { return "pen: no clip at the playhead" }
        let before = clip.opacityMasks.count
        workspace.addPenToolMask([.init(x: 0.4, y: 0.4), .init(x: 0.6, y: 0.4), .init(x: 0.5, y: 0.6)], to: clip.id)
        let masks = workspace.activeSequence?.clip(clip.id)?.opacityMasks ?? []
        guard masks.count == before + 1, let shape = masks.last, shape.mode == Mask.Mode.none,
              workspace.activeTool == .selection, workspace.selectedMask?.maskID == shape.id,
              workspace.timeline.selection == [clip.id] else {
            return "pen: \(masks.map(\.mode.displayName)), tool \(workspace.activeTool)"
        }
        workspace.removeMask(MaskSelection(target: MaskTarget(clipID: clip.id, owner: .opacity), maskID: shape.id))
        return nil
    }

    /// Adds a Stabilizer to V1's second clip, which analyses it right away; every frame of the
    /// clip should be in the analysis.
    static func checkStabilizer(_ workspace: WorkspaceController) async -> String {
        guard let clips = workspace.activeSequence?.videoTracks[0].clips, clips.count > 1 else { return "no clip" }
        let clip = clips[1]
        workspace.addEffect(.stabilizer, to: [clip.id])
        let finished = await waitFor(seconds: 90) { workspace.stabilizationJob == nil }
        guard finished else { return "still analysing" }
        guard let data = workspace.activeSequence?.clip(clip.id)?.effects.first(where: { $0.kind == .stabilizer })?
            .stabilization else { return "no analysis" }
        guard data.isComplete, data.frameCount == Int(clip.duration) else {
            return "\(data.frameCount) of \(clip.duration) frames"
        }
        return data.corrections.count == data.frameCount && data.zoom >= 1 ? "ok" : "no corrections"
    }

    /// Makes the title follow the mask tracked in `checkTracking`; it should move with it.
    static func checkFollow(_ workspace: WorkspaceController) async -> String {
        guard let sequence = workspace.activeSequence,
              let target = sequence.videoTracks[0].clips.first(where: { $0.opacityMasks.first?.path.isAnimated == true }),
              let mask = target.opacityMasks.first,
              let title = sequence.videoTracks.flatMap(\.clips).first(where: {
                  $0.title != nil && $0.start < target.end && target.start < $0.end
              }) else { return "no title over a tracked clip" }
        guard sequence.followableMasks(for: title).contains(where: { $0.mask.id == mask.id }) else { return "not offered" }
        workspace.program.seek(toFrame: max(title.start, target.start))
        _ = await waitFor(seconds: 5) { workspace.program.currentFrame == max(title.start, target.start) }
        workspace.follow(title.id, target: target.id, owner: .opacity, mask: mask.id)
        guard let following = workspace.activeSequence?.clip(title.id), following.follow?.maskID == mask.id,
              workspace.activeSequence?.followTransform(of: following, atFrame: following.follow?.anchorFrame ?? 0,
                                                        pictureSize: { workspace.maskPictureSize(of: $0) }) != nil
        else { return "not following" }
        return "ok"
    }

    /// Clean Up Dialogue on the tone (A2): the four effects go on, and the export later runs them.
    static func checkDialogue(_ workspace: WorkspaceController) -> String {
        guard let tone = workspace.activeSequence?.audioTracks[1].clips.first else { return "no audio clip" }
        workspace.timeline.selection = [tone.id]
        workspace.cleanUpDialogue()
        let kinds = workspace.activeSequence?.clip(tone.id)?.effects.map(\.kind) ?? []
        return kinds == [.parametricEQ, .noiseReduction, .compressor, .hardLimiter] ? "ok" : "\(kinds)"
    }

    /// Writes the sequence as FCPXML and imports it back as a new sequence, as File ▸ Export ▸
    /// Timeline and File ▸ Import Timeline would. Returns "ok", or what differed.
    static func checkTimelineRoundTrip(_ workspace: WorkspaceController, in directory: URL) async -> String {
        guard let original = workspace.activeSequence else { return "no sequence" }
        var report = InterchangeReport()
        let timeline = InterchangeTimeline(original, project: workspace.project, report: &report)
        let url = directory.appending(path: "timeline.fcpxml")
        do { try InterchangeFormat.fcpxml.write(timeline).write(to: url) } catch { return "write: \(error)" }
        await workspace.importTimeline(from: url)
        workspace.interchangeMessage = nil
        guard let imported = workspace.activeSequence, imported.id != original.id else { return "not imported" }
        func media(_ sequence: EditSequence) -> [String] {
            sequence.videoTracks.flatMap(\.clips).filter { !$0.isGenerated }
                .map { "\($0.start)-\($0.duration)" }.sorted()
        }
        let before = media(original)
        let after = media(imported)
        return before == after ? "ok" : "video clips \(before) → \(after)"
    }
}
