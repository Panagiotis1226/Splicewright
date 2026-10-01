import Foundation
import Testing
@testable import SWCore

/// Two 60-frame clips, A then B, meeting at frame 60 on V1, plus a linked copy on A1.
private struct CutFixture {
    var sequence = EditSequence(name: "T", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                                      colorSpace: .rec709))
    let mediaID = UUID()
    var media: MediaDurations { [mediaID: RationalTime(value: 100, timescale: 1)] }
    var a = UUID()
    var b = UUID()

    var v1: UUID { sequence.videoTracks[0].id }
    var a1: UUID { sequence.audioTracks[0].id }

    init() {
        let clipA = Clip(mediaID: mediaID, name: "A", start: 0, duration: 60,
                         sourceStart: RationalTime(frames: 100, rate: .fps30))
        let clipB = Clip(mediaID: mediaID, name: "B", start: 60, duration: 60,
                         sourceStart: RationalTime(frames: 500, rate: .fps30))
        a = clipA.id
        b = clipB.id
        sequence.overwrite([TrackPlacement(trackID: v1, clip: clipA), TrackPlacement(trackID: v1, clip: clipB)])
    }

    var resolved: [ResolvedTransition] { sequence.track(v1)?.resolvedTransitions ?? [] }
}

@Suite("Transitions")
struct TransitionTests {
    @Test func dissolveCentersOnTheCut() throws {
        var f = CutFixture()
        let added = f.sequence.addTransition(.crossDissolve, trackID: f.v1, at: 60)
        let id = try #require(added)
        let resolved = try #require(f.resolved.first)
        #expect(resolved.id == id)
        #expect(resolved.range == FrameRange(start: 45, end: 75))
        #expect(resolved.left?.id == f.a && resolved.right?.id == f.b)
    }

    @Test func alignment() throws {
        var f = CutFixture()
        f.sequence.addTransition(.dipToBlack, trackID: f.v1, at: 60, duration: 20, alignment: .startAtCut)
        #expect(f.resolved.first?.range == FrameRange(start: 60, end: 80))
        let id = try #require(f.resolved.first?.id)
        f.sequence.updateTransition(id) { $0.alignment = .endAtCut }
        #expect(f.resolved.first?.range == FrameRange(start: 40, end: 60))
    }

    @Test func fadesAtFreeEdges() {
        var f = CutFixture()
        f.sequence.addTransition(.crossDissolve, trackID: f.v1, at: 0, duration: 10)
        f.sequence.addTransition(.crossDissolve, trackID: f.v1, at: 120, duration: 10)
        #expect(f.resolved.map(\.range) == [FrameRange(start: 0, end: 10), FrameRange(start: 110, end: 120)])
        #expect(f.resolved[0].left == nil && f.resolved[1].right == nil)
    }

    @Test func clampedToTheClips() {
        var f = CutFixture()
        f.sequence.addTransition(.crossDissolve, trackID: f.v1, at: 60, duration: 600)
        #expect(f.resolved.first?.range == FrameRange(start: 0, end: 120))
    }

    @Test func noTransitionAwayFromAnEdgeOrOnTheWrongKindOfTrack() {
        var f = CutFixture()
        let midClip = f.sequence.addTransition(.crossDissolve, trackID: f.v1, at: 30)
        let audioOnVideo = f.sequence.addTransition(.constantPower, trackID: f.v1, at: 60)
        #expect(midClip == nil && audioOnVideo == nil)
    }

    @Test func replacingAtTheSameCut() {
        var f = CutFixture()
        f.sequence.addTransition(.crossDissolve, trackID: f.v1, at: 60)
        f.sequence.addTransition(.wipeRight, trackID: f.v1, at: 60)
        #expect(f.resolved.map(\.kind) == [.wipeRight])
    }

