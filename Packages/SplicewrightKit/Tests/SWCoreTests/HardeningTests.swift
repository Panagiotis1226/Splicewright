import Foundation
import Testing
@testable import SWCore

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Auto-save")
struct AutoSaveTests {
    @Test func keysAreStableAndShort() {
        let key = AutoSaveStore.key(for: "/Users/me/Movies/Trip.splicewright")
        #expect(key == AutoSaveStore.key(for: "/Users/me/Movies/Trip.splicewright"))
        #expect(key != AutoSaveStore.key(for: "/Users/me/Movies/Trip 2.splicewright"))
        #expect(key.count == 8)
    }

    @Test func fileNamesAreReadableAndSafe() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13:20 UTC
        #expect(AutoSaveStore.fileName(projectName: "Trip/Cut: 1", date: date, timeZone: utc)
                == "Trip-Cut- 1 2026-09-21 at 14.13.20.splicewright")
        #expect(AutoSaveStore.folderName(projectName: "  ", key: "ab12cd34") == "Untitled ab12cd34")
    }

    @Test func savesVersionsThatOpenAndPrunesOldOnes() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutoSaveStore(root: root)
        var project = Project()
        project.addMedia([makeItem("A")])
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for minute in 0..<5 {
            try store.save(project, projectName: "Trip", key: "k1", date: start.addingTimeInterval(Double(minute) * 60),
                           keep: 3)
        }
        let folder = store.folder(projectName: "Trip", key: "k1")
        let versions = store.versions(in: folder)
        #expect(versions.count == 3, "only the newest three are kept")
        #expect(versions.first?.date == start.addingTimeInterval(240))
        #expect(versions.first?.projectName == "Trip")

        // Each version is a normal project package.
        let data = try Data(contentsOf: try #require(versions.first).url.appendingPathComponent("project.json"))
        #expect(try ProjectFileCoder.decode(data) == project)

        // No temporary packages are left behind.
        let hidden = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }
        #expect(hidden.isEmpty)

        try store.save(project, projectName: "Other", key: "k2", date: start.addingTimeInterval(600), keep: 3)
        #expect(store.latestVersions().map(\.projectName) == ["Other", "Trip"])
        #expect(store.totalSize() > 0)
    }

    @Test func savesInTheSameSecondDontOverwrite() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutoSaveStore(root: root)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try store.save(Project(), projectName: "P", key: "k", date: date, keep: 10)
        let second = try store.save(Project(), projectName: "P", key: "k", date: date, keep: 10)
        #expect(first != second)
        #expect(store.versions(in: store.folder(projectName: "P", key: "k")).count == 2)
    }

    @Test func policyIsClamped() {
        let policy = AutoSavePolicy(intervalMinutes: 0, maximumVersions: 10_000).clamped()
        #expect(policy.intervalMinutes == 1 && policy.maximumVersions == 200)
    }
}

@Suite("Relink and changed media")
struct RelinkTests {
    private func item(_ path: String, size: Int64?) -> MediaItem {
        var item = makeItem((path as NSString).lastPathComponent, path: path)
        item.info.fileSize = size
        return item
    }

    @Test func matchesByNamePreferringTheSameSize() {
        let first = item("/old/A001.mov", size: 100)
        let second = item("/old/B002.MOV", size: 200)
        let third = item("/old/C003.mov", size: 300)
        let unknownSize = item("/old/D004.mov", size: nil)
        let candidates = [
            RelinkCandidate(path: "/new/x/A001.mov", size: 999),
            RelinkCandidate(path: "/new/y/A001.mov", size: 100),
            RelinkCandidate(path: "/new/b002.mov", size: 200),
            RelinkCandidate(path: "/new/C003.mov", size: 301),
            RelinkCandidate(path: "/new/D004.mov", size: 5),
        ]
        let matches = RelinkMatcher.matches(for: [first, second, third, unknownSize], in: candidates)
        #expect(matches[first.id] == "/new/y/A001.mov", "same name and size wins")
        #expect(matches[second.id] == "/new/b002.mov", "names match ignoring case")
        #expect(matches[third.id] == nil, "a same-named file of another size is a different file")
        #expect(matches[unknownSize.id] == "/new/D004.mov", "without a known size, the name is enough")
    }

