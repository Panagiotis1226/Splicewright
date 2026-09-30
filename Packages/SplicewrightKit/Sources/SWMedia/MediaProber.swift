import AVFoundation
import CoreMedia
import CoreVideo
import SWCore

public enum MediaProbeError: LocalizedError {
    case unreadable(URL)
    case noMediaStreams(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "\(url.lastPathComponent) can't be read by AVFoundation."
        case .noMediaStreams(let url): return "\(url.lastPathComponent) has no video or audio."
        }
    }
}

/// Reads codec, resolution, frame rate, bit depth and color tagging from a media file.
public struct MediaProber: Sendable {
    public init() {}

    public func probe(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (duration, isReadable) = try await asset.load(.duration, .isReadable)
        guard isReadable else { throw MediaProbeError.unreadable(url) }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else { throw MediaProbeError.noMediaStreams(url) }

        var video: VideoStreamInfo?
        if let track = videoTracks.first {
            video = try await probeVideo(track)
        }
        var audio: [AudioStreamInfo] = []
        for track in audioTracks {
            if let info = try await probeAudio(track) { audio.append(info) }
        }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        return MediaInfo(
            container: ContainerFormat(fileExtension: url.pathExtension),
            duration: RationalTime(duration),
            video: video,
            audio: audio,
            fileSize: fileSize
        )
    }

    // MARK: - Video

    func probeVideo(_ track: AVAssetTrack) async throws -> VideoStreamInfo {
        let (formatDescriptions, naturalSize, transform) =
            try await track.load(.formatDescriptions, .naturalSize, .preferredTransform)
        let (nominalFrameRate, minFrameDuration, dataRate) =
            try await track.load(.nominalFrameRate, .minFrameDuration, .estimatedDataRate)

        let description = formatDescriptions.first
        let codec = description.map { VideoCodec(rawValue: FourCC.string(from: CMFormatDescriptionGetMediaSubType($0))) }
            ?? VideoCodec(rawValue: "????")

        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let rotation = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
        let normalizedRotation = (rotation % 360 + 360) % 360

        let nominalFPS = Double(nominalFrameRate)
        let hasMinDuration = minFrameDuration.isValid && minFrameDuration.isNumeric
        let minDuration = hasMinDuration ? minFrameDuration.seconds : 0
        let isVariable = FrameRateAnalysis.isVariable(nominalFPS: nominalFPS, minFrameDurationSeconds: minDuration)
        let frameRate = hasMinDuration && !isVariable
            ? FrameRate.resolve(nominalFPS: nominalFPS, minFrameDuration: minFrameDuration.value,
                                timescale: minFrameDuration.timescale)
            : FrameRate.approximating(nominalFPS)

        let atoms = description.flatMap(Self.sampleDescriptionAtoms) ?? [:]
        let decoderConfig: DecoderConfiguration?
        switch codec.family {
        case .hevc: decoderConfig = atoms["hvcC"].flatMap { CodecConfigurationParser.parseHEVC([UInt8]($0)) }
        case .h264: decoderConfig = atoms["avcC"].flatMap { CodecConfigurationParser.parseAVC([UInt8]($0)) }
        case .proRes, .other: decoderConfig = nil
        }

        let color = description.map(Self.colorDescription) ?? .untagged
        let explicitDepth = description.flatMap {
            Self.extensionValue($0, kCMFormatDescriptionExtension_BitsPerComponent) as? Int
        }

        return VideoStreamInfo(
            codec: codec,
            width: Int(abs(displayRect.width).rounded()),
            height: Int(abs(displayRect.height).rounded()),
            rotationDegrees: normalizedRotation,
            frameRate: frameRate,
            nominalFPS: nominalFPS,
            isVariableFrameRate: isVariable,
            bitDepth: Self.bitDepth(decoderConfig: decoderConfig, explicit: explicitDepth, codec: codec, color: color),
            chroma: decoderConfig?.chroma ?? Self.impliedChroma(codec: codec),
            color: color,
            hasDolbyVisionMetadata: atoms["dvcC"] != nil || atoms["dvvC"] != nil || codec == .dolbyVisionHEVC
                || codec == .dolbyVisionHEVCInBand,
            estimatedBitRate: dataRate > 0 ? Double(dataRate) : nil
        )
    }

    static func extensionValue(_ description: CMFormatDescription, _ key: CFString) -> Any? {
        CMFormatDescriptionGetExtension(description, extensionKey: key)
    }

    /// Codec configuration boxes (`hvcC`, `avcC`, `dvcC`, ...) keyed by four-character name.
    static func sampleDescriptionAtoms(_ description: CMFormatDescription) -> [String: Data]? {
        let value = extensionValue(description, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
        guard let dictionary = value as? [String: Any] else { return nil }
        var atoms: [String: Data] = [:]
        for (key, value) in dictionary {
            if let data = value as? Data {
                atoms[key] = data
            } else if let array = value as? [Data], let first = array.first {
                atoms[key] = first
            }
        }
        return atoms
    }

    static func colorDescription(_ description: CMFormatDescription) -> ColorDescription {
        let primaries = extensionValue(description, kCMFormatDescriptionExtension_ColorPrimaries) as? String
        let transfer = extensionValue(description, kCMFormatDescriptionExtension_TransferFunction) as? String
        let matrix = extensionValue(description, kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        return ColorDescription(
            primaries: ColorTags.primaries(primaries),
            transfer: ColorTags.transfer(transfer),
            matrix: ColorTags.matrix(matrix)
        )
    }

    /// Decoder configuration is authoritative for H.264/HEVC. ProRes depth is fixed by the
    /// codec (the BitsPerComponent extension can report the decoder's working precision).
    static func bitDepth(decoderConfig: DecoderConfiguration?, explicit: Int?, codec: VideoCodec,
                         color: ColorDescription) -> Int? {
        if let depth = decoderConfig?.bitDepth { return depth }
        if codec.family == .proRes { return impliedBitDepth(codec: codec, color: color) }
        return explicit ?? impliedBitDepth(codec: codec, color: color)
    }

    static func impliedBitDepth(codec: VideoCodec, color: ColorDescription) -> Int? {
        switch codec.family {
        case .proRes: return (codec == .proRes4444 || codec == .proRes4444XQ) ? 12 : 10
        case .hevc, .h264: return color.dynamicRange.isHDR ? 10 : nil
        case .other: return nil
        }
    }

    static func impliedChroma(codec: VideoCodec) -> ChromaSubsampling? {
        switch codec.family {
        case .proRes: return (codec == .proRes4444 || codec == .proRes4444XQ) ? .yuv444 : .yuv422
        default: return nil
        }
    }

    // MARK: - Audio

    func probeAudio(_ track: AVAssetTrack) async throws -> AudioStreamInfo? {
        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let description = formatDescriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return nil
        }
        return AudioStreamInfo(
            codec: AudioCodec(rawValue: FourCC.string(from: asbd.mFormatID)),
            sampleRate: asbd.mSampleRate,
            channelCount: Int(asbd.mChannelsPerFrame)
        )
    }
}
