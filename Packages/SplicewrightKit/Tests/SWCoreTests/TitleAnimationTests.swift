import Foundation
import Testing
@testable import SWCore

@Suite("Title in and out animations")
struct TitleAnimationTests {
    @Test func fadeAndSlideRunOverTheirLengthAndSettle() {
        let animation = TitleAnimation(animateIn: .slideUp, animateOut: .fade, inDuration: 1, outDuration: 0.5)
        let start = animation.state(at: 0, duration: 5)
        #expect(start.opacity == 0 && start.offsetY > 0.07, "starts below, invisible")
        let middle = animation.state(at: 2, duration: 5)
        #expect(middle.isIdentity, "still between the ends")
        let leaving = animation.state(at: 4.75, duration: 5)
        #expect(abs(leaving.opacity - 0.5) < 1e-9 && leaving.offsetY == 0, "half faded out, not moving")
        #expect(animation.state(at: 5, duration: 5).opacity == 0)
    }

    @Test func slidesKeepGoingTheSameWayOut() {
        let animation = TitleAnimation(animateIn: .slideLeft, animateOut: .slideLeft, inDuration: 1, outDuration: 1)
        #expect(animation.state(at: 0, duration: 4).offsetX > 0, "comes in from the right")
        #expect(animation.state(at: 3.9, duration: 4).offsetX < 0, "leaves to the left")
    }

    @Test func endsShrinkToFitAShortClip() {
        let animation = TitleAnimation(animateIn: .fade, animateOut: .fade, inDuration: 2, outDuration: 2)
        // A one-second clip: each end gets half a second.
        #expect(abs(animation.state(at: 0.25, duration: 1).opacity - 0.5) < 1e-9)
        #expect(abs(animation.state(at: 0.75, duration: 1).opacity - 0.5) < 1e-9)
    }

    @Test func popOvershootsThenSettles() {
        let scales = stride(from: 0.0, through: 1.0, by: 0.05).map { TitleAnimation.backOut($0) }
        #expect(abs(scales.first ?? 1) < 1e-9 && abs((scales.last ?? 0) - 1) < 1e-9)
        #expect((scales.max() ?? 0) > 1.05, "goes past full size on the way")
    }

    @Test func typewriterHidesTheTailWithoutMovingTheLayout() {
        let animation = TitleAnimation(animateIn: .typewriter, inDuration: 1)
        let state = animation.state(at: 0.5, duration: 5)
        let parts = state.textOpacity("Hello world")
        #expect(parts == [TitleTextOpacity(location: 5, length: 6, opacity: 0)], "the first five letters show")
        #expect(animation.state(at: 1, duration: 5).textOpacity("Hello world").isEmpty)
        // Characters are grapheme clusters, measured in UTF-16 for Core Text.
        var emoji = TitleAnimationState()
        emoji.reveal = .characters(0.5)
        #expect(emoji.textOpacity("👋🏽ab") == [TitleTextOpacity(location: 4, length: 2, opacity: 0)])
    }

    @Test func wordsFadeInOneAfterAnother() {
        var state = TitleAnimationState()
        state.reveal = .words(0)
        let words = TitleAnimationState.words("one two  three")
        #expect(words.map(\.location) == [0, 4, 9] && words.map(\.length) == [3, 3, 5])
        #expect(state.textOpacity("one two  three").map(\.opacity) == [0, 0, 0])
        state.reveal = .words(0.5)
        let middle = state.textOpacity("one two  three")
        #expect(!middle.contains { $0.location == 0 }, "the first word is in")
        #expect(middle.last?.location == 9 && middle.last?.opacity == 0, "the last is still to come")
        state.reveal = .words(1)
        #expect(state.textOpacity("one two  three").isEmpty)
    }

    @Test func scaleAndOffsetAreAboutTheTitlesPosition() {
        var state = TitleAnimationState()
        state.scale = 2
        state.offsetY = 0.1
        let spec = TitleSpec(positionX: 0.25, positionY: 0.5)
        let transform = TitleSpec.animationTransform(state, spec: spec, width: 400, height: 200)
        let center = transform.apply(x: 100, y: 100)
        #expect(center.x == 100 && center.y == 120, "the title's centre only moves by the offset")
        #expect(TitleSpec.animationTransform(TitleAnimationState(), spec: spec, width: 400, height: 200) == .identity)
    }

    @Test func oldTitlesLoadWithoutAnAnimation() throws {
        var spec = TitleSpec(text: "Hi")
        spec.animation = TitleAnimation(animateIn: .pop)
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(TitleSpec.self, from: data).animation?.animateIn == .pop)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["animation"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(TitleSpec.self, from: old).animation == nil)
    }
}
