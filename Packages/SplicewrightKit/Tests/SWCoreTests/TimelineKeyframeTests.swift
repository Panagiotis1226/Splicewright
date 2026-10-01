import Foundation
import Testing
@testable import SWCore

@Suite("Keyframes on the timeline")
struct TimelineKeyframeTests {
    private let rate = FrameRate.fps30

    private func clip(start: Int64, duration: Int64 = 100, sourceStart: Int64 = 0) -> Clip {
        Clip(mediaID: UUID(), name: "c", start: start, duration: duration,
             sourceStart: RationalTime(frames: sourceStart, rate: rate))
    }

    private func key(_ property: inout AnimatableProperty, sourceFrame: Int64, _ value: Double) {
        if !property.isAnimated { property.setAnimated(true, at: RationalTime(frames: sourceFrame, rate: rate)) }
        property.set([value], at: RationalTime(frames: sourceFrame, rate: rate), tolerance: rate.frameDuration)
    }

    @Test func keyframesSitAtTheirSequenceFrames() {
        var plain = clip(start: 100)
        key(&plain.motion.opacity, sourceFrame: 10, 100)
        key(&plain.motion.opacity, sourceFrame: 40, 0)
        #expect(plain.keyframeFrames(rate: rate) == [110, 140], "source time plus the clip's start, not its left edge")

        // Trimmed: the source starts at frame 30, so source frame 40 is 10 frames in; frame 10 is cut off.
        var trimmed = clip(start: 0, sourceStart: 30)
        key(&trimmed.motion.scale, sourceFrame: 10, 50)
        key(&trimmed.motion.scale, sourceFrame: 40, 100)
        #expect(trimmed.keyframeFrames(rate: rate) == [10])
    }

    @Test func speedChangesMoveThem() {
        var fast = clip(start: 0)
        fast.speed = AnimatableProperty([200])
        key(&fast.motion.opacity, sourceFrame: 40, 50)
        #expect(fast.keyframeFrames(rate: rate) == [20], "at 200% source frame 40 plays at sequence frame 20")

        // Time remapping: speed keyframes are timed from the clip's start.
        var remapped = clip(start: 50)
        remapped.speed.setAnimated(true, at: .zero)
        remapped.speed.set([50], at: RationalTime(frames: 30, rate: rate), tolerance: rate.frameDuration)
        #expect(remapped.keyframeFrames(rate: rate) == [50, 80])
    }

    @Test func effectParametersCountAndDuplicatesMerge() {
        var seq = EditSequence(name: "S", settings: SequenceSettings(width: 1920, height: 1080, frameRate: rate,
                                                                     colorSpace: .rec709))
        var base = clip(start: 0)
        key(&base.motion.opacity, sourceFrame: 15, 100)
        key(&base.motion.position, sourceFrame: 15, 0)
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: base)])
        let effect = seq.addEffect(.gaussianBlur, to: [base.id])[base.id]!
        seq.setAnimatable(.effect(effect, "blurriness"), of: base.id, to: [0], atFrame: 60)
        seq.updateAnimatable(.effect(effect, "blurriness"), of: base.id) {
            $0.setAnimated(true, at: RationalTime(frames: 60, rate: rate))
        }
        let frames = seq.clip(base.id)?.keyframeFrames(rate: rate)
        #expect(frames == [15, 60], "opacity and position at 15 show once; the blur's keyframe too")
        #expect(Clip.rubberBandProperty(isAudio: true) == .volume && Clip.rubberBandProperty(isAudio: false) == .opacity)
    }
}
