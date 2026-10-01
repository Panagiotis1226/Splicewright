import Foundation
import Testing
@testable import SWCore

@Suite("Keyframes")
struct KeyframeTests {
    private func seconds(_ value: Double) -> RationalTime { RationalTime(seconds: value, timescale: 600) }
    private let frame = RationalTime(value: 1, timescale: 30)

    @Test func interpolation() {
        var property = AnimatableProperty([0])
        property.setAnimated(true, at: seconds(0))
        property.set([100], at: seconds(2), tolerance: frame)
        #expect(property.value(at: seconds(-1)) == [0], "before the first keyframe")
        #expect(property.value(at: seconds(1)) == [50], "linear midpoint")
        #expect(property.value(at: seconds(5)) == [100], "after the last keyframe")

        property.setInterpolation(.easeInOut, for: Set(property.keyframes.map(\.id)))
        #expect(property.value(at: seconds(1)) == [50], "ease in and out is symmetric")
        #expect(property.value(at: seconds(0.2))[0] < 10, "eased: slow start")
        #expect(property.value(at: seconds(1.8))[0] > 90, "eased: slow finish")

        property.setInterpolation(.hold, for: [property.keyframes[0].id])
        #expect(property.value(at: seconds(1.99)) == [0])
        #expect(property.value(at: seconds(2)) == [100])
    }

    @Test func easeOutOnlyStartsSlowly() {
        let slowStart = AnimatableProperty.ease(0.1, out: true, in: false)
        let slowEnd = AnimatableProperty.ease(0.9, out: false, in: true)
        #expect(slowStart < 0.1 && slowEnd > 0.9)
        #expect(AnimatableProperty.ease(1, out: true, in: false) == 1)
    }

    @Test func stopwatchToggleAndMove() throws {
        var property = AnimatableProperty([10, 20])
        property.set([1, 2], at: seconds(1), tolerance: frame)
        #expect(!property.isAnimated && property.values == [1, 2], "without the stopwatch, setting changes the constant")
        property.setAnimated(true, at: seconds(1))
        property.set([5, 5], at: seconds(3), tolerance: frame)
        #expect(property.keyframes.count == 2)
        property.set([6, 6], at: seconds(3.01), tolerance: frame)
        #expect(property.keyframes.count == 2, "within a frame updates the existing keyframe")
        property.toggleKeyframe(at: seconds(2), tolerance: frame)
        #expect(property.keyframes.count == 3)
        #expect(property.keyframes[1].values == [3.5, 4])
        property.toggleKeyframe(at: seconds(2), tolerance: frame)
        #expect(property.keyframes.count == 2)
        let last = try #require(property.keyframes.last)
        property.move(last.id, to: seconds(1), tolerance: frame)
        #expect(property.keyframes.count == 1, "moving onto a keyframe replaces it")
        #expect(property.next(after: seconds(0))?.values == [6, 6])
        property.setAnimated(false, at: seconds(1))
        #expect(!property.isAnimated && property.values == [6, 6])
    }

