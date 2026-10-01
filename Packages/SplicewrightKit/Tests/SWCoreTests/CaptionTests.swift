import Foundation
import Testing
@testable import SWCore

private func words(_ text: String, from start: Double = 0, each: Double = 0.3, gap: Double = 0.05) -> [TimedWord] {
    var time = start
    return text.split(separator: " ").map { word in
        defer { time += each + gap }
        return TimedWord(text: String(word), start: time, duration: each)
    }
}

private func sequence(_ rate: FrameRate = .fps30) -> EditSequence {
    EditSequence(name: "S", settings: SequenceSettings(width: 1920, height: 1080, frameRate: rate, colorSpace: .rec709))
}

@Suite("Caption segmenter")
struct CaptionSegmenterTests {
    @Test func breaksAtSentencesAndPauses() {
        var input = words("Hello world. This is Splicewright")
        input += words("after a pause", from: 3)
        let captions = CaptionSegmenter.captions(from: input, rate: .fps30, style: .standard)
        #expect(captions.map(\.text) == ["Hello world.", "This is Splicewright", "after a pause"])
        #expect(captions[0].start == 0)
        #expect(captions[2].start == 90, "3 s at 30 fps")
        #expect(zip(captions, captions.dropFirst()).allSatisfy { $0.end <= $1.start }, "no overlaps")
    }

    @Test func keepsWithinLineLimitsAndBalancesTwoLines() {
        let long = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen"
        let captions = CaptionSegmenter.captions(from: words(long, each: 0.2, gap: 0.02), rate: .fps30, style: .standard)
        #expect(captions.count >= 2)
        for caption in captions {
            let lines = caption.text.split(separator: "\n")
            #expect(lines.count <= 2)
            #expect(lines.allSatisfy { $0.count <= 42 }, "\(caption.text)")
        }
        let social = CaptionSegmenter.captions(from: words(long, each: 0.2, gap: 0.02), rate: .fps30, style: .social)
        #expect(social.allSatisfy { !$0.text.contains("\n") && $0.text.count <= 18 })
    }

    @Test func minimumDurationAndClosedGaps() {
        // A one-word caption, then another 2 frames after it ends.
        let input = [TimedWord(text: "Hi.", start: 0, duration: 0.1), TimedWord(text: "Yes.", start: 2, duration: 0.5)]
        let captions = CaptionSegmenter.captions(from: input, rate: .fps30, style: .standard)
        #expect(captions[0].duration == 24, "stretched to 0.8 s")
        let close = [TimedWord(text: "A.", start: 0, duration: 1), TimedWord(text: "B.", start: 1.05, duration: 1)]
        let closed = CaptionSegmenter.captions(from: close, rate: .fps30, style: .standard)
        #expect(closed[0].end == closed[1].start, "a gap under 3 frames closes up")
    }

    @Test func longSpeechIsSplitBySevenSeconds() {
        let input = (0..<40).map { TimedWord(text: "go", start: Double($0) * 0.25, duration: 0.2) }
        let captions = CaptionSegmenter.captions(from: input, rate: .fps30, style: CaptionStyle(title: TitleSpec(),
                                                                                                  maxCharactersPerLine: 400,
                                                                                                  maxLines: 2))
        #expect(captions.allSatisfy { $0.duration <= 7 * 30 + 1 })
        #expect(captions.count >= 2)
    }

    @Test func resplitKeepsTypedCaptions() {
        let rate = FrameRate.fps30
        var captions = CaptionSegmenter.captions(from: words("Hello world. This is Splicewright."), rate: rate,
                                                 style: .standard)
        captions.append(Caption(start: 300, duration: 30, text: "Typed by hand"))
        let social = CaptionSegmenter.resplit(captions, rate: rate, style: .social)
        #expect(social.last?.text == "Typed by hand")
        #expect(social.dropLast().allSatisfy { $0.text.count <= 18 })
    }
}

@Suite("Caption edits")
struct CaptionEditTests {
    private func fixture() -> (EditSequence, UUID, [UUID]) {
        var seq = sequence()
        let captions = [Caption(start: 0, duration: 30, text: "First"), Caption(start: 40, duration: 30, text: "Second"),
                        Caption(start: 100, duration: 30, text: "Third")]
        let track = seq.addCaptionTrack(name: "Subtitles", language: "en-US", captions: captions)
        return (seq, track, captions.map(\.id))
    }

