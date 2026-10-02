import Foundation
import Testing
@testable import SWCore

/// The Stabilizer on a synthetic shot: a slow pan with hand shake whose camera path is known.
@Suite("Stabilizer")
struct StabilizationTests {
    private static let (width, height) = (240, 135)

    private static let texture: Plane = {
        var generator = SeededGenerator(seed: 5)
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
        let low = noise.values.min() ?? 0
        let high = noise.values.max() ?? 1
        noise.values = noise.values.map { ($0 - low) / max(high - low, 1e-6) }
        return noise
    }()

    /// A pan of 1.5 px a frame with shake of a few pixels and a fraction of a degree.
    private static let cameras: [Affine2D] = {
        var generator = SeededGenerator(seed: 11)
        return (0..<24).map { frame in
            guard frame > 0 else { return .identity }
            let shakeX = Double.random(in: -3...3, using: &generator)
            let shakeY = Double.random(in: -3...3, using: &generator)
            let turn = Double.random(in: -0.6...0.6, using: &generator) * .pi / 180
            let (c, s) = (cos(turn), sin(turn))
            let center = (Double(width) / 2, Double(height) / 2)
            return Affine2D.translation(-center.0, -center.1)
                .concatenating(Affine2D(a: c, b: s, c: -s, d: c, tx: 0, ty: 0))
                .concatenating(.translation(center.0 + 1.5 * Double(frame) + shakeX, center.1 + shakeY))
        }
    }()

    /// Frame `index` as the camera saw it: frame-0 content at `camera(p)`.
    private static func frame(_ index: Int) -> TrackingImage {
        let back = Self.cameras[index].inverted ?? .identity
        var plane = Plane(width: Self.width, height: Self.height)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let source = back.apply(x: Double(x), y: Double(y))
                plane.values[y * Self.width + x] = Self.texture.sample(source.x + 120, source.y + 67)
            }
        }
        return TrackingImage(luma: plane)
    }

    private func analysed() -> StabilizationData { Self.analysis }

    /// Analysed once for all the tests.
    private static let analysis: StabilizationData = {
        var data = StabilizationData(pictureWidth: Double(width), pictureHeight: Double(height))
        let analyzer = StabilizationAnalyzer(first: frame(0), method: .positionScaleRotation,
                                             pictureWidth: Double(width))
        data.times = [0]
        data.path = [StabilizationData.numbers(.identity)]
        for index in 1..<cameras.count {
            let (camera, confidence) = analyzer.add(frame(index))
            precondition(confidence > 0.5, "frame \(index)")
            data.times.append(Double(index) / 30)
            data.path.append(StabilizationData.numbers(camera))
        }
        data.isComplete = true
        data.update()
        return data
    }()

    private func distance(_ a: Affine2D, _ b: Affine2D, at point: (Double, Double)) -> Double {
        let p = a.apply(x: point.0, y: point.1)
        let q = b.apply(x: point.0, y: point.1)
        return hypot(p.x - q.x, p.y - q.y)
    }

    @Test func analysisRecoversTheCameraPath() {
        let data = analysed()
        for (index, truth) in Self.cameras.enumerated() {
            let measured = StabilizationData.affine(data.path[index])
            for corner in [(0.0, 0.0), (240.0, 135.0), (120.0, 67.0)] {
                #expect(distance(measured, truth, at: corner) < 1, "frame \(index)")
            }
        }
    }

    @Test func noMotionHoldsTheFirstFrame() {
        var data = analysed()
        data.settings.result = .noMotion
        data.settings.framing = .stabilizeOnly
        data.update()
        // Corrected, every frame puts frame-0 content back where it was.
        for index in data.times.indices {
            let fix = StabilizationData.affine(data.corrections[index])
            let held = Self.cameras[index].concatenating(fix)
            #expect(distance(held, .identity, at: (60, 30)) < 1, "frame \(index)")
        }
    }

    @Test func smoothMotionKeepsThePanButNotTheShake() {
        var data = analysed()
        data.settings.smoothness = 60
        data.update()
        // Where frame-0's center ends up after correction, frame by frame.
        let positions = data.times.indices.map { index -> (x: Double, y: Double) in
            let shown = Self.cameras[index].concatenating(StabilizationData.affine(data.corrections[index]))
            return shown.apply(x: 120, y: 67)
        }
        let raw = Self.cameras.map { $0.apply(x: 120, y: 67) }
        func jitter(_ path: [(x: Double, y: Double)]) -> Double {
            // Second differences: zero for a steady pan, large for shake.
            (1..<(path.count - 1)).reduce(0) { sum, i in
                sum + hypot(path[i + 1].x - 2 * path[i].x + path[i - 1].x, path[i + 1].y - 2 * path[i].y + path[i - 1].y)
            }
        }
        #expect(jitter(positions) < jitter(raw) * 0.3, "most of the shake is gone")
        #expect(positions.last!.x - positions.first!.x > 20, "the pan is kept")
    }

    @Test func autoScaleZoomsJustEnoughToHideTheEdges() {
        var data = analysed()
        data.settings.result = .noMotion
        data.update()
        #expect(data.zoom > 1 && data.zoom < 1.5)
        let fixes = data.corrections.map(StabilizationData.affine)
        #expect(abs(StabilizationData.coveringZoom(fixes, width: 240, height: 135, limit: 2) - data.zoom) < 1e-6)
        data.settings.framing = .stabilizeOnly
        data.update()
        #expect(data.zoom == 1)
        data.settings.framing = .autoScale
        data.settings.maximumScale = 101
        data.update()
        #expect(abs(data.zoom - 1.01) < 1e-9, "capped")
    }

    @Test func correctionsBetweenFramesAreBlendedAndSaved() throws {
        let data = analysed()
        let between = try #require(data.correction(at: 1.5 / 30))
        let before = try #require(data.correction(at: 1.0 / 30))
        let after = try #require(data.correction(at: 2.0 / 30))
        let mid = between.apply(x: 50, y: 50)
        let a = before.apply(x: 50, y: 50)
        let b = after.apply(x: 50, y: 50)
        #expect(abs(mid.x - (a.x + b.x) / 2) < 1e-6 && abs(mid.y - (a.y + b.y) / 2) < 1e-6)

        var clip = Clip(mediaID: UUID(), name: "c", start: 0, duration: 24, sourceStart: .zero)
        var effect = ClipEffect(kind: .stabilizer)
        effect.stabilization = data
        clip.effects = [effect]
        #expect(clip.stabilization(at: RationalTime(seconds: 0.1, timescale: 600)) != nil)
        #expect(clip.resolvedEffects(at: .zero).isEmpty, "it's no pixel pass")
        let decoded = try JSONDecoder().decode(ClipEffect.self, from: JSONEncoder().encode(effect))
        #expect(decoded == effect)
        clip.effects[0].isEnabled = false
        #expect(clip.stabilization(at: .zero) == nil)
    }
}
