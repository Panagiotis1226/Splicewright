import Foundation
import Testing
@testable import SWCore

/// A 30 fps sequence with helpers to lay out clips by frame.
private struct Fixture {
    var sequence = EditSequence(name: "Test", settings: SequenceSettings(
        width: 1920, height: 1080, frameRate: .fps30, colorSpace: .rec709))
    let mediaID = UUID()
    var media: MediaDurations { [mediaID: RationalTime(value: 100, timescale: 1)] }  // 3000 frames

    var v1: UUID { sequence.videoTracks[0].id }
    var v2: UUID { sequence.videoTracks[1].id }
    var a1: UUID { sequence.audioTracks[0].id }
    var a2: UUID { sequence.audioTracks[1].id }

    /// Places a linked video+audio clip on V1/A1 showing source frames starting at `source`.
    @discardableResult
    mutating func addLinked(_ name: String, start: Int64, duration: Int64, source: Int64 = 100) -> (UUID, UUID) {
        let link = UUID()
        let sourceStart = RationalTime(frames: source, rate: .fps30)
        let video = Clip(mediaID: mediaID, name: name, start: start, duration: duration, sourceStart: sourceStart, linkID: link)
        let audio = Clip(mediaID: mediaID, name: name, start: start, duration: duration, sourceStart: sourceStart, linkID: link)
        sequence.overwrite([TrackPlacement(trackID: v1, clip: video), TrackPlacement(trackID: a1, clip: audio)])
        return (video.id, audio.id)
    }

    @discardableResult
    mutating func add(_ name: String, track: UUID, start: Int64, duration: Int64, source: Int64 = 100) -> UUID {
        let clip = Clip(mediaID: mediaID, name: name, start: start, duration: duration,
                        sourceStart: RationalTime(frames: source, rate: .fps30))
        sequence.overwrite([TrackPlacement(trackID: track, clip: clip)])
        return clip.id
    }

    /// "name@start+duration" for each clip on a track, in order.
    func layout(_ track: UUID) -> [String] {
        sequence.track(track)?.clips.map { "\($0.name)@\($0.start)+\($0.duration)" } ?? []
    }

    func sourceFrame(_ clipID: UUID) -> Int64? {
        sequence.clip(clipID)?.sourceStart.frameIndex(at: .fps30)
    }
}

@Suite("Timeline: placing clips")
struct TimelinePlacementTests {
    @Test func overwriteTrimsAndSplitsUnderlyingClips() {
        var f = Fixture()
        f.add("A", track: f.v1, start: 0, duration: 100)
        f.add("B", track: f.v1, start: 30, duration: 20)
        #expect(f.layout(f.v1) == ["A@0+30", "B@30+20", "A@50+50"])
        // The right half of a split shows the source that was under it.
        let right = f.sequence.videoTracks[0].clips[2]
        #expect(right.sourceStart.frameIndex(at: .fps30) == 150)
    }

    @Test func insertRipplesSyncLockedTracksAndSplitsSpanningClips() {
        var f = Fixture()
        f.addLinked("A", start: 0, duration: 60)
        f.add("Music", track: f.a2, start: 0, duration: 200)
        let clip = Clip(mediaID: f.mediaID, name: "B", start: 30, duration: 10, sourceStart: .zero)
        f.sequence.insert([TrackPlacement(trackID: f.v1, clip: clip)], at: 30)
        #expect(f.layout(f.v1) == ["A@0+30", "B@30+10", "A@40+30"])
        // A1 isn't a target but is sync-locked: split and shifted, leaving a gap.
        #expect(f.layout(f.a1) == ["A@0+30", "A@40+30"])
        #expect(f.layout(f.a2) == ["Music@0+30", "Music@40+170"])
    }

    @Test func insertLeavesUnsyncedAndLockedTracksAlone() {
        var f = Fixture()
        f.addLinked("A", start: 0, duration: 60)
        f.add("Music", track: f.a2, start: 0, duration: 200)
        f.sequence.audioTracks[1].isSyncLocked = false
        f.sequence.audioTracks[0].isLocked = true
        let clip = Clip(mediaID: f.mediaID, name: "B", start: 30, duration: 10, sourceStart: .zero)
        f.sequence.insert([TrackPlacement(trackID: f.v1, clip: clip)], at: 30)
        #expect(f.layout(f.a1) == ["A@0+60"])
        #expect(f.layout(f.a2) == ["Music@0+200"])
    }

