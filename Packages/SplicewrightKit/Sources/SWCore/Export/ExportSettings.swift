import Foundation

public enum ExportCodec: String, Sendable, Hashable, Codable, CaseIterable {
    case h264
    case hevc
    case hevc10
    case proRes422HQ
    case proRes422
    case proRes422LT
    case proRes422Proxy

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        case .hevc10: return "HEVC 10-bit"
        case .proRes422HQ: return "Apple ProRes 422 HQ"
        case .proRes422: return "Apple ProRes 422"
        case .proRes422LT: return "Apple ProRes 422 LT"
        case .proRes422Proxy: return "Apple ProRes 422 Proxy"
        }
    }

    public var isProRes: Bool {
        switch self {
        case .proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy: return true
        case .h264, .hevc, .hevc10: return false
        }
    }

    public var bitDepth: Int {
        switch self {
        case .h264, .hevc: return 8
        case .hevc10, .proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy: return 10
        }
    }

    /// 8-bit codecs can't carry HDR without banding; Splicewright doesn't offer it.
    public var supportsHDR: Bool { bitDepth >= 10 }

    /// Bitrate-controlled codecs; ProRes has a fixed data rate per resolution.
    public var usesBitRate: Bool { !isProRes }

    /// Apple's target data rate at 1920×1080, 29.97 fps (ProRes only).
    var proResMegabitsAt1080p30: Double {
        switch self {
        case .proRes422HQ: return 220
        case .proRes422: return 147
        case .proRes422LT: return 102
        case .proRes422Proxy: return 45
        case .h264, .hevc, .hevc10: return 0
        }
    }
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

/// Output frame size: the sequence's, or scaled so the short side has `lines` pixels.
public enum ExportSize: Sendable, Hashable, Codable {
    case matchSequence
    case lines(Int)

    public static let hd1080 = ExportSize.lines(1080)
    public static let presets: [ExportSize] = [2160, 1440, 1080, 720, 540, 480].map { .lines($0) }

    public var displayName: String {
        switch self {
        case .matchSequence: return "Match Sequence"
        case .lines(2160): return "2160p (4K UHD)"
        case .lines(1440): return "1440p"
        case .lines(let lines): return "\(lines)p"
        }
    }
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

    /// ProRes in the sequence's own color space (a mastering/intermediate file).
    public static func proRes(_ codec: ExportCodec = .proRes422HQ, for sequence: EditSequence) -> ExportPreset {
        ExportPreset(name: "\(codec.displayName) · Match Sequence", codec: codec, container: .mov,
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
        [matchSequence(sequence), .h264SDR, .hevcSDR, .hevcHLG, .hevcPQ]
            + [ExportCodec.proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy].map { proRes($0, for: sequence) }
    }
}

public enum ExportValidationError: Error, Equatable, Sendable {
    case hdrNeedsTenBit
    case proResNeedsQuickTime
    case pcmNeedsQuickTime
    case missingInOut
    case emptyRange
    case invalidBitRate

    public var message: String {
        switch self {
        case .hdrNeedsTenBit: return "HDR export needs HEVC 10-bit or ProRes; H.264 and 8-bit HEVC are SDR only."
        case .proResNeedsQuickTime: return "ProRes can only be written to a QuickTime (.mov) file."
        case .pcmNeedsQuickTime: return "Uncompressed PCM audio needs a QuickTime (.mov) file."
        case .missingInOut: return "Set both an In and an Out point on the sequence to export that range."
        case .emptyRange: return "There's nothing to export: the sequence is empty."
        case .invalidBitRate: return "Enter a bitrate between 1 and 800 Mbps."
        }
    }
}

/// Things that are allowed but probably not what the user wants.
public enum ExportWarning: Hashable, Sendable {
    /// The export rate is higher than every source clip's, so frames repeat.
    case frameRateAboveSources(fastestSource: FrameRate)
    /// The export rate isn't a whole multiple or divisor of the sequence rate, so motion judders.
    case frameRateMismatch
    /// H.264 at 4K above 60 fps is beyond many encoders and players.
    case h264HighFrameRate
    case upscaled

    public var message: String {
        switch self {
        case .frameRateAboveSources(let fastest):
            return "Frames will repeat: the fastest clip is \(fastest.displayName) fps. " +
                "Shoot at the export rate (e.g. 120 fps) for smoother motion."
        case .frameRateMismatch:
            return "The export rate doesn't divide evenly into the sequence rate, so motion may judder."
        case .h264HighFrameRate:
            return "H.264 at 4K above 60 fps may not encode or play everywhere; HEVC is safer."
        case .upscaled:
            return "This is larger than the sequence, so the picture is upscaled."
        }
    }
}

/// Everything an export needs besides the sequence itself.
public struct ExportSettings: Sendable, Hashable, Codable {
    public var preset: ExportPreset
    public var range: ExportRange
    public var size: ExportSize
    public var quality: ExportQuality
    /// The output frame rate; nil matches the sequence.
    public var frameRate: FrameRate?
    /// A target bitrate in megabits per second that replaces `quality` (H.264/HEVC only).
    public var customMegabits: Double?
    /// The caption track drawn into the picture, or nil for none.
    public var burnInCaptions: UUID?
    /// The caption track written next to the video as a file, or nil for none.
    public var sidecarCaptions: UUID?
    /// The sidecar file's format (nil is SubRip).
    public var sidecarFormat: SubRip.Format?
    /// Writes markers as chapter marks in the file (nil means yes when there are markers).
    public var embedsChapters: Bool?
    /// Normalizes the audio to this loudness (nil leaves it as mixed).
    public var loudness: LoudnessTarget?

