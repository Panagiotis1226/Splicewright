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

/// The part a layer plays in a transition.
public struct LayerTransition: Sendable, Hashable {
    public enum Role: Sendable, Hashable { case outgoing, incoming }

    public var id: UUID
    public var kind: TransitionKind
    /// The frames the whole transition covers.
    public var range: FrameRange
    public var role: Role

    public init(id: UUID, kind: TransitionKind, range: FrameRange, role: Role) {
        self.id = id
        self.kind = kind
        self.range = range
        self.role = role
    }
}

/// One video layer in a render segment, listed bottom (V1) to top. Inside a transition a
/// track contributes two layers, outgoing then incoming, that the compositor mixes.
public struct RenderLayer: Sendable, Hashable {
    public var trackIndex: Int
    public var clipID: UUID
    public var mediaID: UUID
    public var opacity: Double
    public var transition: LayerTransition?
    /// Set for a title clip, which has no media.
    public var title: TitleSpec?
    /// Position, scale, rotation, anchor and opacity (possibly keyframed).
    public var motion: Motion
    /// Where the clip starts in the sequence and in its source, to evaluate keyframes.
    public var clipStart: Int64
    public var sourceStart: RationalTime
    /// Set for clips not at 100% forwards, to map sequence time to source time.
    public var timing: ClipTiming?
    /// The clip's effect stack (resolved per frame by the compositor).
    public var effects: [VideoEffect] = []
    /// An adjustment layer: its effects apply to everything composited below it.
    public var isAdjustment = false

    public init(trackIndex: Int, clipID: UUID, mediaID: UUID, opacity: Double, transition: LayerTransition? = nil,
                title: TitleSpec? = nil, motion: Motion = Motion(), clipStart: Int64 = 0, sourceStart: RationalTime = .zero) {
        self.trackIndex = trackIndex
        self.clipID = clipID
        self.mediaID = mediaID
        self.opacity = opacity
        self.transition = transition
        self.title = title
        self.motion = motion
        self.clipStart = clipStart
        self.sourceStart = sourceStart
    }
}

/// A stretch of the timeline where the same layers are visible.
public struct RenderSegment: Sendable, Hashable {
    public var range: FrameRange
    public var layers: [RenderLayer]
}

/// A clip's audio fade in and fade out, in sequence frames.
public struct ClipFades: Sendable {
    public enum Curve: Sendable, Hashable { case linear, constantPower }

    public var fadeIn: (range: FrameRange, curve: Curve)?
    public var fadeOut: (range: FrameRange, curve: Curve)?

    public init() {}

    /// Gain multiplier (0...1) at sequence frame position `frame` (fractional).
    public func gain(at frame: Double) -> Double {
        var gain = 1.0
        if let fadeIn {
            gain *= Self.curve(fadeIn.curve, progress: Self.progress(frame, fadeIn.range))
        }
        if let fadeOut {
            gain *= Self.curve(fadeOut.curve, progress: 1 - Self.progress(frame, fadeOut.range))
        }
        return gain
    }

    private static func progress(_ frame: Double, _ range: FrameRange) -> Double {
        guard range.length > 0 else { return 1 }
        return min(max((frame - Double(range.start)) / Double(range.length), 0), 1)
    }

    /// Constant power keeps loudness steady through a crossfade: sin/cos instead of a line.
    static func curve(_ curve: Curve, progress: Double) -> Double {
        switch curve {
        case .linear: return progress
        case .constantPower: return sin(progress * .pi / 2)
        }
    }
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
        let transitions = sequence.videoTracks.map { $0.isOutputEnabled ? $0.resolvedTransitions : [] }
        for (index, track) in sequence.videoTracks.enumerated() where track.isOutputEnabled {
            for clip in track.clips {
                cuts.insert(min(clip.start, total))
                cuts.insert(min(clip.end, total))
            }
            for transition in transitions[index] {
                cuts.insert(min(max(transition.range.start, 0), total))
                cuts.insert(min(transition.range.end, total))
            }
        }
        for track in sequence.captionTracks where track.isOutputEnabled {
            for caption in track.captions {
                cuts.insert(min(caption.start, total))
                cuts.insert(min(caption.end, total))
            }
        }
        let boundaries = cuts.sorted()
        var segments: [RenderSegment] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
            var layers: [RenderLayer] = []
            for (index, track) in sequence.videoTracks.enumerated() where track.isOutputEnabled {
                func layer(_ clip: Clip?, _ transition: LayerTransition? = nil) -> RenderLayer? {
                    guard let clip, clip.isEnabled, clip.isVisible, clip.isGenerated || isAvailable(clip.mediaID) else {
                        return nil
                    }
                    var layer = RenderLayer(trackIndex: index, clipID: clip.id, mediaID: clip.mediaID,
                                            opacity: min(1, clip.opacity), transition: transition, title: clip.title,
                                            motion: clip.motion, clipStart: clip.start, sourceStart: clip.sourceStart)
                    if clip.isRetimed { layer.timing = clip.timing(rate: sequence.rate) }
                    layer.effects = clip.effects.filter(\.isEnabled)
                    layer.isAdjustment = clip.isAdjustment
                    // An adjustment layer with nothing to apply draws nothing.
                    if clip.isAdjustment && layer.effects.isEmpty { return nil }
                    return layer
                }
                if let active = transitions[index].first(where: { $0.range.contains(start) }) {
                    let range = active.range
                    let outgoing = layer(active.left, LayerTransition(id: active.id, kind: active.kind, range: range,
                                                                      role: .outgoing))
                    let incoming = layer(active.right, LayerTransition(id: active.id, kind: active.kind, range: range,
                                                                       role: .incoming))
                    layers += [outgoing, incoming].compactMap { $0 }
                } else if let single = layer(track.clip(at: start)) {
                    layers.append(single)
                }
            }
            // Captions draw over all video, in track order.
            for (index, track) in sequence.captionTracks.enumerated() where track.isOutputEnabled {
                guard let caption = track.caption(at: start), !caption.text.isEmpty else { continue }
                layers.append(RenderLayer(trackIndex: sequence.videoTracks.count + index, clipID: caption.id,
                                          mediaID: Clip.generatedMediaID, opacity: 1,
                                          title: track.style.titleSpec(text: caption.text), clipStart: caption.start))
            }
            segments.append(RenderSegment(range: FrameRange(start: start, end: end), layers: layers))
        }
        return segments
    }

    /// Volume envelopes for audio crossfades and fades on one track: for each clip, the
    /// frames over which it fades in and out.
    public static func audioFades(for track: Track) -> [UUID: ClipFades] {
        var fades: [UUID: ClipFades] = [:]
        for transition in track.resolvedTransitions where transition.kind.isAudio {
            let curve: ClipFades.Curve = transition.kind == .constantPower ? .constantPower : .linear
            if let left = transition.left {
                fades[left.id, default: ClipFades()].fadeOut = (transition.range, curve)
            }
            if let right = transition.right {
                fades[right.id, default: ClipFades()].fadeIn = (transition.range, curve)
            }
        }
        return fades
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
