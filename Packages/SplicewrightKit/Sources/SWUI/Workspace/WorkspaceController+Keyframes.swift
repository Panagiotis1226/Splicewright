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
    func keyframeTime(in clip: Clip, for property: ClipProperty = .position) -> RationalTime {
        keyframeTime(in: clip, for: .clip(property))
    }

    func keyframeTime(in clip: Clip, for ref: PropertyRef) -> RationalTime {
        guard let sequence = activeSequence else { return clip.sourceStart }
        let frame = min(max(playheadFrame, clip.start), clip.end - 1)
        return clip.keyframeTime(for: ref, atSequenceFrame: frame, rate: sequence.rate)
    }

    // MARK: - Values

    /// Sets a property at the playhead. With `live`, the change shows immediately but isn't
    /// an undo step until `endLiveEdit` (used while dragging).
    func setProperty(_ property: ClipProperty, of clipID: UUID, to values: [Double], live: Bool = false) {
        setValue(.clip(property), of: clipID, to: values, actionName: property.displayName, live: live)
    }

    func setValue(_ ref: PropertyRef, of clipID: UUID, to values: [Double], actionName: String, live: Bool = false) {
        guard let clip = activeSequence?.clip(clipID) else { return }
        // A constant speed changes the clip's length, as Speed/Duration does.
        if ref == .clip(.speed), !clip.speed.isAnimated, let percent = values.first {
            setConstantSpeed(percent, of: clip, live: live)
            return
        }
        let frame = min(max(playheadFrame, clip.start), clip.end - 1)
        let change: (inout EditSequence) -> Void = { $0.setAnimatable(ref, of: clipID, to: values, atFrame: frame) }
        if live {
            liveEdit(change)
        } else {
            editSequence(actionName) { sequence, _ in change(&sequence) }
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
        setAnimated(animated, .clip(property), of: clip)
    }

    func setAnimated(_ animated: Bool, _ ref: PropertyRef, of clip: Clip) {
        let time = keyframeTime(in: clip, for: ref)
        editSequence(animated ? "Enable Keyframes" : "Disable Keyframes") { sequence, _ in
            sequence.updateAnimatable(ref, of: clip.id) { $0.setAnimated(animated, at: time) }
        }
    }

    func toggleKeyframe(_ ref: PropertyRef, of clip: Clip) {
        let time = keyframeTime(in: clip, for: ref)
        let tolerance = activeSequence?.rate.frameDuration ?? RationalTime(value: 1, timescale: 30)
        editSequence("Keyframe") { sequence, _ in
            sequence.updateAnimatable(ref, of: clip.id) { $0.toggleKeyframe(at: time, tolerance: tolerance) }
        }
    }

    /// Every keyframeable number of a clip: its properties and its effects' parameters.
    func allRefs(of clip: Clip) -> [PropertyRef] {
        ClipProperty.allCases.map { PropertyRef.clip($0) }
            + clip.effects.flatMap { effect in effect.kind.parameters.map { PropertyRef.effect(effect.id, $0.key) } }
    }

    /// Moves the playhead to the previous or next keyframe of `ref` (of everything if nil).
    func goToKeyframe(next: Bool, _ ref: PropertyRef?, of clip: Clip) {
        guard let rate = activeSequence?.rate else { return }
        let refs = ref.map { [$0] } ?? allRefs(of: clip)
        // Each property's keyframes in its own time, compared as sequence frames.
        let frames = refs.compactMap { ref -> Int64? in
            let time = keyframeTime(in: clip, for: ref)
            guard let animated = clip.animatable(ref),
                  let keyframe = next ? animated.next(after: time) : animated.previous(before: time) else { return nil }
            return clip.sequenceFrame(ofKeyframeTime: keyframe.time, for: ref, rate: rate)
        }
        guard let target = next ? frames.min() : frames.max() else { return }
        program.seek(toFrame: target)
    }

    func moveKeyframe(_ id: UUID, _ ref: PropertyRef, of clipID: UUID, toFrame frame: Int64, live: Bool) {
        guard let sequence = activeSequence, let clip = sequence.clip(clipID) else { return }
        let clamped = min(max(frame, clip.start), clip.end - 1)
        let time = clip.keyframeTime(for: ref, atSequenceFrame: clamped, rate: sequence.rate)
        let tolerance = sequence.rate.frameDuration
        let change: (inout EditSequence) -> Void = { sequence in
            sequence.updateAnimatable(ref, of: clipID) { $0.move(id, to: time, tolerance: tolerance) }
        }
        if live { liveEdit(change) } else { editSequence("Move Keyframe") { sequence, _ in change(&sequence) } }
    }

    func setInterpolation(_ interpolation: KeyframeInterpolation, ids: Set<UUID>, _ ref: PropertyRef, of clipID: UUID) {
        editSequence("Keyframe Interpolation") { sequence, _ in
            sequence.updateAnimatable(ref, of: clipID) { $0.setInterpolation(interpolation, for: ids) }
        }
    }

    func deleteKeyframes(_ ids: Set<UUID>, _ ref: PropertyRef, of clipID: UUID) {
        editSequence("Delete Keyframes") { sequence, _ in
            sequence.updateAnimatable(ref, of: clipID) { animated in ids.forEach { animated.remove($0) } }
        }
    }

    /// One number of one keyframe: X or Y of a Position keyframe, say.
    struct KeyframeComponent {
        var id: UUID
        var property: PropertyRef
        var component: Int
    }

    /// Sets one component of a keyframe's value (dragging its point in the graph editor).
    func setKeyframeValue(_ value: Double, _ point: KeyframeComponent, of clipID: UUID, live: Bool) {
        let change: (inout EditSequence) -> Void = { sequence in
            sequence.updateAnimatable(point.property, of: clipID) {
                $0.setValue(value, component: point.component, of: point.id)
            }
        }
        if live { liveEdit(change) } else { editSequence("Keyframe Value") { sequence, _ in change(&sequence) } }
    }

    /// A dragged Bezier handle in the graph editor.
    struct HandleEdit {
        var side: HandleSide
        var slopes: [Double]
        var influence: Double
        /// ⌥-drag: the other side stays where it is.
        var breaking: Bool
    }

    func setHandle(_ edit: HandleEdit, of id: UUID, _ ref: PropertyRef, of clipID: UUID, live: Bool) {
        let change: (inout EditSequence) -> Void = { sequence in
            sequence.updateAnimatable(ref, of: clipID) {
                $0.setHandle(edit.side, of: id, slopes: edit.slopes, influence: edit.influence, breaking: edit.breaking)
            }
        }
        if live { liveEdit(change) } else { editSequence("Keyframe Handle") { sequence, _ in change(&sequence) } }
    }

    func resetValue(_ ref: PropertyRef, of clipID: UUID, actionName: String) {
        editSequence(actionName) { sequence, _ in sequence.resetAnimatable(ref, of: clipID) }
    }

    func setUniformScale(_ uniform: Bool, of clipID: UUID) {
        editSequence("Uniform Scale") { sequence, _ in sequence.setUniformScale(uniform, of: clipID) }
    }
}
