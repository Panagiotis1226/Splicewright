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
        case proRes422Proxy
        case proRes422LT

        public var displayName: String {
            switch self {
            case .proRes422Proxy: return "Apple ProRes 422 Proxy"
            case .proRes422LT: return "Apple ProRes 422 LT"
            }
        }
    }

    public var resolution: Resolution
    public var codec: Codec

    public init(resolution: Resolution = .p1080, codec: Codec = .proRes422Proxy) {
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
        return "\(size)-\(codec == .proRes422Proxy ? "apco" : "apcs")"
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
