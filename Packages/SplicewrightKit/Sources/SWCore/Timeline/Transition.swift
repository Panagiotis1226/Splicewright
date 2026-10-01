import Foundation

public enum TransitionKind: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case crossDissolve
    case dipToBlack
    case dipToWhite
    /// A dissolve mixed in gamma-encoded space, like film's optical dissolves.
    case filmDissolve
    /// Wipes are named for the direction the edge moves.
    case wipeRight
    case wipeLeft
    case wipeDown
    case wipeUp
    // Audio
    case constantPower
    case constantGain

    public var id: String { rawValue }

    public var isAudio: Bool { self == .constantPower || self == .constantGain }

    public var trackKind: TrackKind { isAudio ? .audio : .video }

    public static var video: [TransitionKind] { allCases.filter { !$0.isAudio } }
    public static var audio: [TransitionKind] { allCases.filter(\.isAudio) }

    public var displayName: String {
        switch self {
        case .crossDissolve: return "Cross Dissolve"
        case .dipToBlack: return "Dip to Black"
        case .dipToWhite: return "Dip to White"
        case .filmDissolve: return "Film Dissolve"
        case .wipeRight: return "Wipe Right"
        case .wipeLeft: return "Wipe Left"
        case .wipeDown: return "Wipe Down"
        case .wipeUp: return "Wipe Up"
        case .constantPower: return "Constant Power"
        case .constantGain: return "Constant Gain"
        }
    }
}

/// Where a transition sits relative to its cut.
public enum TransitionAlignment: String, Sendable, Hashable, Codable, CaseIterable {
    case center, startAtCut, endAtCut

    public var displayName: String {
        switch self {
        case .center: return "Center at Cut"
        case .startAtCut: return "Start at Cut"
        case .endAtCut: return "End at Cut"
        }
    }
}

/// A transition at a cut between two clips on one track, or at a clip's free edge
/// (a fade in or out, when one side is nil).
///
/// It refers to its clips by ID, so it follows trims, rolls, slips, slides, moves and ripple
/// edits. If the clips stop meeting at the cut, the transition no longer applies (and is
/// pruned when the edit is committed).
public struct Transition: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var kind: TransitionKind
    /// The clip ending at the cut (nil for a fade in).
    public var leftClipID: UUID?
    /// The clip starting at the cut (nil for a fade out).
    public var rightClipID: UUID?
    public var duration: Int64
    public var alignment: TransitionAlignment

    public init(id: UUID = UUID(), kind: TransitionKind, leftClipID: UUID?, rightClipID: UUID?,
                duration: Int64, alignment: TransitionAlignment = .center) {
        self.id = id
        self.kind = kind
        self.leftClipID = leftClipID
        self.rightClipID = rightClipID
        self.duration = duration
        self.alignment = alignment
    }
}

/// A transition placed on the timeline: its cut, the frames it covers and the clips it mixes.
public struct ResolvedTransition: Sendable, Hashable, Identifiable {
    public var transition: Transition
    public var cut: Int64
    /// Frames before and after the cut, after clamping to the clips' lengths.
    public var before: Int64
    public var after: Int64
    public var left: Clip?
    public var right: Clip?

    public var id: UUID { transition.id }
    public var kind: TransitionKind { transition.kind }
    public var range: FrameRange { FrameRange(start: cut - before, end: cut + after) }
    public var duration: Int64 { before + after }
}

public extension Track {
    /// Transitions whose clips still meet, with their frame ranges, in timeline order.
    ///
    /// A transition never extends past either clip, and two transitions never overlap
    /// inside a short clip (the later one is shortened).
    var resolvedTransitions: [ResolvedTransition] {
        let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        var result: [ResolvedTransition] = []
        for transition in transitions where transition.duration > 0 {
            let left = transition.leftClipID.flatMap { byID[$0] }
            let right = transition.rightClipID.flatMap { byID[$0] }
            if transition.leftClipID != nil && left == nil { continue }
            if transition.rightClipID != nil && right == nil { continue }
            let cut: Int64
            switch (left, right) {
            case let (left?, right?):
                guard left.end == right.start else { continue }
                cut = left.end
            case let (left?, nil):
                // A fade out needs the clip's end to be free.
                guard clips.first(where: { $0.start == left.end }) == nil else { continue }
                cut = left.end
            case let (nil, right?):
                guard clips.first(where: { $0.end == right.start }) == nil else { continue }
                cut = right.start
            case (nil, nil):
                continue
            }
            var (before, after) = Self.split(transition.duration, transition.alignment, left: left, right: right)
            before = left.map { min(before, $0.duration) } ?? 0
            after = right.map { min(after, $0.duration) } ?? 0
            guard before + after > 0 else { continue }
            result.append(ResolvedTransition(transition: transition, cut: cut, before: before, after: after,
                                             left: left, right: right))
        }
        result.sort { $0.cut < $1.cut }
        // Inside a clip shorter than its two transitions, shorten the later one's lead-in.
        for index in result.indices.dropFirst() {
            let previous = result[index - 1]
            let overlap = previous.range.end - result[index].range.start
            if overlap > 0 { result[index].before = max(0, result[index].before - overlap) }
        }
        return result.filter { $0.duration > 0 }
    }

