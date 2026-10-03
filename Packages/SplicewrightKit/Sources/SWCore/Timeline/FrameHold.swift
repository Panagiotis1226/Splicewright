import Foundation

/// Frame holds, as Premiere's Add Frame Hold and Insert Frame Hold Segment: a clip that shows one
/// source frame for its whole length. It's an ordinary clip with Time Remapping held at 0%, so it
/// trims, moves and exports like any other, and its speed can be keyframed again to let it play.
public extension Clip {
    /// The clip showing only the source frame at `sourceTime`.
    func holding(_ sourceTime: RationalTime) -> Clip {
        var clip = self
        clip.sourceStart = sourceTime
        clip.isReversed = false
        var speed = AnimatableProperty([0])
        speed.setAnimated(true, at: .zero)
        clip.speed = speed
        return clip
    }

    /// Whether the clip shows a single frame throughout.
    var isFrameHold: Bool {
        speed.isAnimated && speed.keyframes.allSatisfy { ($0.values.first ?? 100) == 0 }
    }
}

public extension EditSequence {
    /// Add Frame Hold: from `frame` to its end, the video clip shows the frame at `frame` (the part
    /// before plays as it did). Linked audio isn't touched. Returns the held clip's ID.
    @discardableResult
    mutating func addFrameHold(to clipID: UUID, at frame: Int64) -> UUID? {
        guard let (trackID, clip) = videoClip(clipID, at: frame) else { return nil }
        let held = clip.sourceTime(atSequenceFrame: frame, rate: rate)
        if frame > clip.start { razor(at: frame, trackIDs: [trackID]) }
        guard let right = track(trackID)?.clips.first(where: { $0.start == frame }) else { return nil }
        var hold = right.holding(held)
        hold.linkID = nil
        updateTrack(trackID) { track in
            if let index = track.clips.firstIndex(where: { $0.id == right.id }) { track.clips[index] = hold }
        }
        return hold.id
    }

    /// Insert Frame Hold Segment: splits the video clip at `frame` and opens `length` frames there,
    /// on its track and every sync-locked one, filled with the frame at `frame`. Returns the hold's ID.
    @discardableResult
    mutating func insertFrameHoldSegment(in clipID: UUID, at frame: Int64, length: Int64) -> UUID? {
        guard length > 0, let (trackID, clip) = videoClip(clipID, at: frame) else { return nil }
        var hold = clip.holding(clip.sourceTime(atSequenceFrame: frame, rate: rate))
        hold.id = UUID()
        hold.start = frame
        hold.duration = length
        hold.linkID = nil
        insert([TrackPlacement(trackID: trackID, clip: hold)], at: frame)
        return hold.id
    }

    /// A media clip on an unlocked video track, with `frame` inside it.
    private func videoClip(_ clipID: UUID, at frame: Int64) -> (UUID, Clip)? {
        for track in videoTracks where !track.isLocked {
            if let clip = track.clips.first(where: { $0.id == clipID }), clip.range.contains(frame), !clip.isGenerated {
                return (track.id, clip)
            }
        }
        return nil
    }
}
