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
}
