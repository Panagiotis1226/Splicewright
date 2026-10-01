import AppKit
import SWCore
import SWPlayback

/// What the New Sequence / Sequence Settings sheet is editing.
public enum SequenceSheetRequest: Identifiable, Equatable {
    case new(SequenceSettings, name: String, mediaIDs: [UUID])
    case edit(UUID)

    public var id: String {
        switch self {
        case .new: return "new"
        case .edit(let id): return id.uuidString
        }
    }
}

/// Sequence and timeline actions. Every edit goes through `ProjectDocument.perform`, so it's
/// undoable and marks the document dirty.
extension WorkspaceController {
    public var activeSequence: EditSequence? {
        activeSequenceID.flatMap { project.sequence($0) }
    }

    /// The playhead, in sequence frames.
    public var playheadFrame: Int64 { program.currentFrame }

    // MARK: - Sequences

    public func requestNewSequence() {
        let first = selectedMediaIDs.first.flatMap { project.item($0) }
        let settings = first.map { SequenceSettings.matching($0.info) } ?? .uhd4K2997
        sequenceSheet = .new(settings, name: "Sequence", mediaIDs: [])
    }

    public func requestSequenceSettings() {
        guard let id = activeSequenceID else { return }
        sequenceSheet = .edit(id)
    }

    /// Creates a sequence and, if `mediaIDs` is non-empty, appends those clips to it.
    @discardableResult
    public func createSequence(named name: String, settings: SequenceSettings, adding mediaIDs: [UUID] = []) -> UUID? {
        var created: EditSequence?
        document?.perform("New Sequence", undoManager: undoManager) { project in
            var sequence = project.addSequence(named: name, settings: settings)
            for id in mediaIDs {
                guard let item = project.item(id) else { continue }
                let placements = sequence.makeClips(for: item, sourceRange: item.marks.range(
                    duration: item.info.duration, rate: item.info.displayFrameRate), at: sequence.durationFrames,
                    videoTrackID: sequence.videoTracks[0].id, audioTrackID: sequence.audioTracks[0].id)
                sequence.overwrite(placements)
            }
            project.updateSequence(sequence.id) { $0 = sequence }
            created = sequence
        }
        if let created {
            activeSequenceID = created.id
            activePanel = .timeline
            timeline.selection = []
        }
        return created?.id
    }

    /// Premiere's "New Sequence from Clip": settings match the clip, which is placed on V1/A1.
    public func newSequence(fromClip id: UUID) {
        guard let item = project.item(id) else { return }
        createSequence(named: item.name, settings: .matching(item.info), adding: [id])
    }

