import Foundation

/// Export settings for where a video is going, from each platform's published upload advice as
/// of 2026: YouTube's recommended upload encoding settings (H.264 High, 4:2:0, AAC at 48 kHz,
/// its SDR and HDR bitrate tables), and the specs TikTok, Instagram, Facebook, X and LinkedIn
/// give for 1080p uploads. Each platform re-encodes what it gets, so these aim a little above
/// what it streams, at sizes it shows without rescaling.
public enum SocialDestination: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case youTube, youTubeShorts, tikTok, instagramReels, facebookReels, x, linkedIn

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .youTube: return "YouTube"
        case .youTubeShorts: return "YouTube Shorts"
        case .tikTok: return "TikTok"
        case .instagramReels: return "Instagram Reels"
        case .facebookReels: return "Facebook Reels"
        case .x: return "X"
        case .linkedIn: return "LinkedIn"
        }
    }

    /// The frame shape the platform fills, width by height (nil: it takes most shapes).
    public var aspect: (width: Int, height: Int)? {
        switch self {
        case .youTube: return (16, 9)
        case .youTubeShorts, .tikTok, .instagramReels, .facebookReels: return (9, 16)
        case .x, .linkedIn: return nil
        }
    }

    /// The largest short side worth uploading (YouTube plays 4K; the rest show 1080p at most).
    public var maxShortSide: Int { self == .youTube ? 2160 : 1080 }

    /// Longest upload, in seconds, with what the limit is (nil: none that matters).
    public var maxDuration: (seconds: Double, note: String)? {
        switch self {
        case .youTube, .facebookReels: return nil
        case .youTubeShorts: return (180, "Shorts can be up to 3 minutes")
        case .tikTok: return (3600, "TikTok takes up to 60 minutes uploaded from a computer (10 in the app)")
        case .instagramReels: return (900, "Reels can be up to 15 minutes")
        case .x: return (140, "X allows 2 minutes 20 seconds without Premium")
        case .linkedIn: return (900, "LinkedIn allows 15 minutes uploaded from a computer")
        }
    }

    /// Largest file, in bytes, with what the limit is (nil: none that matters).
    public var maxBytes: (bytes: Int64, note: String)? {
        switch self {
        case .youTube, .youTubeShorts, .facebookReels: return nil
        case .tikTok: return (4_000_000_000, "TikTok takes files up to 4 GB from a computer")
        case .instagramReels: return (4_000_000_000, "Instagram takes files up to 4 GB")
        case .x: return (512_000_000, "X takes 512 MB without Premium")
        case .linkedIn: return (5_000_000_000, "LinkedIn takes files up to 5 GB")
        }
    }

    /// AAC bitrate: YouTube asks for 384 kbps stereo, Instagram 128; the rest get 256.
    public var audioKilobits: Int {
        switch self {
        case .youTube, .youTubeShorts: return 384
        case .instagramReels: return 128
        case .tikTok, .facebookReels, .x, .linkedIn: return 256
        }
    }

    /// Video bitrate in megabits per second, for a frame `shortSide` pixels on its short side.
    public func megabits(shortSide: Int, fps: Double, hdr: Bool) -> Double {
        let high = fps > 30.5
        switch self {
        case .youTube, .youTubeShorts:
            // YouTube's table: standard / high frame rate, SDR then HDR (4K at the top of its range).
            let table: [(Int, sdr: (Double, Double), hdr: (Double, Double))] = [
                (720, (5, 7.5), (6.5, 9.5)), (1080, (8, 12), (10, 15)), (1440, (16, 24), (20, 30)),
                (2160, (45, 68), (56, 85)),
            ]
            let row = table.first { shortSide <= $0.0 } ?? table[table.count - 1]
            let pair = hdr ? row.hdr : row.sdr
            return high ? pair.1 : pair.0
        case .tikTok, .instagramReels, .x:
            return scaled(high ? 12 : 10, shortSide: shortSide)
        case .facebookReels:
            return scaled(high ? 16 : 12, shortSide: shortSide)
        case .linkedIn:
            return scaled(high ? 12 : 8, shortSide: shortSide)
        }
    }

    /// A 1080p bitrate for smaller frames, by area (no lower than 2 Mbps).
    private func scaled(_ at1080: Double, shortSide: Int) -> Double {
        let ratio = Double(min(shortSide, 1080)) / 1080
        return max(2, (at1080 * ratio * ratio * 10).rounded() / 10)
    }

    /// Export settings for this platform: H.264 SDR (YouTube keeps an HDR sequence HDR in HEVC
    /// 10-bit), no larger than the platform shows, at most 60 fps, its bitrate and audio, and
    /// loudness at -14 LUFS, where these platforms play back.
    public func settings(for sequence: EditSequence) -> ExportSettings {
        let space = sequence.settings.colorSpace
        let preset = self == .youTube && space.isHDR ? ExportPreset.matchSequence(sequence) : .h264SDR
        let shortSide = min(sequence.settings.width, sequence.settings.height)
        let size: ExportSize = shortSide > maxShortSide ? .lines(maxShortSide) : .matchSequence
        var settings = ExportSettings(preset: preset, size: size, frameRate: Self.frameRate(for: sequence.rate))
        let output = settings.outputSize(for: sequence)
        let fps = settings.outputRate(for: sequence).framesPerSecond
        settings.customMegabits = megabits(shortSide: min(output.width, output.height), fps: fps,
                                           hdr: preset.colorSpace.isHDR)
        settings.audioKilobits = audioKilobits
        settings.loudness = .streaming
        settings.destination = self
        return settings
    }

    /// The sequence rate, or half of it above 60 fps (120 → 60, 119.88 → 59.94, 100 → 50).
    static func frameRate(for rate: FrameRate) -> FrameRate? {
        guard rate.framesPerSecond > 60.5 else { return nil }
        let half = rate.framesPerSecond / 2
        return FrameRate.standard.first { abs($0.framesPerSecond - half) < 0.001 }
            ?? FrameRate(numerator: rate.numerator, denominator: rate.denominator * 2)
    }

    /// What doesn't suit the platform: the frame's shape, the length, the file size.
    public func warnings(for settings: ExportSettings, sequence: EditSequence) -> [ExportWarning] {
        var warnings: [ExportWarning] = []
        if let aspect {
            let (width, height) = settings.outputSize(for: sequence)
            let wanted = Double(aspect.width) / Double(aspect.height)
            if abs(Double(width) / Double(height) - wanted) / wanted > 0.02 {
                warnings.append(.destinationShape(self, width: width, height: height))
            }
        }
        if let limit = maxDuration, let frames = settings.frameRange(for: sequence),
           Double(frames.length) / sequence.rate.framesPerSecond > limit.seconds {
            warnings.append(.destinationTooLong(limit.note))
        }
        if let limit = maxBytes, settings.estimatedBytes(for: sequence) > limit.bytes {
            warnings.append(.destinationTooLarge(limit.note))
        }
        return warnings
    }
}
