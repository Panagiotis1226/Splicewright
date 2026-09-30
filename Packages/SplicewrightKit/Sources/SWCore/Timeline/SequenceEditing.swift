import Foundation

/// Media durations by media ID, used to keep trims and slips inside the source media.
public typealias MediaDurations = [UUID: RationalTime]

/// A clip bound for a track, as produced by `EditSequence.makeClips`.
public struct TrackPlacement: Sendable, Hashable {
    public var trackID: UUID
    public var clip: Clip

    public init(trackID: UUID, clip: Clip) {
        self.trackID = trackID
        self.clip = clip
    }
}

public enum TrimEdge: Sendable, Hashable {
    case start, end
}

/// Timeline edits, following Premiere's model:
///
/// - Overwrite, lift, and non-ripple trims only touch the tracks they name.
/// - Insert, extract, ripple delete and ripple trims also apply to every other unlocked,
///   sync-locked track. Those tracks are split and shifted (insert) or have the same range
///   removed (extract) so everything stays in sync. Turn sync lock off to protect a track.
/// - Locked tracks are never changed.
public extension EditSequence {
    // MARK: - Source → timeline

    /// Clips for `media`'s `sourceRange`, placed at `frame` on the given tracks. Video and
    /// audio clips from the same source are linked.
    func makeClips(for media: MediaItem, sourceRange: TimeRange, at frame: Int64,
                   videoTrackID: UUID?, audioTrackID: UUID?) -> [TrackPlacement] {
        let frames = max(1, sourceRange.duration.frameIndex(at: rate))
        var placements: [TrackPlacement] = []
        let wantsVideo = media.info.video != nil && videoTrackID != nil
        let wantsAudio = !media.info.audio.isEmpty && audioTrackID != nil
        let link: UUID? = wantsVideo && wantsAudio ? UUID() : nil
        if wantsVideo, let videoTrackID {
            placements.append(TrackPlacement(trackID: videoTrackID, clip: Clip(
                mediaID: media.id, name: media.name, start: frame, duration: frames,
                sourceStart: sourceRange.start, linkID: link)))
        }
        if wantsAudio, let audioTrackID {
            placements.append(TrackPlacement(trackID: audioTrackID, clip: Clip(
                mediaID: media.id, name: media.name, start: frame, duration: frames,
                sourceStart: sourceRange.start, linkID: link)))
        }
        return placements
    }

    var targetedVideoTrackID: UUID? { videoTracks.first { $0.isTargeted && !$0.isLocked }?.id }
    var targetedAudioTrackID: UUID? { audioTracks.first { $0.isTargeted && !$0.isLocked }?.id }

    // MARK: - Overwrite / insert

    /// Places clips, replacing whatever they cover. Placements on locked tracks are skipped.
    mutating func overwrite(_ placements: [TrackPlacement]) {
        var linkMap: [UUID: UUID] = [:]
        let rate = self.rate
        for placement in placements where track(placement.trackID)?.isLocked == false {
            updateTrack(placement.trackID) { $0.place(placement.clip, rate: rate, linkMap: &linkMap) }
        }
    }

    /// Opens a gap of `length` frames at `frame` on the placements' tracks and all sync-locked
    /// tracks, then places the clips. Clips spanning `frame` are split.
    mutating func insert(_ placements: [TrackPlacement], at frame: Int64) {
        let length = placements.map(\.clip.duration).max() ?? 0
        guard length > 0 else { return }
        insertGap(at: frame, length: length, targets: Set(placements.map(\.trackID)))
        overwrite(placements)
    }

    /// Opens a gap without placing anything (ripple trims use this too).
    mutating func insertGap(at frame: Int64, length: Int64, targets: Set<UUID>) {
        var linkMap: [UUID: UUID] = [:]
        let rate = self.rate
        updateAllTracks { track in
            guard !track.isLocked, targets.contains(track.id) || track.isSyncLocked else { return }
            track.split(at: frame, rate: rate, linkMap: &linkMap)
            track.shift(from: frame, by: length)
        }
    }

    // MARK: - Lift / extract

