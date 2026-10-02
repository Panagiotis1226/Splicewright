import Foundation

/// A clip moving with a tracked mask on another clip: a name over a person, a logo on a sign.
public struct FollowLink: Sendable, Hashable, Codable {
    public var targetClipID: UUID
    public var owner: MaskOwner
    public var maskID: UUID
    /// The sequence frame it was attached on; it keeps its place relative to the mask from there.
    public var anchorFrame: Int64
    public var followsScale = true
    public var followsRotation = true

    public init(targetClipID: UUID, owner: MaskOwner, maskID: UUID, anchorFrame: Int64) {
        self.targetClipID = targetClipID
        self.owner = owner
        self.maskID = maskID
        self.anchorFrame = anchorFrame
    }
}

public extension Clip {
    /// A point of the clip's picture (fractions of it as shown) in sequence pixels at a sequence
    /// frame: through the Stabilizer, the fit into the frame, and Motion, as the Program
    /// monitor shows it. `pictureSize` is the picture as shown (the frame's size for titles).
    func framePoint(u: Double, v: Double, atSequenceFrame frame: Int64, settings: SequenceSettings,
                    pictureSize: (width: Double, height: Double)) -> (x: Double, y: Double) {
        let time = keyframeTime(for: .clip(.position), atSequenceFrame: frame, rate: settings.frameRate)
        var (u, v) = (u, v)
        if let fix = stabilization(at: time) {
            let moved = fix.correction.apply(x: u * fix.width, y: v * fix.height)
            (u, v) = (moved.x / fix.width, moved.y / fix.height)
        }
        let (width, height) = (Double(settings.width), Double(settings.height))
        let (pw, ph) = (max(pictureSize.width, 1), max(pictureSize.height, 1))
        let fit = min(width / pw, height / ph)
        let point = (width / 2 + (2 * u - 1) * pw * fit / 2, height / 2 + (2 * v - 1) * ph * fit / 2)
        return motion.transform(at: time, renderWidth: width, renderHeight: height, scale: 1)
            .apply(x: point.0, y: point.1)
    }
}

public extension EditSequence {
    /// How a following clip moves at a sequence frame, in sequence pixels (applied after its own
    /// Motion): the mask's motion since the anchor frame, as position, and scale and rotation if
    /// it follows those. Nil if it follows nothing (or the target or mask is gone).
    func followTransform(of clip: Clip, atFrame frame: Int64,
                         pictureSize: (Clip) -> (width: Double, height: Double)) -> Affine2D? {
        guard let link = clip.follow, link.targetClipID != clip.id, let target = self.clip(link.targetClipID),
              let mask = target.masks(of: link.owner).first(where: { $0.id == link.maskID }), target.duration > 0 else {
            return nil
        }
        let ref = PropertyRef.mask(link.owner, link.maskID, .path)
        let size = pictureSize(target)
        // Beyond the target clip, hold where the mask was at its first or last frame.
        func points(_ at: Int64) -> [(x: Double, y: Double)] {
            let held = min(max(at, target.start), target.end - 1)
            let vertices = mask.vertices(at: target.keyframeTime(for: ref, atSequenceFrame: held, rate: rate))
            return vertices.map { target.framePoint(u: $0.x, v: $0.y, atSequenceFrame: held, settings: settings,
                                                    pictureSize: size) }
        }
        let before = points(link.anchorFrame)
        let now = points(frame)
        guard before.count == now.count, before.count >= 2,
              let fitted = MotionFit.fit(.positionScaleRotation, zip(before, now).map { Correspondence(from: $0, to: $1) })
        else { return nil }
        let m = fitted.m
        let n = Double(before.count)
        let from = (before.reduce(0) { $0 + $1.x } / n, before.reduce(0) { $0 + $1.y } / n)
        let to = (now.reduce(0) { $0 + $1.x } / n, now.reduce(0) { $0 + $1.y } / n)
        let scale = link.followsScale ? hypot(m[0], m[3]) : 1
        let angle = link.followsRotation ? atan2(m[3], m[0]) : 0
        let (c, s) = (cos(angle) * scale, sin(angle) * scale)
        // About the mask's center: turn and scale there, then move with it.
        return Affine2D.translation(-from.0, -from.1)
            .concatenating(Affine2D(a: c, b: s, c: -s, d: c, tx: 0, ty: 0))
            .concatenating(.translation(to.0, to.1))
    }

    /// Masks on other clips a clip could follow: on video clips overlapping it, with an animated path.
    func followableMasks(for clip: Clip) -> [(clip: Clip, owner: MaskOwner, mask: Mask)] {
        videoTracks.flatMap(\.clips).filter { $0.id != clip.id && $0.start < clip.end && clip.start < $0.end }
            .flatMap { other in
                ([MaskOwner.opacity] + other.effects.map { MaskOwner.effect($0.id) }).flatMap { owner in
                    other.masks(of: owner).filter(\.path.isAnimated).map { (other, owner, $0) }
                }
            }
    }
}