    @Test func splitLinkedClipsStayLinkedPairwise() throws {
        var f = Fixture()
        f.addLinked("A", start: 0, duration: 60)
        f.sequence.razor(at: 20, trackIDs: [f.v1, f.a1])
        let video = f.sequence.videoTracks[0].clips
        let audio = f.sequence.audioTracks[0].clips
        #expect(video.count == 2 && audio.count == 2)
        #expect(video[0].linkID == audio[0].linkID)
        #expect(video[1].linkID == audio[1].linkID)
        #expect(video[0].linkID != video[1].linkID)
        let expanded = f.sequence.expandingLinks([video[1].id])
        #expect(expanded == [video[1].id, audio[1].id])
    }

    @Test func makeClipsFromSourceRange() throws {
        let f = Fixture()
        let info = MediaInfo(container: .quickTime, duration: RationalTime(value: 10, timescale: 1),
                             video: VideoStreamInfo(codec: .hevc, width: 3840, height: 2160, frameRate: .fps30,
                                                    nominalFPS: 30, bitDepth: 10, color: .rec2100HLG),
                             audio: [AudioStreamInfo(codec: .aac, sampleRate: 48_000, channelCount: 2)])
        let item = MediaItem(name: "Clip", filePath: "/c.mov", info: info)
        let range = TimeRange(start: RationalTime(value: 1, timescale: 1), duration: RationalTime(value: 2, timescale: 1))
        let placements = f.sequence.makeClips(for: item, sourceRange: range, at: 90,
                                              videoTrackID: f.v1, audioTrackID: f.a1)
        #expect(placements.count == 2)
        #expect(placements.allSatisfy { $0.clip.duration == 60 && $0.clip.start == 90 })
        #expect(placements[0].clip.linkID != nil && placements[0].clip.linkID == placements[1].clip.linkID)
        let videoOnly = f.sequence.makeClips(for: item, sourceRange: range, at: 0, videoTrackID: f.v1, audioTrackID: nil)
        #expect(videoOnly.count == 1 && videoOnly[0].clip.linkID == nil)
    }
}

@Suite("Timeline: removing")
struct TimelineRemovalTests {
    @Test func liftLeavesGap() {
        var f = Fixture()
        f.add("A", track: f.v1, start: 0, duration: 100)
        f.sequence.lift(FrameRange(start: 20, end: 40), trackIDs: [f.v1])
        #expect(f.layout(f.v1) == ["A@0+20", "A@40+60"])
    }

    @Test func extractClosesGapOnSyncLockedTracks() {
        var f = Fixture()
        f.addLinked("A", start: 0, duration: 100)
        f.sequence.extract(FrameRange(start: 20, end: 40), trackIDs: [f.v1])
        #expect(f.layout(f.v1) == ["A@0+20", "A@20+60"])
        #expect(f.layout(f.a1) == ["A@0+20", "A@20+60"])
        #expect(f.sequence.durationFrames == 80)
    }

    @Test func rippleDeleteClosesEachGap() {
        var f = Fixture()
        let a = f.add("A", track: f.v1, start: 0, duration: 10)
        f.add("B", track: f.v1, start: 10, duration: 10)
        let c = f.add("C", track: f.v1, start: 20, duration: 10)
        f.add("D", track: f.v1, start: 30, duration: 10)
        f.sequence.delete([a, c], ripple: true)
        #expect(f.layout(f.v1) == ["B@0+10", "D@10+10"])
    }

    @Test func deleteWithoutRippleLeavesGaps() {
        var f = Fixture()
        let a = f.add("A", track: f.v1, start: 0, duration: 10)
        f.add("B", track: f.v1, start: 10, duration: 10)
        f.sequence.delete([a], ripple: false)
        #expect(f.layout(f.v1) == ["B@10+10"])
    }

