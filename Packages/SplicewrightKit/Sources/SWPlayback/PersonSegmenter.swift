import CoreVideo
import Foundation
import ImageIO
import Vision

/// Remove Background's matte: macOS's built-in person segmentation (Vision), run on the
/// clip's decoded frame. Nothing is downloaded.
enum PersonSegmenter {
    struct Matte {
        var bytes: [UInt8]
        var width: Int
        var height: Int
    }

    /// Where the people are in `buffer` (1 = person). Phone video is stored sideways, so Vision is
    /// told how the picture is turned (`quarterTurns` clockwise to show it upright); the caller
    /// works out from the matte's shape whether it came back upright or as stored.
    static func matte(_ buffer: CVPixelBuffer, quarterTurns: Int) -> Matte? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let turns = ((quarterTurns % 4) + 4) % 4
        let orientation: CGImagePropertyOrientation = turns == 1 ? .right : (turns == 3 ? .left : .up)
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let mask = request.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let (width, height) = (CVPixelBufferGetWidth(mask), CVPixelBufferGetHeight(mask))
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        var bytes = [UInt8](repeating: 0, count: width * height)
        let source = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width { bytes[row * width + column] = source[row * rowBytes + column] }
        }
        return Matte(bytes: bytes, width: width, height: height)
    }
}
