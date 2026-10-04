import Foundation
import Testing
@testable import SWCore

@Suite("Media metadata")
struct MediaMetadataTests {
    @Test func fourCC() {
        #expect(FourCC.string(from: 0x6876_6331) == "hvc1")
        #expect(FourCC.string(from: 0x6170_6368) == "apch")
        #expect(FourCC.string(from: 0x0000_0001) == "0x00000001")
    }

    @Test func codecFamilies() {
        #expect(VideoCodec(rawValue: "avc1").family == .h264)
        #expect(VideoCodec(rawValue: "hev1").family == .hevc)
        #expect(VideoCodec(rawValue: "dvh1").family == .hevc)
        #expect(VideoCodec(rawValue: "apcn").displayName == "ProRes 422")
        #expect(!VideoCodec(rawValue: "vp09").isSupportedForEditing)
        #expect(VideoCodec(rawValue: "vp09").displayName == "VP09")
    }

    @Test func hevcMain10Record() throws {
        var record = [UInt8](repeating: 0, count: 23)
        record[0] = 1
        record[1] = 0x02          // profile_space 0, tier 0, profile_idc 2 (Main 10)
        record[16] = 0xFC | 0x01  // chroma_format_idc 1 (4:2:0)
        record[17] = 0xF8 | 0x02  // bit_depth_luma_minus8 = 2
        let config = try #require(CodecConfigurationParser.parseHEVC(record))
        #expect(config.profileIDC == 2)
        #expect(config.bitDepth == 10)
        #expect(config.chroma == .yuv420)
        #expect(CodecConfigurationParser.parseHEVC([1, 2, 3]) == nil)
    }

    @Test func avcHighProfileRecord() throws {
        // version, profile 100 (High), compat, level, lengthSize, 1 SPS (len 2), 1 PPS (len 1), ext.
        let record: [UInt8] = [1, 100, 0, 51, 0xFF, 0xE1, 0, 2, 0x67, 0x64, 1, 0, 1, 0x68,
                               0xFC | 1, 0xF8 | 0, 0xF8 | 0, 0]
        let config = try #require(CodecConfigurationParser.parseAVC(record))
        #expect(config.profileIDC == 100)
        #expect(config.bitDepth == 8)
        #expect(config.chroma == .yuv420)
    }

    @Test func avcMainProfileImpliesEightBit() throws {
        let record: [UInt8] = [1, 77, 0, 40, 0xFF, 0xE1, 0, 1, 0x67, 1, 0, 1, 0x68]
        let config = try #require(CodecConfigurationParser.parseAVC(record))
        #expect(config.bitDepth == 8)
        let truncatedHigh10: [UInt8] = [1, 110, 0, 51, 0xFF, 0xE1, 0, 9]
        #expect(CodecConfigurationParser.parseAVC(truncatedHigh10)?.bitDepth == 10)
    }

    @Test func colorDescriptions() {
        #expect(ColorDescription.rec2100HLG.dynamicRange == .hlg)
        #expect(ColorDescription.rec2100PQ.displayName == "Rec.2100 PQ")
        #expect(ColorDescription.rec709.displayName == "Rec.709")
        #expect(ColorDescription.untagged.displayName == "Untagged")
        #expect(ColorDescription.untagged.resolved(forHeight: 2160) == .rec709)
        #expect(ColorDescription.untagged.resolved(forHeight: 480).matrix == .bt601)
    }

    @Test func resolutionNames() {
        func video(_ w: Int, _ h: Int) -> VideoStreamInfo {
            VideoStreamInfo(codec: .h264, width: w, height: h, frameRate: .fps30, nominalFPS: 30,
                            bitDepth: 8, color: .rec709)
        }
        #expect(video(3840, 2160).resolutionName == "UHD 4K")
        #expect(video(2160, 3840).resolutionName == "UHD 4K")
        #expect(video(4096, 2160).resolutionName == "DCI 4K")
        #expect(video(1920, 1080).resolutionName == "1080p")
        #expect(video(1440, 1080).resolutionName == "1440×1080")
    }

