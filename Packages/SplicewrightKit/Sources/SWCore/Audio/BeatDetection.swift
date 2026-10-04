import Foundation

/// How Detect Beats reads the music and what it does with the beats.
public struct BeatSettings: Sendable, Hashable, Codable {
    /// The tempo it looks for lies in this range; between two candidates it leans towards
    /// `preferredBPM` (most music sits near 120).
    public var minimumBPM: Double
    public var maximumBPM: Double
    public var preferredBPM: Double
    /// Use every Nth beat (2 = every other, 4 = once a bar in 4/4), starting at beat `offset`.
    public var every: Int
    public var offset: Int

    public init(minimumBPM: Double = 60, maximumBPM: Double = 200, preferredBPM: Double = 120, every: Int = 1,
                offset: Int = 0) {
        self.minimumBPM = minimumBPM
        self.maximumBPM = maximumBPM
        self.preferredBPM = preferredBPM
        self.every = every
        self.offset = offset
    }

    public static let bpmRange: ClosedRange<Double> = 30...300

    /// The beats to use from all that were found.
    public func picked<Beat>(_ beats: [Beat]) -> [Beat] {
        let step = max(every, 1)
        let first = min(max(offset, 0), step - 1)
        return beats.enumerated().filter { $0.offset >= first && ($0.offset - first) % step == 0 }.map(\.element)
    }
}

/// The beats found: when each falls (seconds from the start of what was analysed) and the tempo.
public struct BeatAnalysis: Sendable, Hashable {
    public var bpm: Double
    public var beats: [Double]

    public init(bpm: Double, beats: [Double]) {
        self.bpm = bpm
        self.beats = beats
    }
}

