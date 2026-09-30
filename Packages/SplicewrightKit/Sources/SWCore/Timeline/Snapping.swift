import Foundation

/// Snapping for timeline drags: clip edges, the playhead and sequence marks attract
/// dragged edges within a threshold.
public struct Snapper: Sendable {
    public var points: [Int64]
    public var threshold: Int64

    public init(points: [Int64], threshold: Int64) {
        self.points = points.sorted()
        self.threshold = max(0, threshold)
    }

    /// Candidate points in `sequence`, ignoring the clips being dragged.
    public init(sequence: EditSequence, excluding ids: Set<UUID>, playhead: Int64?, threshold: Int64) {
        var points = Set<Int64>([0])
        for track in sequence.allTracks {
            for clip in track.clips where !ids.contains(clip.id) {
                points.insert(clip.start)
                points.insert(clip.end)
            }
        }
        if let playhead { points.insert(playhead) }
        if let inFrame = sequence.marks.inFrame { points.insert(inFrame) }
        if let outFrame = sequence.marks.outFrame { points.insert(outFrame + 1) }
        self.init(points: Array(points), threshold: threshold)
    }

    /// The snap point nearest `frame`, if within the threshold.
    public func snap(_ frame: Int64) -> Int64? {
        var best: Int64?
        for point in points where abs(point - frame) <= threshold {
            if best.map({ abs(point - frame) < abs($0 - frame) }) ?? true { best = point }
        }
        return best
    }

    /// Adjusts a drag `delta` so whichever of `edges` lands closest to a snap point sits on it.
    /// Returns the adjusted delta and the point snapped to (for drawing the snap line).
    public func snapDelta(_ delta: Int64, edges: [Int64]) -> (delta: Int64, point: Int64?) {
        var bestAdjustment: Int64?
        var bestPoint: Int64?
        for edge in edges {
            let moved = edge + delta
            guard let point = snap(moved) else { continue }
            let adjustment = point - moved
            if bestAdjustment.map({ abs(adjustment) < abs($0) }) ?? true {
                bestAdjustment = adjustment
                bestPoint = point
            }
        }
        return (delta + (bestAdjustment ?? 0), bestPoint)
    }
}