    @Test func warnings() {
        var info = makeItem("A").info
        #expect(MediaSupport.warnings(for: info).isEmpty)
        info.video?.isVariableFrameRate = true
        info.video?.hasDolbyVisionMetadata = true
        #expect(MediaSupport.warnings(for: info) == [.variableFrameRate, .dolbyVisionReadAsHLG])
        info.video = VideoStreamInfo(codec: VideoCodec(rawValue: "vp09"), width: 1920, height: 1080,
                                     frameRate: .fps30, nominalFPS: 30, bitDepth: 8, color: .untagged)
        let blocking = MediaSupport.warnings(for: info).filter(\.isBlocking)
        #expect(blocking == [.unsupportedVideoCodec("VP09")])
        let empty = MediaInfo(container: .mpeg4, duration: .zero, video: nil, audio: [])
        #expect(MediaSupport.warnings(for: empty) == [.noMediaStreams])
    }

    @Test func durationTimecodeAndAudioSummary() {
        // Drop-frame timecode matches wall-clock time exactly every ten minutes.
        let info = makeItem("A", seconds: 600, rate: .fps29_97).info
        #expect(info.durationTimecode == "00;10;00;00")
        #expect(info.audioSummary == "AAC 48 kHz Stereo")
    }

    @Test func importPolicy() {
        #expect(ImportPolicy.isImportable(URL(fileURLWithPath: "/a/clip.MOV")))
        #expect(ImportPolicy.isImportable(URL(fileURLWithPath: "/a/clip.mp4")))
        #expect(ImportPolicy.isImportable(URL(fileURLWithPath: "/a/voice.wav")))
        #expect(!ImportPolicy.isImportable(URL(fileURLWithPath: "/a/._clip.mov")))
        #expect(!ImportPolicy.isImportable(URL(fileURLWithPath: "/a/clip.mkv")))
        for still in ["logo.PNG", "photo.jpg", "IMG_0001.HEIC", "scan.tiff"] {
            #expect(ImportPolicy.isImportable(URL(fileURLWithPath: "/a/\(still)")), "\(still)")
            #expect(ContainerFormat(fileExtension: (still as NSString).pathExtension) == .image)
        }
    }

    @Test func stillsArePlacedForFiveSecondsAndStretchFarther() {
        let picture = VideoStreamInfo(codec: VideoCodec(rawValue: "PNG"), width: 1200, height: 800, frameRate: nil,
                                      nominalFPS: 0, bitDepth: 8, color: .rec709)
        let still = MediaInfo(container: .image, duration: MediaInfo.stillDuration, video: picture, audio: [])
        #expect(still.isStill && still.placementDuration == RationalTime(value: 5, timescale: 1))
        #expect(MediaSupport.warnings(for: still).isEmpty, "an image isn't an unsupported video codec")
        #expect(still.duration.seconds == 3600, "trims can stretch a still far past its first five seconds")
        let movie = MediaInfo(container: .quickTime, duration: RationalTime(value: 12, timescale: 1), video: picture,
                              audio: [])
        #expect(!movie.isStill && movie.placementDuration == movie.duration)
        let range = SourceMarks.empty.range(duration: still.placementDuration, rate: still.displayFrameRate)
        #expect(range.end.seconds == 5)
    }
}

@Suite("Waveforms")
struct WaveformTests {
    @Test func accumulatesPerChannelPeaks() {
        var accumulator = PeakAccumulator(channelCount: 2, sampleRate: 8, samplesPerBucket: 2)
        // Frames: (L, R) = (0.5, -1), (-0.25, 0.1), (0.1, 0.2), (0, 0), (1.5, 0)
        accumulator.append(interleaved: [0.5, -1, -0.25, 0.1, 0.1, 0.2])
        accumulator.append(interleaved: [0, 0, 1.5, 0])
        let peaks = accumulator.finish()
        #expect(peaks.bucketCount == 3)
        #expect([UInt8](peaks.channels[0]) == [128, 26, 255])
        #expect([UInt8](peaks.channels[1]) == [255, 51, 0])
        #expect(peaks.peak(from: 0, to: 0.25) == 1)
        #expect(peaks.peak(from: 0.25, to: 0.5) == Float(51) / 255)
    }

