import Foundation
import SWCore

extension SmokeTestDriver {
    /// Tracks the mask added in `addEffects` four frames forward (Texture, not stopping when
    /// unsure, since the fixtures are synthetic); each frame should get a Mask Path keyframe.
    static func checkTracking(_ workspace: WorkspaceController) async -> String {
        guard let clip = workspace.activeSequence?.videoTracks[0].clips.first(where: { !$0.opacityMasks.isEmpty }),
              let mask = clip.opacityMasks.first else { return "no masked clip" }
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
}