    @Test func lockedTracksAreUntouched() {
        var f = Fixture()
        let a = f.add("A", track: f.v1, start: 0, duration: 10)
        f.sequence.videoTracks[0].isLocked = true
        f.sequence.delete([a], ripple: true)
        f.sequence.razor(at: 5, trackIDs: [f.v1])
        #expect(f.layout(f.v1) == ["A@0+10"])
    }
}

@Suite("Timeline: move")
struct TimelineMoveTests {
    @Test func moveOverwritesDestinationAndKeepsLinks() {
        var f = Fixture()
        let (video, audio) = f.addLinked("A", start: 0, duration: 20)
        f.add("B", track: f.v1, start: 50, duration: 40)
        f.sequence.move([video, audio], by: 60)
        #expect(f.layout(f.v1) == ["B@50+10", "A@60+20", "B@80+10"])
        #expect(f.layout(f.a1) == ["A@60+20"])
    }

    @Test func moveAcrossTracksAndClampsAtZero() {
        var f = Fixture()
        let a = f.add("A", track: f.v1, start: 10, duration: 20)
        f.sequence.move([a], by: -50, trackOffset: 1)
        #expect(f.layout(f.v1).isEmpty)
        #expect(f.layout(f.v2) == ["A@0+20"])
        f.sequence.move([a], by: 0, trackOffset: 10)
        #expect(f.layout(f.sequence.videoTracks[2].id) == ["A@0+20"])
    }
}

@Suite("Timeline: trims")
struct TimelineTrimTests {
    @Test func trimEndStopsAtNextClipAndMediaEnd() {
        var f = Fixture()
        let a = f.add("A", track: f.v1, start: 0, duration: 20)
        f.add("B", track: f.v1, start: 30, duration: 10)
        #expect(f.sequence.trim(a, edge: .end, by: 50, media: f.media) == 10)
        #expect(f.layout(f.v1) == ["A@0+30", "B@30+10"])
        // Source frame 100 onward leaves 2900 frames; the clip can't exceed them.
        let solo = f.add("S", track: f.v2, start: 0, duration: 10)
        #expect(f.sequence.trim(solo, edge: .end, by: 5000, media: f.media) == 2890)
    }

    @Test func trimStartMovesSourceAndStopsAtMediaHead() {
        var f = Fixture()
        let a = f.add("A", track: f.v1, start: 200, duration: 20, source: 30)
        #expect(f.sequence.trim(a, edge: .start, by: 5, media: f.media) == 5)
        #expect(f.layout(f.v1) == ["A@205+15"])
        #expect(f.sourceFrame(a) == 35)
        #expect(f.sequence.trim(a, edge: .start, by: -100, media: f.media) == -35)
        #expect(f.sourceFrame(a) == 0)
        #expect(f.layout(f.v1) == ["A@170+50"])
    }

    @Test func trimKeepsAtLeastOneFrame() {
        var f = Fixture()
        let a = f.add("A", track: f.v1, start: 0, duration: 20)
        #expect(f.sequence.trim(a, edge: .end, by: -50, media: f.media) == -19)
        #expect(f.layout(f.v1) == ["A@0+1"])
    }

    @Test func trimMovesLinkedPartner() {
        var f = Fixture()
        let (video, _) = f.addLinked("A", start: 0, duration: 20)
        f.sequence.trim(video, edge: .end, by: -5, media: f.media)
        #expect(f.layout(f.a1) == ["A@0+15"])
    }

    @Test func rippleTrimEndShiftsFollowingClips() {
        var f = Fixture()
        let (video, _) = f.addLinked("A", start: 0, duration: 20)
        f.add("B", track: f.v1, start: 20, duration: 10)
        f.add("M", track: f.a2, start: 0, duration: 100)
        #expect(f.sequence.rippleTrim(video, edge: .end, by: -5, media: f.media) == -5)
        #expect(f.layout(f.v1) == ["A@0+15", "B@15+10"])
        #expect(f.layout(f.a1) == ["A@0+15"])
        #expect(f.layout(f.a2) == ["M@0+15", "M@15+80"])
        #expect(f.sequence.rippleTrim(video, edge: .end, by: 10, media: f.media) == 10)
        #expect(f.layout(f.v1) == ["A@0+25", "B@25+10"])
    }

