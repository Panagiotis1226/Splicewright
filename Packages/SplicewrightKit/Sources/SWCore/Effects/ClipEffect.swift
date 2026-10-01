import Foundation

/// The video and audio effects in the Effects panel. Parameters are keyframeable, like Motion.
public enum EffectKind: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case crop, gaussianBlur, dropShadow, sharpen, horizontalFlip, verticalFlip, mirror
    /// Lumetri-style basic correction (with RGB curves) and a .cube look-up table.
    case colorCorrection, lut
    case parametricEQ, compressor, hardLimiter

    public var id: String { rawValue }

    public var isAudio: Bool {
        switch self {
        case .parametricEQ, .compressor, .hardLimiter: return true
        default: return false
        }
    }

    public static var video: [EffectKind] { allCases.filter { !$0.isAudio } }
    public static var audio: [EffectKind] { allCases.filter(\.isAudio) }

    public var displayName: String {
        switch self {
        case .crop: return "Crop"
        case .gaussianBlur: return "Gaussian Blur"
        case .dropShadow: return "Drop Shadow"
        case .sharpen: return "Sharpen"
        case .horizontalFlip: return "Horizontal Flip"
        case .verticalFlip: return "Vertical Flip"
        case .mirror: return "Mirror"
        case .colorCorrection: return "Color Correction"
        case .lut: return "LUT"
        case .parametricEQ: return "Parametric EQ"
        case .compressor: return "Compressor"
        case .hardLimiter: return "Hard Limiter"
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
        case .colorCorrection:
            return [.init("exposure", "Exposure", unit: "stops", range: -4...4, step: 0.01),
                    .init("contrast", "Contrast", unit: "", range: -100...100, step: 0.5),
                    .init("highlights", "Highlights", unit: "", range: -100...100, step: 0.5),
                    .init("shadows", "Shadows", unit: "", range: -100...100, step: 0.5),
                    .init("whites", "Whites", unit: "", range: -100...100, step: 0.5),
                    .init("blacks", "Blacks", unit: "", range: -100...100, step: 0.5),
                    .init("temperature", "Temperature", unit: "", range: -100...100, step: 0.5),
                    .init("tint", "Tint", unit: "", range: -100...100, step: 0.5),
                    .init("saturation", "Saturation", unit: "", range: 0...200, step: 0.5, default: 100),
                    .init("vibrance", "Vibrance", unit: "", range: -100...100, step: 0.5)]
        case .lut:
            return [.init("intensity", "Intensity", unit: "%", range: 0...100, step: 0.5, default: 100)]
        case .mirror:
            return [.init("center", "Reflection Center", unit: "%", range: 0...100, step: 0.2, default: 50),
                    .init("angle", "Reflection Angle", unit: "°", range: -360...360, step: 0.5)]
        case .parametricEQ:
            return [.init("lowFrequency", "Low Frequency", unit: "Hz", range: 20...1000, step: 1, default: 100),
                    .init("lowGain", "Low Gain", unit: "dB", range: -18...18, step: 0.1),
                    .init("midFrequency", "Mid Frequency", unit: "Hz", range: 100...10000, step: 5, default: 1000),
                    .init("midGain", "Mid Gain", unit: "dB", range: -18...18, step: 0.1),
                    .init("midQ", "Mid Q", unit: "", range: 0.1...10, step: 0.01, default: 1),
                    .init("highFrequency", "High Frequency", unit: "Hz", range: 1000...20000, step: 10, default: 8000),
                    .init("highGain", "High Gain", unit: "dB", range: -18...18, step: 0.1)]
        case .compressor:
            return [.init("threshold", "Threshold", unit: "dB", range: -60...0, step: 0.1, default: -20),
                    .init("ratio", "Ratio", unit: ":1", range: 1...20, step: 0.05, default: 4),
                    .init("attack", "Attack", unit: "ms", range: 0.1...200, step: 0.1, default: 10),
                    .init("release", "Release", unit: "ms", range: 5...2000, step: 1, default: 100),
                    .init("makeup", "Makeup Gain", unit: "dB", range: 0...24, step: 0.1)]
        case .hardLimiter:
            return [.init("ceiling", "Maximum Amplitude", unit: "dB", range: -24...0, step: 0.1, default: -1),
                    .init("inputBoost", "Input Boost", unit: "dB", range: 0...24, step: 0.1)]
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
        case .colorCorrection: return "camera.filters"
        case .lut: return "cube"
        case .parametricEQ: return "slider.vertical.3"
        case .compressor: return "arrow.down.right.and.arrow.up.left"
        case .hardLimiter: return "chart.line.flattrend.xyaxis"
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
public struct ClipEffect: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var kind: EffectKind
    public var isEnabled: Bool
    /// Values by parameter key, in source time like Motion.
    public var parameters: [String: AnimatableProperty]
    /// LUT: the .cube file it applies. Schema 10.
    public var lutPath: String?
    /// Color Correction: its RGB curves (nil is straight). Schema 10.
    public var curves: ColorCurves?
    /// The effect applies only inside these (none: everywhere). Schema 10.
    public var masks: [Mask] = []

    public init(id: UUID = UUID(), kind: EffectKind, isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        parameters = Dictionary(uniqueKeysWithValues: kind.parameters.map { ($0.key, AnimatableProperty([$0.defaultValue])) })
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, isEnabled, parameters, lutPath, curves, masks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(EffectKind.self, forKey: .kind)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        parameters = try container.decodeIfPresent([String: AnimatableProperty].self, forKey: .parameters) ?? [:]
        lutPath = try container.decodeIfPresent(String.self, forKey: .lutPath)
        curves = try container.decodeIfPresent(ColorCurves.self, forKey: .curves)
        masks = try container.decodeIfPresent([Mask].self, forKey: .masks) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(parameters, forKey: .parameters)
        try container.encodeIfPresent(lutPath, forKey: .lutPath)
        try container.encodeIfPresent(curves, forKey: .curves)
        if !masks.isEmpty { try container.encode(masks, forKey: .masks) }
    }

    public func parameter(_ key: String) -> AnimatableProperty {
        parameters[key] ?? AnimatableProperty([kind.parameters.first { $0.key == key }?.defaultValue ?? 0])
    }

    /// A parameter's value at a source time.
    public func value(_ key: String, at time: RationalTime) -> Double {
        parameter(key).value(at: time).first ?? 0
    }

    public var isAnimated: Bool { parameters.values.contains(where: \.isAnimated) || masks.contains(where: \.isAnimated) }

    /// Every parameter's value at `time`, for rendering.
    public func resolved(at time: RationalTime) -> ResolvedEffect {
        let values = kind.parameters.map { ($0.key, value($0.key, at: time)) }
        var resolved = ResolvedEffect(kind: kind, values: Dictionary(uniqueKeysWithValues: values))
        resolved.lutPath = lutPath
        resolved.curves = curves
        resolved.masks = masks.map { $0.resolved(at: time) }
        return resolved
    }

    /// The same effect with its keyframes shifted (for Paste Attributes).
    func retimed(by offset: RationalTime) -> ClipEffect {
        var copy = self
        copy.id = UUID()
        copy.parameters = parameters.mapValues { $0.retimed(by: offset) }
        copy.masks = masks.map { $0.retimed(by: offset) }
        return copy
    }
}

/// An effect's values at one frame.
public struct ResolvedEffect: Sendable, Hashable {
    public var kind: EffectKind
    public var values: [String: Double]
    public var lutPath: String?
    public var curves: ColorCurves?
    /// Where the effect applies (none: everywhere).
    public var masks: [ResolvedMask] = []

    public init(kind: EffectKind, values: [String: Double]) {
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
        case .horizontalFlip, .verticalFlip, .mirror, .hardLimiter: return false
        case .parametricEQ: return ["lowGain", "midGain", "highGain"].allSatisfy { self[$0] == 0 }
        case .compressor: return self["ratio"] <= 1 && self["makeup"] <= 0
        case .colorCorrection:
            let neutral = kind.parameters.allSatisfy { abs(self[$0.key] - $0.defaultValue) < 1e-9 }
            return neutral && (curves?.isIdentity ?? true)
        case .lut: return lutPath == nil || self["intensity"] <= 0
        }
    }
}