/// Finds the beat in music fed to it in buffers, the classic way that holds up across genres:
/// an onset strength envelope from spectral flux (log magnitudes, 2048-sample windows every
/// 512), the tempo from its autocorrelation weighted towards a preferred tempo, then beats by
/// dynamic programming (Ellis 2007, as in librosa): onsets that also keep a steady pulse.
public struct BeatDetector: Sendable {
    public let sampleRate: Double
    static let windowSize = 2048
    static let hop = 512
    private let fft = FFT(size: windowSize)
    private let hann: [Double]
    /// The last `windowSize` mono samples, oldest first, and how many arrived since the last frame.
    private var recent: [Double]
    private var pending = 0
    private var received = 0
    private var previous: [Double]
    private var real: [Double]
    private var imaginary: [Double]
    /// Onset strength per hop.
    private(set) var onsets: [Double] = []
    /// Log-spaced bands from 30 Hz to 11 kHz (like a mel scale), as ranges of spectrum bins, so a
    /// kick's few low bins count as much as a hi-hat's many high ones.
    private let bands: [Range<Int>]

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let size = Self.windowSize
        hann = (0..<size).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(size)) }
        recent = [Double](repeating: 0, count: size)
        real = [Double](repeating: 0, count: size)
        imaginary = [Double](repeating: 0, count: size)
        bands = Self.bands(sampleRate: sampleRate, size: size)
        previous = [Double](repeating: 0, count: bands.count)
    }

    static func bands(sampleRate: Double, size: Int, count: Int = 40) -> [Range<Int>] {
        let binHz = sampleRate / Double(size)
        let (low, high) = (30.0, min(11_000, sampleRate / 2 * 0.95))
        var result: [Range<Int>] = []
        var lower = max(1, Int((low / binHz).rounded()))
        for index in 1...count {
            let edge = low * pow(high / low, Double(index) / Double(count))
            let upper = max(lower + 1, Int((edge / binHz).rounded()))
            guard upper <= size / 2 else { break }
            result.append(lower..<upper)
            lower = upper
        }
        return result
    }

    /// Seconds analysed so far.
    public var duration: Double { Double(received) / sampleRate }

    /// Seconds per onset frame.
    var frameSeconds: Double { Double(Self.hop) / sampleRate }

    public mutating func process(_ channels: [[Float]]) {
        guard let frames = channels.first?.count, !channels.isEmpty else { return }
        let scale = 1 / Double(channels.count)
        for frame in 0..<frames {
            var sum = 0.0
            for channel in channels where frame < channel.count { sum += Double(channel[frame]) }
            recent.append(sum * scale)
            pending += 1
            received += 1
            if pending == Self.hop {
                recent.removeFirst(Self.hop)
                pending = 0
                analyseWindow()
            }
        }
    }

    private mutating func analyseWindow() {
        for index in 0..<Self.windowSize {
            real[index] = recent[index] * hann[index]
            imaginary[index] = 0
        }
        fft.transform(&real, &imaginary)
        var flux = 0.0
        for (index, band) in bands.enumerated() {
            var power = 0.0
            for bin in band { power += real[bin] * real[bin] + imaginary[bin] * imaginary[bin] }
            let level = log1p(100 * (power / Double(band.count)).squareRoot())
            flux += max(0, level - previous[index])
            previous[index] = level
        }
        onsets.append(flux)
    }

    /// The tempo and beats of everything fed in.
    public func analysis(_ settings: BeatSettings = BeatSettings()) -> BeatAnalysis {
        let envelope = Self.normalized(onsets)
        guard envelope.count > 8, envelope.contains(where: { $0 > 0 }) else { return BeatAnalysis(bpm: 0, beats: []) }
        let period = Self.period(envelope, frameSeconds: frameSeconds, settings: settings)
        guard period > 1 else { return BeatAnalysis(bpm: 0, beats: []) }
        let beats = Self.track(envelope, period: period)
        // A window's onset belongs to its centre.
        let lag = Double(Self.windowSize / 2 - Self.hop) / sampleRate
        let times = beats.map { max(0, Double($0) * frameSeconds - lag) }
        return BeatAnalysis(bpm: 60 / (period * frameSeconds), beats: times)
    }

    /// Onset strength with its local average taken off (so a loud passage doesn't look like all
    /// onsets), half-wave rectified, scaled to unit standard deviation.
    static func normalized(_ onsets: [Double]) -> [Double] {
        guard !onsets.isEmpty else { return [] }
        let radius = 16
        var prefix = [0.0]
        for value in onsets { prefix.append((prefix.last ?? 0) + value) }
        var result = onsets.indices.map { index -> Double in
            let low = max(0, index - radius), high = min(onsets.count, index + radius + 1)
            let mean = (prefix[high] - prefix[low]) / Double(high - low)
            return max(0, onsets[index] - mean)
        }
        let mean = result.reduce(0, +) / Double(result.count)
        let deviation = (result.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(result.count)).squareRoot()
        if deviation > 0 { result = result.map { $0 / deviation } }
        return result
    }

    /// The beat period in onset frames: the autocorrelation peak within the tempo range,
    /// weighted by a log-normal prior around the preferred tempo, refined between frames.
    static func period(_ envelope: [Double], frameSeconds: Double, settings: BeatSettings) -> Double {
        let minimum = max(settings.minimumBPM, 1), maximum = max(settings.maximumBPM, minimum + 1)
        let shortest = max(1, Int((60 / maximum / frameSeconds).rounded(.down)))
        let longest = min(envelope.count - 2, Int((60 / minimum / frameSeconds).rounded(.up)))
        guard longest > shortest else { return 0 }
        // Smoothed a little, so a period between two frames still shows as one peak.
        let smooth = envelope.indices.map { index -> Double in
            var sum = 0.0
            for (offset, weight) in zip(-3...3, [0.04, 0.11, 0.21, 0.28, 0.21, 0.11, 0.04])
            where envelope.indices.contains(index + offset) {
                sum += weight * envelope[index + offset]
            }
            return sum
        }
        let mean = smooth.reduce(0, +) / Double(smooth.count)
        let centred = smooth.map { $0 - mean }
        func correlation(_ lag: Int) -> Double {
            var sum = 0.0
            for index in lag..<centred.count { sum += centred[index] * centred[index - lag] }
            return sum / Double(centred.count - lag)
        }
        let values = (shortest - 1...longest + 1).map { correlation(max($0, 1)) }
        func weighted(_ lag: Int) -> Double {
            let bpm = 60 / (Double(lag) * frameSeconds)
            let octaves = log2(bpm / max(settings.preferredBPM, 1))
            return values[lag - shortest + 1] * exp(-0.5 * octaves * octaves)
        }
        guard var best = (shortest...longest).max(by: { weighted($0) < weighted($1) }) else { return 0 }
        // The prior can pick half time when every beat is alike (drum & bass at 174 read as 87):
        // if the pulse at half the period is about as strong, the beats really come that often.
        let half = Int((Double(best) / 2).rounded())
        if half >= shortest, let faster = (max(shortest, half - 1)...min(longest, half + 1))
            .max(by: { values[$0 - shortest + 1] < values[$1 - shortest + 1] }),
            values[faster - shortest + 1] >= 0.8 * values[best - shortest + 1] {
            best = faster
        }
        // A parabola through the peak and its neighbours.
        let (a, b, c) = (values[best - shortest], values[best - shortest + 1], values[best - shortest + 2])
        let denominator = a - 2 * b + c
        let shift = denominator < 0 ? min(max(0.5 * (a - c) / denominator, -0.5), 0.5) : 0
        return Double(best) + shift
    }

    /// The beat frames: each scored by its onset plus the best earlier beat about a period back
    /// (penalised the further the gap strays from the period), then traced back from the end.
    static func track(_ envelope: [Double], period: Double, tightness: Double = 100) -> [Int] {
        let count = envelope.count
        // Onsets smoothed over a narrow window around each frame.
        let reach = max(1, Int(period.rounded()))
        let kernel = (-reach...reach).map { exp(-0.5 * pow(Double($0) * 32 / period, 2)) }
        let local = (0..<count).map { index -> Double in
            var sum = 0.0
            for (offset, weight) in zip(-reach...reach, kernel) where (0..<count).contains(index + offset) {
                sum += weight * envelope[index + offset]
            }
            return sum
        }
        var score = [Double](repeating: 0, count: count)
        var back = [Int](repeating: -1, count: count)
        let peak = local.max() ?? 0
        var started = false
        for index in 0..<count {
            let earliest = index - Int((2 * period).rounded()), latest = index - Int((period / 2).rounded())
            var best = -Double.infinity, from = -1
            if latest >= 0 {
                for candidate in max(0, earliest)...latest {
                    let gap = Double(index - candidate) / period
                    let value = score[candidate] - tightness * pow(log(gap), 2)
                    if value > best { (best, from) = (value, candidate) }
                }
            }
            // Before the music starts there's nothing to follow.
            if !started && local[index] < 0.01 * peak { from = -1 }
            if local[index] >= 0.01 * peak { started = true }
            score[index] = local[index] + (from >= 0 ? best : 0)
            back[index] = from
        }
        // The last beat: the last strong local maximum of the running score.
        var maxima: [Int] = []
        for index in 0..<count {
            let left = index == 0 ? -Double.infinity : score[index - 1]
            let right = index == count - 1 ? -Double.infinity : score[index + 1]
            if score[index] > left && score[index] >= right { maxima.append(index) }
        }
        guard !maxima.isEmpty else { return [] }
        let sorted = maxima.map { score[$0] }.sorted()
        let median = sorted[sorted.count / 2]
        guard var beat = maxima.last(where: { score[$0] >= 0.5 * median }) else { return [] }
        var beats: [Int] = []
        while beat >= 0 {
            beats.append(beat)
            beat = back[beat]
        }
        beats.reverse()
        return trimmed(beats, local: local)
    }

    /// Without weak beats at either end (the tracker carries on into silence or fade-outs).
    static func trimmed(_ beats: [Int], local: [Double]) -> [Int] {
        guard !beats.isEmpty else { return [] }
        let strengths = beats.map { local[$0] }
        let rms = (strengths.map { $0 * $0 }.reduce(0, +) / Double(strengths.count)).squareRoot()
        let threshold = 0.5 * rms
        guard let first = beats.firstIndex(where: { local[$0] >= threshold }),
              let last = beats.lastIndex(where: { local[$0] >= threshold }) else { return [] }
        return Array(beats[first...last])
    }
}

