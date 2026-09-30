import Foundation

/// Trim, ripple, roll, slip and slide. Each takes a requested frame delta, clamps it to what
/// the media and neighbouring clips allow, applies it to the clip and its linked partners,
/// and returns the delta actually applied (0 if nothing could move).
public extension EditSequence {
    /// Allowed delta range, intersected across every clip an edit touches.
    struct DeltaBounds {
        var lower = Int64.min
        var upper = Int64.max

        mutating func atLeast(_ value: Int64) { lower = max(lower, value) }
        mutating func atMost(_ value: Int64) { upper = min(upper, value) }

        func clamp(_ delta: Int64) -> Int64 {
            guard lower <= upper else { return 0 }
            return min(max(delta, lower), upper)
        }
    }

    /// Selection-tool trim: moves one edge of a clip without affecting other clips.
    @discardableResult
    mutating func trim(_ clipID: UUID, edge: TrimEdge, by delta: Int64, media: MediaDurations) -> Int64 {
        let group = editGroup(for: clipID, edge: edge)
        guard !group.isEmpty else { return 0 }
        var bounds = DeltaBounds()
        for (trackID, clip) in group {
            guard let track = track(trackID) else { continue }
            switch edge {
            case .start:
                bounds.atMost(clip.duration - 1)
                bounds.atLeast(-framesBefore(clip))
                bounds.atLeast((previousClip(before: clip, on: track)?.end ?? 0) - clip.start)
            case .end:
                bounds.atLeast(1 - clip.duration)
                if let available = availableFrames(of: clip.mediaID, after: clip.sourceStart, media: media) {
                    bounds.atMost(available - clip.duration)
                }
                if let next = nextClip(after: clip, on: track) { bounds.atMost(next.start - clip.end) }
            }
        }
        let applied = bounds.clamp(delta)
        guard applied != 0 else { return 0 }
        let rate = self.rate
        for (trackID, clip) in group {
            updateClip(clip.id, on: trackID) { clip in
                switch edge {
                case .start:
                    clip.start += applied
                    clip.duration -= applied
                    clip.sourceStart += RationalTime(frames: applied, rate: rate)
                case .end:
                    clip.duration += applied
                }
            }
        }
        return applied
    }

    /// Ripple Edit tool: trims an edge and shifts everything after it (on sync-locked tracks
    /// too), so no gap opens or overlap occurs. The clip's start position never moves.
    @discardableResult
    mutating func rippleTrim(_ clipID: UUID, edge: TrimEdge, by delta: Int64, media: MediaDurations) -> Int64 {
        let group = editGroup(for: clipID, edge: edge)
        guard let reference = group.first?.clip else { return 0 }
        var bounds = DeltaBounds()
        for (_, clip) in group {
            switch edge {
            case .start:
                bounds.atMost(clip.duration - 1)
                bounds.atLeast(-framesBefore(clip))
            case .end:
                bounds.atLeast(1 - clip.duration)
                if let available = availableFrames(of: clip.mediaID, after: clip.sourceStart, media: media) {
                    bounds.atMost(available - clip.duration)
                }
            }
        }
        let applied = bounds.clamp(delta)
        guard applied != 0 else { return 0 }
        let trackIDs = Set(group.map(\.trackID))
        let rate = self.rate

        switch (edge, applied > 0) {
        case (.start, true):
            // Remove the first `applied` frames: the clip's head is trimmed and the rest closes up.
            extract(FrameRange(start: reference.start, length: applied), trackIDs: trackIDs)
        case (.start, false):
            let extra = -applied
            insertGap(at: reference.start, length: extra, targets: trackIDs)
            for (trackID, clip) in group {
                updateClip(clip.id, on: trackID) { clip in
                    clip.start -= extra
                    clip.duration += extra
                    clip.sourceStart -= RationalTime(frames: extra, rate: rate)
                }
            }
        case (.end, false):
            extract(FrameRange(start: reference.end + applied, end: reference.end), trackIDs: trackIDs)
        case (.end, true):
            insertGap(at: reference.end, length: applied, targets: trackIDs)
            for (trackID, clip) in group {
                updateClip(clip.id, on: trackID) { $0.duration += applied }
            }
        }
        return applied
    }

    /// Rolling Edit tool: moves the cut at `frame` on the clip's track (and its linked
    /// partners' tracks), lengthening one side and shortening the other.
    @discardableResult
    mutating func roll(clipID: UUID, edge: TrimEdge, by delta: Int64, media: MediaDurations) -> Int64 {
        guard let clip = clip(clipID) else { return 0 }
        let frame = edge == .start ? clip.start : clip.end
        let trackIDs = Set(editGroup(for: clipID, edge: edge).map(\.trackID))
        struct CutPair {
            var trackID: UUID
            var left: Clip?
            var right: Clip?
        }
        var pairs: [CutPair] = []
        for trackID in trackIDs {
            guard let track = track(trackID) else { continue }
            let left = track.clips.first { $0.end == frame }
            let right = track.clips.first { $0.start == frame }
            if left != nil || right != nil { pairs.append(CutPair(trackID: trackID, left: left, right: right)) }
        }
        var bounds = DeltaBounds()
        for pair in pairs {
            let (trackID, left, right) = (pair.trackID, pair.left, pair.right)
            guard let track = track(trackID) else { continue }
            if let left {
                bounds.atLeast(1 - left.duration)
                if let available = availableFrames(of: left.mediaID, after: left.sourceStart, media: media) {
                    bounds.atMost(available - left.duration)
                }
                if right == nil, let next = nextClip(after: left, on: track) { bounds.atMost(next.start - left.end) }
            }
            if let right {
                bounds.atMost(right.duration - 1)
                bounds.atLeast(-framesBefore(right))
                if left == nil { bounds.atLeast((previousClip(before: right, on: track)?.end ?? 0) - right.start) }
            }
        }
        let applied = bounds.clamp(delta)
        guard applied != 0 else { return 0 }
        let rate = self.rate
        for pair in pairs {
            let (trackID, left, right) = (pair.trackID, pair.left, pair.right)
            if let left { updateClip(left.id, on: trackID) { $0.duration += applied } }
            if let right {
                updateClip(right.id, on: trackID) { clip in
                    clip.start += applied
                    clip.duration -= applied
                    clip.sourceStart += RationalTime(frames: applied, rate: rate)
                }
            }
        }
        return applied
    }

