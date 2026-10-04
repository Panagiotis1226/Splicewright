import Foundation

/// Something the editor should tell the user about an imported file.
public enum MediaWarning: Sendable, Hashable {
    case unsupportedVideoCodec(String)
    case variableFrameRate
    case untaggedColor
    case dolbyVisionReadAsHLG
    case frameRateAboveSixty(Double)
    case nonStandardFrameRate(Double)
    case noMediaStreams

    public var message: String {
        switch self {
        case .unsupportedVideoCodec(let name):
            return "\(name) video isn't supported for editing. Convert to H.264, HEVC or ProRes."
        case .variableFrameRate:
            return "Variable frame rate. It will be conformed to the sequence frame rate."
        case .untaggedColor:
            return "No color tags. Interpreted as Rec.709."
        case .dolbyVisionReadAsHLG:
            return "Dolby Vision. Edited using its HLG base layer."
        case .frameRateAboveSixty(let fps):
            return String(format: "%.2f fps is above the 60 fps editing limit.", fps)
        case .nonStandardFrameRate(let fps):
            return String(format: "Non-standard frame rate (%.3f fps).", fps)
        case .noMediaStreams:
            return "No video or audio streams."
        }
    }

    /// Blocking warnings prevent the file from being imported.
    public var isBlocking: Bool {
        switch self {
        case .unsupportedVideoCodec, .noMediaStreams: return true
        default: return false
        }
    }
}

public enum MediaSupport {
    public static func warnings(for info: MediaInfo) -> [MediaWarning] {
        var warnings: [MediaWarning] = []
        if info.kind == .empty { return [.noMediaStreams] }
        // A still is drawn from the file: codecs and frame rates don't apply.
        guard let video = info.video, !info.isStill else { return warnings }

        if !video.codec.isSupportedForEditing {
            warnings.append(.unsupportedVideoCodec(video.codec.displayName))
        }
        if video.isVariableFrameRate {
            warnings.append(.variableFrameRate)
        }
        if video.color.transfer == .unknown && video.color.primaries == .unknown {
            warnings.append(.untaggedColor)
        }
        if video.hasDolbyVisionMetadata {
            warnings.append(.dolbyVisionReadAsHLG)
        }
        if video.nominalFPS > 60.5 {
            warnings.append(.frameRateAboveSixty(video.nominalFPS))
        } else if !video.isVariableFrameRate, FrameRate.nearestStandard(to: video.nominalFPS) == nil,
                  video.nominalFPS > 0 {
            warnings.append(.nonStandardFrameRate(video.nominalFPS))
        }
        return warnings
    }
}

/// Which files the importer will even try to open.
public enum ImportPolicy {
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "qt"]
    public static let audioExtensions: Set<String> = ["m4a", "wav", "wave", "aif", "aiff", "aifc", "caf", "mp3"]
    /// Stills: they go on the timeline like video clips, for any length.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp",
                                                      "gif", "webp"]

    public static func isImportable(fileExtension: String) -> Bool {
        let ext = fileExtension.lowercased()
        return videoExtensions.contains(ext) || audioExtensions.contains(ext) || imageExtensions.contains(ext)
    }

    public static func isImportable(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        return isImportable(fileExtension: url.pathExtension)
    }
}
