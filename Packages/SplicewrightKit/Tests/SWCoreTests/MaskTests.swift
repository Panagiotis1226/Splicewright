import Foundation
import Testing
@testable import SWCore

@Suite("Masks")
struct MaskTests {
    private let rate = FrameRate.fps30

    private func sequence() -> (EditSequence, UUID) {
        var seq = EditSequence(name: "S", settings: SequenceSettings(width: 1920, height: 1080, frameRate: rate,
                                                                     colorSpace: .rec709))
        let clip = Clip(mediaID: UUID(), name: "v", start: 0, duration: 100, sourceStart: .zero)
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: clip)])
        return (seq, clip.id)
    }

    @Test func ellipseIsACircle() {
        let mask = Mask.ellipse(centerX: 0.5, centerY: 0.5, radiusX: 0.25, radiusY: 0.25)
        let vertices = mask.vertices(at: .zero)
        #expect(vertices.count == 4)
        var worst = 0.0
        for segment in 0..<4 {
            for step in 0...20 {
                let point = Mask.point(on: vertices, segment: segment, t: Double(step) / 20)
                let radius = hypot(point.x - 0.5, point.y - 0.5)
                worst = max(worst, abs(radius - 0.25) / 0.25)
            }
        }
        #expect(worst < 0.001, "within 0.1% of a circle, got \(worst)")
    }

    @Test func insertingAVertexKeepsTheShape() {
        let vertices = Mask.ellipse().vertices(at: .zero)
        let split = 0.3
        let inserted = Mask.insertingVertex(into: vertices, segment: 1, t: split)
        #expect(inserted.count == 5)
        for step in 0...10 {
            let s = Double(step) / 10
            let before = Mask.point(on: inserted, segment: 1, t: s)
            let expectedBefore = Mask.point(on: vertices, segment: 1, t: s * split)
            let after = Mask.point(on: inserted, segment: 2, t: s)
            let expectedAfter = Mask.point(on: vertices, segment: 1, t: split + s * (1 - split))
            #expect(abs(before.x - expectedBefore.x) < 1e-9 && abs(before.y - expectedBefore.y) < 1e-9)
            #expect(abs(after.x - expectedAfter.x) < 1e-9 && abs(after.y - expectedAfter.y) < 1e-9)
        }
        // The other segments don't move.
        let untouched = Mask.point(on: inserted, segment: 3, t: 0.5)
        let original = Mask.point(on: vertices, segment: 2, t: 0.5)
        #expect(abs(untouched.x - original.x) < 1e-12 && abs(untouched.y - original.y) < 1e-12)
    }

    @Test func pathKeyframesInterpolateVertexByVertex() {
        var mask = Mask.rectangle(left: 0.2, top: 0.2, right: 0.4, bottom: 0.4)
        let start = RationalTime(frames: 0, rate: rate)
        let end = RationalTime(frames: 30, rate: rate)
        mask.path.setAnimated(true, at: start)
        mask.offset(dx: 0.4, dy: 0.2, at: end, tolerance: rate.frameDuration)
        #expect(mask.isAnimated)
        let middle = mask.vertices(at: RationalTime(frames: 15, rate: rate))
        #expect(abs(middle[0].x - 0.4) < 1e-9 && abs(middle[0].y - 0.3) < 1e-9)
        #expect(abs(middle[2].x - 0.6) < 1e-9 && abs(middle[2].y - 0.5) < 1e-9)

        // A vertex added while animated goes into every keyframe, so the counts stay equal.
        mask.insertVertex(segment: 0, t: 0.5)
        #expect(mask.path.keyframes.allSatisfy { $0.values.count == 30 })
        #expect(mask.vertices(at: RationalTime(frames: 15, rate: rate)).count == 5)

        // Removing one does the same, down to three.
        mask.removeVertex(at: 1)
        #expect(mask.path.keyframes.allSatisfy { $0.values.count == 24 })
        mask.removeVertex(at: 0)
        mask.removeVertex(at: 0)
        #expect(mask.vertices(at: .zero).count == 3, "a mask keeps at least three points")
        #expect(EffectKind.gaussianBlur.supportsMasks && !EffectKind.crop.supportsMasks)
    }

    @Test func resolvedClampsAndRetimes() {
        var mask = Mask.ellipse()
        mask.feather = AnimatableProperty([-5])
        mask.opacity = AnimatableProperty([150])
        let resolved = mask.resolved(at: .zero)
        #expect(resolved.feather == 0 && resolved.opacity == 1 && resolved.vertices.count == 4)

        mask.path.setAnimated(true, at: RationalTime(frames: 10, rate: rate))
        let copy = mask.retimed(by: RationalTime(frames: 5, rate: rate))
        #expect(copy.id != mask.id && copy.path.keyframes.first?.time == RationalTime(frames: 15, rate: rate))
    }

    @Test func codableRoundTripAndOldClipsLoad() throws {
        let (seq, clipID) = sequence()
        var edited = seq
        let effect = try #require(edited.addEffect(.gaussianBlur, to: [clipID])[clipID])
        edited.addMask(.ellipse(), to: .opacity, of: clipID)
        edited.addMask(.rectangle(), to: .effect(effect), of: clipID)
        let data = try JSONEncoder().encode(edited)
        let decoded = try JSONDecoder().decode(EditSequence.self, from: data)
        #expect(decoded == edited)
        #expect(decoded.clip(clipID)?.opacityMasks.count == 1 && decoded.clip(clipID)?.effects.first?.masks.count == 1)

        // A clip saved before masks (no keys) loads with none, and one without masks writes no key.
        let plain = try JSONEncoder().encode(seq)
        let text = try #require(String(data: plain, encoding: .utf8))
        #expect(!text.contains("opacityMasks") && !text.contains("\"masks\""))
        let old = try JSONDecoder().decode(EditSequence.self, from: plain)
        #expect(old.clip(clipID)?.opacityMasks.isEmpty == true)
    }

    @Test func noneMasksAreShapesToTrackAndAttachTo() throws {
        var (seq, clipID) = sequence()
        var shape = Mask.ellipse()
        shape.mode = .none
        #expect(!shape.mode.isDrawn && Mask.Mode.add.isDrawn && Mask.Mode.subtract.isDrawn)
        #expect(Mask.Mode.allCases.map(\.displayName) == ["Add", "Subtract", "None"])
        let added = seq.addMask(shape, to: .opacity, of: clipID)
        let maskID = try #require(added)
        let decoded = try JSONDecoder().decode(EditSequence.self, from: JSONEncoder().encode(seq))
        #expect(decoded.clip(clipID)?.opacityMasks.first?.mode == Mask.Mode.none)

        // Once tracked (its path animated), a title over the clip can follow it.
        seq.updateMask(maskID, of: .opacity, in: clipID) { mask in
            mask.path.setAnimated(true, at: .zero)
            mask.setVertices(Mask.ellipse(centerX: 0.6).vertices(at: .zero), at: RationalTime(frames: 10, rate: .fps30),
                             tolerance: FrameRate.fps30.frameDuration)
        }
        let animated = seq.clip(clipID)?.opacityMasks.first?.path.isAnimated
        #expect(animated == true)
        let title = Clip(mediaID: UUID(), name: "t", start: 0, duration: 30, sourceStart: .zero)
        #expect(seq.followableMasks(for: title).map(\.mask.id) == [maskID])
    }

    @Test func effectsUseATrackedShape() throws {
        var (seq, clipID) = sequence()
        var shape = Mask.ellipse()
        shape.mode = .none
        let addedShape = seq.addMask(shape, to: .opacity, of: clipID)
        let shapeID = try #require(addedShape)
        let blur = try #require(seq.addEffect(.gaussianBlur, to: [clipID])[clipID])
        let source = MaskSource(owner: .opacity, maskID: shapeID)
        #expect(seq.clip(clipID)?.linkableMasks(for: .effect(blur)).map(\.source) == [source])
        #expect(seq.clip(clipID)?.linkableMasks(for: .opacity).isEmpty == true, "not onto its own owner")
        let linked = seq.linkMask(to: source, on: .effect(blur), of: clipID)
        let linkedID = try #require(linked)

        // Tracking moves the shape; the blur's mask goes with it, keeping its own mode.
        let later = RationalTime(frames: 10, rate: rate)
        let moved = Mask.ellipse(centerX: 0.7).vertices(at: .zero)
        seq.updateMask(shapeID, of: .opacity, in: clipID) { mask in
            mask.path.setAnimated(true, at: .zero)
            mask.setVertices(moved, at: later, tolerance: rate.frameDuration)
        }
        let resolved = try #require(seq.clip(clipID)?.resolvingMaskLinks())
        let blurMask = try #require(resolved.effects.first?.masks.first)
        #expect(blurMask.id == linkedID && blurMask.mode == .add && blurMask.name == "Mask (1)")
        #expect(blurMask.vertices(at: later) == moved)
        let layer = try #require(RenderPlan.videoSegments(for: seq).first?.layers.first)
        #expect(layer.effects.first?.masks.first?.vertices(at: later) == moved, "the render plan uses the shape")
        let followable = seq.followableMasks(for: Clip(mediaID: UUID(), name: "t", start: 0, duration: 30,
                                                       sourceStart: .zero)).map(\.mask.id)
        #expect(followable == [shapeID], "the shape, not its uses")

        // Deleting the shape leaves the blur its last path.
        seq.removeMask(shapeID, of: .opacity, in: clipID)
        let kept = try #require(seq.clip(clipID)?.effects.first?.masks.first)
        #expect(kept.pathSource == nil && kept.vertices(at: later) == moved)
    }

    @Test func editsAndPropertyRefs() throws {
        var (seq, clipID) = sequence()
        let addedFirst = seq.addMask(.ellipse(), to: .opacity, of: clipID)
        let addedSecond = seq.addMask(.rectangle(), to: .opacity, of: clipID)
        let first = try #require(addedFirst)
        let second = try #require(addedSecond)
        #expect(seq.clip(clipID)?.opacityMasks.map(\.name) == ["Mask (1)", "Mask (2)"])
        let orphan = seq.addMask(.ellipse(), to: .effect(UUID()), of: clipID)
        #expect(orphan == nil, "no such effect")

        let feather = PropertyRef.mask(.opacity, first, .feather)
        seq.updateAnimatable(feather, of: clipID) { $0.values = [5000] }
        #expect(seq.clip(clipID)?.animatable(feather)?.values == [1000], "clamped to the feather range")
        seq.resetAnimatable(feather, of: clipID)
        #expect(seq.clip(clipID)?.animatable(feather)?.values == [10])

        let refs = try #require(seq.clip(clipID)?.allRefs)
        #expect(refs.contains(.mask(.opacity, second, .path)) && refs.contains(feather))

        // Keyframes on a mask show on the timeline like any other.
        seq.updateAnimatable(.mask(.opacity, second, .opacity), of: clipID) {
            $0.setAnimated(true, at: RationalTime(frames: 20, rate: rate))
        }
        #expect(seq.clip(clipID)?.keyframeFrames(rate: rate) == [20])

        seq.removeMask(first, of: .opacity, in: clipID)
        #expect(seq.clip(clipID)?.opacityMasks.map(\.id) == [second])
        #expect(seq.clip(clipID)?.animatable(feather) == nil)
    }
}