    public func updateSequenceSettings(_ id: UUID, name: String, settings: SequenceSettings) {
        document?.perform("Sequence Settings", undoManager: undoManager) { project in
            project.updateSequence(id) { sequence in
                sequence.settings = settings
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sequence.name = trimmed }
            }
        }
    }

    public func openSequence(_ id: UUID) {
        activeSequenceID = id
        activePanel = .timeline
        timeline.selection = []
        projectDidChange(project)
    }

    public func deleteSequence(_ id: UUID) {
        document?.perform("Delete Sequence", undoManager: undoManager) { $0.deleteSequence(id) }
    }

    public func renameSequence(_ id: UUID, to name: String) {
        document?.perform("Rename Sequence", undoManager: undoManager) { $0.renameSequence(id, to: name) }
    }

    // MARK: - Editing

    /// Applies an undoable change to the active sequence.
    func editSequence(_ actionName: String, _ change: (inout EditSequence, MediaDurations) -> Void) {
        guard let id = activeSequenceID else { return }
        document?.perform(actionName, undoManager: undoManager) { project in
            let durations = project.mediaDurations
            project.updateSequence(id) { sequence in
                change(&sequence, durations)
                // Transitions whose clips no longer meet go away with the edit that separated them.
                sequence.pruneTransitions()
            }
        }
    }

    /// Commits a sequence produced by a timeline drag.
    func commitTimelineEdit(_ actionName: String, _ sequence: EditSequence) {
        editSequence(actionName) { current, _ in current = sequence }
    }

    /// Insert (,) or Overwrite (.) the Source monitor's marked range at the playhead,
    /// on the targeted tracks. Creates a matching sequence if none is open.
    public func editFromSource(overwrite: Bool) {
        guard let item = sourceItem else { return }
        if activeSequence == nil {
            createSequence(named: item.name, settings: .matching(item.info))
        }
        guard let sequence = activeSequence else { return }
        let range = item.marks.range(duration: item.info.duration, rate: item.info.displayFrameRate)
        let frame = min(playheadFrame, sequence.durationFrames)
        let placements = sequence.makeClips(for: item, sourceRange: range, at: frame,
                                            videoTrackID: sequence.targetedVideoTrackID,
                                            audioTrackID: sequence.targetedAudioTrackID)
        guard !placements.isEmpty else {
            NSSound.beep()
            return
        }
        editSequence(overwrite ? "Overwrite" : "Insert") { sequence, _ in
            if overwrite { sequence.overwrite(placements) } else { sequence.insert(placements, at: frame) }
        }
        let end = frame + (placements.map(\.clip.duration).max() ?? 0)
        program.update(sequence: activeSequence, project: project)
        program.seek(toFrame: end)
        timeline.selection = Set(placements.map(\.clip.id))
    }

    /// Lift (;) or Extract (') the sequence In/Out range on targeted tracks (all if none).
    public func liftOrExtract(extract: Bool) {
        guard let sequence = activeSequence, let range = sequence.marks.range else {
            NSSound.beep()
            return
        }
        let targets = Set(sequence.allTracks.filter(\.isTargeted).map(\.id))
        let tracks = targets.isEmpty ? Set(sequence.allTracks.map(\.id)) : targets
        editSequence(extract ? "Extract" : "Lift") { sequence, _ in
            if extract { sequence.extract(range, trackIDs: tracks) } else { sequence.lift(range, trackIDs: tracks) }
            sequence.marks = SequenceMarks()
        }
        if extract { program.seek(toFrame: range.start) }
    }

    public func deleteSelectedClips(ripple: Bool) {
        guard let sequence = activeSequence, !timeline.selection.isEmpty else { return }
        let ids = sequence.expandingLinks(timeline.selection)
        // The selection can hold captions too; they're removed without rippling.
        let captions = captionIDs(in: timeline.selection)
        editSequence(ripple ? "Ripple Delete" : "Delete") { sequence, _ in
            sequence.delete(ids.subtracting(captions), ripple: ripple)
            sequence.deleteCaptions(captions)
        }
        timeline.selection = []
    }

    /// Add Edit (⌘K): cut at the playhead on targeted tracks, or on every track with `allTracks`.
    public func addEdit(allTracks: Bool) {
        guard let sequence = activeSequence else { return }
        let targeted = Set(sequence.allTracks.filter(\.isTargeted).map(\.id))
        let tracks = allTracks || targeted.isEmpty ? Set(sequence.allTracks.map(\.id)) : targeted
        let frame = playheadFrame
        editSequence("Add Edit") { sequence, _ in sequence.razor(at: frame, trackIDs: tracks) }
    }

    public func setClipsEnabled(_ ids: Set<UUID>, _ enabled: Bool) {
        editSequence(enabled ? "Enable Clip" : "Disable Clip") { sequence, _ in
            sequence.updateClipProperties(ids) { $0.isEnabled = enabled }
        }
    }

    public func setClipsLinked(_ ids: Set<UUID>, _ linked: Bool) {
        editSequence(linked ? "Link" : "Unlink") { sequence, _ in sequence.setLinked(ids, linked) }
    }

    public func setClipOpacity(_ ids: Set<UUID>, _ opacity: Double) {
        editSequence("Opacity") { sequence, _ in
            sequence.updateClipProperties(ids) { $0.opacity = min(max(opacity, 0), 1) }
        }
    }

    public func setClipGain(_ ids: Set<UUID>, _ gainDB: Double) {
        editSequence("Audio Gain") { sequence, _ in
            sequence.updateClipProperties(ids) { $0.gainDB = min(max(gainDB, -60), 24) }
        }
    }

    public func setTrackFlags(_ trackID: UUID, _ name: String, _ change: @escaping (inout Track) -> Void) {
        editSequence(name) { sequence, _ in sequence.setTrackFlags(trackID, change) }
    }

    public func addTrack(_ kind: TrackKind) {
        editSequence(kind == .video ? "Add Video Track" : "Add Audio Track") { sequence, _ in
            sequence.addTrack(kind)
        }
    }

    public func removeTrack(_ trackID: UUID) {
        editSequence("Delete Track") { sequence, _ in sequence.removeTrack(trackID) }
    }

    /// Drops Project-panel clips onto the timeline at `frame`. Video goes to the video track
    /// matching `trackID`'s number, audio to the matching audio track. Overwrites, or inserts
    /// with `insert` (⌘-drag). Creates a sequence from the first clip if none is open.
    public func dropMedia(_ ids: [UUID], atFrame frame: Int64, trackID: UUID?, insert: Bool) {
        let items = ids.compactMap { project.item($0) }
        guard let first = items.first else { return }
        if activeSequence == nil {
            createSequence(named: first.name, settings: .matching(first.info), adding: items.map(\.id))
            return
        }
        guard let sequence = activeSequence else { return }
        let (videoTrack, audioTrack) = tracks(pairedWith: trackID, in: sequence)
        var placements: [TrackPlacement] = []
        var cursor = max(0, frame)
        for item in items {
            let range = item.marks.range(duration: item.info.duration, rate: item.info.displayFrameRate)
            let clips = sequence.makeClips(for: item, sourceRange: range, at: cursor, videoTrackID: videoTrack,
                                           audioTrackID: audioTrack)
            placements += clips
            cursor += clips.map(\.clip.duration).max() ?? 0
        }
        guard !placements.isEmpty else { return }
        let start = max(0, frame)
        editSequence(insert ? "Insert" : "Overwrite") { sequence, _ in
            if insert {
                sequence.insertGap(at: start, length: cursor - start, targets: Set(placements.map(\.trackID)))
            }
            sequence.overwrite(placements)
        }
        timeline.selection = Set(placements.map(\.clip.id))
        activePanel = .timeline
    }

    /// The video and audio tracks with the same number as `trackID` (V2 ↔ A2).
    func tracks(pairedWith trackID: UUID?, in sequence: EditSequence) -> (video: UUID?, audio: UUID?) {
        let videoIndex = sequence.videoTracks.firstIndex { $0.id == trackID }
        let audioIndex = sequence.audioTracks.firstIndex { $0.id == trackID }
        let index = videoIndex ?? audioIndex ?? 0
        let video = sequence.videoTracks[min(index, sequence.videoTracks.count - 1)]
        let audio = sequence.audioTracks[min(index, sequence.audioTracks.count - 1)]
        return (video.isLocked ? nil : video.id, audio.isLocked ? nil : audio.id)
    }

    // MARK: - Sequence transport and marks

    func handleSequenceTransport(_ action: ShortcutAction) -> Bool {
        guard let sequence = activeSequence else { return false }
        let engine = program
        switch action {
        case .togglePlay: engine.togglePlay()
        case .shuttleForward: engine.shuttleForward()
        case .shuttleReverse: engine.shuttleReverse()
        case .shuttleStop: engine.pause()
        case .stepForward(let frames): engine.step(by: Int64(frames))
        case .stepBackward(let frames): engine.step(by: -Int64(frames))
        case .goToStart: engine.seek(toFrame: 0)
        case .goToEnd: engine.seek(toFrame: sequence.durationFrames)
        case .previousEditPoint:
            engine.pause()
            engine.seek(toFrame: sequence.previousEditPoint(before: engine.currentFrame) ?? 0)
        case .nextEditPoint:
            engine.pause()
            if let next = sequence.nextEditPoint(after: engine.currentFrame) { engine.seek(toFrame: next) }
        default:
            return handleSequenceMarks(action, in: sequence)
        }
        return true
    }

    private func handleSequenceMarks(_ action: ShortcutAction, in sequence: EditSequence) -> Bool {
        let frame = program.currentFrame
        switch action {
        case .goToIn:
            if let frame = sequence.marks.inFrame { program.seek(toFrame: frame) }
        case .goToOut:
            if let frame = sequence.marks.outFrame { program.seek(toFrame: frame) }
        case .markIn:
            editSequence("Mark In") { sequence, _ in
                sequence.marks.inFrame = frame
                if let out = sequence.marks.outFrame, out < frame { sequence.marks.outFrame = nil }
            }
        case .markOut:
            editSequence("Mark Out") { sequence, _ in
                sequence.marks.outFrame = frame
                if let inFrame = sequence.marks.inFrame, inFrame > frame { sequence.marks.inFrame = nil }
            }
        case .clearIn: editSequence("Clear In") { sequence, _ in sequence.marks.inFrame = nil }
        case .clearOut: editSequence("Clear Out") { sequence, _ in sequence.marks.outFrame = nil }
        case .clearInAndOut: editSequence("Clear In and Out") { sequence, _ in sequence.marks = SequenceMarks() }
        default:
            return false
        }
        return true
    }

    /// Editing keys that work from any panel (or from the timeline only, where noted).
    func handleEditingShortcut(_ action: ShortcutAction) -> Bool {
        switch action {
        case .insertEdit:
            editFromSource(overwrite: false)
        case .overwriteEdit:
            editFromSource(overwrite: true)
        case .liftEdit:
            liftOrExtract(extract: false)
        case .extractEdit:
            liftOrExtract(extract: true)
        case .deleteSelection where activePanel == .timeline && timeline.selectedTransition != nil:
            if let id = timeline.selectedTransition { deleteTransition(id) }
        case .deleteSelection where activePanel == .timeline:
            deleteSelectedClips(ripple: false)
        case .rippleDelete where activePanel == .timeline:
            deleteSelectedClips(ripple: true)
        case .zoomIn where activePanel == .timeline:
            timeline.zoom(by: 1.5, anchorX: timelineAnchorX, headerWidth: TimelineLayout.headerWidth)
        case .zoomOut where activePanel == .timeline:
            timeline.zoom(by: 1 / 1.5, anchorX: timelineAnchorX, headerWidth: TimelineLayout.headerWidth)
        case .zoomToFit where activePanel == .timeline:
            timeline.zoomToFit(durationFrames: activeSequence?.durationFrames ?? 0, laneWidth: timelineLaneWidth)
        case .toggleSnapping where activePanel == .timeline:
            timeline.isSnapping.toggle()
        default:
            return false
        }
        return true
    }

    /// Zoom keys keep the playhead in place.
    private var timelineAnchorX: CGFloat {
        TimelineLayout.headerWidth + CGFloat(playheadFrame) * timeline.pixelsPerFrame - timeline.scrollX
    }

    /// Width of the clip lanes, reported by the timeline view.
    var timelineLaneWidth: CGFloat {
        get { TimelineLayout.lastLaneWidth }
        set { TimelineLayout.lastLaneWidth = newValue }
    }
}
