import AppKit
import SWCore

/// Clip ▸ Add Frame Hold and Insert Frame Hold Segment, at the playhead; Group and Ungroup.
extension WorkspaceController {
    /// How long Insert Frame Hold Segment holds, as in Premiere.
    static let frameHoldSegmentSeconds = 2.0

    /// From the playhead to the clip's end, the selected (or top) video clip shows the frame there.
    public func addFrameHold() {
        let frame = program.currentFrame
        guard let clip = footageClip(at: frame) else {
            NSSound.beep()
            return
        }
        var hold: UUID?
        editSequence("Add Frame Hold") { sequence, _ in hold = sequence.addFrameHold(to: clip.id, at: frame) }
        if let hold { timeline.selection = [hold] }
    }

    /// Splits the selected (or top) video clip at the playhead and inserts two seconds of the frame there.
    public func insertFrameHoldSegment() {
        let frame = program.currentFrame
        guard let clip = footageClip(at: frame), let rate = activeSequence?.rate else {
            NSSound.beep()
            return
        }
        let length = Int64((Self.frameHoldSegmentSeconds * rate.framesPerSecond).rounded())
        var hold: UUID?
        editSequence("Insert Frame Hold Segment") { sequence, _ in
            hold = sequence.insertFrameHoldSegment(in: clip.id, at: frame, length: length)
        }
        if let hold { timeline.selection = [hold] }
    }

    /// Clip ▸ Group: the selected clips (and their linked partners) select and move together.
    public func groupSelectedClips() {
        let ids = timeline.selection
        var changed = false
        editSequence("Group") { sequence, _ in changed = sequence.setGrouped(ids, true) }
        if !changed { NSSound.beep() }
    }

    /// Clip ▸ Ungroup: the selected clips' groups come apart.
    public func ungroupSelectedClips() {
        let ids = timeline.selection
        var changed = false
        editSequence("Ungroup") { sequence, _ in changed = sequence.setGrouped(ids, false) }
        if !changed { NSSound.beep() }
    }
}
