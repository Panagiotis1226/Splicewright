import Foundation

public enum ExportCodec: String, Sendable, Hashable, Codable, CaseIterable {
    case h264
    case hevc
    case hevc10
    case proRes422HQ

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        case .hevc10: return "HEVC 10-bit"
        case .proRes422HQ: return "Apple ProRes 422 HQ"
        }
    }

    public var bitDepth: Int {
        switch self {
        case .h264, .hevc: return 8
        case .hevc10, .proRes422HQ: return 10
        }
    }

    /// 8-bit codecs can't carry HDR without banding; Splicewright doesn't offer it.
    public var supportsHDR: Bool { bitDepth >= 10 }

    /// Bitrate-controlled codecs; ProRes has a fixed data rate per resolution.
    public var usesBitRate: Bool { self != .proRes422HQ }
}

public enum ExportContainer: String, Sendable, Hashable, Codable, CaseIterable {
    case mp4, mov

    public var fileExtension: String { rawValue }
    public var displayName: String { self == .mp4 ? "MPEG-4 (.mp4)" : "QuickTime (.mov)" }
}

public enum ExportAudioCodec: String, Sendable, Hashable, Codable {
    case aac
    case pcm24

    public var displayName: String { self == .aac ? "AAC 320 kbps" : "Linear PCM 24-bit" }
}

public enum ExportQuality: String, Sendable, Hashable, Codable, CaseIterable {
    case standard, high, maximum

    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .maximum: return "Maximum"
        }
    }

    var multiplier: Double {
        switch self {
        case .standard: return 1
        case .high: return 1.6
        case .maximum: return 2.5
        }
    }
}

public enum ExportRange: String, Sendable, Hashable, Codable {
    case entireSequence, inToOut
}

public enum ExportSize: String, Sendable, Hashable, Codable {
    case matchSequence, hd1080

    public var displayName: String { self == .matchSequence ? "Match Sequence" : "1080p" }
}

/// What to encode: codec, container, color space and audio.
public struct ExportPreset: Sendable, Hashable, Codable, Identifiable {
    public var name: String
    public var codec: ExportCodec
    public var container: ExportContainer
    public var colorSpace: SequenceColorSpace
    public var audio: ExportAudioCodec

    public var id: String { name }

    public init(name: String, codec: ExportCodec, container: ExportContainer, colorSpace: SequenceColorSpace,
                audio: ExportAudioCodec) {
        self.name = name
        self.codec = codec
        self.container = container
        self.colorSpace = colorSpace
        self.audio = audio
    }

    public static let h264SDR = ExportPreset(name: "H.264 · SDR (Rec.709)", codec: .h264, container: .mp4,
                                             colorSpace: .rec709, audio: .aac)
    public static let hevcSDR = ExportPreset(name: "HEVC · SDR (Rec.709)", codec: .hevc, container: .mp4,
                                             colorSpace: .rec709, audio: .aac)
    public static let hevcHLG = ExportPreset(name: "HEVC 10-bit · HDR HLG", codec: .hevc10, container: .mov,
                                             colorSpace: .rec2100HLG, audio: .aac)
    public static let hevcPQ = ExportPreset(name: "HEVC 10-bit · HDR10 (PQ)", codec: .hevc10, container: .mp4,
                                            colorSpace: .rec2100PQ, audio: .aac)

    /// ProRes 422 HQ in the sequence's own color space (a mastering/intermediate file).
    public static func proRes(for sequence: EditSequence) -> ExportPreset {
        ExportPreset(name: "Apple ProRes 422 HQ · Match Sequence", codec: .proRes422HQ, container: .mov,
                     colorSpace: sequence.settings.colorSpace, audio: .pcm24)
    }

    /// HEVC 10-bit for HDR sequences, H.264 for SDR ones.
    public static func matchSequence(_ sequence: EditSequence) -> ExportPreset {
        let space = sequence.settings.colorSpace
        return ExportPreset(name: "Match Sequence (\(space.isHDR ? "HEVC 10-bit" : "H.264"))",
                            codec: space.isHDR ? .hevc10 : .h264, container: space == .rec2100HLG ? .mov : .mp4,
                            colorSpace: space, audio: .aac)
    }

    public static func builtIn(for sequence: EditSequence) -> [ExportPreset] {
        [matchSequence(sequence), .h264SDR, .hevcSDR, .hevcHLG, .hevcPQ, proRes(for: sequence)]
    }
}

public enum ExportValidationError: Error, Equatable, Sendable {
    case hdrNeedsTenBit
    case proResNeedsQuickTime
    case pcmNeedsQuickTime
    case missingInOut
    case emptyRange

