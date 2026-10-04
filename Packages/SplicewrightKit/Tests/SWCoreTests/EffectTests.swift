import Foundation
import Testing
@testable import SWCore

@Suite("Video effects and adjustment layers")
struct EffectTests {
    private func sequence() -> (EditSequence, UUID, UUID) {
        var seq = EditSequence(name: "S", settings: SequenceSettings(width: 1920, height: 1080, frameRate: .fps30,
                                                                     colorSpace: .rec709))
        let link = UUID()
        let video = Clip(mediaID: UUID(), name: "v", start: 0, duration: 100, sourceStart: .zero, linkID: link)
        var audio = video
        audio.id = UUID()
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[0].id, clip: video),
                       TrackPlacement(trackID: seq.audioTracks[0].id, clip: audio)])
        return (seq, video.id, audio.id)
    }

    @Test func defaultsClampingAndKeyframes() throws {
        var (seq, video, audio) = sequence()
        let added = seq.addEffect(.dropShadow, to: [video, audio])
        #expect(added.keys.sorted() == [video], "audio clips don't get video effects")
        let effectID = try #require(added[video])
        let effect = try #require(seq.clip(video)?.effects.first)
        #expect(effect.value("opacity", at: .zero) == 50 && effect.value("direction", at: .zero) == 135)

        seq.updateEffect(effectID, of: video) { $0.parameters["opacity"]?.values = [500] }
        #expect(seq.clip(video)?.effects.first?.value("opacity", at: .zero) == 100, "clamped to its range")

        seq.updateEffect(effectID, of: video) { effect in
            effect.parameters["distance"]?.setAnimated(true, at: .zero)
            effect.parameters["distance"]?.set([110], at: RationalTime(value: 1, timescale: 1),
                                               tolerance: FrameRate.fps30.frameDuration)
        }
        let animated = try #require(seq.clip(video))
        #expect(animated.isAnimated)
        #expect(animated.resolvedEffects(at: RationalTime(value: 1, timescale: 2)).first?["distance"] == 60)
    }

    @Test func stackOrderDisableAndNoOps() throws {
        var (seq, video, _) = sequence()
        let addedBlur = seq.addEffect(.gaussianBlur, to: [video])
        let addedFlip = seq.addEffect(.horizontalFlip, to: [video])
        let blur = try #require(addedBlur[video])
        let flip = try #require(addedFlip[video])
        #expect(seq.clip(video)?.resolvedEffects(at: .zero).map(\.kind) == [.horizontalFlip], "a zero blur is skipped")
        seq.updateEffect(blur, of: video) { $0.parameters["blurriness"]?.values = [20] }
        seq.moveEffect(flip, of: video, by: -1)
        #expect(seq.clip(video)?.effects.map(\.kind) == [.horizontalFlip, .gaussianBlur])
        seq.updateEffect(flip, of: video) { $0.isEnabled = false }
        #expect(seq.clip(video)?.resolvedEffects(at: .zero).map(\.kind) == [.gaussianBlur])
        seq.removeEffect(blur, from: video)
        #expect(seq.clip(video)?.effects.count == 1)
    }

    @Test func removeBackgroundIsAVideoEffectThatKeepsAllBackgroundAsANoOp() throws {
        var (seq, video, audio) = sequence()
        let added = seq.addEffect(.removeBackground, to: [video, audio])
        #expect(added.keys.sorted() == [video] && !EffectKind.removeBackground.isAudio)
        let effectID = try #require(added[video])
        let effect = try #require(seq.clip(video)?.effects.first)
        #expect(effect.value("feather", at: .zero) == 2 && effect.value("background", at: .zero) == 0)
        #expect(seq.clip(video)?.resolvedEffects(at: .zero).map(\.kind) == [.removeBackground])
        seq.updateEffect(effectID, of: video) { $0.parameters["background"]?.values = [100] }
        #expect(seq.clip(video)?.resolvedEffects(at: .zero).isEmpty == true, "keeping all the background changes nothing")
    }

    @Test func effectsFollowCutsAndPasteAttributes() throws {
        var (seq, video, _) = sequence()
        seq.addEffect(.crop, to: [video])
        seq.razor(at: 50, trackIDs: [seq.videoTracks[0].id])
        #expect(seq.videoTracks[0].clips.allSatisfy { $0.effects.map(\.kind) == [.crop] })
        let source = try #require(seq.videoTracks[0].clips.first)
        let target = try #require(seq.videoTracks[0].clips.last)
        seq.removeEffect(target.effects[0].id, from: target.id)
        seq.pasteAttributes(from: source, to: [target.id], motion: true, volume: false)
        let pasted = try #require(seq.clip(target.id)?.effects.first)
        #expect(pasted.kind == .crop && pasted.id != source.effects[0].id, "a copy, not the same effect")
    }

    @Test func adjustmentLayersRenderAboveTheTracksBelow() throws {
        var (seq, _, _) = sequence()
        let added = seq.addAdjustmentLayer(at: 20, duration: 40, trackID: seq.videoTracks[1].id)
        let layer = try #require(added)
        #expect(seq.clip(layer)?.isAdjustment == true && seq.clip(layer)?.isGenerated == true)
        // Without effects it draws nothing.
        #expect(RenderPlan.videoSegments(for: seq).first { $0.range.contains(30) }?.layers.count == 1)
        seq.addEffect(.gaussianBlur, to: [layer])
        let layers = try #require(RenderPlan.videoSegments(for: seq).first { $0.range.contains(30) }?.layers)
        #expect(layers.map(\.isAdjustment) == [false, true], "on top of V1")
        #expect(layers[1].effects.map(\.kind) == [.gaussianBlur])
        // It can be extended left like a title, with no source limit.
        #expect(seq.trim(layer, edge: .start, by: -15, media: [:]) == -15)
        // Not on audio tracks.
        #expect(seq.addAdjustmentLayer(at: 0, trackID: seq.audioTracks[0].id) == nil)
    }

    @Test func adjustmentLayersGoAboveEveryClipInTheirRange() throws {
        var (seq, _, _) = sequence()
        let firstAdded = seq.addAdjustmentLayer(at: 20, duration: 40)
        let first = try #require(firstAdded)
        #expect(seq.videoTracks[1].clips.map(\.id) == [first], "the free track right above V1")
        // With a clip on the top track, a new track is added above it.
        let trackCount = seq.videoTracks.count
        let top = Clip(mediaID: UUID(), name: "top", start: 0, duration: 100, sourceStart: .zero)
        seq.overwrite([TrackPlacement(trackID: seq.videoTracks[trackCount - 1].id, clip: top)])
        let secondAdded = seq.addAdjustmentLayer(at: 30, duration: 10)
        let second = try #require(secondAdded)
        #expect(seq.videoTracks.count == trackCount + 1)
        #expect(seq.videoTracks.last?.clips.map(\.id) == [second])
        // Past every clip it still goes on V2 at the lowest, like a title, leaving V1 for footage.
        let thirdAdded = seq.addAdjustmentLayer(at: 500, duration: 10)
        let third = try #require(thirdAdded)
        #expect(seq.videoTracks[1].clips.contains { $0.id == third })
    }

    @Test func savedAndOldClipsLoad() throws {
        var (seq, video, _) = sequence()
        seq.addEffect(.mirror, to: [video])
        let clip = try #require(seq.clip(video))
        #expect(try JSONDecoder().decode(Clip.self, from: try JSONEncoder().encode(clip)) == clip)
        let plain = Clip(mediaID: UUID(), name: "p", start: 0, duration: 1, sourceStart: .zero)
        let json = String(bytes: try JSONEncoder().encode(plain), encoding: .utf8) ?? ""
        #expect(!json.contains("effects") && !json.contains("isAdjustment"))
    }
}
