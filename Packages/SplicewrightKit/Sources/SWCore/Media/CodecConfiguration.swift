import Foundation

public enum ChromaSubsampling: String, Sendable, Hashable, Codable {
    case monochrome = "4:0:0"
    case yuv420 = "4:2:0"
    case yuv422 = "4:2:2"
    case yuv444 = "4:4:4"

    init?(chromaFormatIDC: UInt8) {
        switch chromaFormatIDC {
        case 0: self = .monochrome
        case 1: self = .yuv420
        case 2: self = .yuv422
        case 3: self = .yuv444
        default: return nil
        }
    }
}

/// Facts about a stream that are only available from its decoder configuration record.
public struct DecoderConfiguration: Sendable, Hashable {
    public var profileIDC: UInt8
    public var bitDepth: Int?
    public var chroma: ChromaSubsampling?

    public init(profileIDC: UInt8, bitDepth: Int?, chroma: ChromaSubsampling?) {
        self.profileIDC = profileIDC
        self.bitDepth = bitDepth
        self.chroma = chroma
    }
}

/// Parses `hvcC` / `avcC` decoder configuration records (ISO/IEC 14496-15),
/// which is the reliable place to learn an H.264/HEVC stream's bit depth.
public enum CodecConfigurationParser {
    /// HEVCDecoderConfigurationRecord. Layout (bytes): 0 version, 1 profile space/tier/idc,
    /// 2-5 compat flags, 6-11 constraint flags, 12 level, 13-14 segmentation, 15 parallelism,
    /// 16 chroma_format_idc (low 2 bits), 17 bit_depth_luma_minus8 (low 3 bits), ...
    public static func parseHEVC(_ record: [UInt8]) -> DecoderConfiguration? {
        guard record.count >= 23, record[0] == 1 else { return nil }
        let profile = record[1] & 0x1F
        let chroma = ChromaSubsampling(chromaFormatIDC: record[16] & 0x03)
        let bitDepth = Int(record[17] & 0x07) + 8
        return DecoderConfiguration(profileIDC: profile, bitDepth: bitDepth, chroma: chroma)
    }

    /// AVCDecoderConfigurationRecord. Bit depth is only stored explicitly for High
    /// profiles, after the SPS/PPS arrays; otherwise it is implied by the profile.
    public static func parseAVC(_ record: [UInt8]) -> DecoderConfiguration? {
        guard record.count >= 7, record[0] == 1 else { return nil }
        let profile = record[1]
        var index = 5
        let spsCount = Int(record[index] & 0x1F)
        index += 1
        for _ in 0..<spsCount {
            guard let length = readLength(record, at: index) else { return fallbackAVC(profile) }
            index += 2 + length
        }
        guard index < record.count else { return fallbackAVC(profile) }
        let ppsCount = Int(record[index])
        index += 1
        for _ in 0..<ppsCount {
            guard let length = readLength(record, at: index) else { return fallbackAVC(profile) }
            index += 2 + length
        }
        let highProfiles: Set<UInt8> = [100, 110, 122, 144, 244]
        guard highProfiles.contains(profile), index + 3 < record.count else { return fallbackAVC(profile) }
        let chroma = ChromaSubsampling(chromaFormatIDC: record[index] & 0x03)
        let bitDepth = Int(record[index + 1] & 0x07) + 8
        return DecoderConfiguration(profileIDC: profile, bitDepth: bitDepth, chroma: chroma)
    }

    private static func readLength(_ record: [UInt8], at index: Int) -> Int? {
        guard index + 1 < record.count else { return nil }
        let length = Int(record[index]) << 8 | Int(record[index + 1])
        return index + 2 + length <= record.count ? length : nil
    }

    private static func fallbackAVC(_ profile: UInt8) -> DecoderConfiguration {
        // High 10 (110), High 4:2:2 (122) and High 4:4:4 (244) default to 10-bit.
        let tenBit: Set<UInt8> = [110, 122, 244]
        return DecoderConfiguration(profileIDC: profile, bitDepth: tenBit.contains(profile) ? 10 : 8, chroma: nil)
    }
}