    @Test func aFileIsUsedOnce() {
        let first = item("/a/clip.mov", size: nil)
        let second = item("/b/clip.mov", size: nil)
        let matches = RelinkMatcher.matches(for: [first, second], in: [RelinkCandidate(path: "/n/clip.mov", size: nil)])
        #expect(matches.count == 1)
    }

    @Test func findsCandidatesInSubfolders() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("Day 1/Card A", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(count: 10).write(to: deep.appendingPathComponent("A001.mov"))
        try Data(count: 3).write(to: root.appendingPathComponent(".hidden.mov"))
        let found = RelinkMatcher.candidates(in: root)
        #expect(found.map { ($0.path as NSString).lastPathComponent } == ["A001.mov"])
        #expect(found.first?.size == 10)
    }

    @Test func detectsChangedFiles() {
        var media = item("/m/a.mov", size: 100)
        let date = Date(timeIntervalSince1970: 1000)
        media.fileModifiedAt = date
        #expect(!media.hasChanged(comparedTo: FileFingerprint(size: 100, modified: date)))
        #expect(media.hasChanged(comparedTo: FileFingerprint(size: 101, modified: date)))
        #expect(media.hasChanged(comparedTo: FileFingerprint(size: 100, modified: date.addingTimeInterval(60))))
        media.fileModifiedAt = nil
        #expect(!media.hasChanged(comparedTo: FileFingerprint(size: 100, modified: date.addingTimeInterval(60))),
                "no recorded date: only the size counts")
    }

    @Test func olderProjectsDecodeWithoutModificationDates() throws {
        var project = Project()
        project.addMedia([makeItem("A")])
        var json = try #require(String(bytes: try ProjectFileCoder.encode(project), encoding: .utf8))
        #expect(!json.contains("fileModifiedAt"), "nil isn't written")
        json = json.replacingOccurrences(of: "\"schemaVersion\" : 5", with: "\"schemaVersion\" : 3")
        let decoded = try ProjectFileCoder.decode(Data(json.utf8))
        #expect(decoded.media.first?.fileModifiedAt == nil)
    }

    @Test func updatingInfoAfterAChange() {
        var project = Project()
        let added = project.addMedia([makeItem("A")])[0]
        var info = added.info
        info.fileSize = 42
        let date = Date(timeIntervalSince1970: 5)
        project.updateMediaInfo(added.id, info: info, modified: date)
        #expect(project.media[0].info.fileSize == 42 && project.media[0].fileModifiedAt == date)
    }
}

