import Foundation
import Testing
@testable import SWCore

func makeItem(_ name: String, path: String? = nil, seconds: Int64 = 10, rate: FrameRate = .fps30,
              binID: UUID? = nil) -> MediaItem {
    let video = VideoStreamInfo(codec: .hevc, width: 3840, height: 2160, frameRate: rate,
                                nominalFPS: rate.framesPerSecond, bitDepth: 10, color: .rec2100HLG)
    let info = MediaInfo(container: .quickTime, duration: RationalTime(value: seconds, timescale: 1),
                         video: video, audio: [AudioStreamInfo(codec: .aac, sampleRate: 48_000, channelCount: 2)])
    return MediaItem(name: name, filePath: path ?? "/media/\(name).mov", info: info, binID: binID)
}

@Suite("Project")
struct ProjectTests {
    @Test func addMediaSkipsDuplicatePaths() {
        var project = Project()
        let first = project.addMedia([makeItem("A"), makeItem("B")])
        #expect(first.count == 2)
        let second = project.addMedia([makeItem("A again", path: "/media/A.mov"), makeItem("C")])
        #expect(second.map(\.name) == ["C"])
        #expect(project.media.count == 3)
    }

    @Test func addMediaDropsUnknownBin() {
        var project = Project()
        let added = project.addMedia([makeItem("A", binID: UUID())])
        #expect(added.first?.binID == nil)
    }

    @Test func binNamesAreUnique() {
        var project = Project()
        #expect(project.addBin().name == "Bin")
        #expect(project.addBin().name == "Bin 2")
        #expect(project.addBin(named: "  ").name == "Bin 3")
        #expect(project.addBin(named: "Footage").name == "Footage")
    }

    @Test func deletingBinMovesMediaToRoot() {
        var project = Project()
        let bin = project.addBin(named: "Footage")
        project.addMedia([makeItem("A", binID: bin.id), makeItem("B")])
        #expect(project.items(inBin: bin.id).count == 1)
        project.deleteBin(bin.id)
        #expect(project.bins.isEmpty)
        #expect(project.items(inBin: nil).count == 2)
    }

    @Test func moveAndRemoveMedia() {
        var project = Project()
        let bin = project.addBin()
        let items = project.addMedia([makeItem("A"), makeItem("B")])
        project.moveMedia([items[0].id], toBin: bin.id)
        #expect(project.item(items[0].id)?.binID == bin.id)
        project.moveMedia([items[1].id], toBin: UUID())
        #expect(project.item(items[1].id)?.binID == nil)
        project.removeMedia([items[0].id])
        #expect(project.media.map(\.name) == ["B"])
    }

    @Test func renameRejectsBlankNames() {
        var project = Project()
        let item = project.addMedia([makeItem("A")])[0]
        project.renameMedia(item.id, to: "   ")
        #expect(project.item(item.id)?.name == "A")
        project.renameMedia(item.id, to: " Interview ")
        #expect(project.item(item.id)?.name == "Interview")
    }

    @Test func marksSnapAndClampToMedia() throws {
        var project = Project()
        let item = project.addMedia([makeItem("A", seconds: 10, rate: .fps30)])[0]
        project.updateMarks(of: item.id) { $0.setIn(RationalTime(seconds: 1.51, timescale: 600)) }
        project.updateMarks(of: item.id) { $0.setOut(RationalTime(value: 20, timescale: 1)) }
        let marks = try #require(project.item(item.id)?.marks)
        #expect(marks.inPoint == RationalTime(frames: 45, rate: .fps30))
        // Clamped to the last frame (frame 299 of a 300-frame clip).
        #expect(marks.outPoint == RationalTime(frames: 299, rate: .fps30))
        let range = marks.range(duration: RationalTime(value: 10, timescale: 1), rate: .fps30)
        #expect(range.duration == RationalTime(frames: 255, rate: .fps30))
    }

    @Test func settingInAfterOutClearsOut() {
        var marks = SourceMarks()
        marks.setOut(RationalTime(value: 2, timescale: 1))
        marks.setIn(RationalTime(value: 3, timescale: 1))
        #expect(marks.outPoint == nil)
        marks.setOut(RationalTime(value: 1, timescale: 1))
        #expect(marks.inPoint == nil)
    }

    @Test func sameFrameInAndOutSelectsOneFrame() {
        var marks = SourceMarks()
        let frame = RationalTime(frames: 10, rate: .fps24)
        marks.setIn(frame)
        marks.setOut(frame)
        let range = marks.range(duration: RationalTime(value: 5, timescale: 1), rate: .fps24)
        #expect(range.duration == FrameRate.fps24.frameDuration)
    }

    @Test func fileRoundTrip() throws {
        var project = Project()
        let bin = project.addBin(named: "Footage")
        project.addMedia([makeItem("A", binID: bin.id), makeItem("B", rate: .fps59_94)])
        project.updateMarks(of: project.media[1].id) { $0.setIn(RationalTime(frames: 12, rate: .fps59_94)) }
        let data = try ProjectFileCoder.encode(project)
        let decoded = try ProjectFileCoder.decode(data)
        #expect(decoded == project)
    }

    @Test func rejectsNewerSchema() {
        let data = Data(#"{"schemaVersion": 99, "bins": [], "media": []}"#.utf8)
        #expect(throws: ProjectFileError.newerSchema(found: 99, supported: Project.currentSchemaVersion)) {
            try ProjectFileCoder.decode(data)
        }
        #expect(throws: ProjectFileError.corrupt) {
            try ProjectFileCoder.decode(Data("not json".utf8))
        }
    }

    @Test func toleratesMissingOptionalKeys() throws {
        let project = try ProjectFileCoder.decode(Data(#"{"schemaVersion": 1}"#.utf8))
        #expect(project.media.isEmpty && project.bins.isEmpty)
    }
}