    /// Frames before and after the cut for a duration and alignment. One-sided transitions
    /// sit entirely on their clip.
    private static func split(_ duration: Int64, _ alignment: TransitionAlignment, left: Clip?,
                              right: Clip?) -> (Int64, Int64) {
        if left == nil { return (0, duration) }
        if right == nil { return (duration, 0) }
        switch alignment {
        case .center:
            let before = duration / 2
            return (before, duration - before)
        case .startAtCut: return (0, duration)
        case .endAtCut: return (duration, 0)
        }
    }

    func resolvedTransition(_ id: UUID) -> ResolvedTransition? {
        resolvedTransitions.first { $0.id == id }
    }
}

public extension EditSequence {
    /// The default transition length: one second.
    var defaultTransitionDuration: Int64 { Int64(rate.timecodeBase) }

    func transition(_ id: UUID) -> (trackID: UUID, transition: ResolvedTransition)? {
        for track in allTracks {
            if let resolved = track.resolvedTransition(id) { return (track.id, resolved) }
        }
        return nil
    }

    /// Adds (or replaces) the transition at the clip edge at `frame` on `trackID`.
    ///
    /// The transition is centered on a cut between two clips, or sits on the clip for a free
    /// edge (a fade). Returns the new transition's ID, or nil if no clip edge is at `frame`
    /// or the kind doesn't suit the track.
    @discardableResult
    mutating func addTransition(_ kind: TransitionKind, trackID: UUID, at frame: Int64, duration: Int64? = nil,
                                alignment: TransitionAlignment = .center) -> UUID? {
        guard let track = track(trackID), track.kind == kind.trackKind, !track.isLocked else { return nil }
        let left = track.clips.first { $0.end == frame }
        let right = track.clips.first { $0.start == frame }
        guard left != nil || right != nil else { return nil }
        let transition = Transition(kind: kind, leftClipID: left?.id, rightClipID: right?.id,
                                    duration: max(1, duration ?? defaultTransitionDuration), alignment: alignment)
        updateTrack(trackID) { track in
            track.transitions.removeAll { $0.leftClipID == transition.leftClipID && $0.rightClipID == transition.rightClipID }
            // A fade at an edge is replaced by a two-sided transition there, and vice versa.
            track.transitions.removeAll { existing in
                (left != nil && existing.leftClipID == left?.id) || (right != nil && existing.rightClipID == right?.id)
            }
            track.transitions.append(transition)
        }
        return transition.id
    }

    mutating func removeTransitions(_ ids: Set<UUID>) {
        updateAllTracks { $0.transitions.removeAll { ids.contains($0.id) } }
    }

    /// Changes a transition's kind, duration or alignment (never its clips).
    mutating func updateTransition(_ id: UUID, _ change: (inout Transition) -> Void) {
        updateAllTracks { track in
            guard let index = track.transitions.firstIndex(where: { $0.id == id }) else { return }
            var transition = track.transitions[index]
            change(&transition)
            transition.id = id
            transition.leftClipID = track.transitions[index].leftClipID
            transition.rightClipID = track.transitions[index].rightClipID
            transition.duration = max(1, transition.duration)
            if transition.kind.trackKind != track.kind { transition.kind = track.transitions[index].kind }
            track.transitions[index] = transition
        }
    }

    /// Drops transitions that no longer apply (their clips were deleted or no longer meet).
    mutating func pruneTransitions() {
        updateAllTracks { track in
            let live = Set(track.resolvedTransitions.map(\.id))
            if live.count != track.transitions.count { track.transitions.removeAll { !live.contains($0.id) } }
        }
    }

    /// The cut or free clip edge nearest `frame` on a track, within `tolerance` frames.
    func nearestClipEdge(to frame: Int64, trackID: UUID, tolerance: Int64) -> Int64? {
        guard let track = track(trackID) else { return nil }
        let edges = Set(track.clips.flatMap { [$0.start, $0.end] })
        return edges.filter { abs($0 - frame) <= tolerance }.min { abs($0 - frame) < abs($1 - frame) }
    }

    /// Applies `kind` at the edit point nearest `frame` on each given track (⌘D / ⇧⌘D).
    /// Returns the IDs of the transitions added.
    @discardableResult
    mutating func applyTransition(_ kind: TransitionKind, near frame: Int64, trackIDs: [UUID],
                                  tolerance: Int64) -> [UUID] {
        trackIDs.compactMap { trackID in
            nearestClipEdge(to: frame, trackID: trackID, tolerance: tolerance).flatMap {
                addTransition(kind, trackID: trackID, at: $0)
            }
        }
    }
}