public extension Clip {
    /// Video effects drawn at a source time: enabled ones that do something, in stack order.
    func resolvedEffects(at time: RationalTime) -> [ResolvedEffect] {
        effects.filter { $0.isEnabled && !$0.kind.isAudio }.map { $0.resolved(at: time) }.filter { !$0.isNoOp }
    }

    /// Audio effects heard at a source time, in stack order.
    func resolvedAudioEffects(at time: RationalTime) -> [ResolvedEffect] {
        effects.filter { $0.isEnabled && $0.kind.isAudio }.map { $0.resolved(at: time) }.filter { !$0.isNoOp }
    }
}

public extension EditSequence {
    /// Adds an effect to the end of each clip's stack: video effects to video clips, audio
    /// effects to audio clips (others are skipped). Returns the new effects' IDs by clip.
    @discardableResult
    mutating func addEffect(_ kind: EffectKind, to ids: Set<UUID>) -> [UUID: UUID] {
        var added: [UUID: UUID] = [:]
        let tracks = kind.isAudio ? audioTracks : videoTracks
        let matching = ids.intersection(tracks.flatMap { $0.clips.map(\.id) })
        updateClipProperties(matching) { clip in
            let effect = ClipEffect(kind: kind)
            clip.effects.append(effect)
            added[clip.id] = effect.id
        }
        return added
    }

    mutating func updateEffect(_ effectID: UUID, of clipID: UUID, _ change: (inout ClipEffect) -> Void) {
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
