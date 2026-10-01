import Foundation

/// What the Speed/Duration dialog asks for, as in Premiere.
public struct SpeedChange: Sendable, Hashable {
    /// Percent; nil keeps each clip's speed (e.g. when only toggling Reverse).
    public var percent: Double?
    /// A new duration in frames instead of a speed: the speed follows from the source span.
    public var duration: Int64?
    public var isReversed: Bool
    public var maintainsPitch: Bool
    /// Shift later clips (and sync-locked tracks) so nothing overlaps or leaves a gap.
    public var ripple: Bool

    public init(percent: Double? = nil, duration: Int64? = nil, isReversed: Bool = false, maintainsPitch: Bool = true,
                ripple: Bool = false) {
        self.percent = percent
        self.duration = duration
        self.isReversed = isReversed
        self.maintainsPitch = maintainsPitch
        self.ripple = ripple
    }
}

public extension EditSequence {
    /// Applies Speed/Duration to clips (pass linked partners too). The source each clip plays
    /// stays the same, so its length changes with its speed. Without ripple, a clip that would
    /// run into the next one is shortened to fit. Clips with Time Remapping are skipped.
    mutating func changeSpeed(_ ids: Set<UUID>, _ change: SpeedChange) {
        let rate = self.rate
        // Later clips first, so rippling one doesn't move another before it's changed.
        let targets = allTracks.flatMap { track in track.clips.filter { ids.contains($0.id) }.map { (track.id, $0) } }
            .sorted { $0.1.start > $1.1.start }
        var rippled: Set<UUID> = []
        for (trackID, original) in targets where !original.speed.isAnimated && !rippled.contains(original.id) {
            guard let current = clip(original.id), track(trackID)?.isLocked == false else { continue }
            let span = current.timing(rate: rate).sourceSpan
            let wanted: (duration: Int64, percent: Double)
            if let duration = change.duration {
                let frames = max(1, duration)
                wanted = (frames, span * rate.framesPerSecond / Double(frames) * 100)
            } else {
                let percent = min(max(change.percent ?? current.speedPercent, ClipTiming.constantSpeedRange.lowerBound),
                                  ClipTiming.constantSpeedRange.upperBound)
                wanted = (max(1, Int64((span * rate.framesPerSecond / (percent / 100)).rounded())), percent)
            }
            let percent = min(max(wanted.percent, ClipTiming.constantSpeedRange.lowerBound),
                              ClipTiming.constantSpeedRange.upperBound)
            // The partners that share this clip's edges move with it when rippling.
            let group = editGroup(for: current.id, edge: nil).filter { ids.contains($0.clip.id) }
            let groupTracks = Set(group.map(\.trackID))
            let members = change.ripple ? group : [(trackID: trackID, clip: current)]
            // Reversing plays the same source from its other end: the last frame shown comes
            // first. Worked out before any lengths change.
            var reversedStarts: [UUID: RationalTime] = [:]
            for (_, member) in members where member.isReversed != change.isReversed {
                reversedStarts[member.id] = member.sourceTime(atSequenceFrame: member.end - 1, rate: rate)
            }
            var newDuration = wanted.duration
            if change.ripple {
                let delta = newDuration - current.duration
                if delta > 0 {
                    insertGap(at: current.end, length: delta, targets: groupTracks)
                } else if delta < 0 {
                    // Close the gap after the shortened clips on their tracks and sync-locked ones.
                    for (partnerTrack, partner) in group { updateClip(partner.id, on: partnerTrack) { $0.duration += delta } }
                    extract(FrameRange(start: current.end + delta, end: current.end), trackIDs: groupTracks)
                }
                rippled.formUnion(group.map(\.clip.id))
            } else if let track = track(trackID), let next = nextClip(after: current, on: track) {
                newDuration = min(newDuration, next.start - current.start)
            }
            for (memberTrack, member) in members {
                updateClip(member.id, on: memberTrack) { clip in
                    if let start = reversedStarts[member.id] { clip.sourceStart = start }
                    clip.isReversed = change.isReversed
                    clip.speed = AnimatableProperty([percent])
                    clip.maintainsPitch = change.maintainsPitch
                    clip.duration = max(1, newDuration)
                }
            }
        }
    }

    /// Rate Stretch tool: drags an edge to change the clip's length, changing its speed so it
    /// still plays the same source. Returns the frames actually applied.
    @discardableResult
    mutating func rateStretch(_ clipID: UUID, edge: TrimEdge, by delta: Int64) -> Int64 {
        let group = editGroup(for: clipID, edge: edge)
        guard !group.isEmpty else { return 0 }
        let rate = self.rate
        var bounds = DeltaBounds()
        for (trackID, clip) in group {
            guard let track = track(trackID), !clip.speed.isAnimated else { return 0 }
            let span = clip.timing(rate: rate).sourceSpan * rate.framesPerSecond
            // Keep the speed within 1%...10000%.
            let shortest = max(1, Int64((span / (ClipTiming.constantSpeedRange.upperBound / 100)).rounded(.up)))
            let longest = Int64((span / (ClipTiming.constantSpeedRange.lowerBound / 100)).rounded(.down))
            switch edge {
            case .start:
                bounds.atMost(clip.duration - shortest)
                bounds.atLeast(clip.duration - longest)
                bounds.atLeast((previousClip(before: clip, on: track)?.end ?? 0) - clip.start)
            case .end:
                bounds.atLeast(shortest - clip.duration)
                bounds.atMost(longest - clip.duration)
                if let next = nextClip(after: clip, on: track) { bounds.atMost(next.start - clip.end) }
            }
        }
        let applied = bounds.clamp(delta)
        guard applied != 0 else { return 0 }
        for (trackID, clip) in group {
            let span = clip.timing(rate: rate).sourceSpan * rate.framesPerSecond
            let duration = edge == .start ? clip.duration - applied : clip.duration + applied
            updateClip(clip.id, on: trackID) { clip in
                if edge == .start { clip.start += applied }
                clip.duration = duration
                clip.speed = AnimatableProperty([span / Double(duration) * 100])
            }
        }
        return applied
    }
}
