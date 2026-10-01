import Foundation

/// Any keyframeable number on a clip: one of its own properties or a parameter of one of
/// its effects. Effect Controls rows and keyframe edits work through this.
public enum PropertyRef: Sendable, Hashable {
    case clip(ClipProperty)
    case effect(UUID, String)

    /// Speed keyframes are timed from the clip's start; everything else is in source time.
    var isClipTimed: Bool { self == .clip(.speed) }
}

public extension Clip {
    /// The property, or nil if the effect is gone.
    func animatable(_ ref: PropertyRef) -> AnimatableProperty? {
        switch ref {
        case .clip(let property): return self.property(property)
        case .effect(let id, let key): return effects.first { $0.id == id }?.parameter(key)
        }
    }

    func keyframeTime(for ref: PropertyRef, atSequenceFrame frame: Int64, rate: FrameRate) -> RationalTime {
        ref.isClipTimed ? RationalTime(frames: frame - start, rate: rate) : sourceTime(atSequenceFrame: frame, rate: rate)
    }

    func sequenceFrame(ofKeyframeTime time: RationalTime, for ref: PropertyRef, rate: FrameRate) -> Int64 {
        ref.isClipTimed ? start + time.frameIndex(at: rate) : sequenceFrame(atSourceTime: time, rate: rate)
    }
}

public extension EditSequence {
    /// Changes one keyframeable number of a clip (values stay within its range).
    mutating func updateAnimatable(_ ref: PropertyRef, of clipID: UUID, _ change: (inout AnimatableProperty) -> Void) {
        switch ref {
        case .clip(let property):
            updateProperty(property, of: clipID, change)
        case .effect(let effectID, let key):
            updateEffect(effectID, of: clipID) { effect in
                var property = effect.parameter(key)
                change(&property)
                effect.parameters[key] = property
            }
        }
    }

    /// Sets a value at sequence frame `frame` (a keyframe if it's animated).
    mutating func setAnimatable(_ ref: PropertyRef, of clipID: UUID, to values: [Double], atFrame frame: Int64) {
        guard let clip = clip(clipID) else { return }
        let time = clip.keyframeTime(for: ref, atSequenceFrame: frame, rate: rate)
        let tolerance = rate.frameDuration
        updateAnimatable(ref, of: clipID) { $0.set(values, at: time, tolerance: tolerance) }
    }

    /// Back to its default, without keyframes.
    mutating func resetAnimatable(_ ref: PropertyRef, of clipID: UUID) {
        switch ref {
        case .clip(let property):
            resetProperty(property, of: clipID)
        case .effect(let effectID, let key):
            updateEffect(effectID, of: clipID) { effect in
                let value = effect.kind.parameters.first { $0.key == key }?.defaultValue ?? 0
                effect.parameters[key] = AnimatableProperty([value])
            }
        }
    }
}
