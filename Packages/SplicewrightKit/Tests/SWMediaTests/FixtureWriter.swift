import AVFoundation
import CoreVideo
import VideoToolbox
import XCTest

/// Writes short synthetic clips so media tests need no checked-in footage.
///
/// Encoders can be missing on virtualized CI hosts; callers turn a nil result into a skip.
enum FixtureWriter {
    struct VideoSpec {
        var fileType: AVFileType
        var codec: AVVideoCodecType
        var width: Int
        var height: Int
        var frameDuration: CMTime
        var frameCount: Int
        var tenBit: Bool
        var colorProperties: [String: String]
        var profileLevel: String?
    }

    static let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "SplicewrightFixtures-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let rec709: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    static let rec2100HLG: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
    ]

    static let rec2100PQ: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
    ]

    static func h264SDR(fps2997 frames: Int = 30) -> VideoSpec {
        VideoSpec(fileType: .mp4, codec: .h264, width: 1920, height: 1080,
                  frameDuration: CMTime(value: 1001, timescale: 30000), frameCount: frames,
                  tenBit: false, colorProperties: rec709, profileLevel: nil)
    }

    static func hevcHLG(fps5994 frames: Int = 30) -> VideoSpec {
        VideoSpec(fileType: .mov, codec: .hevc, width: 3840, height: 2160,
                  frameDuration: CMTime(value: 1001, timescale: 60000), frameCount: frames,
                  tenBit: true, colorProperties: rec2100HLG,
                  profileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel as String)
    }

    static func hevcPQ() -> VideoSpec {
        VideoSpec(fileType: .mp4, codec: .hevc, width: 3840, height: 2160,
                  frameDuration: CMTime(value: 1, timescale: 30), frameCount: 15,
                  tenBit: true, colorProperties: rec2100PQ,
                  profileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel as String)
    }

    static func proRes422() -> VideoSpec {
        VideoSpec(fileType: .mov, codec: .proRes422, width: 1920, height: 1080,
                  frameDuration: CMTime(value: 1, timescale: 25), frameCount: 10,
                  tenBit: true, colorProperties: rec709, profileLevel: nil)
    }

    /// Writes the clip, or returns nil if this machine can't encode it.
    static func writeVideo(_ spec: VideoSpec, name: String) async throws -> URL? {
        let url = directory.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: spec.fileType)

        var compression: [String: Any] = [:]
        if let profile = spec.profileLevel { compression[AVVideoProfileLevelKey] = profile }
        var settings: [String: Any] = [
            AVVideoCodecKey: spec.codec,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height,
            AVVideoColorPropertiesKey: spec.colorProperties,
        ]
        if !compression.isEmpty { settings[AVVideoCompressionPropertiesKey] = compression }

        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        // Camera files use a timescale that represents their rate exactly (e.g. 60000 for 59.94).
        input.mediaTimeScale = spec.frameDuration.timescale
        let pixelFormat = spec.tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                      : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: spec.width,
            kCVPixelBufferHeightKey as String: spec.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<spec.frameCount {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { return nil }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool, let buffer = makeBuffer(pool: pool, shade: frame) else {
                return nil
            }
            let time = CMTimeMultiply(spec.frameDuration, multiplier: Int32(frame))
            guard adaptor.append(buffer, withPresentationTime: time) else { return nil }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }

    private static func makeBuffer(pool: CVPixelBufferPool, shade: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, plane == 0 ? Int32(0x40 + shade % 0x80) : 0x80, bytes)
        }
        return buffer
    }

    /// A stereo 48 kHz sine wave at the given amplitude.
    static func writeSine(name: String, seconds: Double = 1, amplitude: Float = 0.5) throws -> URL {
        let url = directory.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw XCTSkip("Can't create audio format")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 48_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else {
            throw XCTSkip("Can't allocate audio buffer")
        }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let value = amplitude * sin(2 * .pi * 440 * Float(frame) / 48_000)
            channels[0][frame] = value
            channels[1][frame] = value / 2
        }
        try file.write(from: buffer)
        return url
    }
}