    @Test func rippleTrimStartKeepsPositionAndShiftsRest() {
        var f = Fixture()
        let a = f.add("A", track: f.v1, start: 10, duration: 20, source: 50)
        f.add("B", track: f.v1, start: 30, duration: 10)
        #expect(f.sequence.rippleTrim(a, edge: .start, by: 5, media: f.media) == 5)
        #expect(f.layout(f.v1) == ["A@10+15", "B@25+10"])
        #expect(f.sourceFrame(a) == 55)
        #expect(f.sequence.rippleTrim(a, edge: .start, by: -8, media: f.media) == -8)
        #expect(f.layout(f.v1) == ["A@10+23", "B@33+10"])
        #expect(f.sourceFrame(a) == 47)
    }

    @Test func rollMovesTheCut() {
        var f = Fixture()
        let a = f.add("A", track: f.v1, start: 0, duration: 20)
        let b = f.add("B", track: f.v1, start: 20, duration: 20, source: 10)
        #expect(f.sequence.roll(clipID: a, edge: .end, by: 5, media: f.media) == 5)
        #expect(f.layout(f.v1) == ["A@0+25", "B@25+15"])
        #expect(f.sourceFrame(b) == 15)
        // B's head can't go before source frame 0.
        #expect(f.sequence.roll(clipID: b, edge: .start, by: -100, media: f.media) == -15)
        #expect(f.layout(f.v1) == ["A@0+10", "B@10+30"])
    }

    @Test func slipKeepsPositionWithinMedia() {
        var f = Fixture()
        let a = f.add("A", track: f.v1, start: 0, duration: 100, source: 10)
        #expect(f.sequence.slip(a, by: -50, media: f.media) == -10)
        #expect(f.sourceFrame(a) == 0)
        #expect(f.sequence.slip(a, by: 5000, media: f.media) == 2900)
        #expect(f.layout(f.v1) == ["A@0+100"])
    }

    @Test func slideTrimsAdjacentNeighbours() {
        var f = Fixture()
        f.add("A", track: f.v1, start: 0, duration: 20)
        let b = f.add("B", track: f.v1, start: 20, duration: 10)
        let c = f.add("C", track: f.v1, start: 30, duration: 20, source: 100)
        #expect(f.sequence.slide(b, by: 5, media: f.media) == 5)
        #expect(f.layout(f.v1) == ["A@0+25", "B@25+10", "C@35+15"])
        #expect(f.sourceFrame(c) == 105)
        // C must keep at least one frame.
        #expect(f.sequence.slide(b, by: 100, media: f.media) == 14)
        #expect(f.layout(f.v1) == ["A@0+39", "B@39+10", "C@49+1"])
    }

    @Test func slideIntoGap() {
        var f = Fixture()
        let a = f.add("A", track: f.v1, start: 10, duration: 10)
        #expect(f.sequence.slide(a, by: -30, media: f.media) == -10)
        #expect(f.layout(f.v1) == ["A@0+10"])
    }
}

@Suite("Timeline: navigation and snapping")
struct TimelineNavigationTests {
    @Test func editPoints() {
        var f = Fixture()
        f.add("A", track: f.v1, start: 10, duration: 20)
        f.add("B", track: f.a2, start: 25, duration: 10)
        #expect(f.sequence.editPoints == [0, 10, 25, 30, 35])
        #expect(f.sequence.nextEditPoint(after: 10) == 25)
        #expect(f.sequence.previousEditPoint(before: 10) == 0)
        #expect(f.sequence.nextEditPoint(after: 35) == nil)
    }

    @Test func snapperPicksNearestEdge() {
        var f = Fixture()
        let a = f.add("A", track: f.v1, start: 0, duration: 20)
        f.add("B", track: f.v1, start: 50, duration: 10)
        let snapper = Snapper(sequence: f.sequence, excluding: [a], playhead: 100, threshold: 3)
        #expect(snapper.snap(48) == 50)
        #expect(snapper.snap(45) == nil)
        // Dragging A (0...20) by 28: its end lands at 48 and snaps to 50.
        let result = snapper.snapDelta(28, edges: [0, 20])
        #expect(result.delta == 30 && result.point == 50)
        #expect(snapper.snapDelta(98, edges: [0, 20]).delta == 100)
    }

