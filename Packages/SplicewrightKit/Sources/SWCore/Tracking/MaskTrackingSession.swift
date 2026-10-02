import Foundation

/// One tracked frame: the mask's path there and how sure the tracker is.
public struct TrackingStep: Sendable {
    public var vertices: [Mask.Vertex]
    /// 0...1: the share of points that agreed, how well the area matched, or how much of the color is still there.
    public var confidence: Double
    /// The object couldn't be found well enough (hidden, blurred, out of frame).
    public var isLost: Bool
}

/// Follows a mask's object frame by frame. Start it on the frame the mask is drawn on, then
/// hand it each next frame (forward or backward in time) at the same size; it returns the
/// mask's path on that frame. Frames are `TrackingImage`s of the clip's picture as shown, and
/// paths are in the mask's own coordinates (fractions of the picture).
/// Used from one task at a time (each frame after the last).
public final class MaskTrackingSession: @unchecked Sendable {
    public let settings: TrackingSettings
    private let motion: TrackingSettings.Motion
    private let levels: Int
    private let width: Int
    private let height: Int

    /// What new frames are compared with (the first frame, or the one before), and the mask there.
    private var reference: TrackingImage
    private var referenceVertices: [Mask.Vertex]
    /// The mask on the last tracked frame, and the motion from the reference to it.
    private var currentVertices: [Mask.Vertex]
    private var total = Homography.identity
    /// The last frame-to-frame motion, used to predict the next one.
    private var lastStep = Homography.identity

    private var corners: [(x: Double, y: Double)] = []
    private var template: TextureAligner.Template?
    private var colorModel: ColorTracker.Model?
    private var colorState: ColorTracker.State?

    /// Below this the object counts as lost.
    static let lostBelow = 0.35

    public init?(settings: TrackingSettings, first: TrackingImage, vertices: [Mask.Vertex]) {
        guard vertices.count >= 2 else { return nil }
        self.settings = settings
        motion = settings.effectiveMotion
        levels = settings.searchRange.pyramidLevels
        width = first.width
        height = first.height
        reference = first
        referenceVertices = vertices
        currentVertices = vertices
        let outline = Outline(vertices, width: width, height: height)
        switch settings.method {
        case .points:
            corners = PointTracker.corners(in: first, outline: outline)
            guard corners.count >= motion.minimumPoints else { return nil }
        case .texture:
            guard let made = TextureAligner.template(from: first, outline: outline, levels: levels) else { return nil }
            template = made
        case .color:
            guard let model = ColorTracker.model(from: first, outline: outline) else { return nil }
            colorModel = model
            colorState = ColorTracker.State(center: model.center, scale: 1, angle: 0)
        }
    }

    /// Tracks into the next frame.
    public func track(_ image: TrackingImage) -> TrackingStep {
        let adapting = settings.reference == .previousFrame && settings.method != .color
        let result: (motion: Homography, confidence: Double)?
        switch settings.method {
        case .points: result = trackPoints(image, adapting: adapting)
        case .texture: result = trackTexture(image, adapting: adapting)
        case .color: result = trackColor(image)
        }
        let confidence = result?.confidence ?? 0
        let isLost = result == nil || confidence < Self.lostBelow
        // Lost: keep the mask where the motion so far predicts it.
        let measured = result?.motion ?? (adapting ? lastStep : lastStep.after(total))
        let previousTotal = total
        if adapting {
            currentVertices = Self.transform(currentVertices, by: measured, width: width, height: height)
            lastStep = measured
            total = measured.after(total)
            reference = image
            prepareNext(from: image)
        } else {
            total = measured
            currentVertices = Self.transform(referenceVertices, by: total, width: width, height: height)
            if let inverse = previousTotal.inverse { lastStep = total.after(inverse) }
        }
        return TrackingStep(vertices: currentVertices, confidence: confidence, isLost: isLost)
    }

    /// Adapting: the next frame is compared with this one, inside the mask as it is now.
    private func prepareNext(from image: TrackingImage) {
        let outline = Outline(currentVertices, width: width, height: height)
        switch settings.method {
        case .points:
            corners = PointTracker.corners(in: image, outline: outline)
        case .texture:
            if let made = TextureAligner.template(from: image, outline: outline, levels: levels) { template = made }
        case .color:
            break
        }
    }

    private var threshold: Double { max(1, 1.5 * Double(max(width, height)) / 960) }

    private func trackPoints(_ image: TrackingImage, adapting: Bool) -> (motion: Homography, confidence: Double)? {
        let predicted = adapting ? lastStep : lastStep.after(total)
        let guesses = corners.map { predicted.apply($0.x, $0.y) }
        let found = PointTracker.trackChecked(corners, guesses: guesses, from: reference, to: image, levels: levels)
        let pairs = zip(corners, found).compactMap { from, to in to.map { Correspondence(from: from, to: $0) } }
        guard let (fitted, inliers) = MotionFit.robust(motion, pairs, threshold: threshold) else { return nil }
        let agreeing = inliers.filter { $0 }.count
        let needed = max(8, motion.minimumPoints * 3)
        // Share of all points that were followed and agreed, discounted when there are few.
        let share = Double(agreeing) / Double(max(corners.count, 1))
        let confidence = min(1, share * 1.6) * min(1, Double(agreeing) / Double(needed))
        return (fitted, confidence)
    }

    private func trackTexture(_ image: TrackingImage, adapting: Bool) -> (motion: Homography, confidence: Double)? {
        guard let template else { return nil }
        let initial = adapting ? lastStep : lastStep.after(total)
        guard let aligned = TextureAligner.align(template, in: image, model: motion, initial: initial, levels: levels) else {
            return nil
        }
        // A correlation of 0.6 or so is a weak match; 0.9 and up a clear one.
        let confidence = min(1, max(0, (aligned.match - 0.5) / 0.4))
        return (aligned.motion, confidence)
    }

    private func trackColor(_ image: TrackingImage) -> (motion: Homography, confidence: Double)? {
        guard let model = colorModel, let state = colorState else { return nil }
        let (next, confidence) = ColorTracker.track(model, image: image, from: state, motion: motion)
        colorState = next
        return (ColorTracker.motion(model, next), confidence)
    }

    /// Moves a path's points (and their handles' ends) by a motion in pixels.
    static func transform(_ vertices: [Mask.Vertex], by motion: Homography, width: Int, height: Int) -> [Mask.Vertex] {
        let (w, h) = (Double(width), Double(height))
        return vertices.map { vertex in
            let point = motion.apply(vertex.x * w, vertex.y * h)
            let incoming = motion.apply((vertex.x + vertex.inX) * w, (vertex.y + vertex.inY) * h)
            let outgoing = motion.apply((vertex.x + vertex.outX) * w, (vertex.y + vertex.outY) * h)
            return Mask.Vertex(x: point.x / w, y: point.y / h, inX: (incoming.x - point.x) / w,
                               inY: (incoming.y - point.y) / h, outX: (outgoing.x - point.x) / w,
                               outY: (outgoing.y - point.y) / h)
        }
    }
}
