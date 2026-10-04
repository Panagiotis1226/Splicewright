import Foundation

/// Copied timeline clips. Track positions are relative (0 is the lowest copied track of each
/// kind) and times start at 0, so a paste can land anywhere, in any sequence or project.
public struct ClipboardContent: Sendable, Hashable, Codable {
    public struct Item: Sendable, Hashable, Codable {
        public var kind: TrackKind
        public var trackOffset: Int
        public var clip: Clip
    }

    public var items: [Item]
    /// The media the clips use, so they can be pasted into another project.
    public var media: [MediaItem]
    /// The rate the clips' frames are counted at.
    public var rate: FrameRate

    /// Length in frames (from the first clip's start to the last clip's end).
    public var duration: Int64 { items.map(\.clip.end).max() ?? 0 }

    /// The first video clip, else the first clip (the source for Paste Attributes).
    public var attributeSource: Clip? {
        (items.first { $0.kind == .video } ?? items.first)?.clip
    }

    public static let pasteboardType = "com.splicewright.clips"
}

public extension EditSequence {
    /// Copies the clips with `ids` (and the media they use, looked up in `project`).
    func copyClips(_ ids: Set<UUID>, project: Project) -> ClipboardContent? {
        var items: [ClipboardContent.Item] = []
        for (kind, tracks) in [(TrackKind.video, videoTracks), (.audio, audioTracks)] {
            let used = tracks.indices.filter { tracks[$0].clips.contains { ids.contains($0.id) } }
            guard let lowest = used.first else { continue }
            for index in used {
                for clip in tracks[index].clips where ids.contains(clip.id) {
                    items.append(.init(kind: kind, trackOffset: index - lowest, clip: clip))
                }
            }
        }
        guard let start = items.map(\.clip.start).min() else { return nil }
        for index in items.indices { items[index].clip.start -= start }
        let mediaIDs = Set(items.map(\.clip.mediaID))
        return ClipboardContent(items: items, media: project.media.filter { mediaIDs.contains($0.id) }, rate: rate)
    }

    /// Pastes clips at `frame`, overwriting what's there, starting on the targeted track of
    /// each kind (else the first). Tracks are added when the clips need more. Returns the new
    /// clips' IDs.
    @discardableResult
    mutating func paste(_ content: ClipboardContent, at frame: Int64) -> Set<UUID> {
        var links: [UUID: UUID] = [:]
        var groups: [UUID: UUID] = [:]
        var placements: [TrackPlacement] = []
        for item in content.items {
            let base = tracks(item.kind).firstIndex { $0.isTargeted && !$0.isLocked } ?? 0
            let index = base + item.trackOffset
            while tracks(item.kind).count <= index { addTrack(item.kind) }
            var clip = item.clip
            clip.id = UUID()
            if let link = clip.linkID {
                clip.linkID = links[link] ?? UUID()
                links[link] = clip.linkID
            }
            if let group = clip.groupID {
                clip.groupID = groups[group] ?? UUID()
                groups[group] = clip.groupID
            }
            if content.rate != rate {
                let start = RationalTime(frames: clip.start, rate: content.rate).frameIndex(at: rate)
                let end = RationalTime(frames: clip.end, rate: content.rate).frameIndex(at: rate)
                clip.start = start
                clip.duration = max(1, end - start)
            }
            clip.start += frame
            placements.append(TrackPlacement(trackID: tracks(item.kind)[index].id, clip: clip))
        }
        overwrite(placements)
        let placed = Set(placements.map(\.clip.id))
        return placed.filter { clip($0) != nil }
    }

    private func tracks(_ kind: TrackKind) -> [Track] {
        kind == .video ? videoTracks : audioTracks
    }
}
