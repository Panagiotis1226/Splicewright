import AVFoundation
import CoreVideo
import VideoToolbox

public enum FixtureError: Error {
    case audioSetupFailed
}

/// Writes short synthetic clips so media tests need no checked-in footage.
///
/// Encoders can be missing on virtualized CI hosts; callers turn a nil result into a skip.
public enum FixtureWriter {
    /// A flat color as code values at the clip's bit depth (8-bit: 0...255, 10-bit: 0...1023).
    public struct Fill: Sendable {
        public var y: UInt16
        public var cb: UInt16
        public var cr: UInt16

        public init(y: UInt16, cb: UInt16, cr: UInt16) {
            self.y = y
            self.cb = cb
            self.cr = cr
        }

        /// Video-range neutral grey at `level` (0 = black, 1 = white).
        public static func grey(_ level: Double, tenBit: Bool) -> Fill {
            let scale = tenBit ? 4.0 : 1.0
            let y = UInt16((16 * scale + level * 219 * scale).rounded())
            let c = UInt16(128 * scale)
            return Fill(y: y, cb: c, cr: c)
        }
    }

    public struct VideoSpec {
        public var fileType: AVFileType
        public var codec: AVVideoCodecType
        public var width: Int
        public var height: Int
        public var frameDuration: CMTime
        public var frameCount: Int
        public var tenBit: Bool
        public var colorProperties: [String: String]
        public var profileLevel: String?
        /// Solid color; nil draws a changing grey ramp.
        public var fill: Fill?
    }

    public static let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "SplicewrightFixtures-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    public static let rec709: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    public static let rec2100HLG: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
    ]

    public static let rec2100PQ: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
    ]

    public static func h264SDR(fps2997 frames: Int = 30, fill: Fill? = nil) -> VideoSpec {
        VideoSpec(fileType: .mp4, codec: .h264, width: 1920, height: 1080,
                  frameDuration: CMTime(value: 1001, timescale: 30000), frameCount: frames,
                  tenBit: false, colorProperties: rec709, profileLevel: nil, fill: fill)
    }

    /// 1080p30 H.264, for sequences at 30 fps.
    public static func h264SDR30(frames: Int = 30, width: Int = 1920, height: Int = 1080, fill: Fill? = nil) -> VideoSpec {
        VideoSpec(fileType: .mov, codec: .h264, width: width, height: height,
                  frameDuration: CMTime(value: 1, timescale: 30), frameCount: frames,
                  tenBit: false, colorProperties: rec709, profileLevel: nil, fill: fill)
    }

    public static func hevcHLG(fps5994 frames: Int = 30, width: Int = 3840, height: Int = 2160,
                               fill: Fill? = nil) -> VideoSpec {
        VideoSpec(fileType: .mov, codec: .hevc, width: width, height: height,
                  frameDuration: CMTime(value: 1001, timescale: 60000), frameCount: frames,
                  tenBit: true, colorProperties: rec2100HLG,
                  profileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel as String, fill: fill)
    }

    public static func hevcPQ(frames: Int = 15, width: Int = 3840, height: Int = 2160, fill: Fill? = nil) -> VideoSpec {
        VideoSpec(fileType: .mp4, codec: .hevc, width: width, height: height,
                  frameDuration: CMTime(value: 1, timescale: 30), frameCount: frames,
                  tenBit: true, colorProperties: rec2100PQ,
                  profileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel as String, fill: fill)
    }

    public static func proRes422() -> VideoSpec {
        VideoSpec(fileType: .mov, codec: .proRes422, width: 1920, height: 1080,
                  frameDuration: CMTime(value: 1, timescale: 25), frameCount: 10,
                  tenBit: true, colorProperties: rec709, profileLevel: nil, fill: nil)
    }

    /// Writes the clip, or returns nil if this machine can't encode it.
    public static func writeVideo(_ spec: VideoSpec, name: String) async throws -> URL? {
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
            guard let pool = adaptor.pixelBufferPool,
                  let buffer = makeBuffer(pool: pool, shade: frame, fill: spec.fill, tenBit: spec.tenBit) else {
                return nil
            }
            let time = CMTimeMultiply(spec.frameDuration, multiplier: Int32(frame))
            guard adaptor.append(buffer, withPresentationTime: time) else { return nil }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }

    private static func makeBuffer(pool: CVPixelBufferPool, shade: Int, fill: Fill?, tenBit: Bool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let color = fill ?? Fill.grey(0.2 + Double(shade % 60) / 100, tenBit: tenBit)
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            for row in 0..<rows {
                let line = base.advanced(by: row * rowBytes)
                if tenBit {
                    // 10-bit codes live in the top bits of 16-bit little-endian samples.
                    let samples = line.assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width {
                        if plane == 0 {
                            samples[x] = color.y << 6
                        } else {
                            samples[2 * x] = color.cb << 6
                            samples[2 * x + 1] = color.cr << 6
                        }
                    }
                } else {
                    let samples = line.assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        if plane == 0 {
                            samples[x] = UInt8(color.y)
                        } else {
                            samples[2 * x] = UInt8(color.cb)
                            samples[2 * x + 1] = UInt8(color.cr)
                        }
                    }
                }
            }
        }
        return buffer
    }

    /// A stereo 48 kHz sine wave at the given amplitude.
    public static func writeSine(name: String, seconds: Double = 1, amplitude: Float = 0.5) throws -> URL {
        let url = directory.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw FixtureError.audioSetupFailed
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 48_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else {
            throw FixtureError.audioSetupFailed
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