    public static let customMegabitRange: ClosedRange<Double> = 1...800

    public init(preset: ExportPreset, range: ExportRange = .entireSequence, size: ExportSize = .matchSequence,
                quality: ExportQuality = .standard, frameRate: FrameRate? = nil, customMegabits: Double? = nil) {
        self.preset = preset
        self.range = range
        self.size = size
        self.quality = quality
        self.frameRate = frameRate
        self.customMegabits = customMegabits
    }

    /// The sequence as it's rendered: only the burned-in caption track is drawn.
    public func preparedSequence(_ sequence: EditSequence) -> EditSequence {
        var prepared = sequence
        for index in prepared.captionTracks.indices {
            prepared.captionTracks[index].isOutputEnabled = prepared.captionTracks[index].id == burnInCaptions
        }
        return prepared
    }

    /// The sidecar caption file's contents, timed to the exported range, or nil when none is wanted.
    public func sidecarText(for sequence: EditSequence) -> String? {
        guard let id = sidecarCaptions, let track = sequence.captionTrack(id) else { return nil }
        // Times are written in seconds, so the export frame rate doesn't matter.
        return SubRip.write(track.captions, rate: sequence.rate, range: frameRange(for: sequence),
                            format: sidecarFormat ?? .srt)
    }

    /// Chapter marks for the exported file, timed from the start of the exported range.
    public func chapters(for sequence: EditSequence) -> [Chapters.Chapter] {
        guard embedsChapters ?? true else { return [] }
        return Chapters.chapters(from: sequence.markers, rate: sequence.rate, range: frameRange(for: sequence))
    }

    /// Where the sidecar goes: beside the video, with the same name.
    public func sidecarURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension((sidecarFormat ?? .srt).fileExtension)
    }

    public func outputRate(for sequence: EditSequence) -> FrameRate {
        frameRate ?? sequence.rate
    }

    public func validate(for sequence: EditSequence) -> [ExportValidationError] {
        var errors: [ExportValidationError] = []
        if preset.colorSpace.isHDR && !preset.codec.supportsHDR { errors.append(.hdrNeedsTenBit) }
        if preset.codec.isProRes && preset.container != .mov { errors.append(.proResNeedsQuickTime) }
        if let custom = customMegabits, preset.codec.usesBitRate, !(Self.customMegabitRange ~= custom) {
            errors.append(.invalidBitRate)
        }
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

    /// Output frame size: the sequence size, or scaled so the short side has the preset's line
    /// count (1080p of a 4K sequence is 1920×1080; of a vertical one, 1080×1920). Dimensions are
    /// even, as encoders require.
    public func outputSize(for sequence: EditSequence) -> (width: Int, height: Int) {
        let width = Double(sequence.settings.width)
        let height = Double(sequence.settings.height)
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        guard case .lines(let lines) = size, lines > 0 else { return (even(width), even(height)) }
        let scale = Double(lines) / min(width, height)
        return (even(width * scale), even(height * scale))
    }

    public func warnings(for sequence: EditSequence, project: Project) -> [ExportWarning] {
        var warnings: [ExportWarning] = []
        let rate = outputRate(for: sequence)
        let frames = frameRange(for: sequence)
        let sourceRates = sequence.videoTracks.flatMap(\.clips)
            .filter { clip in frames.map { clip.range.overlaps($0) } ?? true }
            .compactMap { project.item($0.mediaID)?.info.video?.frameRate }
        if let fastest = sourceRates.max(by: { $0.framesPerSecond < $1.framesPerSecond }),
           rate.framesPerSecond > fastest.framesPerSecond * 1.01 {
            warnings.append(.frameRateAboveSources(fastestSource: fastest))
        }
        let ratio = max(rate.framesPerSecond, sequence.rate.framesPerSecond)
            / min(rate.framesPerSecond, sequence.rate.framesPerSecond)
        if abs(ratio - ratio.rounded()) > 0.01 { warnings.append(.frameRateMismatch) }
        let output = outputSize(for: sequence)
        if preset.codec == .h264, rate.framesPerSecond > 61, min(output.width, output.height) > 1440 {
            warnings.append(.h264HighFrameRate)
        }
        if output.width * output.height > sequence.settings.width * sequence.settings.height {
            warnings.append(.upscaled)
        }
        return warnings
    }

    /// Average video bitrate in bits per second (nil for ProRes).
    public func bitRate(width: Int, height: Int, fps: Double) -> Int? {
        guard preset.codec.usesBitRate else { return nil }
        if let customMegabits { return Int((customMegabits * 1_000_000).rounded()) }
        // Bits per pixel per frame at Standard quality. At 3840×2160, 30 fps: H.264 ≈ 45 Mbps,
        // HEVC ≈ 30 Mbps, HEVC 10-bit ≈ 36 Mbps. Higher frame rates need less per frame.
        let bitsPerPixel: Double
        switch preset.codec {
        case .h264: bitsPerPixel = 0.18
        case .hevc: bitsPerPixel = 0.12
        case .hevc10: bitsPerPixel = 0.145
        case .proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy: return nil
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
        let fps = outputRate(for: sequence).framesPerSecond
        let videoBits: Double
        if let rate = bitRate(width: width, height: height, fps: fps) {
            videoBits = Double(rate)
        } else {
            // ProRes data rates scale with pixels × frame rate from Apple's 1080p29.97 figures.
            videoBits = preset.codec.proResMegabitsAt1080p30 * 1_000_000 * Double(width * height) / (1920 * 1080)
                * fps / 29.97
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