@Suite("Clipboard")
struct ClipboardTests {
    private func sequence() -> EditSequence {
        var sequence = EditSequence(name: "S", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                                          colorSpace: .rec709))
        sequence.addTrack(.video)
        return sequence
    }

    @Test func copyAndPasteKeepsLayoutLinksAndAnimation() throws {
        var project = Project()
        let media = project.addMedia([makeItem("A")])[0]
        var sequence = sequence()
        let range = TimeRange(start: .zero, end: RationalTime(value: 2, timescale: 1))
        let placements = sequence.makeClips(for: media, sourceRange: range, at: 30, videoTrackID: sequence.videoTracks[1].id,
                                            audioTrackID: sequence.audioTracks[0].id)
        sequence.overwrite(placements)
        let videoID = placements[0].clip.id
        sequence.updateProperty(.scale, of: videoID) { $0.values = [50] }
        let ids = Set(placements.map(\.clip.id))

        let content = try #require(sequence.copyClips(ids, project: project))
        #expect(content.items.count == 2 && content.duration == 60)
        #expect(content.items.allSatisfy { $0.trackOffset == 0 && $0.clip.start == 0 })
        #expect(content.media.map(\.id) == [media.id])
        #expect(content.attributeSource?.motion.scale.values == [50])

        // Survives the pasteboard.
        let decoded = try JSONDecoder().decode(ClipboardContent.self, from: try JSONEncoder().encode(content))
        #expect(decoded == content)

        let pasted = sequence.paste(decoded, at: 200)
        #expect(pasted.count == 2 && pasted.isDisjoint(with: ids))
        let clips = pasted.compactMap { sequence.clip($0) }
        #expect(clips.allSatisfy { $0.start == 200 && $0.duration == 60 })
        #expect(Set(clips.map(\.linkID)).count == 1, "the copies are linked to each other")
        #expect(clips.first?.linkID != placements[0].clip.linkID, "but not to the originals")
        #expect(sequence.videoTracks[0].clips.contains { pasted.contains($0.id) }, "lands on the targeted (first) track")
        #expect(clips.contains { $0.motion.scale.values == [50] })
    }

    @Test func pasteOverwritesAndAddsTracks() throws {
        var sequence = sequence()
        let media = UUID()
        func clip(_ start: Int64, _ length: Int64) -> Clip {
            Clip(mediaID: media, name: "c", start: start, duration: length, sourceStart: .zero)
        }
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[0].id, clip: clip(0, 100))])
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[1].id, clip: clip(0, 10))])
        let ids = Set(sequence.videoTracks.flatMap { $0.clips.map(\.id) })
        let content = try #require(sequence.copyClips(ids, project: Project()))
        #expect(content.items.map(\.trackOffset).sorted() == [0, 1])

        // Paste onto the top track: the upper clip needs a new one.
        let count = sequence.videoTracks.count
        sequence.setTrackFlags(sequence.videoTracks[count - 1].id) { $0.isTargeted = true }
        sequence.paste(content, at: 50)
        #expect(sequence.videoTracks.count == count + 1)
        #expect(sequence.videoTracks[count - 1].clips.last.map { ($0.start, $0.duration) } ?? (0, 0) == (50, 100))
        #expect(sequence.videoTracks[count].clips.map(\.start) == [50])

        // Pasting over existing clips overwrites them.
        sequence.setTrackFlags(sequence.videoTracks[0].id) { $0.isTargeted = true }
        sequence.paste(content, at: 50)
        #expect(sequence.videoTracks[0].clips.map(\.start) == [0, 50])
        #expect(sequence.videoTracks[0].clips.map(\.duration) == [50, 100])
    }

    @Test func pasteConvertsFrameRates() throws {
        var source = sequence()
        source.overwrite([TrackPlacement(trackID: source.videoTracks[0].id,
                                         clip: Clip(mediaID: UUID(), name: "c", start: 0, duration: 30, sourceStart: .zero))])
        let content = try #require(source.copyClips(Set(source.videoTracks[0].clips.map(\.id)), project: Project()))
        var target = EditSequence(name: "60", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps60,
                                                                         colorSpace: .rec709))
        target.paste(content, at: 0)
        #expect(target.videoTracks[0].clips.first?.duration == 60, "one second either way")
    }

    @Test func pastingIntoAnotherProjectAddsTheMedia() {
        var project = Project()
        let item = makeItem("A", binID: UUID())
        project.addMissingMedia([item])
        project.addMissingMedia([item])
        #expect(project.media.count == 1)
        #expect(project.media[0].binID == nil, "its bin isn't in this project")
    }
}

@Suite("Log")
struct AppLogTests {
    @Test func writesAndRollsOver() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = AppLog(directory: folder, name: "test", maximumBytes: 400)
        log.info("first line", category: "import")
        log.error("multi\nline", category: "export")
        let lines = log.lines()
        #expect(lines.count == 2)
        #expect(lines[0].contains("[INFO] [import] first line"))
        #expect(lines[1].hasSuffix("[ERROR] [export] multi line"))
        for index in 0..<20 { log.warning("filler \(index)") }
        log.flush()
        #expect(FileManager.default.fileExists(atPath: log.previousURL.path), "rolled over")
        let size = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.size] as? Int ?? 0
        #expect(size <= 400)
    }
}