    @Test func bucketSize() {
        #expect(WaveformPeaks.bucketSize(forSampleRate: 48_000) == 240)
        #expect(WaveformPeaks.bucketSize(forSampleRate: 100) == 1)
    }

    @Test func stableHashIsDeterministic() {
        #expect(StableHash.hex("") == "cbf29ce484222325")
        #expect(StableHash.hex("a") == "af63dc4c8601ec8c")
        #expect(StableHash.hex("clip.mov") == StableHash.hex("clip.mov"))
    }
}

@Suite("Key map")
struct KeyMapTests {
    @Test func premiereDefaults() {
        #expect(KeyMap.action(for: KeyInput(.space)) == .togglePlay)
        #expect(KeyMap.action(for: .character("l")) == .shuttleForward)
        #expect(KeyMap.action(for: .character("J")) == .shuttleReverse)
        #expect(KeyMap.action(for: .character("i")) == .markIn)
        #expect(KeyMap.action(for: .character("I", .shift)) == .goToIn)
        #expect(KeyMap.action(for: .character("o", .option)) == .clearOut)
        #expect(KeyMap.action(for: .character("x", .option)) == .clearInAndOut)
        #expect(KeyMap.action(for: KeyInput(.rightArrow, .shift)) == .stepForward(frames: 5))
        #expect(KeyMap.action(for: .character("c")) == .selectTool(.razor))
        #expect(KeyMap.action(for: .character("v")) == .selectTool(.selection))
    }

    @Test func timelineShortcuts() {
        #expect(KeyMap.action(for: .character(",")) == .insertEdit)
        #expect(KeyMap.action(for: .character(".")) == .overwriteEdit)
        #expect(KeyMap.action(for: .character(";")) == .liftEdit)
        #expect(KeyMap.action(for: .character("'")) == .extractEdit)
        #expect(KeyMap.action(for: KeyInput(.delete)) == .deleteSelection)
        #expect(KeyMap.action(for: KeyInput(.delete, .shift)) == .rippleDelete)
        #expect(KeyMap.action(for: KeyInput(.delete, .option)) == .rippleDelete)
        #expect(KeyMap.action(for: KeyInput(.upArrow)) == .previousEditPoint)
        #expect(KeyMap.action(for: KeyInput(.downArrow)) == .nextEditPoint)
        #expect(KeyMap.action(for: .character("=")) == .zoomIn)
        #expect(KeyMap.action(for: .character("-")) == .zoomOut)
        #expect(KeyMap.action(for: .character("\\")) == .zoomToFit)
        #expect(KeyMap.action(for: .character("s")) == .toggleSnapping)
    }

    @Test func commandCombosGoToMenus() {
        #expect(KeyMap.action(for: .character("i", .command)) == nil)
        #expect(KeyMap.action(for: .character("c", .control)) == nil)
        #expect(KeyMap.action(for: .character("q")) == nil)
    }

    @Test func toolShortcutsAreUnique() {
        let shortcuts = EditTool.allCases.map(\.shortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test func shuttleRates() {
        #expect(Shuttle.rate(afterForwardFrom: 0) == 1)
        #expect(Shuttle.rate(afterForwardFrom: 1) == 2)
        #expect(Shuttle.rate(afterForwardFrom: 8) == 8)
        #expect(Shuttle.rate(afterForwardFrom: -2) == 1)
        #expect(Shuttle.rate(afterReverseFrom: 0) == -1)
        #expect(Shuttle.rate(afterReverseFrom: -4) == -8)
    }
}
