import Foundation

/// The Audio Track Mixer's levels: track faders and pan, and the Mix fader.
public enum Mixer {
    /// At or below this, a fader is silent (shown as -∞).
    public static let silentDB = -96.0
    public static let maximumDB = 6.0

    /// The linear gain for a fader position in dB.
    public static func gain(dB: Double) -> Double {
        dB <= silentDB ? 0 : pow(10, min(dB, maximumDB) / 20)
    }

    /// Left and right gains for a pan from -100 (left) to 100 (right). Like Premiere's balance on
    /// a stereo track: the centre leaves both sides alone, and turning one way fades the other
    /// side out along an equal-power curve.
    public static func balance(_ pan: Double) -> (left: Double, right: Double) {
        let amount = min(max(pan, -100), 100) / 100
        let left = amount > 0 ? cos(amount * .pi / 2) : 1
        let right = amount < 0 ? cos(-amount * .pi / 2) : 1
        return (left, right)
    }

    /// "-∞" or "-6.0" for a fader readout.
    public static func label(dB: Double) -> String {
        guard dB > silentDB else { return "-∞" }
        let tenths = (dB * 10).rounded() / 10
        return tenths == 0 ? "0.0" : (tenths > 0 ? "+" : "") + String(tenths)
    }
}

public extension EditSequence {
    mutating func setTrackVolume(_ trackID: UUID, dB: Double) {
        updateTrack(trackID) { $0.volumeDB = min(max(dB, Mixer.silentDB), Mixer.maximumDB) }
    }

    mutating func setTrackPan(_ trackID: UUID, _ pan: Double) {
        updateTrack(trackID) { $0.pan = min(max(pan, -100), 100) }
    }

    mutating func setMixVolume(dB: Double) {
        mixVolumeDB = min(max(dB, Mixer.silentDB), Mixer.maximumDB)
    }
}
