import Foundation

/// Converts a big-endian four-character code (as used by CoreMedia) to text, e.g. 'hvc1'.
public enum FourCC {
    public static func string(from code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        guard printable, let text = String(bytes: bytes, encoding: .ascii) else {
            return String(format: "0x%08X", code)
        }
        return text
    }
}

/// A video codec, identified by its sample-description four-character code.
public struct VideoCodec: RawRepresentable, Sendable, Hashable, Codable {
    public enum Family: String, Sendable {
        case h264, hevc, proRes, other
    }

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let h264 = VideoCodec(rawValue: "avc1")
    public static let hevc = VideoCodec(rawValue: "hvc1")
    public static let hevcInBand = VideoCodec(rawValue: "hev1")
    public static let dolbyVisionHEVC = VideoCodec(rawValue: "dvh1")
    public static let dolbyVisionHEVCInBand = VideoCodec(rawValue: "dvhe")
    public static let proRes422Proxy = VideoCodec(rawValue: "apco")
    public static let proRes422LT = VideoCodec(rawValue: "apcs")
    public static let proRes422 = VideoCodec(rawValue: "apcn")
    public static let proRes422HQ = VideoCodec(rawValue: "apch")
    public static let proRes4444 = VideoCodec(rawValue: "ap4h")
    public static let proRes4444XQ = VideoCodec(rawValue: "ap4x")

    public var family: Family {
        switch rawValue {
        case "avc1", "avc3": return .h264
        case "hvc1", "hev1", "dvh1", "dvhe": return .hevc
        case "apco", "apcs", "apcn", "apch", "ap4h", "ap4x": return .proRes
        default: return .other
        }
    }

    public var displayName: String {
        switch rawValue {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "dvh1", "dvhe": return "HEVC (Dolby Vision)"
        case "apco": return "ProRes 422 Proxy"
        case "apcs": return "ProRes 422 LT"
        case "apcn": return "ProRes 422"
        case "apch": return "ProRes 422 HQ"
        case "ap4h": return "ProRes 4444"
        case "ap4x": return "ProRes 4444 XQ"
        default: return rawValue.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    /// Codecs Splicewright v1 edits natively (hardware decode on Apple silicon).
    public var isSupportedForEditing: Bool { family != .other }
}

public struct AudioCodec: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let aac = AudioCodec(rawValue: "aac ")
    public static let linearPCM = AudioCodec(rawValue: "lpcm")
    public static let appleLossless = AudioCodec(rawValue: "alac")

    public var displayName: String {
        switch rawValue {
        case "aac ", "aach", "aacl": return "AAC"
        case "lpcm": return "PCM"
        case "alac": return "Apple Lossless"
        case ".mp3": return "MP3"
        case "ac-3": return "AC-3"
        case "ec-3": return "E-AC-3"
        default: return rawValue.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }
}

public enum ContainerFormat: String, Sendable, Hashable, Codable {
    case quickTime = "mov"
    case mpeg4 = "mp4"
    case appleM4V = "m4v"
    case audioM4A = "m4a"
    case wave = "wav"
    case aiff
    case coreAudio = "caf"
    case mp3
    case unknown

    public init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "mov", "qt": self = .quickTime
        case "mp4": self = .mpeg4
        case "m4v": self = .appleM4V
        case "m4a": self = .audioM4A
        case "wav", "wave": self = .wave
        case "aif", "aiff", "aifc": self = .aiff
        case "caf": self = .coreAudio
        case "mp3": self = .mp3
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .quickTime: return "QuickTime (.mov)"
        case .mpeg4: return "MPEG-4 (.mp4)"
        case .appleM4V: return "MPEG-4 (.m4v)"
        case .audioM4A: return "MPEG-4 Audio (.m4a)"
        case .wave: return "WAVE"
        case .aiff: return "AIFF"
        case .coreAudio: return "Core Audio (.caf)"
        case .mp3: return "MP3"
        case .unknown: return "Unknown"
        }
    }
}
