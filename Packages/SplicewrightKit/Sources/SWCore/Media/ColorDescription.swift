import Foundation

public enum ColorPrimaries: String, Sendable, Hashable, Codable {
    case bt709, bt2020, displayP3, dciP3, bt601NTSC, bt601PAL, unknown
}

public enum TransferFunction: String, Sendable, Hashable, Codable {
    case bt709, bt2020, sRGB, linear, hlg, pq, unknown
}

public enum YCbCrMatrix: String, Sendable, Hashable, Codable {
    case bt709, bt601, bt2020, unknown
}

public enum DynamicRange: String, Sendable, Hashable, Codable {
    case sdr, hlg, pq

    public var isHDR: Bool { self != .sdr }

    public var displayName: String {
        switch self {
        case .sdr: return "SDR"
        case .hlg: return "HDR (HLG)"
        case .pq: return "HDR (PQ)"
        }
    }
}

/// Color tagging read from a video track's format description.
public struct ColorDescription: Sendable, Hashable, Codable {
    public var primaries: ColorPrimaries
    public var transfer: TransferFunction
    public var matrix: YCbCrMatrix

    public init(primaries: ColorPrimaries, transfer: TransferFunction, matrix: YCbCrMatrix) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
    }

    public static let rec709 = ColorDescription(primaries: .bt709, transfer: .bt709, matrix: .bt709)
    public static let rec2100HLG = ColorDescription(primaries: .bt2020, transfer: .hlg, matrix: .bt2020)
    public static let rec2100PQ = ColorDescription(primaries: .bt2020, transfer: .pq, matrix: .bt2020)
    public static let untagged = ColorDescription(primaries: .unknown, transfer: .unknown, matrix: .unknown)

    public var dynamicRange: DynamicRange {
        switch transfer {
        case .hlg: return .hlg
        case .pq: return .pq
        default: return .sdr
        }
    }

    public var isFullyTagged: Bool {
        primaries != .unknown && transfer != .unknown && matrix != .unknown
    }

    /// How untagged media is interpreted: Rec.709 for HD and larger, Rec.601 below.
    public func resolved(forHeight height: Int) -> ColorDescription {
        let sd = height > 0 && height < 720
        return ColorDescription(
            primaries: primaries == .unknown ? (sd ? .bt601NTSC : .bt709) : primaries,
            transfer: transfer == .unknown ? .bt709 : transfer,
            matrix: matrix == .unknown ? (sd ? .bt601 : .bt709) : matrix
        )
    }

    /// Short label for the Project panel "Color" column.
    public var displayName: String {
        switch (primaries, transfer) {
        case (.bt2020, .hlg): return "Rec.2100 HLG"
        case (.bt2020, .pq): return "Rec.2100 PQ"
        case (_, .hlg): return "HLG"
        case (_, .pq): return "PQ"
        case (.bt709, .bt709), (.bt709, .unknown): return "Rec.709"
        case (.bt2020, _): return "Rec.2020"
        case (.displayP3, _): return "Display P3"
        case (.dciP3, _): return "DCI-P3"
        case (.bt601NTSC, _), (.bt601PAL, _): return "Rec.601"
        case (_, .sRGB): return "sRGB"
        case (.unknown, .unknown): return "Untagged"
        default: return "Rec.709"
        }
    }
}
