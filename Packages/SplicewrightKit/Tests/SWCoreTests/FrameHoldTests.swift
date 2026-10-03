import Foundation
import Testing
@testable import SWCore

@Suite("Frame holds")
struct FrameHoldTests {
    private let rate = FrameRate.fps30

    /// A 100-frame video clip with linked audio, its source starting at 5 s.
    private func sequence() -> (EditSequence, video: UUID, audio: UUID) {
        var seq = EditSequence(name: "H", settings: SequenceSettings(width: 1920, height: 1080, frameRate: rate,
                                                                    colorSpace: .rec709))
        let link = UUID()
        let source = RationalTime(frames: 150, rate: rate)
        let video = Clip(mediaID: UUID(), name: "v", start: 0, duration: 100, sourceStart: source, linkID: link)
        var audio = video
        audio.id = UUID()
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: video),
                       TrackPlacement(trackID: seq.audioTracks[0].id, clip: audio)])
        return (seq, video.id, audio.id)
    }

    @Test func addFrameHoldFreezesFromThePlayhead() throws {
        var (seq, video, audio) = sequence()
        let added = seq.addFrameHold(to: video, at: 40)
        let holdID = try #require(added)
        let clips = seq.videoTracks[0].clips
        #expect(clips.map(\.range) == [FrameRange(start: 0, end: 40), FrameRange(start: 40, end: 100)])
        let hold = try #require(seq.clip(holdID))
        #expect(hold.isFrameHold && hold.linkID == nil)
        let frozen = RationalTime(frames: 190, rate: rate)
        for frame in [Int64(40), 70, 99] {
            #expect(abs((hold.sourceTime(atSequenceFrame: frame, rate: rate) - frozen).seconds) < 1e-6, "frame \(frame)")
        }
        #expect(clips[0].sourceTime(atSequenceFrame: 39, rate: rate) == RationalTime(frames: 189, rate: rate))
        #expect(seq.audioTracks[0].clips.map(\.id) == [audio], "linked audio plays on")

        // On a clip's first frame the whole clip holds.
        var (whole, first, _) = sequence()
        whole.addFrameHold(to: first, at: 0)
        #expect(whole.videoTracks[0].clips.count == 1 && whole.videoTracks[0].clips[0].isFrameHold)
    }

    @Test func insertFrameHoldSegmentRipplesTheRest() throws {
        var (seq, video, _) = sequence()
        let inserted = seq.insertFrameHoldSegment(in: video, at: 40, length: 60)
        let holdID = try #require(inserted)
        let clips = seq.videoTracks[0].clips
        #expect(clips.map(\.range) == [FrameRange(start: 0, end: 40), FrameRange(start: 40, end: 100),
                                       FrameRange(start: 100, end: 160)])
        #expect(clips[1].id == holdID && clips[1].isFrameHold)
        #expect(clips[1].sourceTime(atSequenceFrame: 80, rate: rate) == RationalTime(frames: 190, rate: rate))
        #expect(clips[2].sourceTime(atSequenceFrame: 100, rate: rate) == RationalTime(frames: 190, rate: rate),
                "the rest carries on from the held frame")
        // The audio (sync-locked) gets the same gap.
        #expect(seq.audioTracks[0].clips.map(\.range) == [FrameRange(start: 0, end: 40), FrameRange(start: 100, end: 160)])
        #expect(seq.durationFrames == 160)
    }

    @Test func holdsSurviveSavingAndNeedAVideoClip() throws {
        var (seq, video, audio) = sequence()
        #expect(seq.addFrameHold(to: audio, at: 10) == nil, "audio clips don't hold")
        #expect(seq.addFrameHold(to: video, at: 100) == nil, "the playhead must be on the clip")
        let added = seq.addFrameHold(to: video, at: 30)
        let holdID = try #require(added)
        let decoded = try JSONDecoder().decode(EditSequence.self, from: JSONEncoder().encode(seq))
        #expect(decoded.clip(holdID)?.isFrameHold == true)
    }
}
