import AppKit
import SWCore

/// Effect Controls and Program monitor editing of clip motion, opacity and volume.
extension WorkspaceController {
    /// The clip Effect Controls shows: the selected video clip, else the selected audio clip.
    var effectControlsClip: (clip: Clip, isVideo: Bool)? {
        guard let sequence = activeSequence else { return nil }
        let clips = timeline.selection.compactMap { sequence.clip($0) }
        let videoIDs = Set(sequence.videoTracks.flatMap { $0.clips.map(\.id) })
        if let video = clips.first(where: { videoIDs.contains($0.id) }) { return (video, true) }
        return clips.first.map { ($0, false) }
    }

    /// The playhead, clamped into the clip, as the clip's source time (where keyframes go).
    func keyframeTime(in clip: Clip) -> RationalTime {
        guard let sequence = activeSequence else { return clip.sourceStart }
        let frame = min(max(playheadFrame, clip.start), clip.end - 1)
        return clip.sourceTime(atSequenceFrame: frame, rate: sequence.rate)
    }

    // MARK: - Values

    /// Sets a property at the playhead. With `live`, the change shows immediately but isn't
    /// an undo step until `endLiveEdit` (used while dragging).
    func setProperty(_ property: ClipProperty, of clipID: UUID, to values: [Double], live: Bool = false) {
        guard let clip = activeSequence?.clip(clipID) else { return }
        let frame = min(max(playheadFrame, clip.start), clip.end - 1)
        let change: (inout EditSequence) -> Void = { $0.setProperty(property, of: clipID, to: values, atFrame: frame) }
        if live {
            liveEdit(change)
        } else {
            editSequence(property.displayName) { sequence, _ in change(&sequence) }
        }
    }

    func liveEdit(_ change: (inout EditSequence) -> Void) {
        guard let id = activeSequenceID, let document else { return }
        if liveEditOriginal == nil { liveEditOriginal = document.project }
        document.performWithoutUndo { $0.updateSequence(id, change) }
    }

    /// Ends a live edit as one undoable change.
    func endLiveEdit(_ actionName: String) {
        guard let original = liveEditOriginal, let document else { return }
        liveEditOriginal = nil
        let final = document.project
        guard final != original else { return }
        document.performWithoutUndo { $0 = original }
        document.perform(actionName, undoManager: undoManager) { $0 = final }
    }

    // MARK: - Keyframes

    func setAnimated(_ animated: Bool, _ property: ClipProperty, of clip: Clip) {
        let time = keyframeTime(in: clip)
        editSequence(animated ? "Enable Keyframes" : "Disable Keyframes") { sequence, _ in
            sequence.updateProperty(property, of: clip.id) { $0.setAnimated(animated, at: time) }
        }
    }

    func toggleKeyframe(_ property: ClipProperty, of clip: Clip) {
        let time = keyframeTime(in: clip)
        let tolerance = activeSequence?.rate.frameDuration ?? RationalTime(value: 1, timescale: 30)
        editSequence("Keyframe") { sequence, _ in
            sequence.updateProperty(property, of: clip.id) { $0.toggleKeyframe(at: time, tolerance: tolerance) }
        }
    }

    /// Moves the playhead to the previous or next keyframe of `property` (all properties if nil).
    func goToKeyframe(next: Bool, _ property: ClipProperty?, of clip: Clip) {
        guard let rate = activeSequence?.rate else { return }
        let time = keyframeTime(in: clip)
        let properties = property.map { [$0] } ?? ClipProperty.allCases
        let candidates = properties.compactMap { name -> Keyframe? in
            let animated = clip.property(name)
            return next ? animated.next(after: time) : animated.previous(before: time)
        }
        let target = next ? candidates.min { $0.time < $1.time } : candidates.max { $0.time < $1.time }
        guard let target else { return }
        program.seek(toFrame: clip.sequenceFrame(atSourceTime: target.time, rate: rate))
    }

    func moveKeyframe(_ id: UUID, _ property: ClipProperty, of clipID: UUID, toFrame frame: Int64, live: Bool) {
        guard let sequence = activeSequence, let clip = sequence.clip(clipID) else { return }
        let clamped = min(max(frame, clip.start), clip.end - 1)
        let time = clip.sourceTime(atSequenceFrame: clamped, rate: sequence.rate)
        let tolerance = sequence.rate.frameDuration
        let change: (inout EditSequence) -> Void = { sequence in
            sequence.updateProperty(property, of: clipID) { $0.move(id, to: time, tolerance: tolerance) }
        }
        if live { liveEdit(change) } else { editSequence("Move Keyframe") { sequence, _ in change(&sequence) } }
    }

    func setInterpolation(_ interpolation: KeyframeInterpolation, ids: Set<UUID>, _ property: ClipProperty,
                          of clipID: UUID) {
        editSequence("Keyframe Interpolation") { sequence, _ in
            sequence.updateProperty(property, of: clipID) { $0.setInterpolation(interpolation, for: ids) }
        }
    }

    func deleteKeyframes(_ ids: Set<UUID>, _ property: ClipProperty, of clipID: UUID) {
        editSequence("Delete Keyframes") { sequence, _ in
            sequence.updateProperty(property, of: clipID) { animated in ids.forEach { animated.remove($0) } }
        }
    }

    func resetProperty(_ property: ClipProperty, of clipID: UUID) {
        editSequence("Reset \(property.displayName)") { sequence, _ in sequence.resetProperty(property, of: clipID) }
    }

    func setUniformScale(_ uniform: Bool, of clipID: UUID) {
        editSequence("Uniform Scale") { sequence, _ in sequence.setUniformScale(uniform, of: clipID) }
    }
}