    @Test func movesAndTrimsStopAtNeighbours() {
        var (seq, track, ids) = fixture()
        seq.moveCaption(ids[1], to: 0)
        #expect(seq.caption(ids[1])?.caption.start == 30, "stops at the end of the first")
        seq.moveCaption(ids[1], to: 95)
        #expect(seq.caption(ids[1])?.caption.start == 70, "stops where it would hit the third")
        seq.trimCaption(ids[0], edge: .end, to: 500)
        #expect(seq.caption(ids[0])?.caption.end == 70)
        seq.trimCaption(ids[2], edge: .start, to: 200)
        #expect(seq.caption(ids[2])?.caption.duration == 1, "keeps a frame")
        #expect(seq.captionTrack(track)?.captions.map(\.id) == ids)
    }

    @Test func splitAtAWordAndMerge() throws {
        var seq = sequence()
        let captions = CaptionSegmenter.captions(from: words("one two three four"), rate: .fps30, style: .standard)
        let track = seq.addCaptionTrack(name: "S", language: "en", captions: captions)
        let id = try #require(captions.first?.id)
        let third = try #require(captions.first?.words[2])
        let split = seq.splitCaption(id, at: third.start)
        let right = try #require(split)
        #expect(seq.caption(id)?.caption.text == "one two")
        #expect(seq.caption(right)?.caption.text == "three four")
        #expect(seq.caption(right)?.caption.start == third.start)
        seq.mergeCaptionWithNext(id)
        #expect(seq.captionTrack(track)?.captions.count == 1)
        #expect(seq.caption(id)?.caption.text == "one two three four")
    }

    @Test func splitEditedTextByTime() throws {
        var (seq, _, ids) = fixture()
        seq.setCaptionText(ids[0], "alpha beta gamma delta")
        let split = seq.splitCaption(ids[0], at: 15)
        let right = try #require(split)
        #expect(seq.caption(ids[0])?.caption.text == "alpha beta")
        #expect(seq.caption(right)?.caption.text == "gamma delta")
    }

    @Test func findReplaceShiftAddDelete() {
        var (seq, track, ids) = fixture()
        #expect(seq.replaceInCaptions(on: track, "SECOND", with: "2nd") == 1)
        #expect(seq.caption(ids[1])?.caption.text == "2nd")
        seq.shiftCaptions(on: track, by: -100)
        #expect(seq.caption(ids[0])?.caption.start == 0, "not before frame 0")
        seq.shiftCaptions(on: track, by: 10)
        let added = seq.addCaption(on: track, at: 15, duration: 30, text: "New")
        #expect(added.flatMap { seq.caption($0)?.caption.start } == 40, "after the caption under the playhead")
        #expect(added.flatMap { seq.caption($0)?.caption.duration } == 10, "up to the next caption")
        seq.deleteCaptions([ids[0]])
        #expect(seq.caption(ids[0]) == nil)
    }

    @Test func lockedTracksDontChange() {
        var (seq, track, ids) = fixture()
        seq.updateCaptionTrack(track) { $0.isLocked = true }
        seq.setCaptionText(ids[0], "Changed")
        seq.deleteCaptions([ids[1]])
        #expect(seq.caption(ids[0])?.caption.text == "First")
        #expect(seq.caption(ids[1]) != nil)
    }

    @Test func renderPlanDrawsEnabledCaptionsOnTop() {
        var (seq, track, _) = fixture()
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id,
                                      clip: Clip(mediaID: UUID(), name: "v", start: 0, duration: 200, sourceStart: .zero))])
        let segments = RenderPlan.videoSegments(for: seq)
        let atTen = segments.first { $0.range.contains(10) }
        #expect(atTen?.layers.count == 2)
        #expect(atTen?.layers.last?.title?.text == "First")
        #expect(atTen?.layers.last?.title?.background != nil, "standard style has a box")
        #expect(segments.first { $0.range.contains(35) }?.layers.count == 1, "no caption between captions")
        seq.updateCaptionTrack(track) { $0.isOutputEnabled = false }
        #expect(RenderPlan.videoSegments(for: seq).allSatisfy { $0.layers.count == 1 })
    }

    @Test func schema4SequencesLoadWithoutCaptions() throws {
        var project = Project()
        project.sequences = [sequence()]
        var json = try #require(String(bytes: try ProjectFileCoder.encode(project), encoding: .utf8))
        json = json.replacingOccurrences(of: "\"captionTracks\" : [\n\n      ],", with: "")
            .replacingOccurrences(of: "\"captionTracks\" : [],", with: "")
        #expect(!json.contains("captionTracks"))
        let decoded = try ProjectFileCoder.decode(Data(json.utf8))
        #expect(decoded.sequences.first?.captionTracks.isEmpty == true)
    }
}

