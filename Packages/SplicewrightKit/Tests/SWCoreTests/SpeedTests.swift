import Foundation
import Testing
@testable import SWCore

@Suite("Speed and time remapping")
struct SpeedTests {
    private let rate = FrameRate.fps30
    private let mediaID = UUID()

    /// One 100-frame clip from source second 1 on V1 (with a linked audio clip on A1), and a
    /// clip after it at frame 200.
    private var media: MediaDurations { [mediaID: RationalTime(value: 20, timescale: 1)] }

    private func fixture() -> (EditSequence, UUID, UUID) {
        var sequence = EditSequence(name: "S", settings: SequenceSettings(width: 1920, height: 1080, frameRate: rate,
                                                                          colorSpace: .rec709))
        let link = UUID()
        let video = Clip(mediaID: mediaID, name: "v", start: 0, duration: 100, sourceStart: RationalTime(value: 1, timescale: 1),
                         linkID: link)
        var audio = video
        audio.id = UUID()
        let after = Clip(mediaID: mediaID, name: "after", start: 200, duration: 30, sourceStart: .zero)
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[0].id, clip: video),
                            TrackPlacement(trackID: sequence.audioTracks[0].id, clip: audio),
                            TrackPlacement(trackID: sequence.videoTracks[0].id, clip: after)])
        return (sequence, video.id, audio.id)
    }

    @Test func constantSpeedMapsAndRoundTrips() throws {
        var clip = Clip(mediaID: mediaID, name: "c", start: 10, duration: 60, sourceStart: RationalTime(value: 2, timescale: 1))
        clip.speed = AnimatableProperty([200])
        #expect(clip.sourceTime(atSequenceFrame: 40, rate: rate).seconds == 4, "30 frames at 200% is 2 s of source")
        #expect(clip.sequenceFrame(atSourceTime: RationalTime(value: 4, timescale: 1), rate: rate) == 40)
        #expect(abs(clip.timing(rate: rate).sourceSpan - 4) < 1e-9)
        clip.isReversed = true
        #expect(clip.sourceTime(atSequenceFrame: 40, rate: rate).seconds == 0, "backwards from 2 s")
        #expect(clip.sequenceFrame(atSourceTime: .zero, rate: rate) == 40)
    }

    @Test func remapIntegratesTheSpeed() {
        var clip = Clip(mediaID: mediaID, name: "c", start: 0, duration: 60, sourceStart: .zero)
        // 100% for the first second, then 0% (a freeze), keyframed with Hold.
        clip.speed.setAnimated(true, at: .zero)
        clip.speed.set([0], at: RationalTime(frames: 30, rate: rate), tolerance: rate.frameDuration)
        clip.speed.setInterpolation(.hold, for: Set(clip.speed.keyframes.map(\.id)))
        let timing = clip.timing(rate: rate)
        #expect(timing.isRemapped)
        #expect(abs(timing.sourceOffset(atClipFrame: 15) - 0.5) < 1e-9)
        #expect(abs(timing.sourceOffset(atClipFrame: 50) - timing.sourceOffset(atClipFrame: 31)) < 1e-9, "held")
        #expect(abs(timing.sourceOffset(atClipFrame: 40) - 1) < 1e-9, "held on the keyframe's frame, a full second in")
        #expect(abs(timing.clipFrame(atSourceOffset: 0.5) - 15) < 1e-6)

        // A ramp from 100% to 300% over a second covers 2 s of source in that second.
        var ramp = Clip(mediaID: mediaID, name: "r", start: 0, duration: 30, sourceStart: .zero)
        ramp.speed.setAnimated(true, at: .zero)
        ramp.speed.set([300], at: RationalTime(frames: 30, rate: rate), tolerance: rate.frameDuration)
        #expect(abs(ramp.timing(rate: rate).sourceSpan - 2) < 1e-9)
    }

    @Test func speedDurationKeepsTheSourceAndCanRipple() throws {
        var (sequence, video, audio) = fixture()
        sequence.changeSpeed([video, audio], SpeedChange(percent: 25))
        #expect(sequence.clip(video)?.duration == 200, "400 frames won't fit before the next clip without ripple")
        #expect(sequence.clip(audio)?.duration == 400, "the audio track is free")

        (sequence, video, audio) = fixture()
        sequence.changeSpeed([video, audio], SpeedChange(percent: 50, ripple: true))
        #expect(sequence.clip(video)?.duration == 200 && sequence.clip(audio)?.duration == 200)
        #expect(sequence.videoTracks[0].clips.last?.start == 300, "the next clip moved along")

        (sequence, video, audio) = fixture()
        sequence.changeSpeed([video, audio], SpeedChange(percent: 400, ripple: true))
        #expect(sequence.clip(video)?.duration == 25)
        #expect(sequence.videoTracks[0].clips.last?.start == 125, "the gap closed")

        (sequence, video, audio) = fixture()
        sequence.changeSpeed([video], SpeedChange(duration: 50))
        #expect(sequence.clip(video)?.speedPercent == 200)
    }

    @Test func reverseStartsFromTheLastFrame() throws {
        var (sequence, video, _) = fixture()
        let last = try #require(sequence.clip(video)).sourceTime(atSequenceFrame: 99, rate: rate)
        sequence.changeSpeed([video], SpeedChange(percent: 100, isReversed: true))
        let reversed = try #require(sequence.clip(video))
        #expect(reversed.isReversed && reversed.duration == 100)
        #expect(reversed.sourceTime(atSequenceFrame: 0, rate: rate) == last)
        #expect(reversed.sourceTime(atSequenceFrame: 99, rate: rate).seconds == 1, "ends on the original first frame")
    }

    @Test func trimsSplitsAndSlipsFollowTheSpeed() throws {
        var (sequence, video, _) = fixture()
        sequence.changeSpeed([video], SpeedChange(percent: 200))
        #expect(sequence.clip(video)?.duration == 50)
        // At 200%, 19 s of source after second 1 is 285 frames: the end can't go past it (or the next clip).
        let applied = sequence.trim(video, edge: .end, by: 1000, media: media)
        #expect(applied == 150, "stops at the next clip at frame 200")
        // The head can extend back 1 s of source = 15 frames, but the clip starts at 0.
        #expect(sequence.trim(video, edge: .start, by: -10, media: media) == 0)
        #expect(sequence.trim(video, edge: .start, by: 10, media: media) == 10)
        let trimmed = try #require(sequence.clip(video))
        #expect(abs(trimmed.sourceStart.seconds - (1 + 20.0 / 30)) < 1e-6, "10 frames at 200% skip 20 source frames")

        sequence.razor(at: 100, trackIDs: [sequence.videoTracks[0].id])
        let right = try #require(sequence.videoTracks[0].clips.first { $0.start == 100 })
        #expect(right.speedPercent == 200)
        #expect(abs(right.sourceStart.seconds - trimmed.sourceTime(atSequenceFrame: 100, rate: rate).seconds) < 1e-6)

        // Slip stops where the source ends: 20 s media.
        let slipped = sequence.slip(right.id, by: 10_000, media: media)
        let after = try #require(sequence.clip(right.id))
        #expect(slipped > 0 && abs(after.timing(rate: rate).sourceRange.upper - 20) < 1.0 / 30 + 1e-6)
    }

    @Test func splittingARemappedClipShiftsItsKeyframes() throws {
        var (sequence, video, _) = fixture()
        sequence.updateProperty(.speed, of: video) { speed in
            speed.setAnimated(true, at: .zero)
            speed.set([300], at: RationalTime(frames: 80, rate: rate), tolerance: rate.frameDuration)
        }
        let before = try #require(sequence.clip(video))
        let shown = before.sourceTime(atSequenceFrame: 60, rate: rate)
        sequence.razor(at: 40, trackIDs: [sequence.videoTracks[0].id])
        let right = try #require(sequence.videoTracks[0].clips.first { $0.start == 40 })
        #expect(right.speed.keyframes.map { $0.time.frameIndex(at: rate) } == [-40, 40])
        #expect(abs(right.sourceTime(atSequenceFrame: 60, rate: rate).seconds - shown.seconds) < 1e-6,
                "the same picture at the same frame after the cut")
        // Keyframe times for Speed are clip-relative; for Scale they're source time.
        #expect(right.keyframeTime(for: .speed, atSequenceFrame: 50, rate: rate) == RationalTime(frames: 10, rate: rate))
        #expect(right.sequenceFrame(ofKeyframeTime: RationalTime(frames: 10, rate: rate), for: .speed, rate: rate) == 50)
    }

    @Test func rateStretchKeepsTheSource() throws {
        var (sequence, video, audio) = fixture()
        #expect(sequence.rateStretch(video, edge: .end, by: 100) == 100)
        let stretched = try #require(sequence.clip(video))
        #expect(stretched.duration == 200 && abs(stretched.speedPercent - 50) < 1e-9)
        #expect(sequence.clip(audio)?.duration == 200, "linked audio follows")
        #expect(sequence.rateStretch(video, edge: .end, by: 50) == 0, "the next clip is in the way")
        #expect(sequence.rateStretch(video, edge: .start, by: 150) == 150)
        #expect(abs((sequence.clip(video)?.speedPercent ?? 0) - 200) < 1e-9)
    }

    @Test func olderClipsDecodeAtFullSpeed() throws {
        let clip = Clip(mediaID: mediaID, name: "c", start: 0, duration: 10, sourceStart: .zero)
        let json = String(bytes: try JSONEncoder().encode(clip), encoding: .utf8) ?? ""
        #expect(!json.contains("speed") && !json.contains("isReversed"), "defaults aren't written")
        let decoded = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(decoded.speedPercent == 100 && !decoded.isReversed && decoded.maintainsPitch && !decoded.isRetimed)
        var fast = clip
        fast.speed = AnimatableProperty([150])
        fast.isReversed = true
        let roundTrip = try JSONDecoder().decode(Clip.self, from: try JSONEncoder().encode(fast))
        #expect(roundTrip == fast)
    }

    @Test func renderLayersCarryTiming() {
        var (sequence, video, _) = fixture()
        sequence.changeSpeed([video], SpeedChange(percent: 50, ripple: true))
        let layer = RenderPlan.videoSegments(for: sequence).first?.layers.first
        #expect(layer?.timing?.constantSpeed == 0.5)
    }
}
