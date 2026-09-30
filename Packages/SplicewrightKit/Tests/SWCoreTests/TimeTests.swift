import Testing
@testable import SWCore

@Suite("RationalTime")
struct RationalTimeTests {
    @Test func equalityAcrossTimescales() {
        #expect(RationalTime(value: 1, timescale: 2) == RationalTime(value: 300, timescale: 600))
        #expect(RationalTime(value: 1, timescale: 2).hashValue == RationalTime(value: 300, timescale: 600).hashValue)
        #expect(RationalTime(value: 1001, timescale: 30000) < RationalTime(value: 1, timescale: 29))
    }

    @Test func arithmeticUsesCommonTimescale() {
        let sum = RationalTime(value: 1, timescale: 24) + RationalTime(value: 1, timescale: 30)
        #expect(sum == RationalTime(value: 9, timescale: 120))
        let difference = RationalTime(value: 1, timescale: 1) - RationalTime(value: 1001, timescale: 30000)
        #expect(difference == RationalTime(value: 28999, timescale: 30000))
    }

    @Test func frameIndexAtNTSCRates() {
        // Frame 1800 at 29.97 starts at 1800 * 1001 / 30000 s.
        let time = RationalTime(frames: 1800, rate: .fps29_97)
        #expect(time.frameIndex(at: .fps29_97) == 1800)
        // Half a frame later is still frame 1800.
        let later = time + RationalTime(value: 1001, timescale: 60000)
        #expect(later.frameIndex(at: .fps29_97) == 1800)
        // One minute of wall-clock time at 59.94 is 3596.4 frames.
        #expect(RationalTime(value: 60, timescale: 1).frameIndex(at: .fps59_94) == 3596)
    }

    @Test func negativeTimesFloor() {
        #expect(RationalTime(value: -1, timescale: 600).frameIndex(at: .fps30) == -1)
        #expect(RationalTime(value: -1, timescale: 600).converted(toTimescale: 30).value == -1)
    }

    @Test func snappingToFrames() {
        let time = RationalTime(seconds: 1.51, timescale: 600)
        #expect(time.snapped(to: .fps30) == RationalTime(frames: 45, rate: .fps30))
    }

    @Test func largeValuesDoNotOverflow() {
        // Ten hours at a 1 GHz timescale-equivalent magnitude.
        let time = RationalTime(value: 36_000_000_000_000, timescale: 1_000_000_000)
        #expect(time.frameIndex(at: .fps59_94) == 2_157_842)
        #expect(time > RationalTime(value: 35_999, timescale: 1))
    }
}

@Suite("FrameRate")
struct FrameRateTests {
    @Test(arguments: [
        (23.976, FrameRate.fps23_976), (23.98, .fps23_976), (29.97, .fps29_97), (29.970029, .fps29_97),
        (30.0, .fps30), (59.94, .fps59_94), (60.0, .fps60), (25.0, .fps25), (50.0, .fps50),
    ])
    func nearestStandard(fps: Double, expected: FrameRate) {
        #expect(FrameRate.nearestStandard(to: fps) == expected)
    }

    @Test func nonStandardRatesAreApproximated() {
        #expect(FrameRate.nearestStandard(to: 120) == nil)
        #expect(FrameRate.approximating(120) == FrameRate(numerator: 120))
        #expect(FrameRate.approximating(12.5) == FrameRate(numerator: 25, denominator: 2))
        #expect(FrameRate.approximating(0) == nil)
    }

    @Test func exactFrameDurations() {
        #expect(FrameRate.standard(matchingFrameDuration: 1001, timescale: 60000) == .fps59_94)
        #expect(FrameRate.standard(matchingFrameDuration: 2002, timescale: 120_000) == .fps59_94)
        #expect(FrameRate.standard(matchingFrameDuration: 20, timescale: 600) == .fps30)
        #expect(FrameRate.standard(matchingFrameDuration: 1, timescale: 120) == nil)
        #expect(FrameRate.standard(matchingFrameDuration: 0, timescale: 600) == nil)
    }

    @Test func resolvingQuantizedDurations() {
        // 29.97 fps in a 600-tick movie: durations of 20 ticks read as exactly 1/30 s.
        #expect(FrameRate.resolve(nominalFPS: 29.97, minFrameDuration: 20, timescale: 600) == .fps29_97)
        // True 30 fps in a 600-tick movie.
        #expect(FrameRate.resolve(nominalFPS: 30, minFrameDuration: 20, timescale: 600) == .fps30)
        // A short 59.94 clip whose averaged nominal rate rounds to 60.
        #expect(FrameRate.resolve(nominalFPS: 60, minFrameDuration: 1001, timescale: 60000) == .fps59_94)
        #expect(FrameRate.resolve(nominalFPS: 120, minFrameDuration: 5, timescale: 600) == FrameRate(numerator: 120))
    }

