import Foundation
import Testing
@testable import SWCore

@Suite("Export settings")
struct ExportSettingsTests {
    private func sequence(_ space: SequenceColorSpace = .rec709, width: Int = 3840, height: Int = 2160,
                          rate: FrameRate = .fps30, frames: Int64 = 300) -> EditSequence {
        var seq = EditSequence(name: "My Cut", settings: SequenceSettings(width: width, height: height,
                                                                         frameRate: rate, colorSpace: space))
        if frames > 0 {
            let clip = Clip(mediaID: UUID(), name: "A", start: 0, duration: frames, sourceStart: .zero)
            seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: clip)])
        }
        return seq
    }

    @Test func builtInPresetsAreValid() {
        for space in SequenceColorSpace.allCases {
            let seq = sequence(space)
            for preset in ExportPreset.builtIn(for: seq) {
                #expect(ExportSettings(preset: preset).validate(for: seq).isEmpty, "\(preset.name) in \(space)")
            }
        }
    }

    @Test func matchSequencePicksCodecByColorSpace() {
        #expect(ExportPreset.matchSequence(sequence(.rec709)).codec == .h264)
        #expect(ExportPreset.matchSequence(sequence(.rec2100HLG)).codec == .hevc10)
        #expect(ExportPreset.matchSequence(sequence(.rec2100PQ)).colorSpace == .rec2100PQ)
        #expect(ExportPreset.proRes(for: sequence(.rec2100HLG)).colorSpace == .rec2100HLG)
    }

    @Test func validationRules() {
        let seq = sequence()
        var hdrH264 = ExportPreset.h264SDR
        hdrH264.colorSpace = .rec2100PQ
        #expect(ExportSettings(preset: hdrH264).validate(for: seq) == [.hdrNeedsTenBit])
        var proResMP4 = ExportPreset.proRes(for: seq)
        proResMP4.container = .mp4
        #expect(ExportSettings(preset: proResMP4).validate(for: seq) == [.proResNeedsQuickTime, .pcmNeedsQuickTime])
        #expect(ExportSettings(preset: .h264SDR, range: .inToOut).validate(for: seq) == [.missingInOut])
        #expect(ExportSettings(preset: .h264SDR).validate(for: sequence(frames: 0)) == [.emptyRange])
    }

    @Test func inToOutRangeIsClippedToSequence() {
        var seq = sequence(frames: 100)
        seq.marks = SequenceMarks(inFrame: 90, outFrame: 199)
        let settings = ExportSettings(preset: .h264SDR, range: .inToOut)
        #expect(settings.frameRange(for: seq) == FrameRange(start: 90, end: 100))
        seq.marks = SequenceMarks(inFrame: 10, outFrame: 39)
        #expect(settings.frameRange(for: seq)?.length == 30)
        #expect(ExportSettings(preset: .h264SDR).frameRange(for: seq) == FrameRange(start: 0, end: 100))
    }

    @Test func outputSizeIsEvenAndKeepsAspect() {
        let uhd = sequence()
        #expect(ExportSettings(preset: .h264SDR, size: .hd1080).outputSize(for: uhd) == (1920, 1080))
        #expect(ExportSettings(preset: .h264SDR).outputSize(for: uhd) == (3840, 2160))
        let vertical = sequence(width: 2160, height: 3840)
        #expect(ExportSettings(preset: .h264SDR, size: .hd1080).outputSize(for: vertical) == (1080, 1920))
        let small = sequence(width: 1280, height: 720)
        #expect(ExportSettings(preset: .h264SDR, size: .hd1080).outputSize(for: small) == (1920, 1080))
        #expect(ExportSettings(preset: .h264SDR, size: .lines(720)).outputSize(for: uhd) == (1280, 720))
        #expect(ExportSettings(preset: .h264SDR, size: .lines(480)).outputSize(for: uhd) == (854, 480))
        #expect(ExportSettings(preset: .h264SDR, size: .lines(1440)).outputSize(for: uhd) == (2560, 1440))
        let odd = sequence(width: 1440, height: 1080)
        #expect(ExportSettings(preset: .h264SDR, size: .lines(540)).outputSize(for: odd) == (720, 540))
        let dci = sequence(width: 4096, height: 2160)
        #expect(ExportSettings(preset: .h264SDR, size: .hd1080).outputSize(for: dci) == (2048, 1080))
    }

    @Test func bitRatesScaleWithPixelsFrameRateAndQuality() throws {
        let settings = ExportSettings(preset: .h264SDR)
        let uhd30 = try #require(settings.bitRate(width: 3840, height: 2160, fps: 30))
        let uhd60 = try #require(settings.bitRate(width: 3840, height: 2160, fps: 60))
        let hd30 = try #require(settings.bitRate(width: 1920, height: 1080, fps: 30))
        #expect((40_000_000...50_000_000).contains(uhd30))
        #expect(uhd60 > uhd30 && hd30 < uhd30)
        let hevc = try #require(ExportSettings(preset: .hevcSDR).bitRate(width: 3840, height: 2160, fps: 30))
        #expect(hevc < uhd30)
        let high = try #require(ExportSettings(preset: .h264SDR, quality: .high).bitRate(width: 3840, height: 2160, fps: 30))
        #expect(high > uhd30)
        #expect(ExportSettings(preset: .proRes(for: sequence())).bitRate(width: 3840, height: 2160, fps: 30) == nil)
    }

    @Test func customBitRateAndExportFrameRate() throws {
        var settings = ExportSettings(preset: .hevcSDR, customMegabits: 25)
        #expect(settings.bitRate(width: 3840, height: 2160, fps: 30) == 25_000_000)
        settings.customMegabits = 0
        #expect(settings.validate(for: sequence()) == [.invalidBitRate])
        let seq = sequence(rate: .fps30)
        #expect(ExportSettings(preset: .h264SDR).outputRate(for: seq) == .fps30)
        #expect(ExportSettings(preset: .h264SDR, frameRate: .fps120).outputRate(for: seq) == .fps120)
        let at30 = ExportSettings(preset: .h264SDR).estimatedBytes(for: seq)
        let at60 = ExportSettings(preset: .h264SDR, frameRate: .fps60).estimatedBytes(for: seq)
        #expect(at60 > at30)
    }

    @Test func proResFlavors() {
        let seq = sequence()
        let names = ExportPreset.builtIn(for: seq).map(\.codec).filter(\.isProRes)
        #expect(names == [.proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy])
        let hq = ExportSettings(preset: .proRes(.proRes422HQ, for: seq)).estimatedBytes(for: seq)
        let proxy = ExportSettings(preset: .proRes(.proRes422Proxy, for: seq)).estimatedBytes(for: seq)
        #expect(proxy * 4 < hq)
        #expect(ExportCodec.proRes422LT.bitDepth == 10 && !ExportCodec.proRes422LT.usesBitRate)
    }

    @Test func warnings() {
        var project = Project()
        let item = makeItem("A", rate: .fps30)
        project.addMedia([item])
        var seq = EditSequence(name: "W", settings: SequenceSettings(width: 3840, height: 2160, frameRate: .fps30,
                                                                     colorSpace: .rec709))
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: Clip(
            mediaID: item.id, name: "A", start: 0, duration: 30, sourceStart: .zero))])
        #expect(ExportSettings(preset: .hevcSDR).warnings(for: seq, project: project).isEmpty)
        let fast = ExportSettings(preset: .h264SDR, frameRate: .fps120).warnings(for: seq, project: project)
        #expect(fast.contains(.frameRateAboveSources(fastestSource: .fps30)))
        #expect(fast.contains(.h264HighFrameRate))
        #expect(!fast.contains(.frameRateMismatch))
        #expect(ExportSettings(preset: .hevcSDR, frameRate: .fps25).warnings(for: seq, project: project)
            .contains(.frameRateMismatch))
        var small = seq
        small.settings.width = 1280
        small.settings.height = 720
        #expect(ExportSettings(preset: .hevcSDR, size: .lines(2160)).warnings(for: small, project: project)
            .contains(.upscaled))
    }

    @Test func highFrameRatesAreStandard() {
        #expect(FrameRate.nearestStandard(to: 119.88) == .fps119_88)
        #expect(FrameRate.nearestStandard(to: 120) == .fps120)
        #expect(FrameRate.fps119_88.displayName == "119.88")
        #expect(FrameRate.fps119_88.timecodeBase == 120)
        #expect(!FrameRate.fps119_88.supportsDropFrame)
        #expect(Timecode(frame: 121, rate: .fps120).description == "00:00:01:01")
    }

    @Test func estimatedSize() {
        // 10 s of 4K30 H.264 at ~45 Mbps is roughly 56 MB.
        let seq = sequence(frames: 300)
        let bytes = ExportSettings(preset: .h264SDR).estimatedBytes(for: seq)
        #expect((45_000_000...70_000_000).contains(bytes))
        #expect(ExportSettings(preset: .proRes(for: seq)).estimatedBytes(for: seq) > bytes)
    }

    @Test func defaultFileName() {
        var seq = sequence()
        seq.name = "Final: cut/v2"
        #expect(ExportSettings.defaultFileName(for: seq, preset: .hevcHLG) == "Final- cut-v2.mov")
        seq.name = "  "
        #expect(ExportSettings.defaultFileName(for: seq, preset: .h264SDR) == "Sequence.mp4")
    }
}

@Suite("Color override")
struct ColorOverrideTests {
    @Test func overrideRoundTripsAndOldProjectsLoad() throws {
        var project = Project()
        let item = project.addMedia([makeItem("A")])[0]
        #expect(project.item(item.id)?.effectiveColor == .rec2100HLG)
        project.setColorOverride(.rec709, for: [item.id])
        #expect(project.item(item.id)?.effectiveColor == .rec709)
        let decoded = try ProjectFileCoder.decode(try ProjectFileCoder.encode(project))
        #expect(decoded.item(item.id)?.colorOverride == .rec709)
        project.setColorOverride(nil, for: [item.id])
        #expect(project.item(item.id)?.effectiveColor == .rec2100HLG)

        // Files written before the override existed have no such key.
        var json = String(bytes: try ProjectFileCoder.encode(project), encoding: .utf8) ?? ""
        json = json.replacingOccurrences(of: "\"colorOverride\" : null,", with: "")
        #expect(try ProjectFileCoder.decode(Data(json.utf8)).item(item.id)?.colorOverride == nil)
    }
}
