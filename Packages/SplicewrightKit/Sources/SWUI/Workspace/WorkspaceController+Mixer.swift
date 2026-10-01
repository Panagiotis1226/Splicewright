import Foundation
import SWCore

/// The Audio Track Mixer: track faders and pan, and the Mix fader. Drags are live edits (one
/// undo step when the drag ends); playback hears them without rebuilding.
extension WorkspaceController {
    func setTrackVolume(_ trackID: UUID, dB: Double, live: Bool) {
        mixerEdit("Track Volume", live: live) { $0.setTrackVolume(trackID, dB: dB) }
    }

    func setTrackPan(_ trackID: UUID, _ pan: Double, live: Bool) {
        mixerEdit("Track Pan", live: live) { $0.setTrackPan(trackID, pan) }
    }

    func setMixVolume(dB: Double, live: Bool) {
        mixerEdit("Mix Volume", live: live) { $0.setMixVolume(dB: dB) }
    }

    private func mixerEdit(_ actionName: String, live: Bool, _ change: @escaping (inout EditSequence) -> Void) {
        if live {
            liveEdit(change)
        } else {
            editSequence(actionName) { sequence, _ in change(&sequence) }
        }
    }
}