    @Test func sequenceMarksRange() {
        #expect(SequenceMarks(inFrame: 10, outFrame: 19).range == FrameRange(start: 10, end: 20))
        #expect(SequenceMarks(inFrame: 10).range == nil)
        #expect(SequenceMarks(inFrame: 10, outFrame: 5).range == nil)
    }

    @Test func settingsFromClip() {
        let info = MediaInfo(container: .quickTime, duration: .zero,
                             video: VideoStreamInfo(codec: .hevc, width: 3840, height: 2160, frameRate: .fps59_94,
                                                    nominalFPS: 59.94, bitDepth: 10, color: .rec2100HLG),
                             audio: [])
        let settings = SequenceSettings.matching(info)
        #expect(settings.width == 3840 && settings.frameRate == .fps59_94 && settings.colorSpace == .rec2100HLG)
    }
}

@Suite("Timeline: tracks and properties")
struct TimelineTrackTests {
    @Test func addAndRemoveTracks() {
        var f = Fixture()
        f.sequence.addTrack(.video)
        #expect(f.sequence.videoTracks.count == 4)
        f.add("A", track: f.v1, start: 0, duration: 10)
        f.sequence.removeTrack(f.v1)
        #expect(f.sequence.videoTracks.count == 4, "tracks with clips aren't removed")
        f.sequence.removeTrack(f.v2)
        #expect(f.sequence.videoTracks.count == 3)
    }

    @Test func targetingIsExclusivePerKind() {
        var f = Fixture()
        #expect(f.sequence.targetedVideoTrackID == f.v1)
        f.sequence.setTrackFlags(f.v2) { $0.isTargeted = true }
        #expect(f.sequence.targetedVideoTrackID == f.v2)
        #expect(f.sequence.videoTracks[0].isTargeted == false)
        #expect(f.sequence.targetedAudioTrackID == f.a1)
    }

    @Test func clipPropertiesDontMoveClips() {
        var f = Fixture()
        let a = f.add("A", track: f.v1, start: 5, duration: 10)
        f.sequence.updateClipProperties([a]) { clip in
            clip.opacity = 0.5
            clip.start = 999
        }
        #expect(f.sequence.clip(a)?.opacity == 0.5)
        #expect(f.layout(f.v1) == ["A@5+10"])
    }

    @Test func linkAndUnlink() {
        var f = Fixture()
        let (video, audio) = f.addLinked("A", start: 0, duration: 10)
        f.sequence.setLinked([video, audio], false)
        #expect(f.sequence.expandingLinks([video]) == [video])
        f.sequence.setLinked([video, audio], true)
        #expect(f.sequence.expandingLinks([video]) == [video, audio])
    }
}

@Suite("Project: sequences")
struct ProjectSequenceTests {
    @Test func removingMediaRemovesItsClips() {
        var project = Project()
        let item = project.addMedia([makeItem("A")])[0]
        let sequence = project.addSequence(settings: .uhd4K2997)
        project.updateSequence(sequence.id) { seq in
            let clip = Clip(mediaID: item.id, name: "A", start: 0, duration: 10, sourceStart: .zero)
            seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: clip)])
        }
        #expect(project.clipCount(usingMedia: item.id) == 1)
        project.removeMedia([item.id])
        #expect(project.sequence(sequence.id)?.videoTracks[0].clips.isEmpty == true)
    }

    @Test func sequenceNamesAreUniqueAndRoundTrip() throws {
        var project = Project()
        #expect(project.addSequence(settings: .uhd4K2997).name == "Sequence")
        #expect(project.addSequence(settings: .uhd4K2997).name == "Sequence 2")
        let decoded = try ProjectFileCoder.decode(try ProjectFileCoder.encode(project))
        #expect(decoded == project)
    }

    @Test func version1FilesStillLoad() throws {
        let project = try ProjectFileCoder.decode(Data(#"{"schemaVersion": 1, "bins": [], "media": []}"#.utf8))
        #expect(project.sequences.isEmpty)
        #expect(project.schemaVersion == Project.currentSchemaVersion)
    }
}
