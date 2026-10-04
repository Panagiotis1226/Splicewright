import Foundation
import Testing
@testable import SWCore

@Suite("Auto Reframe")
struct AutoReframeTests {
    private let hd = SequenceSettings(width: 1920, height: 1080, frameRate: .fps30, colorSpace: .rec709)

    @Test func frameSizesKeepTheLongSide() {
        #expect(ReframeSettings(aspect: .vertical).frameSize(from: hd) == (1080, 1920))
        #expect(ReframeSettings(aspect: .portrait).frameSize(from: hd) == (1536, 1920))
        #expect(ReframeSettings(aspect: .square).frameSize(from: hd) == (1920, 1920))
        #expect(ReframeSettings(aspect: .widescreen).frameSize(from: hd) == (1920, 1080))
    }

    @Test func fillScaleAndPositionStayInsideThePicture() {
        // A 16:9 picture in a 9:16 frame: fitted to the width, it must grow 1920/1080 × 1920/1080.
        let geometry = ReframeGeometry(pictureWidth: 1920, pictureHeight: 1080, frameWidth: 1080, frameHeight: 1920)
        #expect(abs(geometry.fillScale - 100 * (1920.0 / 1080) * (1920.0 / 1080)) < 1e-9)
        // Covering, the picture is 3413⅓ wide: the centre can move ±1166⅔ and not at all vertically.
        #expect(geometry.position(x: 0.5, y: 0.5) == [0, 0])
        let right = geometry.position(x: 0.7, y: 0.9)
        #expect(abs(right[0] + 0.2 * 1920 * 1920 / 1080) < 1e-6 && right[1] == 0)
        let edge = geometry.position(x: 1, y: 0.5)
        #expect(abs(edge[0] + (1920.0 * 1920 / 1080 - 1080) / 2) < 1e-6, "stops at the picture's edge")
    }

    @Test func pathIsSmoothedAndSplitAtShotChanges() {
        var samples: [ReframeSample] = []
        for step in 0..<20 {
            let t = Double(step) * 0.2
            // Jitter around 0.3, an outlier, then a new shot with the subject at 0.8.
            let x = step < 10 ? 0.3 + (step % 2 == 0 ? 0.02 : -0.02) : 0.8
            samples.append(ReframeSample(time: t, x: step == 4 ? 0.95 : x, y: 0.5, confidence: step == 6 ? 0 : 1))
        }
        let stretches = ReframePath.smoothed(samples, pace: .standard)
        #expect(stretches.count == 2, "the shot change starts a new stretch")
        #expect(stretches[0].allSatisfy { abs($0.x - 0.3) < 0.03 }, "jitter and the outlier are gone")
        #expect(stretches[1].allSatisfy { abs($0.x - 0.8) < 1e-9 })
    }

    @Test func reframedSequenceKeysPositionAndHoldsAtCuts() throws {
        var sequence = EditSequence(name: "Talk", settings: hd)
        let clip = Clip(mediaID: UUID(), name: "a", start: 0, duration: 120, sourceStart: .zero)
        let title = UUID()
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[0].id, clip: clip)])
        sequence.addTitle(TitleSpec(text: "Hi"), at: 0)
        let path = (0..<20).map { step in
            ReframeSample(time: Double(step) * 0.2, x: step < 10 ? 0.3 : 0.8, y: 0.5, confidence: 1)
        }
        let reframed = sequence.reframed(ReframeSettings(aspect: .vertical, pace: .standard),
                                         pictures: [clip.id: (1920, 1080), title: (1920, 1080)],
                                         paths: [clip.id: path])
        #expect(reframed.id != sequence.id && reframed.name == "Talk (9x16)")
        #expect(reframed.settings.width == 1080 && reframed.settings.height == 1920)
        let motion = try #require(reframed.clip(clip.id)?.motion)
        #expect(abs((motion.scale.values.first ?? 0) - 100 * pow(1920.0 / 1080, 2)) < 1e-6)
        let keys = motion.position.keyframes
        #expect(keys.count >= 4)
        #expect(keys.contains { $0.interpolation == .hold }, "a held jump at the shot change")
        let before = motion.position.value(at: RationalTime(seconds: 0.5, timescale: 600))[0]
        let after = motion.position.value(at: RationalTime(seconds: 3.5, timescale: 600))[0]
        #expect(before > 0 && after < 0, "pans right of centre, then left")
        // Titles are left alone.
        let titleClip = reframed.videoTracks.flatMap(\.clips).first { $0.isTitle }
        #expect(titleClip?.motion == Motion())
    }

    @Test func aClipWithoutAPathFillsTheFrameCentred() throws {
        var sequence = EditSequence(name: "S", settings: hd)
        let clip = Clip(mediaID: UUID(), name: "a", start: 0, duration: 60, sourceStart: .zero)
        sequence.overwrite([TrackPlacement(trackID: sequence.videoTracks[0].id, clip: clip)])
        let reframed = sequence.reframed(ReframeSettings(aspect: .square), pictures: [clip.id: (1920, 1080)], paths: [:])
        let motion = try #require(reframed.clip(clip.id)?.motion)
        #expect(!motion.position.isAnimated && motion.position.values == [0, 0])
        #expect(abs((motion.scale.values.first ?? 0) - 100 * 1920.0 / 1080) < 1e-6)
    }
}
