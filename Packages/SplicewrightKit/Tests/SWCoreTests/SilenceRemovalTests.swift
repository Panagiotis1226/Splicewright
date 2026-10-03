import Foundation
import Testing
@testable import SWCore

@Suite("Remove Silence")
struct SilenceRemovalTests {
    private let rate = 48_000.0

    /// Tone, quiet, tone... as (seconds, loud) pieces, fed in 1024-sample buffers like a reader.
    private func detect(_ pieces: [(Double, Bool)], settings: SilenceSettings = SilenceSettings(),
                        quietLevel: Float = 0) -> [ClosedRange<Double>] {
        var samples: [Float] = []
        for (seconds, loud) in pieces {
            let count = Int(seconds * rate)
            let start = samples.count
            samples += (0..<count).map { index in
                loud ? Float(0.3 * sin(2 * .pi * 220 * Double(start + index) / rate)) : quietLevel
            }
        }
        var detector = SilenceDetector(sampleRate: rate, settings: settings)
        for start in stride(from: 0, to: samples.count, by: 1024) {
            let piece = Array(samples[start..<min(start + 1024, samples.count)])
            detector.process([piece, piece])
        }
        return detector.silences()
    }

    @Test func findsPausesLessThePadding() throws {
        let found = detect([(1, true), (1, false), (1, true)])
        #expect(found.count == 1)
        let pause = try #require(found.first)
        #expect(abs(pause.lowerBound - 1.15) < 0.03 && abs(pause.upperBound - 1.85) < 0.03, "\(pause)")
    }

    @Test func shortPausesAndQuietSoundStay() {
        #expect(detect([(1, true), (0.3, false), (1, true)]).isEmpty, "shorter than the minimum")
        // -40 dB of hum is above a -50 dB threshold: not silence.
        let hum = detect([(1, true), (1, false), (1, true)], settings: SilenceSettings(thresholdDB: -50),
                         quietLevel: 0.01)
        #expect(hum.isEmpty)
        // Leading and trailing silence keep no padding at the outer edge.
        let edges = detect([(1, false), (1, true), (1, false)])
        #expect(edges.count == 2 && edges[0].lowerBound == 0 && abs(edges[1].upperBound - 3) < 0.03)
    }

    @Test func rippleRemoveMovesClipsCaptionsAndMarkers() {
        var seq = EditSequence(name: "S", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                                    colorSpace: .rec709))
        let link = UUID()
        let video = Clip(mediaID: UUID(), name: "v", start: 0, duration: 300, sourceStart: .zero, linkID: link)
        var audio = video
        audio.id = UUID()
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: video),
                       TrackPlacement(trackID: seq.audioTracks[0].id, clip: audio)])
        seq.captionTracks = [CaptionTrack(name: "C", language: "en", captions: [
            Caption(start: 10, duration: 40, text: "before", words: [CaptionWord(text: "before", start: 10, duration: 40)]),
            Caption(start: 120, duration: 60, text: "across the cut"),
            Caption(start: 200, duration: 30, text: "after"),
        ])]
        seq.markers = [Marker(frame: 110), Marker(frame: 250)]
        let ranges = EditSequence.frameRanges([2.0...4.0], from: 40, rate: .fps30)
        #expect(ranges == [FrameRange(start: 100, end: 160)])
        #expect(seq.rippleRemove(ranges) == 60)
        #expect(seq.videoTracks[0].clips.map(\.range) == [FrameRange(start: 0, end: 100), FrameRange(start: 100, end: 240)])
        #expect(seq.audioTracks[0].clips.map(\.range) == seq.videoTracks[0].clips.map(\.range))
        #expect(seq.videoTracks[0].clips[1].sourceStart == RationalTime(frames: 160, rate: .fps30), "the pause is gone")
        let captions = seq.captionTracks[0].captions
        #expect(captions.map(\.range) == [FrameRange(start: 10, end: 50), FrameRange(start: 100, end: 120),
                                          FrameRange(start: 140, end: 170)])
        #expect(seq.markers.map(\.frame) == [100, 190])
    }

    @Test func cutOnlyLeavesThePausesToReview() {
        var seq = EditSequence(name: "S", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                                    colorSpace: .rec709))
        let clip = Clip(mediaID: UUID(), name: "v", start: 0, duration: 300, sourceStart: .zero)
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: clip)])
        let pauses = seq.cutAtRanges([FrameRange(start: 100, end: 160), FrameRange(start: 200, end: 230)])
        #expect(seq.videoTracks[0].clips.count == 5 && pauses.count == 2)
        #expect(seq.durationFrames == 300, "nothing moved")
    }
}