    @Test func followsTrimsRollsAndMoves() throws {
        var f = CutFixture()
        f.sequence.addTransition(.crossDissolve, trackID: f.v1, at: 60, duration: 10)
        f.sequence.roll(clipID: f.a, edge: .end, by: 5, media: f.media)
        #expect(f.resolved.first?.cut == 65)
        f.sequence.slip(f.a, by: 3, media: f.media)
        #expect(f.resolved.count == 1)
        f.sequence.move([f.a, f.b], by: 30)
        #expect(f.resolved.first?.cut == 95)
        // Moving one clip away breaks the cut.
        f.sequence.move([f.b], by: 30)
        #expect(f.resolved.isEmpty)
        f.sequence.pruneTransitions()
        #expect(f.sequence.track(f.v1)?.transitions.isEmpty == true)
    }

    @Test func rippleDeleteAndRazor() throws {
        var f = CutFixture()
        f.sequence.addTransition(.crossDissolve, trackID: f.v1, at: 120, duration: 10)  // fade out at B's end
        f.sequence.razor(at: 90, trackIDs: [f.v1])
        // The fade moved to B's right half.
        let fade = try #require(f.resolved.first)
        #expect(fade.cut == 120 && fade.left?.id != f.b)
        f.sequence.delete([f.a], ripple: true)
        #expect(f.resolved.first?.cut == 60)
    }

    @Test func deletingAClipDropsItsTransition() {
        var f = CutFixture()
        f.sequence.addTransition(.crossDissolve, trackID: f.v1, at: 60)
        f.sequence.delete([f.b], ripple: false)
        #expect(f.resolved.isEmpty)
    }

    @Test func shortClipBetweenTwoTransitions() {
        var f = CutFixture()
        // B becomes 20 frames long (60...80) with C after it.
        f.sequence.trim(f.b, edge: .end, by: -40, media: f.media)
        f.sequence.overwrite([TrackPlacement(trackID: f.v1, clip: Clip(
            mediaID: f.mediaID, name: "C", start: 80, duration: 60, sourceStart: .zero))])
        // Two 30-frame dissolves can't both take 15 frames of B.
        f.sequence.addTransition(.crossDissolve, trackID: f.v1, at: 60, duration: 30)
        f.sequence.addTransition(.crossDissolve, trackID: f.v1, at: 80, duration: 30)
        let ranges = f.resolved.map(\.range)
        #expect(ranges.count == 2)
        #expect(ranges[0].end <= ranges[1].start)
    }

