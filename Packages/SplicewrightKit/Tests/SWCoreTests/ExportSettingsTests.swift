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

    @Test func outputSizeIsEvenAndNeverUpscaled() {
        let uhd = sequence()
        #expect(ExportSettings(preset: .h264SDR, size: .hd1080).outputSize(for: uhd) == (1920, 1080))
        #expect(ExportSettings(preset: .h264SDR).outputSize(for: uhd) == (3840, 2160))
        let vertical = sequence(width: 2160, height: 3840)
        #expect(ExportSettings(preset: .h264SDR, size: .hd1080).outputSize(for: vertical) == (1080, 1920))
        let small = sequence(width: 1280, height: 720)
        #expect(ExportSettings(preset: .h264SDR, size: .hd1080).outputSize(for: small) == (1280, 720))
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
