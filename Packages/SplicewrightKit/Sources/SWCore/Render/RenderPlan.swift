import Foundation

/// A 2D affine transform in pixel space (y down), mirroring `CGAffineTransform` so the
/// fit math can be tested without CoreGraphics.
public struct Affine2D: Sendable, Hashable, Codable {
    public var a, b, c, d, tx, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        (self.a, self.b, self.c, self.d, self.tx, self.ty) = (a, b, c, d, tx, ty)
    }

    public static let identity = Affine2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func scale(_ sx: Double, _ sy: Double) -> Affine2D {
        Affine2D(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }

    public static func translation(_ x: Double, _ y: Double) -> Affine2D {
        Affine2D(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    /// Applies `self`, then `other` (same order as `CGAffineTransform.concatenating`).
    public func concatenating(_ other: Affine2D) -> Affine2D {
        Affine2D(
            a: a * other.a + b * other.c,
            b: a * other.b + b * other.d,
            c: c * other.a + d * other.c,
            d: c * other.b + d * other.d,
            tx: tx * other.a + ty * other.c + other.tx,
            ty: tx * other.b + ty * other.d + other.ty
        )
    }

    public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        (a * x + c * y + tx, b * x + d * y + ty)
    }

    public struct Box: Sendable, Hashable {
        public var minX, minY, maxX, maxY: Double
    }

    /// Bounding box of a `width`×`height` rectangle at the origin after this transform.
    public func bounds(width: Double, height: Double) -> Box {
        let corners = [apply(x: 0, y: 0), apply(x: width, y: 0), apply(x: 0, y: height), apply(x: width, y: height)]
        return Box(minX: corners.map(\.x).min() ?? 0, minY: corners.map(\.y).min() ?? 0,
                   maxX: corners.map(\.x).max() ?? 0, maxY: corners.map(\.y).max() ?? 0)
    }

    /// Maps encoded source pixels to the render frame: applies the track's orientation
    /// transform, then scales to fit inside `renderWidth`×`renderHeight`, centred.
    public static func fit(sourceWidth: Double, sourceHeight: Double, orientation: Affine2D,
                           renderWidth: Double, renderHeight: Double) -> Affine2D {
        let box = orientation.bounds(width: sourceWidth, height: sourceHeight)
        let displayWidth = max(1, box.maxX - box.minX)
        let displayHeight = max(1, box.maxY - box.minY)
        let scale = min(renderWidth / displayWidth, renderHeight / displayHeight)
        let offsetX = (renderWidth - displayWidth * scale) / 2
        let offsetY = (renderHeight - displayHeight * scale) / 2
        return orientation
            .concatenating(.translation(-box.minX, -box.minY))
            .concatenating(.scale(scale, scale))
            .concatenating(.translation(offsetX, offsetY))
    }
}

/// One video layer in a render segment, listed bottom (V1) to top.
public struct RenderLayer: Sendable, Hashable {
    public var trackIndex: Int
    public var clipID: UUID
    public var mediaID: UUID
    public var opacity: Double

    public init(trackIndex: Int, clipID: UUID, mediaID: UUID, opacity: Double) {
        self.trackIndex = trackIndex
        self.clipID = clipID
        self.mediaID = mediaID
        self.opacity = opacity
    }
}

/// A stretch of the timeline where the same layers are visible.
public struct RenderSegment: Sendable, Hashable {
    public var range: FrameRange
    public var layers: [RenderLayer]
}

public enum RenderPlan {
    /// Splits `[0, max(durationFrames, minimumFrames))` into segments at every clip boundary.
    /// Segments cover the whole range with no gaps, as AVFoundation requires of
    /// composition instructions. Hidden tracks, disabled clips and clips whose media
    /// isn't available are left out; empty segments render black.
    public static func videoSegments(for sequence: EditSequence, minimumFrames: Int64 = 1,
                                     isAvailable: (UUID) -> Bool = { _ in true }) -> [RenderSegment] {
        let total = max(sequence.durationFrames, minimumFrames)
        var cuts = Set<Int64>([0, total])
        for track in sequence.videoTracks where track.isOutputEnabled {
            for clip in track.clips {
                cuts.insert(min(clip.start, total))
                cuts.insert(min(clip.end, total))
            }
        }
        let boundaries = cuts.sorted()
        var segments: [RenderSegment] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
            var layers: [RenderLayer] = []
            for (index, track) in sequence.videoTracks.enumerated() where track.isOutputEnabled {
                guard let clip = track.clip(at: start), clip.isEnabled, clip.opacity > 0,
                      isAvailable(clip.mediaID) else { continue }
                layers.append(RenderLayer(trackIndex: index, clipID: clip.id, mediaID: clip.mediaID,
                                          opacity: min(1, clip.opacity)))
            }
            segments.append(RenderSegment(range: FrameRange(start: start, end: end), layers: layers))
        }
        return segments
    }

    /// Linear gain for each audio track: solo overrides mute, as in Premiere's mixer.
    public static func audibleTracks(in sequence: EditSequence) -> [Bool] {
        let anySolo = sequence.audioTracks.contains { $0.isSolo }
        return sequence.audioTracks.map { track in
            anySolo ? track.isSolo : track.isOutputEnabled
        }
    }

    public static func linearGain(dB: Double) -> Double {
        pow(10, dB / 20)
    }
}
