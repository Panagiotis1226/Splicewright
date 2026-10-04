import CoreGraphics
import Foundation
import ImageIO
import SWCore

/// Still images (PNG, JPEG, HEIC...): what the Project panel and the timeline need to know, and
/// the picture itself, the right way up (EXIF orientation applied) and color-managed to sRGB.
public enum StillImage {
    /// Width and height as displayed, and a codec name from the file type.
    public static func probe(_ url: URL) throws -> MediaInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw MediaProbeError.unreadable(url)
        }
        // Orientations 5-8 turn the picture a quarter turn.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let turned = (5...8).contains(orientation)
        let depth = properties[kCGImagePropertyDepth] as? Int
        let video = VideoStreamInfo(codec: VideoCodec(rawValue: url.pathExtension.uppercased()),
                                    width: turned ? height : width, height: turned ? width : height,
                                    frameRate: nil, nominalFPS: 0, bitDepth: depth, color: .rec709)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        return MediaInfo(container: .image, duration: MediaInfo.stillDuration, video: video, audio: [],
                         fileSize: fileSize)
    }

    /// The picture upright, no larger than `maxPixels` on its long side.
    public static func image(at url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixels, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Premultiplied RGBA8 pixels in sRGB, top row first, with their size.
    public static func rgba(at url: URL, maxPixels: Int) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let image = image(at: url, maxPixels: maxPixels), let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }
}
