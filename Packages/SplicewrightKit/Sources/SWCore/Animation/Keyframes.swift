import Foundation

/// How a keyframe eases, like Premiere's temporal interpolation. "In" is the approach to
/// the keyframe and "out" is the departure from it.
public enum KeyframeInterpolation: String, Sendable, Hashable, Codable, CaseIterable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    /// The value jumps at the next keyframe instead of changing gradually.
    case hold

    public var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .easeInOut: return "Ease In and Out"
        case .hold: return "Hold"
        }
    }

    var easesOut: Bool { self == .easeOut || self == .easeInOut }
    var easesIn: Bool { self == .easeIn || self == .easeInOut }
}

/// A property value at a moment of a clip's source media.
public struct Keyframe: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    /// Source media time, so keyframes stay with the picture when the clip is trimmed or cut.
    public var time: RationalTime
    /// One number per component (two for Position and Anchor Point).
    public var values: [Double]
    public var interpolation: KeyframeInterpolation

    public init(id: UUID = UUID(), time: RationalTime, values: [Double], interpolation: KeyframeInterpolation = .linear) {
        self.id = id
        self.time = time
        self.values = values
        self.interpolation = interpolation
    }
}

/// A value that is either constant or animated by keyframes (Premiere's stopwatch).
public struct AnimatableProperty: Sendable, Hashable, Codable {
    /// The value when there are no keyframes.
    public var values: [Double]
    /// Sorted by time. Non-empty means the property is animated.
    public private(set) var keyframes: [Keyframe]

    public init(_ values: [Double], keyframes: [Keyframe] = []) {
        self.values = values
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    public var isAnimated: Bool { !keyframes.isEmpty }

    /// The value at a source time: constant before the first and after the last keyframe.
    public func value(at time: RationalTime) -> [Double] {
        guard let first = keyframes.first, let last = keyframes.last else { return values }
        if time <= first.time { return first.values }
        if time >= last.time { return last.values }
        guard let index = keyframes.lastIndex(where: { $0.time <= time }), index + 1 < keyframes.count else {
            return last.values
        }
        let from = keyframes[index]
        let to = keyframes[index + 1]
        if from.interpolation == .hold { return from.values }
        let span = (to.time - from.time).seconds
        let linear = span > 0 ? (time - from.time).seconds / span : 1
        let eased = Self.ease(linear, out: from.interpolation.easesOut, in: to.interpolation.easesIn)
        return zip(from.values, to.values).map { $0 + ($1 - $0) * eased }
    }

    /// Progress along a segment: an eased end starts or arrives with zero speed.
    static func ease(_ t: Double, out easeOut: Bool, in easeIn: Bool) -> Double {
        let t = min(max(t, 0), 1)
        switch (easeOut, easeIn) {
        case (true, true): return t * t * (3 - 2 * t)
        case (true, false): return t * t * (2 - t)
        case (false, true):
            let u = 1 - t
            return 1 - u * u * (2 - u)
        case (false, false): return t
        }
    }

    public func keyframe(at time: RationalTime, tolerance: RationalTime) -> Keyframe? {
        keyframes.first { abs(($0.time - time).seconds) <= tolerance.seconds / 2 }
    }

    /// Sets the value at `time`: adds or updates a keyframe when animated, else the constant.
    public mutating func set(_ newValues: [Double], at time: RationalTime, tolerance: RationalTime) {
        guard isAnimated else {
            values = newValues
            return
        }
        if let existing = keyframe(at: time, tolerance: tolerance),
           let index = keyframes.firstIndex(where: { $0.id == existing.id }) {
            keyframes[index].values = newValues
        } else {
            insert(Keyframe(time: time, values: newValues))
        }
    }

    /// The stopwatch: turning animation on adds a keyframe at `time` with the current value;
    /// turning it off removes every keyframe and keeps the value at `time`.
    public mutating func setAnimated(_ animated: Bool, at time: RationalTime) {
        if animated, !isAnimated {
            insert(Keyframe(time: time, values: values))
        } else if !animated, isAnimated {
            values = value(at: time)
            keyframes = []
        }
    }

    /// Adds a keyframe at `time` holding the current value there (or removes the one already there).
    public mutating func toggleKeyframe(at time: RationalTime, tolerance: RationalTime) {
        if let existing = keyframe(at: time, tolerance: tolerance) {
            remove(existing.id)
        } else {
            insert(Keyframe(time: time, values: value(at: time)))
        }
    }

    public mutating func remove(_ id: UUID) {
        keyframes.removeAll { $0.id == id }
        if keyframes.isEmpty { values = values.isEmpty ? [0] : values }
    }

    /// Moves a keyframe; one already at the destination is replaced.
    public mutating func move(_ id: UUID, to time: RationalTime, tolerance: RationalTime) {
        guard var moving = keyframes.first(where: { $0.id == id }) else { return }
        keyframes.removeAll { $0.id == id || abs(($0.time - time).seconds) <= tolerance.seconds / 2 }
        moving.time = time
        insert(moving)
    }

    public mutating func setInterpolation(_ interpolation: KeyframeInterpolation, for ids: Set<UUID>) {
        for index in keyframes.indices where ids.contains(keyframes[index].id) {
            keyframes[index].interpolation = interpolation
        }
    }

    public func next(after time: RationalTime) -> Keyframe? {
        keyframes.first { $0.time > time }
    }

    public func previous(before time: RationalTime) -> Keyframe? {
        keyframes.last { $0.time < time }
    }

    private mutating func insert(_ keyframe: Keyframe) {
        keyframes.append(keyframe)
        keyframes.sort { $0.time < $1.time }
    }
}