    /// Clears `range` on `trackIDs`, leaving a gap.
    mutating func lift(_ range: FrameRange, trackIDs: Set<UUID>) {
        var linkMap: [UUID: UUID] = [:]
        let rate = self.rate
        updateAllTracks { track in
            guard !track.isLocked, trackIDs.contains(track.id) else { return }
            track.clear(range, rate: rate, linkMap: &linkMap)
        }
    }

    /// Removes `range` from `trackIDs` and all sync-locked tracks, closing the gap.
    mutating func extract(_ range: FrameRange, trackIDs: Set<UUID>) {
        guard !range.isEmpty else { return }
        var linkMap: [UUID: UUID] = [:]
        let rate = self.rate
        updateAllTracks { track in
            guard !track.isLocked, trackIDs.contains(track.id) || track.isSyncLocked else { return }
            track.clear(range, rate: rate, linkMap: &linkMap)
            track.shift(from: range.end, by: -range.length)
        }
    }

    // MARK: - Razor / delete

    /// Splits clips at `frame` on `trackIDs` (Razor tool, Add Edit).
    mutating func razor(at frame: Int64, trackIDs: Set<UUID>) {
        var linkMap: [UUID: UUID] = [:]
        let rate = self.rate
        updateAllTracks { track in
            guard !track.isLocked, trackIDs.contains(track.id) else { return }
            track.split(at: frame, rate: rate, linkMap: &linkMap)
        }
    }

    /// Deletes clips. With `ripple`, the gaps they leave are closed (Ripple Delete).
    mutating func delete(_ ids: Set<UUID>, ripple: Bool) {
        var ranges: [FrameRange] = []
        var tracksTouched: Set<UUID> = []
        for track in allTracks where !track.isLocked {
            for clip in track.clips where ids.contains(clip.id) {
                ranges.append(clip.range)
                tracksTouched.insert(track.id)
            }
        }
        updateAllTracks { track in
            guard !track.isLocked else { return }
            track.remove(ids)
        }
        guard ripple else { return }
        // Close gaps from the latest to the earliest so earlier ranges stay valid.
        for range in Self.union(ranges).reversed() {
            extract(range, trackIDs: tracksTouched)
        }
    }

    // MARK: - Move

    /// Moves clips by `delta` frames and `trackOffset` tracks (within their kind), overwriting
    /// what they land on — the Selection tool's drag. Clips on locked tracks don't move.
    mutating func move(_ ids: Set<UUID>, by delta: Int64, trackOffset: Int = 0) {
        struct Moving {
            var kind: TrackKind
            var index: Int
            var clip: Clip
        }
        var moving: [Moving] = []
        for (index, track) in videoTracks.enumerated() where !track.isLocked {
            for clip in track.clips where ids.contains(clip.id) { moving.append(Moving(kind: .video, index: index, clip: clip)) }
        }
        for (index, track) in audioTracks.enumerated() where !track.isLocked {
            for clip in track.clips where ids.contains(clip.id) { moving.append(Moving(kind: .audio, index: index, clip: clip)) }
        }
        guard !moving.isEmpty else { return }
        // Never move anything before frame 0.
        let earliest = moving.map(\.clip.start).min() ?? 0
        let shift = max(delta, -earliest)
        let movingIDs = Set(moving.map(\.clip.id))
        updateAllTracks { $0.remove(movingIDs) }

        var placements: [TrackPlacement] = []
        for item in moving {
            let tracks = item.kind == .video ? videoTracks : audioTracks
            let target = min(max(item.index + trackOffset, 0), tracks.count - 1)
            let destination = tracks[target].isLocked ? tracks[item.index] : tracks[target]
            var clip = item.clip
            clip.start += shift
            placements.append(TrackPlacement(trackID: destination.id, clip: clip))
        }
        overwrite(placements)
    }

    // MARK: - Helpers

    internal static func union(_ ranges: [FrameRange]) -> [FrameRange] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.start < $1.start }
        var merged: [FrameRange] = []
        for range in sorted {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1].end = max(last.end, range.end)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Frames of source media available after `sourceTime` for `mediaID`, or nil if unknown.
    internal func availableFrames(of mediaID: UUID, after sourceTime: RationalTime,
                                  media: MediaDurations) -> Int64? {
        guard let duration = media[mediaID] else { return nil }
        return max(0, (duration - sourceTime).frameIndex(at: rate))
    }
}
