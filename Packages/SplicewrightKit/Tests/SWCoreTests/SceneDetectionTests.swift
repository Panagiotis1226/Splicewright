import Foundation
import Testing
@testable import SWCore

@Suite("Scene edit detection")
struct SceneDetectionTests {
    private let width = 64
    private let height = 36

    /// A frame of `color` (r, g, b) with a white square at `square` moving across it, and a little noise.
    private func frame(_ color: (Double, Double, Double), square: Int, seed: Int) -> SceneFrame {
        var bgra = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let inside = (square..<square + 10).contains(x) && (10..<22).contains(y)
                let noise = Double((x * 31 + y * 17 + seed * 13) % 7) - 3
                let index = (y * width + x) * 4
                func value(_ channel: Double) -> UInt8 { UInt8(min(max(inside ? 240 : channel + noise, 0), 255)) }
                (bgra[index], bgra[index + 1], bgra[index + 2]) = (value(color.2), value(color.1), value(color.0))
            }
        }
        return SceneFrame(width: width, height: height, bgra: bgra)
    }

    private func detect(_ frames: [SceneFrame], sensitivity: Double = 50) -> [Int] {
        var detector = SceneDetector(settings: SceneSettings(sensitivity: sensitivity), fps: 30)
        frames.forEach { detector.add($0) }
        return detector.cuts()
    }

    private func shot(_ color: (Double, Double, Double), frames: Int, offset: Int = 0) -> [SceneFrame] {
        (0..<frames).map { frame(color, square: (($0 + offset) * 2) % 50, seed: $0 + offset) }
    }

    @Test func findsHardCutsBetweenShots() {
        let frames = shot((20, 30, 90), frames: 30) + shot((210, 120, 40), frames: 30, offset: 30)
            + shot((40, 160, 60), frames: 30, offset: 60)
        #expect(detect(frames) == [30, 60])
    }

    @Test func motionFlashesAndDissolvesAreNotCuts() {
        // A square moving fast, a one-frame flash, then a 30-frame dissolve to another color.
        var frames = shot((20, 30, 90), frames: 20)
        frames[10] = frame((250, 250, 250), square: 0, seed: 99)
        let from = (20.0, 30.0, 90.0)
        let to = (210.0, 120.0, 40.0)
        for step in 0..<30 {
            let t = Double(step + 1) / 30
            frames.append(frame((from.0 + (to.0 - from.0) * t, from.1 + (to.1 - from.1) * t, from.2 + (to.2 - from.2) * t),
                                square: (step * 7) % 50, seed: step))
        }
        #expect(detect(frames).isEmpty, "\(detect(frames))")
    }

    @Test func sensitivityAndMinimumLength() {
        // Two similar shots: only a sensitive setting splits them.
        let frames = shot((100, 100, 100), frames: 20) + shot((130, 115, 100), frames: 20, offset: 20)
        #expect(detect(frames, sensitivity: 10).isEmpty)
        #expect(detect(frames, sensitivity: 95) == [20])
        // Shots under the minimum length aren't split off.
        let quick = shot((20, 30, 90), frames: 20) + shot((210, 120, 40), frames: 5, offset: 20)
            + shot((40, 160, 60), frames: 20, offset: 25)
        #expect(detect(quick) == [20])
    }

    @Test func editsGoThroughLinkedClipsAndMarkersAreNamed() {
        var seq = EditSequence(name: "S", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                                    colorSpace: .rec709))
        let link = UUID()
        let video = Clip(mediaID: UUID(), name: "Interview", start: 10, duration: 100, sourceStart: .zero, linkID: link)
        var audio = video
        audio.id = UUID()
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: video),
                       TrackPlacement(trackID: seq.audioTracks[0].id, clip: audio)])
        #expect(seq.addSceneEdits(to: video.id, at: [10, 40, 80, 200]) == 2, "only inside the clip")
        #expect(seq.videoTracks[0].clips.map(\.start) == [10, 40, 80])
        #expect(seq.audioTracks[0].clips.map(\.start) == [10, 40, 80])
        seq.addSceneMarkers([80, 40], clipName: "Interview")
        #expect(seq.markers.map(\.name) == ["Interview – scene 2", "Interview – scene 3"])
    }
}
