import Foundation

/// Auto Reframe Sequence: a copy of the sequence at another shape (vertical for Reels, square,
/// 4:5), each clip scaled to fill it and panned to keep its subject in frame.
public struct ReframeSettings: Sendable, Hashable, Codable {
    public enum Aspect: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
        case vertical, portrait, square, widescreen

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .vertical: return "Vertical 9:16"
            case .portrait: return "Vertical 4:5"
            case .square: return "Square 1:1"
            case .widescreen: return "Horizontal 16:9"
            }
        }

        /// Width over height.
        public var ratio: Double {
            switch self {
            case .vertical: return 9.0 / 16
            case .portrait: return 4.0 / 5
            case .square: return 1
            case .widescreen: return 16.0 / 9
            }
        }

        public var suffix: String {
            switch self {
            case .vertical: return "9x16"
            case .portrait: return "4x5"
            case .square: return "1x1"
            case .widescreen: return "16x9"
            }
        }
    }

    /// How quickly the frame follows the subject (Premiere's Motion Tracking presets).
    public enum Pace: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
        case slower, standard, faster

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .slower: return "Slower Motion"
            case .standard: return "Default"
            case .faster: return "Faster Motion"
            }
        }

        /// Seconds the path is smoothed over, and between keyframes.
        var smoothing: Double {
            switch self {
            case .slower: return 1.2
            case .standard: return 0.6
            case .faster: return 0.25
            }
        }

        var keyframeSpacing: Double {
            switch self {
            case .slower: return 1
            case .standard: return 0.5
            case .faster: return 0.25
            }
        }
    }

    public var aspect: Aspect
    public var pace: Pace

    public init(aspect: Aspect = .vertical, pace: Pace = .standard) {
        self.aspect = aspect
        self.pace = pace
    }

    /// The new frame size: the sequence's height kept for narrower shapes (1080 × 1920 from
    /// 1920 × 1080), its width for wider ones; even numbers for the encoders.
    public func frameSize(from settings: SequenceSettings) -> (width: Int, height: Int) {
        let long = Double(max(settings.width, settings.height))
        let (width, height) = aspect.ratio <= 1 ? (long * aspect.ratio, long) : (long, long / aspect.ratio)
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (even(width), even(height))
    }
}

/// Where the subject is in one analysed frame: its centre as fractions of the picture as shown
/// (0,0 top left), and how sure the analysis is (0 when nothing was found).
public struct ReframeSample: Sendable, Hashable, Codable {
    public var time: Double
    public var x: Double
    public var y: Double
    public var confidence: Double

    public init(time: Double, x: Double, y: Double, confidence: Double) {
        self.time = time
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}

public enum ReframePath {
    /// A steady path through the samples (source seconds, in order): low-confidence samples
    /// hold the last good position, single-frame outliers are dropped by a median, then the
    /// path is smoothed over the pace's time. A jump of more than a quarter of the picture
    /// (a shot change) starts a new stretch, smoothed on its own.
    public static func smoothed(_ samples: [ReframeSample], pace: ReframeSettings.Pace) -> [[ReframeSample]] {
        guard !samples.isEmpty else { return [] }
        var filled: [ReframeSample] = []
        var last = samples.first { $0.confidence > 0.2 } ?? ReframeSample(time: 0, x: 0.5, y: 0.5, confidence: 0)
        for sample in samples {
            if sample.confidence > 0.2 { last = sample }
            filled.append(ReframeSample(time: sample.time, x: last.x, y: last.y, confidence: sample.confidence))
        }
        let median = medianFiltered(filled)
        var stretches: [[ReframeSample]] = [[]]
        for sample in median {
            if let previous = stretches[stretches.count - 1].last,
               max(abs(sample.x - previous.x), abs(sample.y - previous.y)) > 0.25 {
                stretches.append([])
            }
            stretches[stretches.count - 1].append(sample)
        }
        return stretches.map { gaussian($0, sigma: pace.smoothing / 2) }
    }

    static func medianFiltered(_ samples: [ReframeSample]) -> [ReframeSample] {
        samples.indices.map { index in
            let window = samples[max(0, index - 2)...min(samples.count - 1, index + 2)]
            func middle(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            var sample = samples[index]
            sample.x = middle(window.map(\.x))
            sample.y = middle(window.map(\.y))
            return sample
        }
    }

    static func gaussian(_ samples: [ReframeSample], sigma: Double) -> [ReframeSample] {
        guard sigma > 0 else { return samples }
        return samples.map { sample in
            var (sumX, sumY, total) = (0.0, 0.0, 0.0)
            for other in samples where abs(other.time - sample.time) <= 3 * sigma {
                let weight = exp(-0.5 * pow((other.time - sample.time) / sigma, 2))
                (sumX, sumY, total) = (sumX + weight * other.x, sumY + weight * other.y, total + weight)
            }
            var smoothed = sample
            if total > 0 { (smoothed.x, smoothed.y) = (sumX / total, sumY / total) }
            return smoothed
        }
    }
}

/// How a clip's picture sits in the reframed sequence.
public struct ReframeGeometry: Sendable, Hashable {
    /// The picture as shown (after rotation), in its own pixels.
    public var pictureWidth: Double
    public var pictureHeight: Double
    public var frameWidth: Double
    public var frameHeight: Double

