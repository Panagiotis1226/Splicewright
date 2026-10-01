import Foundation

/// The video effects in the Effects panel. Parameters are keyframeable, like Motion.
public enum VideoEffectKind: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case crop, gaussianBlur, dropShadow, sharpen, horizontalFlip, verticalFlip, mirror

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .crop: return "Crop"
        case .gaussianBlur: return "Gaussian Blur"
        case .dropShadow: return "Drop Shadow"
        case .sharpen: return "Sharpen"
        case .horizontalFlip: return "Horizontal Flip"
        case .verticalFlip: return "Vertical Flip"
        case .mirror: return "Mirror"
        }
    }

    public var parameters: [EffectParameter] {
        switch self {
        case .crop:
            return [.init("left", "Left", unit: "%", range: 0...100, step: 0.2),
                    .init("top", "Top", unit: "%", range: 0...100, step: 0.2),
                    .init("right", "Right", unit: "%", range: 0...100, step: 0.2),
                    .init("bottom", "Bottom", unit: "%", range: 0...100, step: 0.2),
                    .init("feather", "Edge Feather", unit: "px", range: 0...500, step: 0.5)]
        case .gaussianBlur:
            return [.init("blurriness", "Blurriness", unit: "px", range: 0...500, step: 0.5)]
        case .dropShadow:
            return [.init("opacity", "Opacity", unit: "%", range: 0...100, step: 0.5, default: 50),
                    .init("direction", "Direction", unit: "°", range: -360...360, step: 0.5, default: 135),
                    .init("distance", "Distance", unit: "px", range: 0...4000, step: 0.5, default: 10),
                    .init("softness", "Softness", unit: "px", range: 0...500, step: 0.5, default: 10)]
        case .sharpen:
            return [.init("amount", "Sharpen Amount", unit: "", range: 0...4000, step: 1, default: 25)]
        case .horizontalFlip, .verticalFlip:
            return []
        case .mirror:
            return [.init("center", "Reflection Center", unit: "%", range: 0...100, step: 0.2, default: 50),
                    .init("angle", "Reflection Angle", unit: "°", range: -360...360, step: 0.5)]
        }
    }

    public var symbol: String {
        switch self {
        case .crop: return "crop"
        case .gaussianBlur: return "drop.halffull"
        case .dropShadow: return "square.on.square.squareshape.controlhandles"
        case .sharpen: return "triangle"
        case .horizontalFlip: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .verticalFlip: return "arrow.up.and.down.righttriangle.up.righttriangle.down"
        case .mirror: return "rectangle.lefthalf.inset.filled"
        }
    }
}

/// One keyframeable number of an effect.
public struct EffectParameter: Sendable, Hashable {
    public var key: String
    public var displayName: String
    public var unit: String
    public var range: ClosedRange<Double>
    public var dragStep: Double
    public var defaultValue: Double

    public init(_ key: String, _ displayName: String, unit: String, range: ClosedRange<Double>, step: Double,
                default defaultValue: Double = 0) {
        self.key = key
        self.displayName = displayName
        self.unit = unit
        self.range = range
        dragStep = step
        self.defaultValue = defaultValue
    }
}

/// An effect applied to a clip (or an adjustment layer), in the clip's effect stack.
public struct VideoEffect: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var kind: VideoEffectKind
    public var isEnabled: Bool
    /// Values by parameter key, in source time like Motion.
    public var parameters: [String: AnimatableProperty]

    public init(id: UUID = UUID(), kind: VideoEffectKind, isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        parameters = Dictionary(uniqueKeysWithValues: kind.parameters.map { ($0.key, AnimatableProperty([$0.defaultValue])) })
    }

    public func parameter(_ key: String) -> AnimatableProperty {
        parameters[key] ?? AnimatableProperty([kind.parameters.first { $0.key == key }?.defaultValue ?? 0])
    }

    /// A parameter's value at a source time.
    public func value(_ key: String, at time: RationalTime) -> Double {
        parameter(key).value(at: time).first ?? 0
    }

    public var isAnimated: Bool { parameters.values.contains(where: \.isAnimated) }

    /// Every parameter's value at `time`, for rendering.
    public func resolved(at time: RationalTime) -> ResolvedEffect {
        let values = kind.parameters.map { ($0.key, value($0.key, at: time)) }
        return ResolvedEffect(kind: kind, values: Dictionary(uniqueKeysWithValues: values))
    }

    /// The same effect with its keyframes shifted (for Paste Attributes).
    func retimed(by offset: RationalTime) -> VideoEffect {
        var copy = self
        copy.id = UUID()
        copy.parameters = parameters.mapValues { $0.retimed(by: offset) }
        return copy
    }
}

