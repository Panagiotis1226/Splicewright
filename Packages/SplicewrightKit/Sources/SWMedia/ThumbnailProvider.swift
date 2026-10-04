import AVFoundation
import CoreGraphics
import ImageIO
import SWCore
import UniformTypeIdentifiers

/// Poster frames for the Project panel, cached in memory and on disk.
public actor ThumbnailProvider {
    public static let shared = ThumbnailProvider()

    private let memory = NSCache<NSString, CGImage>()

    /// Forgets thumbnails held in memory (after the disk cache was cleared).
    public func clearMemory() {
        memory.removeAllObjects()
    }
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private let directory: URL

    public init(directory: URL = MediaCache.directory("Thumbnails")) {
        self.directory = directory
        memory.countLimit = 500
    }

    /// A frame from `url` near `seconds`, at most `maxPixels` on its longest side.
    public func thumbnail(for url: URL, at seconds: Double = 0, maxPixels: Int = 320) async -> CGImage? {
        let key = MediaCache.fingerprint(of: url, extra: "\(seconds)|\(maxPixels)")
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let running = inFlight[key] { return await running.value }

        let fileURL = directory.appending(path: "\(key).jpg")
        let task = Task.detached(priority: .utility) { () -> CGImage? in
            if let image = Self.readImage(at: fileURL) { return image }
            guard let image = await Self.generate(url: url, seconds: seconds, maxPixels: maxPixels) else { return nil }
            Self.writeJPEG(image, to: fileURL)
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    static func generate(url: URL, seconds: Double, maxPixels: Int) async -> CGImage? {
        if ImportPolicy.imageExtensions.contains(url.pathExtension.lowercased()) {
            return StillImage.image(at: url, maxPixels: maxPixels)
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        let tolerance = CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        do {
            let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            return result.image
        } catch {
            return nil
        }
    }

    static func readImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        CGImageDestinationFinalize(destination)
    }
}
