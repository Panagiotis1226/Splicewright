import CoreVideo
import SWCore

/// Maps CoreVideo/CoreMedia color tag strings to SWCore's color enums.
public enum ColorTags {
    // Keyed by the CoreVideo constants rather than their string values, which are an SDK detail.
    static let primariesByTag: [String: ColorPrimaries] = [
        kCVImageBufferColorPrimaries_ITU_R_709_2 as String: .bt709,
        kCVImageBufferColorPrimaries_ITU_R_2020 as String: .bt2020,
        kCVImageBufferColorPrimaries_P3_D65 as String: .displayP3,
        kCVImageBufferColorPrimaries_DCI_P3 as String: .dciP3,
        kCVImageBufferColorPrimaries_SMPTE_C as String: .bt601NTSC,
        kCVImageBufferColorPrimaries_EBU_3213 as String: .bt601PAL,
    ]

    static let transferByTag: [String: TransferFunction] = [
        kCVImageBufferTransferFunction_ITU_R_709_2 as String: .bt709,
        kCVImageBufferTransferFunction_ITU_R_2020 as String: .bt2020,
        kCVImageBufferTransferFunction_ITU_R_2100_HLG as String: .hlg,
        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String: .pq,
        kCVImageBufferTransferFunction_sRGB as String: .sRGB,
        kCVImageBufferTransferFunction_Linear as String: .linear,
    ]

    static let matrixByTag: [String: YCbCrMatrix] = [
        kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String: .bt709,
        kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String: .bt601,
        kCVImageBufferYCbCrMatrix_ITU_R_2020 as String: .bt2020,
    ]

    public static func primaries(_ value: String?) -> ColorPrimaries {
        value.flatMap { primariesByTag[$0] } ?? .unknown
    }

    public static func transfer(_ value: String?) -> TransferFunction {
        value.flatMap { transferByTag[$0] } ?? .unknown
    }

    public static func matrix(_ value: String?) -> YCbCrMatrix {
        value.flatMap { matrixByTag[$0] } ?? .unknown
    }
}
