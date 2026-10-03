import Foundation

/// How Scene Edit Detection decides where a shot changes.
public struct SceneSettings: Sendable, Hashable, Codable {
    /// 0...100: higher finds more (and softer) cuts.
    public var sensitivity: Double
    /// Shots shorter than this aren't split again (flashes, quick pans).
    public var minimumSeconds: Double

    public init(sensitivity: Double = 50, minimumSeconds: Double = 0.5) {
        self.sensitivity = sensitivity
        self.minimumSeconds = minimumSeconds
    }

    /// The change from one frame to the next a cut needs (average 0...255 difference).
    var minimumChange: Double { 30 - 22 * min(max(sensitivity, 0), 100) / 100 }
    /// How many times larger than the frames around it that change must be.
    var contrast: Double { 5 - 3 * min(max(sensitivity, 0), 100) / 100 }
}

/// A frame shrunk for scene detection: 8-bit BGRA, any small size (64 pixels across is plenty).
public struct SceneFrame: Sendable {
    public var width: Int
    public var height: Int
    public var bgra: [UInt8]

    public init(width: Int, height: Int, bgra: [UInt8]) {
        self.width = width
        self.height = height
        self.bgra = bgra
    }
}

/// Finds the hard cuts in a run of frames, as an adaptive content detector does: how much each
/// frame's colors differ from the previous one (luma and both chroma channels), and a cut where
/// that jump is both large and several times the change in the frames around it, so motion,
/// pans and flicker that change every frame don't count. Dissolves and fades aren't cuts.
public struct SceneDetector: Sendable {
    public let settings: SceneSettings
    public let fps: Double
    /// The previous two frames as Y, Cb, Cr per pixel.
    private var previous: [Float] = []
    private var beforePrevious: [Float] = []
    /// Change into each frame (index 0 has none).
    private var changes: [Double] = []
    /// Change from two frames back: small across a one-frame flash.
    private var skipChanges: [Double] = []

    public init(settings: SceneSettings, fps: Double) {
        self.settings = settings
        self.fps = max(fps, 1)
    }

    public var frameCount: Int { changes.count }

    public mutating func add(_ frame: SceneFrame) {
        let pixels = frame.width * frame.height
        var current = [Float](repeating: 0, count: pixels * 3)
        for index in 0..<min(pixels, frame.bgra.count / 4) {
            let blue = Float(frame.bgra[index * 4])
            let green = Float(frame.bgra[index * 4 + 1])
            let red = Float(frame.bgra[index * 4 + 2])
            current[index * 3] = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            current[index * 3 + 1] = 0.5389 * (blue - current[index * 3])
            current[index * 3 + 2] = 0.6350 * (red - current[index * 3])
        }
        changes.append(Self.difference(previous, current))
        skipChanges.append(beforePrevious.isEmpty ? .infinity : Self.difference(beforePrevious, current))
        beforePrevious = previous
        previous = current
    }

    /// Average absolute difference per channel (0 for frames of different sizes).
    private static func difference(_ first: [Float], _ second: [Float]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 0 }
        var sum: Float = 0
        for index in first.indices { sum += abs(first[index] - second[index]) }
        return Double(sum) / Double(first.count)
    }

    /// The frames (counted from the first one added) that start a new shot.
    public func cuts() -> [Int] {
        let minimumGap = max(1, Int((settings.minimumSeconds * fps).rounded()))
        var cuts: [Int] = []
        var last = 0
        for index in 1..<max(changes.count, 1) {
            let change = changes[index]
            guard change >= settings.minimumChange else { continue }
            let around = (max(1, index - 2)...min(changes.count - 1, index + 2)).filter { $0 != index }.map { changes[$0] }
            let typical = around.isEmpty ? 0 : around.reduce(0, +) / Double(around.count)
            guard change >= settings.contrast * max(typical, 1), index - last >= minimumGap else { continue }
            // A flash: the frame after it is the shot from before again.
            if index + 1 < changes.count, skipChanges[index + 1] < settings.minimumChange { continue }
            cuts.append(index)
            last = index
        }
        return cuts
    }
}

public extension EditSequence {
    /// Adds edits at `frames` through the clip and its linked clips. Returns how many were made.
    @discardableResult
    mutating func addSceneEdits(to clipID: UUID, at frames: [Int64]) -> Int {
        guard let clip = clip(clipID) else { return 0 }
        let linked = allTracks.filter { track in
            track.clips.contains { $0.id == clipID || (clip.linkID != nil && $0.linkID == clip.linkID) }
        }.map(\.id)
        let inside = frames.filter { $0 > clip.start && $0 < clip.end }
        for frame in inside { razor(at: frame, trackIDs: Set(linked)) }
        return inside.count
    }

    /// Marks each cut with a marker named for the shot it starts.
    mutating func addSceneMarkers(_ frames: [Int64], clipName: String) {
        for (index, frame) in frames.sorted().enumerated() {
            markers.append(Marker(frame: frame, name: "\(clipName) – scene \(index + 2)"))
        }
        markers.sort { $0.frame < $1.frame }
    }
}
