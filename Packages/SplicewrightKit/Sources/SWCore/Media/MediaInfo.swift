import Foundation

public struct VideoStreamInfo: Sendable, Hashable, Codable {
    public var codec: VideoCodec
    /// Display dimensions, after applying the track's rotation.
    public var width: Int
    public var height: Int
    /// Clockwise rotation from the track's preferred transform (0, 90, 180, 270).
    public var rotationDegrees: Int
    /// The matching standard rate, or a rational approximation of the nominal rate.
    public var frameRate: FrameRate?
    public var nominalFPS: Double
    public var isVariableFrameRate: Bool
    public var bitDepth: Int?
    public var chroma: ChromaSubsampling?
    public var color: ColorDescription
    public var hasDolbyVisionMetadata: Bool
    /// Bits per second, if the container reports it.
    public var estimatedBitRate: Double?

    public init(
        codec: VideoCodec, width: Int, height: Int, rotationDegrees: Int = 0,
        frameRate: FrameRate?, nominalFPS: Double, isVariableFrameRate: Bool = false,
        bitDepth: Int?, chroma: ChromaSubsampling? = nil, color: ColorDescription,
        hasDolbyVisionMetadata: Bool = false, estimatedBitRate: Double? = nil
    ) {
        self.codec = codec
        self.width = width
        self.height = height
        self.rotationDegrees = rotationDegrees
        self.frameRate = frameRate
        self.nominalFPS = nominalFPS
        self.isVariableFrameRate = isVariableFrameRate
        self.bitDepth = bitDepth
        self.chroma = chroma
        self.color = color
        self.hasDolbyVisionMetadata = hasDolbyVisionMetadata
        self.estimatedBitRate = estimatedBitRate
    }

    public var dynamicRange: DynamicRange { color.dynamicRange }

    /// "UHD 4K", "DCI 4K", "1080p", or "WxH" for anything else.
    public var resolutionName: String {
        let long = max(width, height)
        let short = min(width, height)
        switch (long, short) {
        case (3840, 2160): return "UHD 4K"
        case (4096, _) where short >= 2048 && short <= 2160: return "DCI 4K"
        case (1920, 1080): return "1080p"
        case (1280, 720): return "720p"
        default: return "\(width)×\(height)"
        }
    }
}

public struct AudioStreamInfo: Sendable, Hashable, Codable {
    public var codec: AudioCodec
    public var sampleRate: Double
    public var channelCount: Int

    public init(codec: AudioCodec, sampleRate: Double, channelCount: Int) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var channelLayoutName: String {
        switch channelCount {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channelCount) ch"
        }
    }
}

/// Everything Splicewright learns about a file when it is imported.
public struct MediaInfo: Sendable, Hashable, Codable {
    public var container: ContainerFormat
    public var duration: RationalTime
    public var video: VideoStreamInfo?
    public var audio: [AudioStreamInfo]
    public var fileSize: Int64?

    public init(container: ContainerFormat, duration: RationalTime, video: VideoStreamInfo?,
                audio: [AudioStreamInfo], fileSize: Int64? = nil) {
        self.container = container
        self.duration = duration
        self.video = video
        self.audio = audio
        self.fileSize = fileSize
    }

    public enum Kind: String, Sendable {
        case videoWithAudio, video, audio, empty
    }

    public var kind: Kind {
        switch (video != nil, !audio.isEmpty) {
        case (true, true): return .videoWithAudio
        case (true, false): return .video
        case (false, true): return .audio
        case (false, false): return .empty
        }
    }

    /// Rate used for timecode and frame stepping. Audio-only media falls back to 30 fps
    /// until a sequence supplies its own rate.
    public var displayFrameRate: FrameRate {
        video?.frameRate ?? .fps30
    }

    public var durationTimecode: String {
        let rate = displayFrameRate
        let frames = max(0, duration.frameIndex(at: rate))
        return Timecode(frame: frames, rate: rate).description
    }

    public var audioSummary: String {
        guard let first = audio.first else { return "—" }
        let kHz = first.sampleRate / 1000
        let rate = kHz.rounded() == kHz ? String(format: "%.0f kHz", kHz) : String(format: "%.1f kHz", kHz)
        let extra = audio.count > 1 ? " ×\(audio.count)" : ""
        return "\(first.codec.displayName) \(rate) \(first.channelLayoutName)\(extra)"
    }
}
