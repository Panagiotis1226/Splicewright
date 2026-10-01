import Foundation
import Testing
@testable import SWCore

@Suite("Bezier keyframes")
struct BezierTests {
    private func t(_ seconds: Double) -> RationalTime { RationalTime(seconds: seconds, timescale: 960_000) }

    private func property(_ points: [(Double, Double)], _ interpolation: KeyframeInterpolation) -> AnimatableProperty {
        AnimatableProperty([0], keyframes: points.map { Keyframe(time: t($0.0), values: [$0.1], interpolation: interpolation) })
    }

    private func slope(_ property: AnimatableProperty, at seconds: Double, side: Double) -> Double {
        let step = 0.001
        let a = property.value(at: t(seconds + (side < 0 ? -step : 0)))[0]
        let b = property.value(at: t(seconds + (side < 0 ? 0 : step)))[0]
        return (b - a) / step
    }

    @Test func autoBezierPassesThroughKeyframesSmoothly() {
        let curve = property([(0, 0), (1, 50), (2, 100)], .autoBezier)
        #expect(abs(curve.value(at: t(1))[0] - 50) < 1e-9)
        #expect(abs(curve.value(at: t(2))[0] - 100) < 1e-9)
        // No corner at the middle keyframe: the slope is the same arriving and leaving.
        let arriving = slope(curve, at: 1, side: -1)
        let leaving = slope(curve, at: 1, side: 1)
        #expect(abs(arriving - leaving) < 1, "\(arriving) vs \(leaving)")
        #expect(abs(leaving - 50) < 1, "along the line through its neighbours")
        // Flat at the ends, like an ease.
        #expect(abs(slope(curve, at: 0, side: 1)) < 1)
        // A peak stays a smooth peak: symmetric, and never overshoots on the way up.
        let peak = property([(0, 0), (1, 100), (2, 0)], .autoBezier)
        #expect(abs(peak.value(at: t(0.5))[0] - 50) < 0.01)
        #expect((0..<100).allSatisfy { peak.value(at: t(Double($0) / 100))[0] <= 100 + 1e-9 })
    }

    @Test func linearIsUnchangedNextToAnything() {
        let line = property([(0, 0), (2, 100)], .linear)
        #expect(abs(line.value(at: t(0.5))[0] - 25) < 1e-9)
        var mixed = property([(0, 0), (1, 100), (2, 100)], .linear)
        mixed.setInterpolation(.autoBezier, for: [mixed.keyframes[2].id])
        #expect(mixed.value(at: t(0.5))[0] == 50, "the first segment has no Bezier end, so it stays linear")
    }

    @Test func continuousHandlesMirrorAndBezierHandlesBreak() throws {
        var curve = property([(0, 0), (1, 0), (2, 0)], .autoBezier)
        let middle = curve.keyframes[1].id
        curve.setHandle(.outgoing, of: middle, slopes: [200], influence: 0.5)
        #expect(curve.keyframes[1].interpolation == .continuousBezier, "dragging an auto handle makes it continuous")
        #expect(curve.keyframes[1].inHandle?.slopes == [200], "the other side follows")
        #expect(curve.value(at: t(1.25))[0] > 10, "it rises after the keyframe")
        #expect(curve.value(at: t(0.75))[0] < -10, "and arrives from below")

        curve.setHandle(.incoming, of: middle, slopes: [-200], influence: 0.5, breaking: true)
        #expect(curve.keyframes[1].interpolation == .bezier)
        #expect(curve.keyframes[1].outHandle?.slopes == [200], "⌥-drag leaves the other side alone")
        #expect(curve.value(at: t(0.75))[0] > 10, "now it arrives from above: a sharp turn")
    }

    @Test func timeNeverRunsBackwardsWithLongHandles() {
        var curve = property([(0, 0), (1, 100)], .bezier)
        curve.setHandle(.outgoing, of: curve.keyframes[0].id, slopes: [0], influence: 1, breaking: true)
        curve.setHandle(.incoming, of: curve.keyframes[1].id, slopes: [0], influence: 1, breaking: true)
        let samples = (0...200).map { curve.value(at: t(Double($0) / 200))[0] }
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 }, "still rises steadily")
        #expect(abs(samples[100] - 50) < 0.5)
    }

    @Test func switchingToBezierKeepsTheShape() {
        var curve = property([(0, 0), (1, 50), (2, 100)], .autoBezier)
        let before = (0...20).map { curve.value(at: t(Double($0) / 10))[0] }
        curve.setInterpolation(.continuousBezier, for: Set(curve.keyframes.map(\.id)))
        let after = (0...20).map { curve.value(at: t(Double($0) / 10))[0] }
        #expect(zip(before, after).allSatisfy { abs($0 - $1) < 1e-6 })
        curve.setInterpolation(.linear, for: Set(curve.keyframes.map(\.id)))
        #expect(curve.keyframes.allSatisfy { $0.inHandle == nil && $0.outHandle == nil })
    }

    @Test func positionComponentsAreIndependent() {
        var position = AnimatableProperty([0, 0], keyframes: [
            Keyframe(time: t(0), values: [0, 0], interpolation: .autoBezier),
            Keyframe(time: t(1), values: [100, -100], interpolation: .autoBezier),
        ])
        #expect(position.value(at: t(0.5)) == [50, -50])
        position.setValue(40, component: 1, of: position.keyframes[1].id)
        #expect(position.keyframes[1].values == [100, 40])
    }

    @Test func handlesSaveAndOldKeyframesLoad() throws {
        var curve = property([(0, 0), (1, 10)], .autoBezier)
        curve.setHandle(.outgoing, of: curve.keyframes[0].id, slopes: [30], influence: 0.6, breaking: true)
        let decoded = try JSONDecoder().decode(AnimatableProperty.self, from: JSONEncoder().encode(curve))
        #expect(decoded == curve)
        let old = #"{"values":[1],"keyframes":[{"id":"7E57AB1E-0000-4000-8000-000000000001","#
            + #""time":{"value":0,"timescale":600},"values":[1],"interpolation":"easeIn"}]}"#
        let legacy = try JSONDecoder().decode(AnimatableProperty.self, from: Data(old.utf8))
        #expect(legacy.keyframes.first?.inHandle == nil && legacy.keyframes.first?.interpolation == .easeIn)
    }

    @Test func bezierSpeedRampsTimeRemapping() {
        let rate = FrameRate.fps30
        var ramp = Clip(mediaID: UUID(), name: "r", start: 0, duration: 60, sourceStart: .zero)
        ramp.speed.setAnimated(true, at: .zero)
        ramp.speed.set([300], at: RationalTime(frames: 30, rate: rate), tolerance: rate.frameDuration)
        let linearEarly = ramp.timing(rate: rate).sourceOffset(atClipFrame: 8)
        ramp.speed.setInterpolation(.autoBezier, for: Set(ramp.speed.keyframes.map(\.id)))
        let timing = ramp.timing(rate: rate)
        // A symmetric S-curve from 100% to 300% averages 200% too: 2 s of source in that second.
        #expect(abs(timing.sourceOffset(atClipFrame: 30) - 2) < 0.01)
        #expect(timing.sourceOffset(atClipFrame: 8) < linearEarly - 0.005, "it stays slow for longer at the start")
    }
}
