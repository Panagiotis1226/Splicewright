import Foundation
import Testing
@testable import SWCore

@Suite("Clip groups")
struct ClipGroupTests {
    private struct Fixture {
        var sequence: EditSequence
        let title: UUID
        let video: UUID
        let audio: UUID
    }

    /// A title on V2, and a video clip with linked audio on V1/A1.
    private func fixture() -> Fixture {
        var seq = EditSequence(name: "G", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                                    colorSpace: .rec709))
        seq.addTrack(.video)
        let link = UUID()
        let video = Clip(mediaID: UUID(), name: "v", start: 0, duration: 100, sourceStart: .zero, linkID: link)
        var audio = video
        audio.id = UUID()
        let title = Clip(mediaID: UUID(), name: "t", start: 20, duration: 40, sourceStart: .zero)
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: video),
                       TrackPlacement(trackID: seq.audioTracks[0].id, clip: audio),
                       TrackPlacement(trackID: seq.videoTracks[1].id, clip: title)])
        return Fixture(sequence: seq, title: title.id, video: video.id, audio: audio.id)
    }

    @Test func groupedClipsSelectTogetherAndUngroup() {
        let made = fixture()
        var seq = made.sequence
        let (title, video, audio) = (made.title, made.video, made.audio)
        #expect(seq.expandingGroups([title]) == [title])
        let grouped = seq.setGrouped([title, video], true)
        #expect(grouped)
        #expect(seq.expandingGroups([title]) == [title, video, audio], "the group, and the video's linked audio")
        #expect(seq.expandingGroups([audio]) == [title, video, audio])
        let single = seq.setGrouped([title], true)
        #expect(!single, "a group needs two clips")
        let ungrouped = seq.setGrouped([audio], false)
        #expect(ungrouped, "ungrouping from any member")
        #expect(seq.expandingGroups([title]) == [title])
        let again = seq.setGrouped([title], false)
        #expect(!again, "nothing left to ungroup")
    }

    @Test func groupsSurviveSavingSplittingAndPasteMakesNewOnes() throws {
        let made = fixture()
        var seq = made.sequence
        let (title, video) = (made.title, made.video)
        seq.setGrouped([title, video], true)
        let decoded = try JSONDecoder().decode(EditSequence.self, from: JSONEncoder().encode(seq))
        #expect(decoded.clip(title)?.groupID != nil && decoded.clip(title)?.groupID == decoded.clip(video)?.groupID)
        // Both halves of a split clip stay in the group.
        seq.razor(at: 50, trackIDs: [seq.videoTracks[0].id])
        #expect(seq.expandingGroups([title]).count == 4)
        // Pasted copies form a group of their own.
        let copied = try #require(seq.copyClips([title, video], project: Project()))
        let pasted = seq.paste(copied, at: 200)
        let original = seq.clip(title)?.groupID
        let pastedGroups = Set(pasted.compactMap { seq.clip($0)?.groupID })
        #expect(pastedGroups.count == 1 && pastedGroups.first != original)
    }
}
