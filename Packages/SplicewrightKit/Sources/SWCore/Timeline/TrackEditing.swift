import Foundation

/// Low-level track operations that every timeline edit is built from.
///
/// When a clip is split, its right half gets a new ID. If the clip was linked, the right
/// half's link ID comes from `linkMap`, so linked clips split in the same edit stay linked.
extension Track {
    /// Removes `range` from this track, trimming or splitting clips that overlap it.
    mutating func clear(_ range: FrameRange, rate: FrameRate, linkMap: inout [UUID: UUID]) {
        guard !range.isEmpty else { return }
        var result: [Clip] = []
        for clip in clips {
            guard clip.range.overlaps(range) else {
                result.append(clip)
                continue
            }
            if clip.start < range.start {
                var left = clip
                left.duration = range.start - clip.start
                result.append(left)
            }
            if clip.end > range.end {
                var right = clip
                right.id = clip.start < range.start ? UUID() : clip.id
                // A transition at the clip's end now belongs to the right piece.
                if right.id != clip.id { reanchorEnd(of: clip.id, to: right.id) }
                if clip.start < range.start, let link = clip.linkID {
                    right.linkID = Self.splitLink(link, &linkMap)
                }
                right.moveStart(by: range.end - clip.start, rate: rate)
                result.append(right)
            }
        }
        clips = result
    }

    /// Splits the clip that spans `frame` (strictly inside it) into two clips.
    mutating func split(at frame: Int64, rate: FrameRate, linkMap: inout [UUID: UUID]) {
        guard let index = clips.firstIndex(where: { $0.start < frame && $0.end > frame }) else { return }
        let clip = clips[index]
        var left = clip
        left.duration = frame - clip.start
        var right = clip
        right.id = UUID()
        right.linkID = clip.linkID.map { Self.splitLink($0, &linkMap) }
        right.moveStart(by: frame - clip.start, rate: rate)
        clips.replaceSubrange(index...index, with: [left, right])
        reanchorEnd(of: clip.id, to: right.id)
    }

    /// Moves transitions on `clipID`'s end edge to `newID` (the right half of a split).
    private mutating func reanchorEnd(of clipID: UUID, to newID: UUID) {
        for index in transitions.indices where transitions[index].leftClipID == clipID {
            transitions[index].leftClipID = newID
        }
    }

    /// Moves every clip starting at or after `frame` by `delta` frames.
    mutating func shift(from frame: Int64, by delta: Int64) {
        guard delta != 0 else { return }
        for index in clips.indices where clips[index].start >= frame {
            clips[index].start += delta
        }
    }

    /// Places `clip`, overwriting whatever was under it.
    mutating func place(_ clip: Clip, rate: FrameRate, linkMap: inout [UUID: UUID]) {
        clear(clip.range, rate: rate, linkMap: &linkMap)
        let index = clips.firstIndex { $0.start > clip.start } ?? clips.endIndex
        clips.insert(clip, at: index)
    }

    mutating func remove(_ ids: Set<UUID>) {
        clips.removeAll { ids.contains($0.id) }
    }

    private static func splitLink(_ link: UUID, _ linkMap: inout [UUID: UUID]) -> UUID {
        if let existing = linkMap[link] { return existing }
        let fresh = UUID()
        linkMap[link] = fresh
        return fresh
    }
}