/// An effect's values at one frame.
public struct ResolvedEffect: Sendable, Hashable {
    public var kind: VideoEffectKind
    public var values: [String: Double]

    public init(kind: VideoEffectKind, values: [String: Double]) {
        self.kind = kind
        self.values = values
    }

    public subscript(_ key: String) -> Double { values[key] ?? 0 }

    /// Whether drawing it changes anything (a zero blur or crop is skipped).
    public var isNoOp: Bool {
        switch kind {
        case .crop: return ["left", "top", "right", "bottom"].allSatisfy { self[$0] <= 0 }
        case .gaussianBlur: return self["blurriness"] <= 0
        case .dropShadow: return self["opacity"] <= 0
        case .sharpen: return self["amount"] <= 0
        case .horizontalFlip, .verticalFlip, .mirror: return false
        }
    }
}

public extension Clip {
    /// Effects drawn at a source time: enabled ones that do something, in stack order.
    func resolvedEffects(at time: RationalTime) -> [ResolvedEffect] {
        effects.filter(\.isEnabled).map { $0.resolved(at: time) }.filter { !$0.isNoOp }
    }
}

public extension EditSequence {
    /// Adds an effect to the end of each video clip's stack (audio clips are skipped). Returns
    /// the new effects' IDs by clip.
    @discardableResult
    mutating func addEffect(_ kind: VideoEffectKind, to ids: Set<UUID>) -> [UUID: UUID] {
        var added: [UUID: UUID] = [:]
        let videoIDs = ids.intersection(videoTracks.flatMap { $0.clips.map(\.id) })
        updateClipProperties(videoIDs) { clip in
            let effect = VideoEffect(kind: kind)
            clip.effects.append(effect)
            added[clip.id] = effect.id
        }
        return added
    }

    mutating func updateEffect(_ effectID: UUID, of clipID: UUID, _ change: (inout VideoEffect) -> Void) {
        updateClipProperties([clipID]) { clip in
            guard let index = clip.effects.firstIndex(where: { $0.id == effectID }) else { return }
            change(&clip.effects[index])
            let effect = clip.effects[index]
            // Keep every value within its parameter's range.
            for parameter in effect.kind.parameters {
                guard var property = effect.parameters[parameter.key] else { continue }
                property.values = property.values.map { min(max($0, parameter.range.lowerBound), parameter.range.upperBound) }
                clip.effects[index].parameters[parameter.key] = property
            }
        }
    }

    mutating func removeEffect(_ effectID: UUID, from clipID: UUID) {
        updateClipProperties([clipID]) { $0.effects.removeAll { $0.id == effectID } }
    }

    /// Moves an effect up (-1) or down (+1) the stack.
    mutating func moveEffect(_ effectID: UUID, of clipID: UUID, by offset: Int) {
        updateClipProperties([clipID]) { clip in
            guard let index = clip.effects.firstIndex(where: { $0.id == effectID }) else { return }
            let target = min(max(index + offset, 0), clip.effects.count - 1)
            guard target != index else { return }
            clip.effects.insert(clip.effects.remove(at: index), at: target)
        }
    }

    /// Adds an adjustment layer: a clip with no media whose effects apply to everything below it.
    /// Without a track, it goes on the first free track above every clip in its range (V2 at the
    /// lowest, like a title; a new track if there's none), so it covers what's there.
    @discardableResult
    mutating func addAdjustmentLayer(at frame: Int64, duration: Int64? = nil, trackID: UUID? = nil) -> UUID? {
        let length = max(1, duration ?? Int64((5 * rate.framesPerSecond).rounded()))
        let range = FrameRange(start: max(0, frame), end: max(0, frame) + length)
        var target: UUID?
        if let trackID {
            guard let track = track(trackID), track.kind == .video, !track.isLocked else { return nil }
            target = trackID
        } else {
            let topmost = videoTracks.lastIndex { !$0.isEmpty(in: range) } ?? -1
            target = videoTracks.dropFirst(max(topmost + 1, 1)).first { !$0.isLocked && $0.isEmpty(in: range) }?.id
            if target == nil {
                addTrack(.video)
                target = videoTracks.last?.id
            }
        }
        guard let target else { return nil }
        var clip = Clip(mediaID: Clip.generatedMediaID, name: "Adjustment Layer", start: range.start, duration: length,
                        sourceStart: .zero)
        clip.isAdjustment = true
        overwrite([TrackPlacement(trackID: target, clip: clip)])
        return clip.id
    }
}
