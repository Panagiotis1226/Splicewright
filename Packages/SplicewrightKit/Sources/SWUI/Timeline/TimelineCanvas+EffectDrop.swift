import AppKit
import SWCore

/// Video effects dropped on clips, and adjustment layers dropped on video tracks.
extension TimelineCanvas {
    private func payloads(_ info: NSDraggingInfo) -> [String] {
        (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .string) }
    }

    func droppedEffect(_ info: NSDraggingInfo) -> VideoEffectKind? {
        guard let payload = payloads(info).first(where: { $0.hasPrefix(EffectsPanel.effectPrefix) }) else { return nil }
        return VideoEffectKind(rawValue: String(payload.dropFirst(EffectsPanel.effectPrefix.count)))
    }

    func isAdjustmentDrop(_ info: NSDraggingInfo) -> Bool {
        payloads(info).contains(EffectsPanel.adjustmentPayload)
    }

    /// The video clip under the drop, and the clips the effect goes on: the whole selection
    /// when the clip is part of it, as in Premiere.
    private func effectDrop(_ info: NSDraggingInfo) -> (clip: Clip, trackID: UUID, ids: Set<UUID>)? {
        guard let sequence = workspace.activeSequence else { return nil }
        let point = convert(info.draggingLocation, from: nil)
        guard let hit = clipHit(at: point, in: sequence), hit.row.kind == .video,
              sequence.track(hit.row.trackID)?.isLocked == false else { return nil }
        let ids = timeline.selection.contains(hit.clip.id) ? timeline.selection : [hit.clip.id]
        return (hit.clip, hit.row.trackID, ids)
    }

    /// The drop highlight for an effect or adjustment layer drag, or nil for any other drag.
    func updateEffectDropTarget(_ info: NSDraggingInfo) -> NSDragOperation? {
        if droppedEffect(info) != nil {
            guard let drop = effectDrop(info) else {
                timeline.dropTarget = nil
                return []
            }
            timeline.dropTarget = TimelineState.DropTarget(frame: drop.clip.start, trackID: drop.trackID,
                                                           length: drop.clip.duration)
            return .copy
        }
        guard isAdjustmentDrop(info) else { return nil }
        let location = dropLocation(info)
        guard let sequence = workspace.activeSequence, let trackID = location.trackID,
              sequence.videoTracks.contains(where: { $0.id == trackID }) else {
            timeline.dropTarget = nil
            return workspace.activeSequence == nil ? .copy : []
        }
        timeline.dropTarget = TimelineState.DropTarget(frame: location.frame, trackID: trackID,
                                                       length: Int64((5 * sequence.rate.framesPerSecond).rounded()))
        return .copy
    }

    /// Whether an effect or adjustment layer drop worked, or nil for any other drag.
    func performEffectDrop(_ info: NSDraggingInfo) -> Bool? {
        if let kind = droppedEffect(info) {
            guard let drop = effectDrop(info) else { return false }
            workspace.addEffect(kind, to: drop.ids)
            return true
        }
        guard isAdjustmentDrop(info) else { return nil }
        let location = dropLocation(info)
        let isVideo = workspace.activeSequence?.videoTracks.contains { $0.id == location.trackID } ?? true
        guard isVideo else { return false }
        workspace.newAdjustmentLayer(trackID: workspace.activeSequence == nil ? nil : location.trackID,
                                     frame: location.frame)
        return true
    }
}
