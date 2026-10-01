import Foundation
import Testing
@testable import SWCore

@Suite("Markers")
struct MarkerTests {
    private func sequence() -> EditSequence {
        EditSequence(name: "S", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30, colorSpace: .rec709))
    }

    @Test func addSortNavigateAndEdit() throws {
        var seq = sequence()
        let late = seq.addMarker(at: 300, name: "Late")
        let early = seq.addMarker(at: 30, name: "Early", color: .red)
        #expect(seq.markers.map(\.id) == [early, late], "kept in frame order")
        #expect(seq.nextMarker(after: 30)?.id == late)
        #expect(seq.previousMarker(before: 300)?.id == early)
        #expect(seq.nextMarker(after: 300) == nil)

        seq.updateMarker(early) { $0.frame = 600; $0.duration = 60; $0.comment = "Notes" }
        #expect(seq.markers.map(\.id) == [late, early], "re-sorted after moving")
        #expect(seq.markers(at: 630).map(\.id) == [early], "a range marker covers its frames")
        #expect(seq.markers(at: 300).map(\.id) == [late], "a point marker only its frame")
        seq.updateMarker(late) { $0.frame = -5 }
        #expect(seq.marker(late)?.frame == 0, "not before the start")
        seq.deleteMarkers([late])
        #expect(seq.markers.count == 1)
    }

    @Test func markersSurviveSavingAndOldProjectsLoad() throws {
        var project = Project()
        var seq = sequence()
        seq.addMarker(at: 15, name: "Hello")
        project.sequences = [seq]
        let item = project.addMedia([makeItem("A")])[0]
        project.updateSourceMarkers(of: item.id) {
            $0 = [SourceMarker(time: RationalTime(value: 2, timescale: 1)), SourceMarker(time: .zero, name: "Start")]
        }
        #expect(project.media[0].markers.first?.name == "Start", "sorted by time")
        let decoded = try ProjectFileCoder.decode(try ProjectFileCoder.encode(project))
        #expect(decoded == project)

        var bare = Project()
        bare.addMedia([makeItem("B")])
        bare.sequences = [sequence()]
        var json = try #require(String(bytes: try ProjectFileCoder.encode(bare), encoding: .utf8))
        json = json.replacingOccurrences(of: "\"markers\" : [\n\n      ],", with: "")
            .replacingOccurrences(of: "\"markers\" : [],", with: "")
        #expect(!json.contains("\"markers\""))
        let old = try ProjectFileCoder.decode(Data(json.utf8))
        #expect(old.sequences[0].markers.isEmpty && old.media[0].markers.isEmpty)
    }

    @Test func sourceMarkersLandOnClipsAtTheirSpeed() {
        var clip = Clip(mediaID: UUID(), name: "c", start: 100, duration: 60, sourceStart: RationalTime(value: 1, timescale: 1))
        let markers = [SourceMarker(time: RationalTime(value: 2, timescale: 1)), SourceMarker(time: .zero),
                       SourceMarker(time: RationalTime(value: 10, timescale: 1))]
        #expect(clip.sourceMarkers(markers, rate: .fps30).map(\.frame) == [130], "1 s in; the others are outside the clip")
        clip.speed = AnimatableProperty([200])
        #expect(clip.sourceMarkers(markers, rate: .fps30).map(\.frame) == [115], "half as far at 200%")
    }

    @Test func youTubeChapters() {
        let rate = FrameRate.fps30
        let markers = [Marker(frame: 45, name: "Intro"), Marker(frame: 30 * 60, name: "Setup"),
                       Marker(frame: 30 * 65, name: "Too close"), Marker(frame: 30 * 600, name: "Results")]
        let chapters = Chapters.chapters(from: markers, rate: rate)
        #expect(chapters.map(\.title) == ["Intro", "Setup", "Results"])
        #expect(chapters.first?.seconds == 0, "the first chapter starts at 0:00")
        #expect(Chapters.youTubeText(chapters) == "0:00 Intro\n1:00 Setup\n10:00 Results\n")
        #expect(Chapters.youTubeWarning(for: chapters) == nil)
        #expect(Chapters.youTubeWarning(for: Array(chapters.prefix(2))) != nil)

        // Flagged chapter markers win over the rest, and long videos get hours.
        var flagged = markers
        flagged[3].isChapter = true
        flagged.append(Marker(frame: 30 * 3700, name: "Bonus", isChapter: true))
        let only = Chapters.chapters(from: flagged, rate: rate)
        #expect(Chapters.youTubeText(only) == "0:00:00 Results\n1:01:40 Bonus\n")

        // An exported range counts from its start.
        let ranged = Chapters.chapters(from: markers, rate: rate, range: FrameRange(start: 30 * 60, end: 30 * 700))
        #expect(ranged.map(\.title) == ["Setup", "Results"] && ranged[1].seconds == 540)
    }

    @Test func csvEscapes() {
        let markers = [Marker(frame: 30, duration: 15, name: "Say \"hi\", then go", comment: "two\nlines", color: .red,
                              isChapter: true)]
        let csv = Chapters.csv(markers, rate: .fps30)
        #expect(csv == "Name,In,Out,Duration,Comment,Color,Chapter\n"
                + "\"Say \"\"hi\"\", then go\",00:00:01:00,00:00:01:15,00:00:00:15,\"two\nlines\",red,yes\n")
    }
}