    public var message: String {
        switch self {
        case .hdrNeedsTenBit: return "HDR export needs HEVC 10-bit or ProRes; H.264 and 8-bit HEVC are SDR only."
        case .proResNeedsQuickTime: return "ProRes can only be written to a QuickTime (.mov) file."
        case .pcmNeedsQuickTime: return "Uncompressed PCM audio needs a QuickTime (.mov) file."
        case .missingInOut: return "Set both an In and an Out point on the sequence to export that range."
        case .emptyRange: return "There's nothing to export: the sequence is empty."
        }
    }
}

/// Everything an export needs besides the sequence itself.
public struct ExportSettings: Sendable, Hashable, Codable {
    public var preset: ExportPreset
    public var range: ExportRange
    public var size: ExportSize
    public var quality: ExportQuality

    public init(preset: ExportPreset, range: ExportRange = .entireSequence, size: ExportSize = .matchSequence,
                quality: ExportQuality = .standard) {
        self.preset = preset
        self.range = range
        self.size = size
        self.quality = quality
    }

    public func validate(for sequence: EditSequence) -> [ExportValidationError] {
        var errors: [ExportValidationError] = []
        if preset.colorSpace.isHDR && !preset.codec.supportsHDR { errors.append(.hdrNeedsTenBit) }
        if preset.codec == .proRes422HQ && preset.container != .mov { errors.append(.proResNeedsQuickTime) }
        if preset.audio == .pcm24 && preset.container != .mov { errors.append(.pcmNeedsQuickTime) }
        switch range {
        case .inToOut where sequence.marks.range == nil:
            errors.append(.missingInOut)
        default:
            if frameRange(for: sequence)?.isEmpty ?? true { errors.append(.emptyRange) }
        }
        return errors
    }

    /// The frames to export, or nil if the requested range isn't available.
    public func frameRange(for sequence: EditSequence) -> FrameRange? {
        let whole = FrameRange(start: 0, end: sequence.durationFrames)
        switch range {
        case .entireSequence:
            return whole
        case .inToOut:
            guard let marked = sequence.marks.range else { return nil }
            let clipped = FrameRange(start: max(0, marked.start), end: min(marked.end, whole.end))
            return clipped.isEmpty ? nil : clipped
        }
    }

    /// Output frame size: the sequence size, or scaled to 1080 lines (1920 wide for 16:9),
    /// never upscaled. Dimensions are even, as encoders require.
    public func outputSize(for sequence: EditSequence) -> (width: Int, height: Int) {
        let width = sequence.settings.width
        let height = sequence.settings.height
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        guard size == .hd1080 else { return (even(Double(width)), even(Double(height))) }
        let shortSide = Double(min(width, height))
        guard shortSide > 1080 else { return (even(Double(width)), even(Double(height))) }
        let scale = 1080 / shortSide
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// Average video bitrate in bits per second (nil for ProRes).
    public func bitRate(width: Int, height: Int, fps: Double) -> Int? {
        guard preset.codec.usesBitRate else { return nil }
        // Bits per pixel per frame at Standard quality. At 3840×2160, 30 fps: H.264 ≈ 45 Mbps,
        // HEVC ≈ 30 Mbps, HEVC 10-bit ≈ 36 Mbps. Higher frame rates need less per frame.
        let bitsPerPixel: Double
        switch preset.codec {
        case .h264: bitsPerPixel = 0.18
        case .hevc: bitsPerPixel = 0.12
        case .hevc10: bitsPerPixel = 0.145
        case .proRes422HQ: return nil
        }
        let frameRateFactor = fps > 30.5 ? 0.8 : 1
        let rate = Double(width * height) * max(fps, 1) * bitsPerPixel * frameRateFactor * quality.multiplier
        return Int(rate.rounded())
    }

    /// Rough output size for the Export sheet.
    public func estimatedBytes(for sequence: EditSequence) -> Int64 {
        guard let frames = frameRange(for: sequence) else { return 0 }
        let seconds = Double(frames.length) / sequence.rate.framesPerSecond
        let (width, height) = outputSize(for: sequence)
        let videoBits: Double
        if let rate = bitRate(width: width, height: height, fps: sequence.rate.framesPerSecond) {
            videoBits = Double(rate)
        } else {
            // ProRes 422 HQ is about 220 Mbps at 1080p30 and scales with pixels × frame rate.
            videoBits = 220_000_000 * Double(width * height) / (1920 * 1080) * sequence.rate.framesPerSecond / 29.97
        }
        let audioBits: Double = preset.audio == .aac ? 320_000 : 48_000 * 24 * 2
        return Int64((videoBits + audioBits) * seconds / 8)
    }

    /// A safe default file name for the sequence.
    public static func defaultFileName(for sequence: EditSequence, preset: ExportPreset) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters)
        let cleaned = sequence.name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "Sequence" : cleaned).\(preset.container.fileExtension)"
    }
}
