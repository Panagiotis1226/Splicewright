import Foundation

/// How proxies are made: a lighter copy of a clip's video for smooth editing. Export always
/// uses the original media.
public struct ProxyPreset: Sendable, Hashable, Codable {
    public enum Resolution: String, Sendable, Hashable, Codable, CaseIterable {
        /// Short side 1080 (1920×1080 for 16:9).
        case p1080
        /// Short side 720.
        case p720
        /// Half the original's size.
        case half

        public var displayName: String {
            switch self {
            case .p1080: return "1080p"
            case .p720: return "720p"
            case .half: return "Half resolution"
            }
        }
    }

    public enum Codec: String, Sendable, Hashable, Codable, CaseIterable {
        /// Small files; long-GOP, so scrubbing is slower than ProRes. 10-bit for HDR sources.
        case hevc
        /// Small files, 8-bit. HDR sources get HEVC 10-bit instead, to avoid banding.
        case h264
        /// Every frame stands alone: the smoothest scrubbing, but files about as big as phone HEVC.
        case proRes422Proxy
        case proRes422LT

        public var displayName: String {
            switch self {
            case .hevc: return "HEVC (H.265)"
            case .h264: return "H.264"
            case .proRes422Proxy: return "Apple ProRes 422 Proxy"
            case .proRes422LT: return "Apple ProRes 422 LT"
            }
        }

        public var isProRes: Bool { self == .proRes422Proxy || self == .proRes422LT }

        public var summary: String {
            switch self {
            case .hevc: return "Smallest files. Scrubbing is a little slower than ProRes."
            case .h264: return "Small files, plays anywhere. 8-bit (HDR clips use HEVC 10-bit)."
            case .proRes422Proxy: return "Smoothest scrubbing and multi-layer playback; larger files."
            case .proRes422LT: return "Higher quality ProRes; the largest proxies."
            }
        }

        /// Data rate at 1920×1080, 30 fps, in megabits per second (ProRes: Apple's published rates).
        var megabitsAt1080p30: Double {
            switch self {
            case .hevc: return 6
            case .h264: return 10
            case .proRes422Proxy: return 45
            case .proRes422LT: return 102
            }
        }
    }

    public var resolution: Resolution
    public var codec: Codec

    public init(resolution: Resolution = .p1080, codec: Codec = .hevc) {
        self.resolution = resolution
        self.codec = codec
    }

    public static let standard = ProxyPreset()

    /// A short tag for file names, e.g. "1080-apco".
    public var tag: String {
        let size: String
        switch resolution {
        case .p1080: size = "1080"
        case .p720: size = "720"
        case .half: size = "half"
        }
        let format: String
        switch codec {
        case .hevc: format = "hvc1"
        case .h264: format = "avc1"
        case .proRes422Proxy: format = "apco"
        case .proRes422LT: format = "apcs"
        }
        return "\(size)-\(format)"
    }

    /// The codec actually used for a source: H.264 can't carry HDR without banding.
    public func effectiveCodec(sourceIsHDR: Bool) -> Codec {
        codec == .h264 && sourceIsHDR ? .hevc : codec
    }

    /// Target data rate for a proxy of this size and frame rate, in bits per second.
    public func bitRate(width: Int, height: Int, fps: Double) -> Double {
        codec.megabitsAt1080p30 * 1_000_000 * Double(width * height) / (1920 * 1080) * max(fps, 1) / 30
    }

    /// Roughly how much disk an hour of proxies takes for a source this size.
    public func bytesPerHour(sourceWidth: Int, sourceHeight: Int, fps: Double) -> Int64 {
        let (width, height) = size(width: sourceWidth, height: sourceHeight)
        return Int64(bitRate(width: width, height: height, fps: fps) * 3600 / 8)
    }

    public var displayName: String { "\(resolution.displayName), \(codec.displayName)" }

    /// The proxy's encoded size for a source of `width`×`height` (encoded, before rotation):
    /// scaled so the short side fits the preset, never upscaled, with even dimensions.
    public func size(width: Int, height: Int) -> (width: Int, height: Int) {
        let width = max(2, width)
        let height = max(2, height)
        let shortSide = Double(min(width, height))
        let scale: Double
        switch resolution {
        case .p1080: scale = min(1, 1080 / shortSide)
        case .p720: scale = min(1, 720 / shortSide)
        case .half: scale = 0.5
        }
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// Whether a source this size is worth a proxy at this preset (it would be smaller).
    public func isUseful(width: Int, height: Int) -> Bool {
        let proxy = size(width: width, height: height)
        return proxy.width * proxy.height < width * height
    }
}
