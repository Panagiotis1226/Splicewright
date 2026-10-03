import Foundation
import Testing
@testable import SWCore

@Suite("Social destinations")
struct SocialDestinationTests {
    private func sequence(width: Int, height: Int, rate: FrameRate = .fps30, seconds: Double = 10,
                          space: SequenceColorSpace = .rec709) -> EditSequence {
        var seq = EditSequence(name: "Cut", settings: SequenceSettings(width: width, height: height, frameRate: rate,
                                                                      colorSpace: space))
        let clip = Clip(mediaID: UUID(), name: "A", start: 0, duration: Int64(seconds * rate.framesPerSecond),
                        sourceStart: .zero)
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: clip)])
        return seq
    }

    @Test func youTubeFollowsItsBitrateTable() {
        let uhd = SocialDestination.youTube.settings(for: sequence(width: 3840, height: 2160))
        #expect(uhd.preset == .h264SDR && uhd.size == .matchSequence && uhd.customMegabits == 45)
        #expect(uhd.audioKilobits == 384 && uhd.loudness == .streaming && uhd.destination == .youTube)
        let hd60 = SocialDestination.youTube.settings(for: sequence(width: 1920, height: 1080, rate: .fps60))
        #expect(hd60.customMegabits == 12 && hd60.frameRate == nil)
        let hdr = SocialDestination.youTube.settings(for: sequence(width: 1920, height: 1080, space: .rec2100PQ))
        #expect(hdr.preset.colorSpace == .rec2100PQ && hdr.customMegabits == 10, "HDR stays HDR, at its rate")
    }

    @Test func verticalPlatformsGetA1080pFrameAtMost60fps() {
        let seq = sequence(width: 2160, height: 3840, rate: .fps120)
        for destination in [SocialDestination.tikTok, .instagramReels, .facebookReels, .youTubeShorts] {
            let settings = destination.settings(for: seq)
            let output = settings.outputSize(for: seq)
            #expect(output.width == 1080 && output.height == 1920, "\(destination)")
            #expect(settings.outputRate(for: seq) == .fps60, "\(destination)")
            #expect(settings.preset == .h264SDR && settings.validate(for: seq).isEmpty)
            #expect(!settings.warnings(for: seq, project: Project()).contains {
                if case .destinationShape = $0 { return true } else { return false }
            })
        }
        #expect(SocialDestination.frameRate(for: .fps119_88) == .fps59_94)
        #expect(SocialDestination.frameRate(for: .fps100) == .fps50)
        #expect(SocialDestination.tikTok.settings(for: seq).customMegabits == 12, "60 fps")
        #expect(SocialDestination.instagramReels.settings(for: seq).audioKilobits == 128)
    }

    @Test func smallerFramesGetLessAndNothingIsUpscaled() {
        let seq = sequence(width: 720, height: 1280)
        let settings = SocialDestination.tikTok.settings(for: seq)
        #expect(settings.size == .matchSequence)
        #expect(settings.customMegabits.map { $0 < 10 && $0 >= 2 } == true)
    }

    @Test func warningsForShapeLengthAndSize() {
        let wide = sequence(width: 1920, height: 1080, seconds: 200)
        let tikTok = SocialDestination.tikTok.settings(for: wide)
        #expect(tikTok.warnings(for: wide, project: Project()).contains(.destinationShape(.tikTok, width: 1920,
                                                                                          height: 1080)))
        let x = SocialDestination.x.settings(for: wide)
        let messages = x.warnings(for: wide, project: Project()).map(\.message)
        #expect(messages.contains { $0.contains("2 minutes 20 seconds") }, "\(messages)")
        #expect(!messages.contains { $0.contains("letterboxed") }, "X takes any shape")
        // An hour at 10 Mbps is about 4.6 GB: over Instagram's 4 GB.
        let long = sequence(width: 1080, height: 1920, seconds: 3600)
        let reels = SocialDestination.instagramReels.settings(for: long)
        #expect(reels.warnings(for: long, project: Project()).contains { $0.message.contains("4 GB") })
    }

    @Test func audioBitrateCountsInTheEstimate() {
        let seq = sequence(width: 1920, height: 1080)
        var settings = ExportSettings(preset: .h264SDR, customMegabits: 8)
        let at320 = settings.estimatedBytes(for: seq)
        settings.audioKilobits = 128
        #expect(at320 - settings.estimatedBytes(for: seq) == Int64(192_000 * 10 / 8))
    }
}
