import Foundation

/// Any keyframeable number on a clip: one of its own properties or a parameter of one of
/// its effects. Effect Controls rows and keyframe edits work through this.
public enum PropertyRef: Sendable, Hashable {
    case clip(ClipProperty)
    case effect(UUID, String)
    /// A mask's path, feather, opacity or expansion.
    case mask(MaskOwner, UUID, MaskProperty)

    /// Speed keyframes are timed from the clip's start; everything else is in source time.
    var isClipTimed: Bool { self == .clip(.speed) }
}

/// What a mask belongs to: the clip's Opacity, or one of its effects.
public enum MaskOwner: Sendable, Hashable, Codable {
    case opacity
    case effect(UUID)
}

public extension Clip {
    /// The property, or nil if the effect or mask is gone.
    func animatable(_ ref: PropertyRef) -> AnimatableProperty? {
        switch ref {
        case .clip(let property): return self.property(property)
        case .effect(let id, let key): return effects.first { $0.id == id }?.parameter(key)
        case .mask(let owner, let id, let property): return masks(of: owner).first { $0.id == id }?[property]
        }
    }

    /// The masks on Opacity or on an effect.
    func masks(of owner: MaskOwner) -> [Mask] {
        switch owner {
        case .opacity: return opacityMasks
        case .effect(let id): return effects.first { $0.id == id }?.masks ?? []
        }
    }

    func keyframeTime(for ref: PropertyRef, atSequenceFrame frame: Int64, rate: FrameRate) -> RationalTime {
        ref.isClipTimed ? RationalTime(frames: frame - start, rate: rate) : sourceTime(atSequenceFrame: frame, rate: rate)
    }

    func sequenceFrame(ofKeyframeTime time: RationalTime, for ref: PropertyRef, rate: FrameRate) -> Int64 {
        ref.isClipTimed ? start + time.frameIndex(at: rate) : sequenceFrame(atSourceTime: time, rate: rate)
    }
}

public extension Clip {
    /// Every keyframeable number of the clip: its properties and its effects' parameters.
    var allRefs: [PropertyRef] {
        let owners = [MaskOwner.opacity] + effects.map { MaskOwner.effect($0.id) }
        let maskRefs = owners.flatMap { owner in
            masks(of: owner).flatMap { mask in MaskProperty.allCases.map { PropertyRef.mask(owner, mask.id, $0) } }
        }
        return ClipProperty.allCases.map { PropertyRef.clip($0) }
            + effects.flatMap { effect in effect.kind.parameters.map { PropertyRef.effect(effect.id, $0.key) } } + maskRefs
    }

    /// The sequence frames where this clip has keyframes (any property or effect), inside the clip.
    func keyframeFrames(rate: FrameRate) -> [Int64] {
        var frames: Set<Int64> = []
        for ref in allRefs {
            for keyframe in animatable(ref)?.keyframes ?? [] {
                let frame = sequenceFrame(ofKeyframeTime: keyframe.time, for: ref, rate: rate)
                if range.contains(frame) { frames.insert(frame) }
            }
        }
        return frames.sorted()
    }

    /// The property a clip's line on the timeline shows and edits, as in Premiere: Volume on
    /// audio clips, Opacity on video clips.
    static func rubberBandProperty(isAudio: Bool) -> ClipProperty { isAudio ? .volume : .opacity }
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
        case .mask(let owner, let maskID, let property):
            updateMask(maskID, of: owner, in: clipID) { mask in
                var value = mask[property]
                change(&value)
                if property != .path {
                    value.values = value.values.map { min(max($0, property.range.lowerBound), property.range.upperBound) }
                }
                mask[property] = value
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
        case .mask(let owner, let maskID, let property):
            updateMask(maskID, of: owner, in: clipID) { mask in
                let defaults = Mask(vertices: [])
                // Resetting the path keeps the shape at the playhead (there's no default shape).
                if property != .path { mask[property] = defaults[property] }
            }
        }
    }
}

public extension EditSequence {
    /// Adds a mask to the clip's Opacity or to one of its effects; returns its ID.
    @discardableResult
    mutating func addMask(_ mask: Mask, to owner: MaskOwner, of clipID: UUID) -> UUID? {
        guard let clip = clip(clipID) else { return nil }
        if case .effect(let id) = owner, !clip.effects.contains(where: { $0.id == id }) { return nil }
        var mask = mask
        mask.name = "Mask (\(clip.masks(of: owner).count + 1))"
        let added = mask
        updateClipProperties([clipID]) { clip in
            switch owner {
            case .opacity: clip.opacityMasks.append(added)
            case .effect(let id):
                if let index = clip.effects.firstIndex(where: { $0.id == id }) { clip.effects[index].masks.append(added) }
            }
        }
        return mask.id
    }

    mutating func updateMask(_ maskID: UUID, of owner: MaskOwner, in clipID: UUID, _ change: (inout Mask) -> Void) {
        updateClipProperties([clipID]) { clip in
            switch owner {
            case .opacity:
                if let index = clip.opacityMasks.firstIndex(where: { $0.id == maskID }) { change(&clip.opacityMasks[index]) }
            case .effect(let id):
                guard let effect = clip.effects.firstIndex(where: { $0.id == id }),
                      let index = clip.effects[effect].masks.firstIndex(where: { $0.id == maskID }) else { return }
                change(&clip.effects[effect].masks[index])
            }
        }
    }

    mutating func removeMask(_ maskID: UUID, of owner: MaskOwner, in clipID: UUID) {
        updateClipProperties([clipID]) { clip in
            clip.detachMaskLinks { $0 == MaskSource(owner: owner, maskID: maskID) }
            switch owner {
            case .opacity: clip.opacityMasks.removeAll { $0.id == maskID }
            case .effect(let id):
                guard let index = clip.effects.firstIndex(where: { $0.id == id }) else { return }
                clip.effects[index].masks.removeAll { $0.id == maskID }
            }
        }
    }
}