@Suite("SubRip")
struct SubRipTests {
    @Test func writesSRTAndVTT() {
        let captions = [Caption(start: 30, duration: 45, text: "Hello\nworld"),
                        Caption(start: 3600 * 30, duration: 15, text: "Later")]
        let srt = SubRip.write(captions, rate: .fps30)
        #expect(srt == "1\n00:00:01,000 --> 00:00:02,500\nHello\nworld\n\n2\n01:00:00,000 --> 01:00:00,500\nLater\n")
        let vtt = SubRip.write(captions, rate: .fps30, format: .vtt)
        #expect(vtt.hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello"))
    }

    @Test func dropFrameRatesUseRealTime() {
        // Frame 30 at 29.97 is 1.001 s.
        #expect(SubRip.timestamp(30, .fps29_97) == "00:00:01,001")
    }

    @Test func rangeClipsAndOffsets() {
        let captions = [Caption(start: 0, duration: 30, text: "Before"), Caption(start: 50, duration: 100, text: "Inside")]
        let srt = SubRip.write(captions, rate: .fps30, range: FrameRange(start: 60, end: 120))
        #expect(srt == "1\n00:00:00,000 --> 00:00:02,000\nInside\n")
    }

    @Test func roundTripAndTolerantParsing() throws {
        let captions = [Caption(start: 12, duration: 40, text: "One"), Caption(start: 90, duration: 20, text: "Two\nlines")]
        let parsed = try SubRip.parse(SubRip.write(captions, rate: .fps30), rate: .fps30)
        #expect(parsed.map(\.start) == [12, 90] && parsed.map(\.duration) == [40, 20])
        #expect(parsed.map(\.text) == ["One", "Two\nlines"])

        let messy = "\u{FEFF}WEBVTT\r\n\r\nintro\r\n00:01.500 --> 00:02.000 align:start\r\n<v Bob><i>Hi</i>\r\n\r\n"
        let vtt = try SubRip.parse(messy, rate: .fps30, startFrame: 100)
        #expect(vtt.first?.text == "Hi" && vtt.first?.start == 145 && vtt.first?.duration == 15)
        #expect(throws: SubRip.ParseError.noCaptions) { try SubRip.parse("nothing here", rate: .fps30) }
    }

    @Test func exportSettingsPickCaptionTracks() throws {
        var seq = sequence()
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id,
                                      clip: Clip(mediaID: UUID(), name: "v", start: 0, duration: 300, sourceStart: .zero))])
        let first = seq.addCaptionTrack(name: "EN", language: "en", captions: [Caption(start: 30, duration: 30, text: "Hi")])
        let second = seq.addCaptionTrack(name: "FR", language: "fr", captions: [Caption(start: 30, duration: 30, text: "Salut")])
        var settings = ExportSettings(preset: ExportPreset.builtIn(for: seq)[0])
        #expect(settings.preparedSequence(seq).captionTracks.allSatisfy { !$0.isOutputEnabled }, "no burn-in by default")
        #expect(settings.sidecarText(for: seq) == nil)
        settings.burnInCaptions = second
        settings.sidecarCaptions = first
        let prepared = settings.preparedSequence(seq)
        #expect(prepared.captionTracks.map { $0.isOutputEnabled } == [false, true])
        #expect(settings.sidecarText(for: seq)?.contains("Hi") == true)
        #expect(settings.sidecarURL(for: URL(fileURLWithPath: "/tmp/Cut.mp4")).lastPathComponent == "Cut.srt")
        let decoded = try JSONDecoder().decode(ExportSettings.self, from: try JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}