    @Test func renderPlanMixesTwoLayersInsideATransition() throws {
        var f = CutFixture()
        f.sequence.addTransition(.crossDissolve, trackID: f.v1, at: 60, duration: 30)
        let segments = RenderPlan.videoSegments(for: f.sequence)
        // The cut itself still splits the transition; both halves mix the same two clips.
        #expect(segments.map(\.range) == [FrameRange(start: 0, end: 45), FrameRange(start: 45, end: 60),
                                          FrameRange(start: 60, end: 75), FrameRange(start: 75, end: 120)])
        for mixed in [segments[1].layers, segments[2].layers] {
            #expect(mixed.map(\.clipID) == [f.a, f.b])
            #expect(mixed.map { $0.transition?.role } == [.outgoing, .incoming])
            #expect(mixed.first?.transition?.range == FrameRange(start: 45, end: 75))
        }
        #expect(segments[0].layers.first?.transition == nil)
    }

    @Test func audioFades() {
        var f = CutFixture()
        let clipA = Clip(mediaID: f.mediaID, name: "A", start: 0, duration: 60, sourceStart: .zero)
        let clipB = Clip(mediaID: f.mediaID, name: "B", start: 60, duration: 60, sourceStart: .zero)
        f.sequence.overwrite([TrackPlacement(trackID: f.a1, clip: clipA), TrackPlacement(trackID: f.a1, clip: clipB)])
        f.sequence.addTransition(.constantPower, trackID: f.a1, at: 60, duration: 30)
        let fades = RenderPlan.audioFades(for: f.sequence.audioTracks[0])
        let out = fades[clipA.id]!
        let into = fades[clipB.id]!
        #expect(out.gain(at: 40) == 1)
        #expect(abs(out.gain(at: 60) - sin(.pi / 4)) < 1e-9)
        #expect(abs(into.gain(at: 60) - sin(.pi / 4)) < 1e-9)
        #expect(out.gain(at: 75) == 0 && into.gain(at: 75) == 1)
    }

    @Test func applyNearPlayhead() {
        var f = CutFixture()
        let added = f.sequence.applyTransition(.crossDissolve, near: 63, trackIDs: [f.v1], tolerance: 10)
        #expect(added.count == 1)
        #expect(f.resolved.first?.cut == 60)
        let far = f.sequence.applyTransition(.crossDissolve, near: 30, trackIDs: [f.v1], tolerance: 10)
        #expect(far.isEmpty)
    }

    @Test func schema2TracksLoadWithoutTransitions() throws {
        var f = CutFixture()
        f.sequence.addTransition(.crossDissolve, trackID: f.v1, at: 60)
        var project = Project()
        project.sequences = [f.sequence]
        var json = String(bytes: try ProjectFileCoder.encode(project), encoding: .utf8) ?? ""
        let decoded = try ProjectFileCoder.decode(Data(json.utf8))
        #expect(decoded.sequences[0].videoTracks[0].transitions.count == 1)
        // Strip every "transitions" key, as a schema 2 file would have none.
        json = json.replacingOccurrences(of: #""transitions" : \[[^\]]*\],?"#, with: "", options: .regularExpression)
        json = json.replacingOccurrences(of: #""schemaVersion" : 3"#, with: #""schemaVersion" : 2"#)
        let old = try ProjectFileCoder.decode(Data(json.utf8))
        #expect(old.sequences[0].videoTracks[0].transitions.isEmpty)
    }
}

@Suite("Titles")
struct TitleTests {
    private func sequence() -> EditSequence {
        EditSequence(name: "T", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                           colorSpace: .rec709))
    }

    @Test func addTitleGoesAboveV1() throws {
        var seq = sequence()
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: Clip(
            mediaID: UUID(), name: "A", start: 0, duration: 300, sourceStart: .zero))])
        let added = seq.addTitle(TitleSpec(text: "Hello\nWorld"), at: 30)
        let id = try #require(added)
        let clip = try #require(seq.videoTracks[1].clips.first)
        #expect(clip.id == id && clip.isTitle && clip.mediaID == Clip.generatedMediaID)
        #expect(clip.name == "Hello" && clip.range == FrameRange(start: 30, end: 180))
        // V2 is now busy there, so the next title goes on V3, then a new V4.
        seq.addTitle(at: 60)
        #expect(seq.videoTracks[2].clips.count == 1)
        seq.addTitle(at: 60)
        #expect(seq.videoTracks.count == 4 && seq.videoTracks[3].clips.count == 1)
    }

    @Test func updateTitleClampsAndRenames() throws {
        var seq = sequence()
        let added = seq.addTitle(at: 0)
        let id = try #require(added)
        seq.updateTitle(id) { spec in
            spec.text = "Credits"
            spec.size = 5
            spec.positionX = -1
        }
        let title = try #require(seq.clip(id)?.title)
        #expect(title.size == TitleSpec.sizeRange.upperBound && title.positionX == 0)
        #expect(seq.clip(id)?.name == "Credits")
    }

    @Test func titlesRenderWithoutMediaAndTakeTransitions() throws {
        var seq = sequence()
        let added = seq.addTitle(at: 0, duration: 60, trackID: seq.videoTracks[0].id)
        let id = try #require(added)
        seq.addTransition(.crossDissolve, trackID: seq.videoTracks[0].id, at: 0, duration: 15)
        let segments = RenderPlan.videoSegments(for: seq, isAvailable: { _ in false })
        #expect(segments.first?.layers.first?.clipID == id)
        #expect(segments.first?.layers.first?.title?.text == "Title")
        #expect(segments.first?.layers.first?.transition?.role == .incoming)
        // Titles have no media, so trims aren't bounded by it.
        let trimmed = seq.trim(id, edge: .end, by: 600, media: [:])
        #expect(trimmed == 600)
    }

    @Test func titleSpecRoundTrips() throws {
        var spec = TitleSpec(text: "Ünïcode ✓", stroke: TitleStroke(), background: .black)
        spec.alignment = .left
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(TitleSpec.self, from: data) == spec)
    }
}
