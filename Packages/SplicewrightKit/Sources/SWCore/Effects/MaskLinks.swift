import Foundation

/// A mask elsewhere on the same clip: on its Opacity or on one of its effects.
public struct MaskSource: Sendable, Hashable, Codable {
    public var owner: MaskOwner
    public var maskID: UUID

    public init(owner: MaskOwner, maskID: UUID) {
        self.owner = owner
        self.maskID = maskID
    }
}

/// Shapes used by more than one mask: a Gaussian Blur limited to a shape drawn with the Pen and
/// tracked, say. The linked mask keeps its own mode, feather, opacity, expansion and Inverted, and
/// takes the shape's path, so tracking or reshaping it moves every effect that uses it.
public extension Clip {
    /// Linked masks with their shape's path (a link to a shape that's gone keeps the path it had).
    func resolvingMaskLinks() -> Clip {
        let linked = opacityMasks.contains { $0.pathSource != nil }
            || effects.contains { $0.masks.contains { $0.pathSource != nil } }
        guard linked else { return self }
        func resolve(_ mask: Mask) -> Mask {
            guard let link = mask.pathSource,
                  let shape = masks(of: link.owner).first(where: { $0.id == link.maskID && $0.pathSource == nil }) else {
                return mask
            }
            var resolved = mask
            resolved.path = shape.path
            return resolved
        }
        var clip = self
        clip.opacityMasks = opacityMasks.map(resolve)
        for index in clip.effects.indices { clip.effects[index].masks = clip.effects[index].masks.map(resolve) }
        return clip
    }

    /// Before shapes are deleted: masks using them keep the shape's path as their own.
    mutating func detachMaskLinks(where isRemoved: (MaskSource) -> Bool) {
        let resolved = resolvingMaskLinks()
        func detach(_ mask: inout Mask, _ current: Mask?) {
            guard let link = mask.pathSource, isRemoved(link) else { return }
            if let current { mask.path = current.path }
            mask.pathSource = nil
        }
        for index in opacityMasks.indices { detach(&opacityMasks[index], resolved.opacityMasks[index]) }
        for effect in effects.indices {
            for index in effects[effect].masks.indices {
                detach(&effects[effect].masks[index], resolved.effects[effect].masks[index])
            }
        }
    }

    /// The shapes on this clip a mask on `owner` can use: masks with paths of their own, elsewhere.
    func linkableMasks(for owner: MaskOwner) -> [(source: MaskSource, mask: Mask)] {
        ([MaskOwner.opacity] + effects.map { MaskOwner.effect($0.id) }).filter { $0 != owner }
            .flatMap { other in
                masks(of: other).filter { $0.pathSource == nil }.map { (MaskSource(owner: other, maskID: $0.id), $0) }
            }
    }
}

public extension EditSequence {
    /// Adds a mask on `owner` that uses `source`'s path; returns its ID.
    @discardableResult
    mutating func linkMask(to source: MaskSource, on owner: MaskOwner, of clipID: UUID) -> UUID? {
        guard source.owner != owner, let shape = clip(clipID)?.masks(of: source.owner)
            .first(where: { $0.id == source.maskID && $0.pathSource == nil }) else { return nil }
        var mask = Mask(vertices: [])
        mask.path = shape.path
        mask.pathSource = source
        guard let id = addMask(mask, to: owner, of: clipID) else { return nil }
        updateMask(id, of: owner, in: clipID) { $0.name = shape.name }
        return id
    }
}