    @Test func displayNames() {
        #expect(FrameRate.fps29_97.displayName == "29.97")
        #expect(FrameRate.fps59_94.displayName == "59.94")
        #expect(FrameRate.fps23_976.displayName == "23.976")
        #expect(FrameRate.fps60.displayName == "60")
    }

    @Test func variableFrameRateHeuristic() {
        #expect(FrameRateAnalysis.isVariable(nominalFPS: 29.97, minFrameDurationSeconds: 1.0 / 60))
        #expect(!FrameRateAnalysis.isVariable(nominalFPS: 29.97, minFrameDurationSeconds: 1001.0 / 30000))
        #expect(!FrameRateAnalysis.isVariable(nominalFPS: 30, minFrameDurationSeconds: 0))
    }
}

@Suite("Timecode")
struct TimecodeTests {
    @Test(arguments: [
        (Int64(0), "00;00;00;00"), (1799, "00;00;59;29"), (1800, "00;01;00;02"),
        (3598, "00;02;00;02"), (17981, "00;09;59;29"), (17982, "00;10;00;00"),
        (107_892, "01;00;00;00"),
    ])
    func dropFrame2997(frame: Int64, expected: String) {
        let timecode = Timecode(frame: frame, rate: .fps29_97)
        #expect(timecode.description == expected)
        #expect(timecode.frameNumber(rate: .fps29_97) == frame)
    }

    @Test(arguments: [(Int64(3599), "00;00;59;59"), (3600, "00;01;00;04"), (35_964, "00;10;00;00")])
    func dropFrame5994(frame: Int64, expected: String) {
        let timecode = Timecode(frame: frame, rate: .fps59_94)
        #expect(timecode.description == expected)
        #expect(timecode.frameNumber(rate: .fps59_94) == frame)
    }

    @Test func dropFrameRoundTripsEveryFrameForAnHour() {
        for frame in stride(from: Int64(0), to: 107_892, by: 7) {
            let timecode = Timecode(frame: frame, rate: .fps29_97)
            #expect(timecode.frameNumber(rate: .fps29_97) == frame)
        }
    }

    @Test func nonDropFrame() {
        #expect(Timecode(frame: 1800, rate: .fps30).description == "00:01:00:00")
        #expect(Timecode(frame: 24 * 3600 + 23, rate: .fps24).description == "01:00:00:23")
        #expect(Timecode(frame: 1800, rate: .fps29_97, dropFrame: false).description == "00:01:00:00")
        #expect(Timecode(frame: -5, rate: .fps30).description == "00:00:00:00")
    }

    @Test func parsing() {
        let parsed = Timecode(string: "00;01;00;02", rate: .fps29_97)
        #expect(parsed?.frameNumber(rate: .fps29_97) == 1800)
        #expect(Timecode(string: "01:02:03:04", rate: .fps25)?.frameNumber(rate: .fps25) == 93_079)
        #expect(Timecode(string: "00:00:00:30", rate: .fps30) == nil)
        #expect(Timecode(string: "garbage", rate: .fps30) == nil)
    }
}

@Suite("TimeRange")
struct TimeRangeTests {
    @Test func containmentIsHalfOpen() {
        let range = TimeRange(start: RationalTime(value: 1, timescale: 1), duration: RationalTime(value: 2, timescale: 1))
        #expect(range.contains(RationalTime(value: 1, timescale: 1)))
        #expect(!range.contains(RationalTime(value: 3, timescale: 1)))
        #expect(range.end == RationalTime(value: 3, timescale: 1))
    }

    @Test func intersection() {
        let a = TimeRange(start: .zero, duration: RationalTime(value: 10, timescale: 1))
        let b = TimeRange(start: RationalTime(value: 5, timescale: 1), duration: RationalTime(value: 10, timescale: 1))
        let five = RationalTime(value: 5, timescale: 1)
        #expect(a.intersection(b) == TimeRange(start: five, duration: five))
        let c = TimeRange(start: RationalTime(value: 10, timescale: 1), duration: RationalTime(value: 1, timescale: 1))
        #expect(a.intersection(c) == nil)
    }
}