    @Test func motionTransform() {
        var motion = Motion()
        func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            motion.transform(at: .zero, renderWidth: 1920, renderHeight: 1080, scale: 1).apply(x: x, y: y)
        }
        #expect(apply(100, 200) == (100, 200), "identity by default")
        motion.position.values = [100, -50]
        #expect(apply(960, 540) == (1060, 490))
        motion.position.values = [0, 0]
        motion.scale.values = [50]
        #expect(apply(0, 0) == (480, 270), "scales about the centre")
        motion.scale.values = [100]
        motion.rotation.values = [90]
        let rotated = apply(1060, 540)
        #expect(abs(rotated.x - 960) < 1e-9 && abs(rotated.y - 640) < 1e-9, "rotates clockwise (y down)")
        motion.rotation.values = [0]
        motion.anchorPoint.values = [100, 0]
        #expect(apply(1060, 540) == (960, 540), "the anchor point lands on Position")
        // Half-resolution preview: offsets scale with it.
        motion.anchorPoint.values = [0, 0]
        motion.position.values = [100, 0]
        let half = motion.transform(at: .zero, renderWidth: 960, renderHeight: 540, scale: 0.5).apply(x: 480, y: 270)
        #expect(half == (530, 270))
    }

    @Test func keyframesStayWithThePictureWhenTrimmedOrCut() throws {
        var sequence = EditSequence(name: "K", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        let clip = Clip(mediaID: UUID(), name: "A", start: 0, duration: 90, sourceStart: .zero)
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[0].id, clip: clip)])
        sequence.updateProperty(.opacity, of: clip.id) { $0.setAnimated(true, at: RationalTime(frames: 30, rate: .fps30)) }
        sequence.setProperty(.opacity, of: clip.id, to: [0], atFrame: 60)
        sequence.trim(clip.id, edge: .start, by: 15, media: [:])
        let trimmed = try #require(sequence.clip(clip.id))
        let keyFrames = trimmed.motion.opacity.keyframes.map { trimmed.sequenceFrame(atSourceTime: $0.time, rate: .fps30) }
        #expect(keyFrames == [30, 60], "trimming the head doesn't move keyframes on the timeline")
        sequence.razor(at: 45, trackIDs: [sequence.videoTracks[0].id])
        let halves = sequence.videoTracks[0].clips
        #expect(halves.count == 2)
        let left = halves[0].motion.opacity.value(at: halves[0].sourceTime(atSequenceFrame: 44, rate: .fps30))
        let right = halves[1].motion.opacity.value(at: halves[1].sourceTime(atSequenceFrame: 45, rate: .fps30))
        #expect(abs(left[0] - right[0]) < 4, "both halves continue the same animation")
    }

    @Test func legacyOpacityLoads() throws {
        let json = #"{"id":"\#(UUID())","mediaID":"\#(UUID())","name":"A","start":0,"duration":10,"#
            + #""sourceStart":{"value":0,"timescale":1},"isEnabled":true,"opacity":0.25,"gainDB":0}"#
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(clip.opacity == 0.25 && !clip.motion.opacity.isAnimated)
        let round = try JSONDecoder().decode(Clip.self, from: try JSONEncoder().encode(clip))
        #expect(round == clip)
    }

    @Test func pasteAttributesKeepsRelativeTiming() throws {
        var sequence = EditSequence(name: "K", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        var source = Clip(mediaID: UUID(), name: "S", start: 0, duration: 60, sourceStart: .zero)
        source.motion.scale.setAnimated(true, at: RationalTime(frames: 10, rate: .fps30))
        let target = Clip(mediaID: UUID(), name: "T", start: 100, duration: 60,
                          sourceStart: RationalTime(frames: 200, rate: .fps30))
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[0].id, clip: target)])
        sequence.pasteAttributes(from: source, to: [target.id])
        let pasted = try #require(sequence.clip(target.id))
        let frame = pasted.sequenceFrame(atSourceTime: pasted.motion.scale.keyframes[0].time, rate: .fps30)
        #expect(frame == 110, "10 frames into the clip, as in the source")
    }

    @Test func audioEnvelope() {
        var clip = Clip(mediaID: UUID(), name: "A", start: 0, duration: 60, sourceStart: .zero, gainDB: -6)
        let flat = RenderPlan.audioEnvelope(for: clip, fades: nil, range: clip.range, rate: .fps30)
        #expect(flat.count == 2 && abs(flat[0].gain - RenderPlan.linearGain(dB: -6)) < 1e-9)
        clip.volume.setAnimated(true, at: .zero)
        clip.volume.set([-60], at: RationalTime(frames: 30, rate: .fps30), tolerance: RationalTime(value: 1, timescale: 30))
        let ramp = RenderPlan.audioEnvelope(for: clip, fades: nil, range: clip.range, rate: .fps30)
        #expect(ramp.count > 8)
        #expect(ramp.first.map { abs($0.gain - RenderPlan.linearGain(dB: -6)) < 1e-6 } == true)
        let at30 = ramp.first { $0.frame == 30 }
        #expect(at30.map { abs($0.gain - RenderPlan.linearGain(dB: -66)) < 1e-6 } == true)
        #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0.frame < $1.frame })
    }
}
