import Foundation

/// How a title comes on and goes off: a preset for each end (like Premiere's animated text
/// presets or CapCut's text In/Out), over a length in seconds.
public struct TitleAnimation: Sendable, Hashable, Codable {
    public enum Style: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
        case none, fade, slideUp, slideDown, slideLeft, slideRight, pop, zoom, typewriter, wordByWord

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .none: return "None"
            case .fade: return "Fade"
            case .slideUp: return "Slide Up"
            case .slideDown: return "Slide Down"
            case .slideLeft: return "Slide Left"
            case .slideRight: return "Slide Right"
            case .pop: return "Pop"
            case .zoom: return "Zoom"
            case .typewriter: return "Typewriter"
            case .wordByWord: return "Word by Word"
            }
        }
    }

    public var animateIn: Style
    public var animateOut: Style
    /// Seconds each end takes; both shrink to fit a short clip.
    public var inDuration: Double
    public var outDuration: Double

    public init(animateIn: Style = .none, animateOut: Style = .none, inDuration: Double = 0.6,
                outDuration: Double = 0.4) {
        self.animateIn = animateIn
        self.animateOut = animateOut
        self.inDuration = inDuration
        self.outDuration = outDuration
    }

    public static let durationRange: ClosedRange<Double> = 0.1...5

    public var isNone: Bool { animateIn == .none && animateOut == .none }

    /// The title `time` seconds into a clip `duration` seconds long.
    public func state(at time: Double, duration: Double) -> TitleAnimationState {
        let length = max(duration, 0)
        var ins = animateIn == .none ? 0 : max(inDuration, 0)
        var outs = animateOut == .none ? 0 : max(outDuration, 0)
        if ins + outs > length, ins + outs > 0 {
            let k = length / (ins + outs)
            ins *= k
            outs *= k
        }
        if ins > 0, time < ins {
            return Self.state(animateIn, progress: max(time, 0) / ins, entering: true)
        }
        if outs > 0, time > length - outs {
            return Self.state(animateOut, progress: max(length - time, 0) / outs, entering: false)
        }
        return TitleAnimationState()
    }

    /// `progress` runs 0 → 1 as the title arrives (in) and 1 → 0 as it leaves (out).
    static func state(_ style: Style, progress: Double, entering: Bool) -> TitleAnimationState {
        let p = min(max(progress, 0), 1)
        let eased = 1 - pow(1 - p, 3)
        var state = TitleAnimationState()
        // Slides keep going the same way on the way out.
        let travel = entering ? 1 - eased : -(1 - eased)
        switch style {
        case .none:
            break
        case .fade:
            state.opacity = p
        case .slideUp:
            state.opacity = p
            state.offsetY = 0.08 * travel
        case .slideDown:
            state.opacity = p
            state.offsetY = -0.08 * travel
        case .slideLeft:
            state.opacity = p
            state.offsetX = 0.1 * travel
        case .slideRight:
            state.opacity = p
            state.offsetX = -0.1 * travel
        case .pop:
            state.opacity = min(1, p * 3)
            state.scale = Self.backOut(p)
        case .zoom:
            state.opacity = p
            state.scale = 1.4 - 0.4 * eased
        case .typewriter:
            state.reveal = .characters(p)
        case .wordByWord:
            state.reveal = .words(p)
        }
        return state
    }

    /// Overshoots past 1, then settles on it.
    static func backOut(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
}

/// A title's look at one moment of its animation.
public struct TitleAnimationState: Sendable, Hashable {
    public enum Reveal: Sendable, Hashable {
        /// Typewriter: this fraction of the characters shows.
        case characters(Double)
        /// Word by word: words fade in one after another over this progress.
        case words(Double)
    }

    public var opacity: Double = 1
    /// Offsets as fractions of the frame (x of its width, y of its height); scale about the
    /// title's position.
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    public var scale: Double = 1
    public var reveal: Reveal?

    public init() {}

    public var isIdentity: Bool { self == TitleAnimationState() }

    /// The text's hidden or fading parts: UTF-16 ranges with their opacity (in steps of 1/8, so
    /// rasterized frames can be reused). Empty when all the text shows.
    public func textOpacity(_ text: String) -> [TitleTextOpacity] {
        switch reveal {
        case nil:
            return []
        case .characters(let progress):
            let characters = Array(text.indices)
            let shown = Int((min(max(progress, 0), 1) * Double(characters.count)).rounded(.down))
            guard shown < characters.count else { return [] }
            let start = text.utf16.distance(from: text.startIndex, to: characters[shown])
            return [TitleTextOpacity(location: start, length: text.utf16.count - start, opacity: 0)]
        case .words(let progress):
            let words = Self.words(text)
            guard !words.isEmpty else { return [] }
            let count = Double(words.count)
            // Each word fades in over a window; the windows overlap so the line flows.
            let window = min(1, 1.5 / count)
            let step = count > 1 ? (1 - window) / (count - 1) : 0
            var parts: [TitleTextOpacity] = []
            for (index, word) in words.enumerated() {
                let alpha = min(max((progress - Double(index) * step) / window, 0), 1)
                let quantized = (alpha * 8).rounded(.down) / 8
                guard quantized < 1 else { continue }
                parts.append(TitleTextOpacity(location: word.location, length: word.length, opacity: quantized))
            }
            return parts
        }
    }

    /// The UTF-16 ranges of the words (runs without whitespace).
    static func words(_ text: String) -> [(location: Int, length: Int)] {
        var result: [(location: Int, length: Int)] = []
        var start: Int?
        var offset = 0
        for character in text {
            let width = character.utf16.count
            if character.isWhitespace {
                if let begun = start { result.append((begun, offset - begun)) }
                start = nil
            } else if start == nil {
                start = offset
            }
            offset += width
        }
        if let begun = start { result.append((begun, offset - begun)) }
        return result
    }
}

/// Part of a title's text drawn at an opacity (a typewriter's hidden tail, a word fading in).
public struct TitleTextOpacity: Sendable, Hashable {
    public var location: Int
    public var length: Int
    public var opacity: Double

    public init(location: Int, length: Int, opacity: Double) {
        self.location = location
        self.length = length
        self.opacity = opacity
    }
}

public extension TitleSpec {
    /// Where the title sits and how it's scaled at one moment of its animation, in pixels of a
    /// `width` × `height` frame (applied before the clip's Motion).
    static func animationTransform(_ state: TitleAnimationState, spec: TitleSpec, width: Double,
                                   height: Double) -> Affine2D {
        guard state.scale != 1 || state.offsetX != 0 || state.offsetY != 0 else { return .identity }
        let cx = spec.positionX * width, cy = spec.positionY * height
        let s = max(state.scale, 0)
        return Affine2D(a: s, b: 0, c: 0, d: s, tx: cx - s * cx + state.offsetX * width,
                        ty: cy - s * cy + state.offsetY * height)
    }
}