public extension EditSequence {
    /// Marks each beat (sequence frames) with a marker.
    mutating func addBeatMarkers(_ frames: [Int64]) {
        for (index, frame) in frames.sorted().enumerated() {
            markers.append(Marker(frame: frame, name: "Beat \(index + 1)", color: .purple))
        }
        markers.sort { $0.frame < $1.frame }
    }

    /// Beat times (seconds from `start`) as sequence frames, without repeats.
    static func beatFrames(_ beats: [Double], from start: Int64, rate: FrameRate) -> [Int64] {
        var seen = Set<Int64>()
        return beats.map { start + Int64(($0 * rate.framesPerSecond).rounded()) }
            .filter { seen.insert($0).inserted }
    }

    /// Cuts the clips (and their linked clips) at the beats inside them. Returns how many cuts.
    @discardableResult
    mutating func cutOnBeats(_ clipIDs: [UUID], at frames: [Int64]) -> Int {
        clipIDs.reduce(0) { total, id in total + addSceneEdits(to: id, at: frames) }
    }
}

public extension EditSequence {
    /// The sequence with only these audio clips left (to listen to just the music); with none
    /// of them in it, unchanged.
    func soloingAudio(_ clipIDs: Set<UUID>) -> EditSequence {
        guard audioTracks.contains(where: { track in track.clips.contains { clipIDs.contains($0.id) } }) else {
            return self
        }
        var solo = self
        for index in solo.audioTracks.indices {
            solo.audioTracks[index].clips.removeAll { !clipIDs.contains($0.id) }
        }
        return solo
    }
}
