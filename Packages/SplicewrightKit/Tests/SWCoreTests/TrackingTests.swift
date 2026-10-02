import Foundation
import Testing
@testable import SWCore

/// Mask tracking on synthetic footage whose motion is known exactly.
@Suite("Mask tracking")
struct TrackingTests {
    private static let width = 320
    private static let height = 180

    /// Blurred noise: blobs and corners everywhere, like real texture.
    private static let texture: Plane = {
        var generator = SeededGenerator(seed: 42)
        let (w, h) = (width * 2, height * 2)
        var noise = Plane(width: w, height: h)
        for index in noise.values.indices { noise.values[index] = Float.random(in: 0...1, using: &generator) }
        for _ in 0..<3 {
            var blurred = noise
            for y in 0..<h {
                for x in 0..<w {
                    var sum: Float = 0
                    for dy in -2...2 { for dx in -2...2 { sum += noise.at(x + dx, y + dy) } }
                    blurred.values[y * w + x] = sum / 25
                }
            }
            noise = blurred
        }
        // Stretch the contrast back up after blurring.
        let low = noise.values.min() ?? 0
        let high = noise.values.max() ?? 1
        noise.values = noise.values.map { ($0 - low) / max(high - low, 1e-6) }
        return noise
    }()

    /// The texture seen through `motion` (picture pixels → frame pixels), with light `gain`.
    private func frame(_ motion: Homography, gain: Float = 1) -> TrackingImage {
        let inverse = motion.inverse ?? .identity
        var plane = Plane(width: Self.width, height: Self.height)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let source = inverse.apply(Double(x) + 160, Double(y) + 90)
                plane.values[y * Self.width + x] = min(1, Self.texture.sample(source.x, source.y) * gain)
            }
        }
        return TrackingImage(luma: plane)
    }

    /// The motion about the frame's center, in frame pixels (the texture is offset by 160, 90).
    private func about(_ motion: Homography) -> Homography {
        Homography.translation(-160, -90).after(motion).after(.translation(160, 90))
    }

    private func rotationScale(degrees: Double, scale: Double, dx: Double, dy: Double) -> Homography {
        let (c, s) = (cos(degrees * .pi / 180) * scale, sin(degrees * .pi / 180) * scale)
        // About the middle of the frame (texture coordinates 320, 180).
        let middle = Homography.translation(320, 180)
        return Homography.translation(dx, dy).after(middle).after(Homography(m: [c, -s, 0, s, c, 0, 0, 0, 1]))
            .after(.translation(-320, -180))
    }

    private let square = Mask.rectangle(left: 0.3, top: 0.25, right: 0.7, bottom: 0.75).vertices(at: .zero)

    /// Where the square's corners should be after `motion` (frame pixels), against the tracked ones.
    private func worstError(_ step: TrackingStep, expected motion: Homography) -> Double {
        let truth = MaskTrackingSession.transform(square, by: about(motion), width: Self.width, height: Self.height)
        return zip(step.vertices, truth).map {
            hypot(($0.x - $1.x) * Double(Self.width), ($0.y - $1.y) * Double(Self.height))
        }.max() ?? .infinity
    }

    private func session(_ method: TrackingSettings.Method, _ motion: TrackingSettings.Motion,
                         reference: TrackingSettings.Reference = .previousFrame) throws -> MaskTrackingSession {
        var settings = TrackingSettings()
        settings.method = method
        settings.motion = motion
        settings.reference = reference
        return try #require(MaskTrackingSession(settings: settings, first: frame(.identity), vertices: square))
    }

    // MARK: - Motion fits

    @Test func fitsRecoverEachMotionAndIgnoreOutliers() throws {
        let truth: [(TrackingSettings.Motion, Homography)] = [
            (.position, .translation(3, -2)),
            (.positionScale, Homography(m: [1.1, 0, 4, 0, 1.1, -3, 0, 0, 1])),
            (.positionScaleRotation, rotationScale(degrees: 7, scale: 0.95, dx: 2, dy: 5)),
            (.affine, Homography(m: [1.05, 0.08, 3, -0.04, 0.97, 1, 0, 0, 1])),
            (.perspective, Homography(m: [1.02, 0.05, 4, -0.03, 0.98, 2, 0.0004, -0.0002, 1])),
        ]
        var generator = SeededGenerator(seed: 7)
        for (model, motion) in truth {
            var pairs: [Correspondence] = (0..<60).map { _ in
                let point = (Double.random(in: 0...300, using: &generator), Double.random(in: 0...200, using: &generator))
                return Correspondence(from: point, to: motion.apply(point.0, point.1))
            }
            // A third of the points went somewhere else entirely (background, a hand passing).
            for index in stride(from: 0, to: 60, by: 3) {
                pairs[index].to = (Double.random(in: 0...300, using: &generator), Double.random(in: 0...200, using: &generator))
            }
            let fitted = try #require(MotionFit.robust(model, pairs, threshold: 1))
            #expect(fitted.inliers.filter { $0 }.count == 40, "\(model): the 40 true points agree")
            for point in [(0.0, 0.0), (300.0, 200.0), (150.0, 40.0)] {
                let a = fitted.motion.apply(point.0, point.1)
                let b = motion.apply(point.0, point.1)
                #expect(hypot(a.x - b.x, a.y - b.y) < 1e-6, "\(model)")
            }
        }
    }

    // MARK: - Methods

    @Test func pointsFollowRotationScaleAndPerspective() throws {
        let turned = rotationScale(degrees: 4, scale: 1.04, dx: 5.5, dy: -3.2)
        let similarity = try session(.points, .positionScaleRotation)
        let step = similarity.track(frame(turned))
        #expect(!step.isLost && step.confidence > 0.6)
        #expect(worstError(step, expected: turned) < 0.5)

        // A plane tilting away: about 2% keystone across the frame between two frames.
        let tilted = Homography(m: [1.01, 0.01, -1, -0.01, 1.0, 2, 0.00003, 0.00002, 1])
        let perspective = try session(.points, .perspective)
        let tiltStep = perspective.track(frame(tilted))
        #expect(!tiltStep.isLost)
        #expect(worstError(tiltStep, expected: tilted) < 0.75)
    }

    @Test func positionOnlyKeepsTheShape() throws {
        let moved = rotationScale(degrees: 0, scale: 1, dx: -6.4, dy: 4.1)
        let tracker = try session(.points, .position)
        let step = tracker.track(frame(moved))
        #expect(worstError(step, expected: moved) < 0.3)
    }

    @Test func textureFollowsThroughALightChange() throws {
        let motion = rotationScale(degrees: 3, scale: 0.97, dx: 4.2, dy: 2.6)
        let tracker = try session(.texture, .positionScaleRotation)
        let step = tracker.track(frame(motion, gain: 1.2))
        #expect(!step.isLost && step.confidence > 0.6)
        #expect(worstError(step, expected: motion) < 0.5)
    }

    @Test func manyFramesAddUpWithoutDrifting() throws {
        for reference in TrackingSettings.Reference.allCases {
            for method in [TrackingSettings.Method.points, .texture] {
                let tracker = try session(method, .positionScaleRotation, reference: reference)
                var last: TrackingStep?
                for index in 1...10 {
                    last = tracker.track(frame(rotationScale(degrees: Double(index) * 0.8, scale: 1, dx: Double(index) * 2.5,
                                                             dy: Double(index) * -1.5)))
                }
                let truth = rotationScale(degrees: 8, scale: 1, dx: 25, dy: -15)
                let step = try #require(last)
                #expect(!step.isLost, "\(method) \(reference)")
                #expect(worstError(step, expected: truth) < 1.5, "\(method) \(reference)")
            }
        }
    }

    @Test func colorFollowsABlobAcrossPlainBackground() throws {
        // A red disc on green: no texture at all, only color.
        func disc(at center: (Double, Double), radius: Double) -> TrackingImage {
            var rgba = [UInt8](repeating: 255, count: Self.width * Self.height * 4)
            for y in 0..<Self.height {
                for x in 0..<Self.width {
                    let inside = hypot(Double(x) - center.0, Double(y) - center.1) <= radius
                    let index = (y * Self.width + x) * 4
                    rgba[index] = inside ? 220 : 40
                    rgba[index + 1] = inside ? 40 : 160
                    rgba[index + 2] = 50
                }
            }
            return TrackingImage(width: Self.width, height: Self.height, rgba: rgba)
        }
        let circle = Mask.ellipse(centerX: 0.5, centerY: 0.5, radiusX: 30.0 / 320, radiusY: 30.0 / 180).vertices(at: .zero)
        var settings = TrackingSettings()
        settings.method = .color
        settings.motion = .positionScale
        let tracker = try #require(MaskTrackingSession(settings: settings, first: disc(at: (160, 90), radius: 30),
                                                      vertices: circle))
        var step = tracker.track(disc(at: (172, 84), radius: 30))
        step = tracker.track(disc(at: (184, 78), radius: 33))
        #expect(!step.isLost)
        let xs = step.vertices.map { $0.x * 320 }
        let ys = step.vertices.map { $0.y * 180 }
        let center = ((xs.min()! + xs.max()!) / 2, (ys.min()! + ys.max()!) / 2)
        #expect(abs(center.0 - 184) < 1.5 && abs(center.1 - 78) < 1.5)
        #expect(abs((xs.max()! - xs.min()!) / 2 - 33) < 3, "grew with the disc")
    }

    @Test func aFrameWithoutTheObjectIsLost() throws {
        var generator = SeededGenerator(seed: 99)
        var other = Plane(width: Self.width, height: Self.height)
        for index in other.values.indices { other.values[index] = Float.random(in: 0...1, using: &generator) }
        for method in [TrackingSettings.Method.points, .texture] {
            let tracker = try session(method, .positionScaleRotation)
            let step = tracker.track(TrackingImage(luma: other))
            #expect(step.isLost, "\(method)")
        }
    }

    @Test func settingsAreSavedWithTheMask() throws {
        var mask = Mask.ellipse()
        var settings = TrackingSettings()
        settings.method = .texture
        settings.motion = .perspective
        settings.reference = .firstFrame
        mask.tracking = settings
        let decoded = try JSONDecoder().decode(Mask.self, from: JSONEncoder().encode(mask))
        #expect(decoded == mask)
        let plain = try JSONEncoder().encode(Mask.ellipse())
        #expect(!(String(data: plain, encoding: .utf8) ?? "").contains("tracking"))
        #expect(try JSONDecoder().decode(Mask.self, from: plain).tracking == nil)
        var color = TrackingSettings()
        color.method = .color
        color.motion = .perspective
        #expect(color.effectiveMotion == .positionScaleRotation)
    }
}
