import Foundation
import Testing
@testable import SWCore

/// A clip following a tracked mask on another clip.
@Suite("Follow a tracked mask")
struct FollowTests {
    private let rate = FrameRate.fps30

    /// V1: a clip whose mask moves right 0.1 of the picture and grows 1.5× by frame 30.
    /// V2: a clip over it that follows the mask from frame 0.
    private func sequence(targetMotion: (inout Motion) -> Void = { _ in }) throws -> (EditSequence, UUID, UUID) {
        var seq = EditSequence(name: "F", settings: SequenceSettings(width: 1920, height: 1080, frameRate: rate,
                                                                     colorSpace: .rec709))
        var target = Clip(mediaID: UUID(), name: "person", start: 0, duration: 60, sourceStart: .zero)
        targetMotion(&target.motion)
        let follower = Clip(mediaID: UUID(), name: "label", start: 0, duration: 60, sourceStart: .zero)
        seq.addTrack(.video)
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: target),
                       TrackPlacement(trackID: seq.videoTracks[1].id, clip: follower)])
        let added = seq.addMask(.rectangle(left: 0.4, top: 0.4, right: 0.6, bottom: 0.6), to: .opacity, of: target.id)
        let maskID = try #require(added)
        let start = RationalTime(frames: 0, rate: rate)
        let later = RationalTime(frames: 30, rate: rate)
        seq.updateMask(maskID, of: .opacity, in: target.id) { mask in
            mask.path.setAnimated(true, at: start)
            // Centered on (0.6, 0.5), 1.5 × as big.
            mask.setVertices(Mask.rectangle(left: 0.45, top: 0.35, right: 0.75, bottom: 0.65).vertices(at: .zero),
                             at: later, tolerance: rate.frameDuration)
        }
        seq.updateClipProperties([follower.id]) {
            $0.follow = FollowLink(targetClipID: target.id, owner: .opacity, maskID: maskID, anchorFrame: 0)
        }
        return (seq, target.id, follower.id)
    }

    private let fullFrame: (Clip) -> (width: Double, height: Double) = { _ in (1920, 1080) }

    private func moved(_ seq: EditSequence, _ follower: UUID, atFrame frame: Int64, _ point: (Double, Double)) throws
        -> (x: Double, y: Double) {
        let clip = try #require(seq.clip(follower))
        let transform = try #require(seq.followTransform(of: clip, atFrame: frame, pictureSize: fullFrame))
        return transform.apply(x: point.0, y: point.1)
    }

    @Test func followsPositionAndScale() throws {
        let (seq, _, follower) = try sequence()
        let still = try moved(seq, follower, atFrame: 0, (100, 100))
        #expect(abs(still.x - 100) < 1e-6 && abs(still.y - 100) < 1e-6, "no change on the anchor frame")
        // The mask's center goes from (960, 540) to (1152, 540), and it grows 1.5×.
        let center = try moved(seq, follower, atFrame: 30, (960, 540))
        #expect(abs(center.x - 1152) < 1e-6 && abs(center.y - 540) < 1e-6)
        let corner = try moved(seq, follower, atFrame: 30, (1060, 540))
        #expect(abs(corner.x - 1302) < 1e-6, "100 px from the center becomes 150")
        let half = try moved(seq, follower, atFrame: 15, (960, 540))
        #expect(abs(half.x - 1056) < 1e-6, "halfway between the keyframes")
        let beyond = try moved(seq, follower, atFrame: 90, (960, 540))
        #expect(abs(beyond.x - 1152) < 1e-6, "past the target's end it holds the last position")
    }

    @Test func positionOnlyKeepsItsSize() throws {
        var (seq, _, follower) = try sequence()
        seq.updateClipProperties([follower]) { $0.follow?.followsScale = false }
        let corner = try moved(seq, follower, atFrame: 30, (1060, 540))
        #expect(abs(corner.x - 1252) < 1e-6)
    }

    @Test func goesThroughTheTargetsOwnMotion() throws {
        // The tracked clip is shown at 50% and moved: the mask's motion on screen is half as far.
        let (seq, _, follower) = try sequence { motion in
            motion.scale = AnimatableProperty([50])
            motion.position = AnimatableProperty([200, 0])
        }
        let center = try moved(seq, follower, atFrame: 30, (1160, 540))
        #expect(abs(center.x - 1256) < 1e-6, "192 × 0.5 = 96 px")
    }

    @Test func listsOnlyTrackedMasksAndSurvivesSaving() throws {
        var (seq, target, follower) = try sequence()
        let clip = try #require(seq.clip(follower))
        #expect(seq.followableMasks(for: clip).map(\.clip.id) == [target])
        seq.addMask(.ellipse(), to: .opacity, of: target)
        #expect(seq.followableMasks(for: clip).count == 1, "a mask that never moves isn't offered")
        let decoded = try JSONDecoder().decode(EditSequence.self, from: JSONEncoder().encode(seq))
        #expect(decoded.clip(follower)?.follow == seq.clip(follower)?.follow)
        // If the target goes, the follower stays where it is.
        seq.removeMask(try #require(seq.clip(target)?.opacityMasks.first?.id), of: .opacity, in: target)
        #expect(seq.followTransform(of: try #require(seq.clip(follower)), atFrame: 30, pictureSize: fullFrame) == nil)
    }
}
