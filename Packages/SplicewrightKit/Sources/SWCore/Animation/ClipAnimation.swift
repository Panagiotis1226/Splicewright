import Foundation

public extension Clip {
    func property(_ property: ClipProperty) -> AnimatableProperty {
        property == .volume ? volume : motion[property]
    }

    mutating func updateProperty(_ property: ClipProperty, _ change: (inout AnimatableProperty) -> Void) {
        var value = self.property(property)
        change(&value)
        // Keep every value inside the property's range.
        value.values = value.values.map { min(max($0, property.range.lowerBound), property.range.upperBound) }
        if property == .volume { volume = value } else { motion[property] = value }
    }

    /// Level in dB at a source time (constant or keyframed).
    func volumeDB(at time: RationalTime) -> Double {
        volume.value(at: time).first ?? 0
    }

    /// Whether any of the clip's properties are keyframed.
    var isAnimated: Bool { motion.isAnimated || volume.isAnimated }
}

public extension EditSequence {
    /// Changes one animatable property of a clip.
    mutating func updateProperty(_ property: ClipProperty, of clipID: UUID,
                                 _ change: (inout AnimatableProperty) -> Void) {
        updateClipProperties([clipID]) { $0.updateProperty(property, change) }
    }

    /// Sets a property's value at sequence frame `frame` (a keyframe if it's animated).
    mutating func setProperty(_ property: ClipProperty, of clipID: UUID, to values: [Double], atFrame frame: Int64) {
        guard let clip = clip(clipID) else { return }
        let time = clip.sourceTime(atSequenceFrame: frame, rate: rate)
        let tolerance = rate.frameDuration
        updateProperty(property, of: clipID) { $0.set(values, at: time, tolerance: tolerance) }
    }

    mutating func setUniformScale(_ uniform: Bool, of clipID: UUID) {
        updateClipProperties([clipID]) { $0.motion.uniformScale = uniform }
    }

    /// Resets a property to its default and removes its keyframes.
    mutating func resetProperty(_ property: ClipProperty, of clipID: UUID) {
        updateProperty(property, of: clipID) { $0 = AnimatableProperty(property.defaultValues) }
    }

    /// Copies motion, opacity and volume from one clip to others (Paste Attributes).
    mutating func pasteAttributes(from source: Clip, to ids: Set<UUID>, motion: Bool = true, volume: Bool = true) {
        updateClipProperties(ids) { clip in
            if motion {
                // Keyframes keep their offset from each clip's start.
                clip.motion = source.motion.retimed(by: clip.sourceStart - source.sourceStart)
            }
            if volume { clip.volume = source.volume.retimed(by: clip.sourceStart - source.sourceStart) }
        }
    }
}

public extension AnimatableProperty {
    /// The same animation shifted by `offset` in source time.
    func retimed(by offset: RationalTime) -> AnimatableProperty {
        AnimatableProperty(values, keyframes: keyframes.map { keyframe in
            var moved = keyframe
            moved.time = keyframe.time + offset
            return moved
        })
    }
}

public extension Motion {
    func retimed(by offset: RationalTime) -> Motion {
        var copy = self
        for property in ClipProperty.video { copy[property] = self[property].retimed(by: offset) }
        return copy
    }
}

public extension RenderPlan {
    /// Gain (linear) breakpoints for an audio clip across `range` (sequence frames, which may
    /// include transition handles): clip gain, keyframed volume and fades combined. Volume and
    /// fades are sampled finely enough that straight lines between points follow their curves.
    static func audioEnvelope(for clip: Clip, fades: ClipFades?, range: FrameRange, rate: FrameRate,
                              samplesPerSegment: Int = 8) -> [(frame: Double, gain: Double)] {
        var points: Set<Double> = [Double(range.start), Double(range.end)]
        func subdivide(_ from: Double, _ to: Double) {
            guard to > from else { return }
            for step in 0...samplesPerSegment {
                points.insert(from + (to - from) * Double(step) / Double(samplesPerSegment))
            }
        }
        if let fades {
            for fade in [fades.fadeIn?.range, fades.fadeOut?.range].compactMap({ $0 }) {
                subdivide(Double(fade.start), Double(fade.end))
            }
        }
        let keyframeFrames = clip.volume.keyframes.map {
            Double(clip.sequenceFrame(atSourceTime: $0.time, rate: rate))
        }
        for (index, frame) in keyframeFrames.enumerated() {
            points.insert(frame)
            guard index + 1 < keyframeFrames.count else { continue }
            if clip.volume.keyframes[index].interpolation == .hold {
                // Step just before the next keyframe.
                points.insert(max(frame, keyframeFrames[index + 1] - 0.01))
            } else {
                subdivide(frame, keyframeFrames[index + 1])
            }
        }
        let lower = Double(range.start)
        let upper = Double(range.end)
        return points.filter { $0 >= lower && $0 <= upper }.sorted().map { frame in
            (frame, audioGain(for: clip, fades: fades, atFrame: frame, rate: rate))
        }
    }

    /// Linear gain of an audio clip at a (fractional) sequence frame.
    static func audioGain(for clip: Clip, fades: ClipFades?, atFrame frame: Double, rate: FrameRate) -> Double {
        let time = clip.sourceStart + RationalTime(seconds: (frame - Double(clip.start)) / rate.framesPerSecond,
                                                   timescale: 48_000)
        let level = linearGain(dB: clip.gainDB + clip.volumeDB(at: time))
        return level * (fades?.gain(at: frame) ?? 1)
    }
}
