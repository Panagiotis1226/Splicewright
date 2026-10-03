import Accelerate
import AVFoundation
import CoreVideo
import SWCore

/// Scene Edit Detection's analysis: decodes a span of a media file in order, shrinks each frame
/// to 64 pixels across, and finds the cuts with a `SceneDetector`.
public enum SceneScan {
    /// Source times where a new shot starts, inside `range` of the file's video.
    public static func cuts(in url: URL, range: CMTimeRange, settings: SceneSettings,
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [CMTime] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let fps = Double(try await track.load(.nominalFrameRate))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA),
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        let box = Box(reader: reader, output: output)
        return try await Task.detached { () throws -> [CMTime] in
            guard box.reader.startReading() else { throw box.reader.error ?? CocoaError(.fileReadUnknown) }
            var detector = SceneDetector(settings: settings, fps: fps > 0 ? fps : 30)
            var times: [CMTime] = []
            let duration = max(range.duration.seconds, 1e-6)
            while !Task.isCancelled, let sample = box.output.copyNextSampleBuffer() {
                guard let image = CMSampleBufferGetImageBuffer(sample), let frame = shrink(image) else { continue }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                detector.add(frame)
                times.append(time)
                progress(min(1, (time - range.start).seconds / duration))
            }
            if Task.isCancelled {
                box.reader.cancelReading()
                throw CancellationError()
            }
            guard box.reader.status == .completed else { throw box.reader.error ?? CocoaError(.fileReadUnknown) }
            return detector.cuts().compactMap { $0 < times.count ? times[$0] : nil }
        }.value
    }

    /// The frame scaled to 64 pixels across (aspect kept), as BGRA bytes.
    static func shrink(_ image: CVPixelBuffer) -> SceneFrame? {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return nil }
        let (sourceWidth, sourceHeight) = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image))
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let width = 64
        let height = max(1, Int((Double(sourceHeight) / Double(sourceWidth) * Double(width)).rounded()))
        var source = vImage_Buffer(data: base, height: vImagePixelCount(sourceHeight), width: vImagePixelCount(sourceWidth),
                                   rowBytes: CVPixelBufferGetBytesPerRow(image))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let error = bytes.withUnsafeMutableBytes { raw -> vImage_Error in
            var destination = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height),
                                            width: vImagePixelCount(width), rowBytes: width * 4)
            return vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
        }
        return error == kvImageNoError ? SceneFrame(width: width, height: height, bgra: bytes) : nil
    }

    private struct Box: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderOutput
    }
}
