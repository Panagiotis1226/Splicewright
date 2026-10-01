import Foundation

/// What moved between Splicewright and an interchange file, and what couldn't.
public struct InterchangeReport: Sendable, Equatable {
    public var notes: [String] = []
    public init(notes: [String] = []) { self.notes = notes }
}

public extension InterchangeTimeline {
    /// The sequence as an interchange timeline: clips, cuts, transitions, constant speed,
    /// opacity, gain and markers. Titles, adjustment layers, effects and keyframes stay behind
    /// (the report says what was left out).
    init(_ sequence: EditSequence, project: Project, report: inout InterchangeReport) {
        self.init(name: sequence.name, width: sequence.settings.width, height: sequence.settings.height,
                  rate: sequence.rate)
        var generated = 0
        var remapped = 0
        var animated = 0
        var effects = 0
        func tracks(_ source: [Track], isAudio: Bool) -> [[InterchangeClip]] {
            source.map { track in
                track.clips.compactMap { clip -> InterchangeClip? in
                    guard !clip.isGenerated, let item = project.item(clip.mediaID) else {
                        generated += 1
                        return nil
                    }
                    if clip.speed.isAnimated { remapped += 1 }
                    if clip.isAnimated { animated += 1 }
                    if !clip.effects.isEmpty { effects += 1 }
                    let media = InterchangeMedia(path: item.filePath, name: item.name, duration: item.info.duration,
                                                 hasVideo: item.info.video != nil, hasAudio: !item.info.audio.isEmpty,
                                                 width: item.info.video?.width, height: item.info.video?.height)
                    let speed = clip.speedPercent * (clip.isReversed ? -1 : 1)
                    return InterchangeClip(name: clip.name, media: media, start: clip.start, duration: clip.duration,
                                           sourceStart: clip.sourceStart, speed: speed, isEnabled: clip.isEnabled,
                                           opacity: isAudio ? 1 : clip.opacity, gainDB: isAudio ? clip.gainDB : 0)
                }
            }
        }
        videoTracks = tracks(sequence.videoTracks, isAudio: false)
        audioTracks = tracks(sequence.audioTracks, isAudio: true)
        for (isAudio, list) in [(false, sequence.videoTracks), (true, sequence.audioTracks)] {
            for (index, track) in list.enumerated() {
                transitions += track.resolvedTransitions.map { resolved in
                    InterchangeTransition(isAudio: isAudio, track: index, frame: resolved.cut, before: resolved.before,
                                          after: resolved.after, kind: resolved.kind)
                }
            }
        }
        markers = sequence.markers
        if generated > 0 { report.notes.append("\(generated) title or adjustment layer clip(s) aren't included.") }
        if remapped > 0 { report.notes.append("\(remapped) time-remapped clip(s) are written at their starting speed.") }
        if animated > 0 { report.notes.append("Keyframes on \(animated) clip(s) aren't included.") }
        if effects > 0 { report.notes.append("Effects on \(effects) clip(s) aren't included.") }
    }
}

public extension EditSequence {
    /// A sequence from an interchange timeline. `mediaIDs` maps each file path to the project's
    /// media item for it; clips whose file has no item are skipped (and counted in the report).
    init(_ timeline: InterchangeTimeline, settings: SequenceSettings, mediaIDs: [String: UUID],
         report: inout InterchangeReport) {
        self.init(name: timeline.name, settings: settings, videoTrackCount: max(3, timeline.videoTracks.count),
                  audioTrackCount: max(3, timeline.audioTracks.count))
        // A video clip and an audio clip of the same file at the same place are linked, as an
        // A/V clip dropped on the timeline would be.
        var links: [String: UUID] = [:]
        func linkKey(_ clip: InterchangeClip) -> String {
            "\(clip.media?.path ?? "")|\(clip.start)|\(clip.duration)|\(clip.sourceStart.seconds)"
        }
        for clip in timeline.videoTracks.flatMap({ $0 }) where timeline.audioTracks.flatMap({ $0 }).contains(where: {
            linkKey($0) == linkKey(clip)
        }) {
            links[linkKey(clip)] = UUID()
        }
        var skipped = 0
        var placements: [TrackPlacement] = []
        for (tracks, isAudio) in [(timeline.videoTracks, false), (timeline.audioTracks, true)] {
            for (index, clips) in tracks.enumerated() {
                let trackID = isAudio ? audioTracks[index].id : videoTracks[index].id
                for source in clips {
                    guard let path = source.media?.path, let mediaID = mediaIDs[path], source.duration > 0 else {
                        skipped += 1
                        continue
                    }
                    var clip = Clip(mediaID: mediaID, name: source.name, start: source.start, duration: source.duration,
                                    sourceStart: source.sourceStart, linkID: links[linkKey(source)], isEnabled: source.isEnabled)
                    if abs(source.speed - 100) > 0.001 {
                        clip.speed = AnimatableProperty([min(max(abs(source.speed), 1), 10_000)])
                        clip.isReversed = source.speed < 0
                    }
                    if isAudio {
                        clip.gainDB = source.gainDB
                    } else if source.opacity < 1 {
                        clip.motion.opacity.values = [max(source.opacity, 0) * 100]
                    }
                    placements.append(TrackPlacement(trackID: trackID, clip: clip))
                }
            }
        }
        overwrite(placements)
        for transition in timeline.transitions where transition.duration > 0 {
            let tracks = transition.isAudio ? audioTracks : videoTracks
            guard transition.track < tracks.count else { continue }
            addTransition(transition.kind, trackID: tracks[transition.track].id, at: transition.frame,
                          duration: transition.duration, alignment: transition.alignment)
        }
        markers = timeline.markers.sorted { $0.frame < $1.frame }
        if skipped > 0 { report.notes.append("\(skipped) clip(s) had no media file and were left out.") }
    }
}
