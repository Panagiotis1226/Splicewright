import Foundation
import Testing
@testable import SWCore

@Suite("Render plan")
struct RenderPlanTests {
    private func sequence() -> EditSequence {
        EditSequence(name: "R", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30, colorSpace: .rec709))
    }

    private func clip(_ start: Int64, _ duration: Int64, opacity: Double = 1) -> Clip {
        Clip(mediaID: UUID(), name: "c", start: start, duration: duration, sourceStart: .zero, opacity: opacity)
    }

    @Test func segmentsCoverTimelineWithoutGaps() {
        var seq = sequence()
        seq.overwrite([
            TrackPlacement(trackID: seq.videoTracks[0].id, clip: clip(10, 20)),
            TrackPlacement(trackID: seq.videoTracks[1].id, clip: clip(20, 20, opacity: 0.5)),
        ])
        let segments = RenderPlan.videoSegments(for: seq)
        #expect(segments.map(\.range) == [
            FrameRange(start: 0, end: 10), FrameRange(start: 10, end: 20),
            FrameRange(start: 20, end: 30), FrameRange(start: 30, end: 40),
        ])
        #expect(segments.map { $0.layers.map(\.trackIndex) } == [[], [0], [0, 1], [1]])
        #expect(segments[2].layers[1].opacity == 0.5)
    }

    @Test func hiddenTracksDisabledClipsAndOfflineMediaAreSkipped() {
        var seq = sequence()
        var disabled = clip(0, 10)
        disabled.isEnabled = false
        let offline = clip(10, 10)
        seq.overwrite([
            TrackPlacement(trackID: seq.videoTracks[0].id, clip: disabled),
            TrackPlacement(trackID: seq.videoTracks[0].id, clip: offline),
            TrackPlacement(trackID: seq.videoTracks[1].id, clip: clip(0, 20)),
        ])
        seq.videoTracks[1].isOutputEnabled = false
        let segments = RenderPlan.videoSegments(for: seq, isAvailable: { $0 != offline.mediaID })
        #expect(segments.allSatisfy { $0.layers.isEmpty })
    }

    @Test func emptySequenceHasOneBlackSegment() {
        let segments = RenderPlan.videoSegments(for: sequence(), minimumFrames: 30)
        #expect(segments == [RenderSegment(range: FrameRange(start: 0, end: 30), layers: [])])
    }

    @Test func soloOverridesMute() {
        var seq = sequence()
        #expect(RenderPlan.audibleTracks(in: seq) == [true, true, true])
        seq.audioTracks[0].isOutputEnabled = false
        #expect(RenderPlan.audibleTracks(in: seq) == [false, true, true])
        seq.audioTracks[2].isSolo = true
        #expect(RenderPlan.audibleTracks(in: seq) == [false, false, true])
        #expect(abs(RenderPlan.linearGain(dB: -6) - 0.501) < 0.001)
    }

    @Test func fitLetterboxesAndRotates() {
        // 4:3 into 16:9 is pillarboxed.
        let fit = Affine2D.fit(sourceWidth: 1440, sourceHeight: 1080, orientation: .identity,
                               renderWidth: 1920, renderHeight: 1080)
        #expect(fit.apply(x: 0, y: 0) == (240, 0))
        #expect(fit.apply(x: 1440, y: 1080) == (1680, 1080))
        // Portrait phone video: encoded 1920×1080, rotated 90° clockwise, fit into 1920×1080.
        let rotate = Affine2D(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let portrait = Affine2D.fit(sourceWidth: 1920, sourceHeight: 1080, orientation: rotate,
                                    renderWidth: 1920, renderHeight: 1080)
        let box = portrait.bounds(width: 1920, height: 1080)
        #expect(abs(box.minX - 656.25) < 0.001 && abs(box.maxX - 1263.75) < 0.001)
        #expect(abs(box.minY) < 0.001 && abs(box.maxY - 1080) < 0.001)
        // The encoded top-left corner ends up at the top-right after a clockwise rotation.
        let corner = portrait.apply(x: 0, y: 0)
        #expect(abs(corner.x - 1263.75) < 0.001 && abs(corner.y) < 0.001)
    }
}

@Suite("Transfer functions")
struct TransferFunctionTests {
    @Test func pqReferencePoints() {
        #expect(abs(TransferFunctions.nitsToPQ(203) - 0.5807) < 0.001)
        #expect(abs(TransferFunctions.nitsToPQ(1000) - 0.7518) < 0.001)
        #expect(abs(TransferFunctions.pqToNits(1) - 10_000) < 0.5)
        for nits in [0.1, 1.0, 100, 203, 1000, 4000] {
            #expect(abs(TransferFunctions.pqToNits(TransferFunctions.nitsToPQ(nits)) - nits) / nits < 1e-9)
        }
    }

    @Test func hlgReferenceWhiteIs203Nits() {
        // BT.2408: HLG reference white is a 75% signal, which is 203 nits on a 1000-nit display.
        #expect(abs(TransferFunctions.hlgGreyToNits(0.75) - 203) < 1.5)
        #expect(abs(TransferFunctions.hlgGreyToNits(1) - 1000) < 0.01)
        for scene in [0.001, 0.05, 0.2, 0.5, 1.0] {
            #expect(abs(TransferFunctions.hlgToScene(TransferFunctions.sceneToHLG(scene)) - scene) < 1e-12)
        }
    }

    @Test func sdrRoundTrip() {
        #expect(abs(TransferFunctions.linearToSDR(TransferFunctions.sdrToLinear(0.5)) - 0.5) < 1e-12)
        #expect(TransferFunctions.linearToSDR(2) == 1)
    }
}
