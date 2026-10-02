import Foundation

/// Clean Up Dialogue: a chain of ordinary audio effects tuned for speech, added in one go.
public enum DialoguePreset {
    /// Each effect and its values: rumble cut and a little presence, the noise taken down,
    /// levels evened out, and peaks kept under -1 dB.
    public static let chain: [(EffectKind, [String: Double])] = [
        (.parametricEQ, ["lowFrequency": 90, "lowGain": -12, "midFrequency": 3000, "midGain": 2.5, "midQ": 1,
                         "highFrequency": 10000, "highGain": 0]),
        (.noiseReduction, ["amount": 50, "reduction": 15]),
        (.compressor, ["threshold": -22, "ratio": 3, "attack": 5, "release": 120, "makeup": 4]),
        (.hardLimiter, ["ceiling": -1, "inputBoost": 0]),
    ]
}

public extension EditSequence {
    /// Adds the Clean Up Dialogue chain to the audio clips among `ids`; returns how many got it.
    @discardableResult
    mutating func cleanUpDialogue(_ ids: Set<UUID>) -> Int {
        var count = 0
        for (kind, values) in DialoguePreset.chain {
            let added = addEffect(kind, to: ids)
            count = max(count, added.count)
            for (clipID, effectID) in added {
                updateEffect(effectID, of: clipID) { effect in
                    for (key, value) in values { effect.parameters[key] = AnimatableProperty([value]) }
                }
            }
        }
        return count
    }
}