    /// Slip tool: changes which part of the source a clip shows, keeping its position and length.
    @discardableResult
    mutating func slip(_ clipID: UUID, by delta: Int64, media: MediaDurations) -> Int64 {
        let group = editGroup(for: clipID, edge: nil)
        var bounds = DeltaBounds()
        for (_, clip) in group {
            bounds.atLeast(-framesBefore(clip))
            if let available = availableFrames(of: clip.mediaID, after: clip.sourceStart, media: media) {
                bounds.atMost(available - clip.duration)
            }
        }
        let applied = bounds.clamp(delta)
        guard applied != 0 else { return 0 }
        let offset = RationalTime(frames: applied, rate: rate)
        for (trackID, clip) in group {
            updateClip(clip.id, on: trackID) { $0.sourceStart += offset }
        }
        return applied
    }

    /// Slide tool: moves a clip between its neighbours. Adjacent neighbours are trimmed to
    /// follow it; gaps are used up first.
    @discardableResult
    mutating func slide(_ clipID: UUID, by delta: Int64, media: MediaDurations) -> Int64 {
        let group = editGroup(for: clipID, edge: nil)
        var bounds = DeltaBounds()
        for (trackID, clip) in group {
            guard let track = track(trackID) else { continue }
            let previous = previousClip(before: clip, on: track)
            let next = nextClip(after: clip, on: track)
            if let previous, previous.end == clip.start {
                bounds.atLeast(1 - previous.duration)
                if let available = availableFrames(of: previous.mediaID, after: previous.sourceStart, media: media) {
                    bounds.atMost(available - previous.duration)
                }
            } else {
                bounds.atLeast((previous?.end ?? 0) - clip.start)
            }
            if let next, next.start == clip.end {
                bounds.atMost(next.duration - 1)
                bounds.atLeast(-framesBefore(next))
            } else if let next {
                bounds.atMost(next.start - clip.end)
            }
        }
        let applied = bounds.clamp(delta)
        guard applied != 0 else { return 0 }
        let rate = self.rate
        for (trackID, clip) in group {
            guard let track = track(trackID) else { continue }
            if let previous = previousClip(before: clip, on: track), previous.end == clip.start {
                updateClip(previous.id, on: trackID) { $0.duration += applied }
            }
            if let next = nextClip(after: clip, on: track), next.start == clip.end {
                updateClip(next.id, on: trackID) { next in
                    next.start += applied
                    next.duration -= applied
                    next.sourceStart += RationalTime(frames: applied, rate: rate)
                }
            }
            updateClip(clip.id, on: trackID) { $0.start += applied }
        }
        return applied
    }

    // MARK: - Helpers

    /// The clip plus linked partners on unlocked tracks. With an edge, partners must share
    /// that edge's frame, so a link whose halves were trimmed apart isn't dragged along.
    internal func editGroup(for clipID: UUID, edge: TrimEdge?) -> [(trackID: UUID, clip: Clip)] {
        guard let clip = clip(clipID) else { return [] }
        var group: [(trackID: UUID, clip: Clip)] = []
        for track in allTracks where !track.isLocked {
            for candidate in track.clips {
                let isSelf = candidate.id == clipID
                let isPartner = clip.linkID != nil && candidate.linkID == clip.linkID && !isSelf
                guard isSelf || isPartner else { continue }
                if isPartner, let edge {
                    let aligned = edge == .start ? candidate.start == clip.start : candidate.end == clip.end
                    if !aligned { continue }
                }
                group.append((track.id, candidate))
            }
        }
        return group
    }

    internal func framesBefore(_ clip: Clip) -> Int64 {
        max(0, clip.sourceStart.frameIndex(at: rate))
    }

    internal func previousClip(before clip: Clip, on track: Track) -> Clip? {
        track.clips.last { $0.end <= clip.start && $0.id != clip.id }
    }

    internal func nextClip(after clip: Clip, on track: Track) -> Clip? {
        track.clips.first { $0.start >= clip.end && $0.id != clip.id }
    }

    internal mutating func updateClip(_ clipID: UUID, on trackID: UUID, _ change: (inout Clip) -> Void) {
        updateTrack(trackID) { track in
            if let index = track.clips.firstIndex(where: { $0.id == clipID }) { change(&track.clips[index]) }
        }
    }
}
