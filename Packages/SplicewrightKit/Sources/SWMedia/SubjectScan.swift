import AVFoundation
import CoreGraphics
import SWCore
import Vision

/// Auto Reframe's analysis: where the subject is, a few times a second, with macOS's built-in
/// Vision requests (nothing to download): faces first, then people, then whatever draws the eye.
public enum SubjectScan {
    /// Samples between `start` and `end` (source seconds) of the file's picture as shown.
    public static func path(in url: URL, from start: Double, to end: Double, interval: Double = 0.2,
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [ReframeSample] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let count = max(1, Int(((end - start) / interval).rounded(.down)) + 1)
        var samples: [ReframeSample] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let time = min(start + Double(index) * interval, max(start, end))
            guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            else { continue }
            let found = await Task.detached { subject(in: image) }.value
            samples.append(ReframeSample(time: time, x: found.x, y: found.y, confidence: found.confidence))
            progress(Double(index + 1) / Double(count))
        }
        return samples
    }

    /// One picture (a still).
    public static func sample(of image: CGImage) -> ReframeSample {
        let found = subject(in: image)
        return ReframeSample(time: 0, x: found.x, y: found.y, confidence: found.confidence)
    }

    /// The subject's centre in an upright picture (0,0 top left) and how sure Vision is.
    static func subject(in image: CGImage) -> (x: Double, y: Double, confidence: Double) {
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([faces, people, saliency])
        // Vision's boxes are normalised with the origin at the bottom left.
        if let found = weightedCentre(faces.results?.map(\.boundingBox) ?? []) {
            return (found.x, found.y, 1)
        }
        if let person = (people.results ?? []).max(by: { area($0.boundingBox) < area($1.boundingBox) }) {
            // Aim at the upper body, where the face would be.
            let box = person.boundingBox
            return (Double(box.midX), 1 - Double(box.minY + box.height * 0.75), Double(person.confidence) * 0.8)
        }
        if let salient = saliency.results?.first?.salientObjects?.max(by: { $0.confidence < $1.confidence }) {
            let box = salient.boundingBox
            return (Double(box.midX), 1 - Double(box.midY), Double(salient.confidence) * 0.5)
        }
        return (0.5, 0.5, 0)
    }

    /// The faces' centre, the bigger ones counting more (the person in front leads).
    private static func weightedCentre(_ boxes: [CGRect]) -> (x: Double, y: Double)? {
        let total = boxes.map(area).reduce(0, +)
        guard total > 0 else { return nil }
        let x = boxes.map { Double($0.midX) * area($0) }.reduce(0, +) / total
        let y = boxes.map { Double($0.midY) * area($0) }.reduce(0, +) / total
        return (x, 1 - y)
    }

    private static func area(_ box: CGRect) -> Double { Double(box.width * box.height) }
}