    public init(pictureWidth: Double, pictureHeight: Double, frameWidth: Double, frameHeight: Double) {
        self.pictureWidth = pictureWidth
        self.pictureHeight = pictureHeight
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
    }

    /// The picture fills the frame when it's fitted (as every clip is) and then scaled by this
    /// much (Motion Scale, %).
    public var fillScale: Double {
        let fit = min(frameWidth / pictureWidth, frameHeight / pictureHeight)
        let cover = max(frameWidth / pictureWidth, frameHeight / pictureHeight)
        return cover / fit * 100
    }

    /// The Motion Position (offset from the frame's centre, sequence pixels) that brings the
    /// picture's point (`x`, `y`) to the centre, as far as it can without showing an edge.
    public func position(x: Double, y: Double) -> [Double] {
        let cover = max(frameWidth / pictureWidth, frameHeight / pictureHeight)
        let (width, height) = (pictureWidth * cover, pictureHeight * cover)
        let limitX = max(0, (width - frameWidth) / 2), limitY = max(0, (height - frameHeight) / 2)
        let dx = -(x - 0.5) * width, dy = -(y - 0.5) * height
        return [min(max(dx, -limitX), limitX), min(max(dy, -limitY), limitY)]
    }
}

public extension EditSequence {
    /// A copy at the new shape, named for it. Every clip with a picture (not titles or adjustment
    /// layers) is scaled to fill the frame; those with an analysed path pan along it, keyed
    /// every so often, with a held jump at each shot change. Without a path a clip stays centred.
    func reframed(_ settings: ReframeSettings, pictures: [UUID: (width: Double, height: Double)],
                  paths: [UUID: [ReframeSample]]) -> EditSequence {
        var copy = self
        copy.id = UUID()
        copy.name = "\(name) (\(settings.aspect.suffix))"
        let size = settings.frameSize(from: self.settings)
        copy.settings.width = size.width
        copy.settings.height = size.height
        for index in copy.videoTracks.indices {
            for clipIndex in copy.videoTracks[index].clips.indices {
                let clip = copy.videoTracks[index].clips[clipIndex]
                guard !clip.isGenerated, let picture = pictures[clip.id], picture.width > 0,
                      picture.height > 0 else { continue }
                let geometry = ReframeGeometry(pictureWidth: picture.width, pictureHeight: picture.height,
                                               frameWidth: Double(size.width), frameHeight: Double(size.height))
                copy.videoTracks[index].clips[clipIndex].motion = Self.reframedMotion(
                    clip.motion, geometry: geometry, path: paths[clip.id] ?? [], pace: settings.pace)
            }
        }
        return copy
    }

    internal static func reframedMotion(_ motion: Motion, geometry: ReframeGeometry, path: [ReframeSample],
                                        pace: ReframeSettings.Pace) -> Motion {
        var reframed = motion
        reframed.scale = AnimatableProperty([geometry.fillScale])
        reframed.uniformScale = true
        reframed.anchorPoint = AnimatableProperty([0, 0])
        let stretches = ReframePath.smoothed(path, pace: pace)
        let first = stretches.first?.first
        reframed.position = AnimatableProperty(first.map { geometry.position(x: $0.x, y: $0.y) } ?? [0, 0])
        let keys = stretches.flatMap { keyframes($0, spacing: pace.keyframeSpacing) }
        guard keys.count > 1 else { return reframed }
        let frames = keys.enumerated().map { offset, key in
            // Straight between keys (the path is already smooth, and a curve could overshoot past
            // the edge limit); at a shot change, hold up to it, then jump.
            Keyframe(time: RationalTime(seconds: key.sample.time, timescale: 90_000),
                     values: geometry.position(x: key.sample.x, y: key.sample.y),
                     interpolation: offset + 1 < keys.count && key.cutAfter ? .hold : .linear)
        }
        let position = AnimatableProperty(reframed.position.values, keyframes: frames)
        reframed.position = position
        return reframed
    }

    /// Samples every `spacing` seconds through a stretch, always with its first and last.
    private static func keyframes(_ stretch: [ReframeSample],
                                  spacing: Double) -> [(sample: ReframeSample, cutAfter: Bool)] {
        guard let first = stretch.first, let last = stretch.last else { return [] }
        var picked = [first]
        for sample in stretch.dropFirst() where sample.time - (picked.last?.time ?? 0) >= spacing - 1e-9 {
            picked.append(sample)
        }
        if picked.last != last { picked.append(last) }
        return picked.enumerated().map { ($0.element, $0.offset == picked.count - 1) }
    }
}
