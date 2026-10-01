import Foundation
import SWCore

/// Where a mask lives: a clip's Opacity or one of its effects.
public struct MaskTarget: Hashable, Sendable {
    public var clipID: UUID
    public var owner: MaskOwner
}

/// One mask, for editing in the Program monitor.
public struct MaskSelection: Hashable, Sendable {
    public var target: MaskTarget
    public var maskID: UUID

    func ref(_ property: MaskProperty) -> PropertyRef { .mask(target.owner, maskID, property) }
}

/// The shapes Effect Controls' mask buttons make.
enum MaskShape { case ellipse, rectangle }

/// Masks: adding them from Effect Controls and editing their paths in the Program monitor.
extension WorkspaceController {
    /// The size masks are fractions of: the media's picture, or the frame for titles and adjustment layers.
    func maskPictureSize(of clip: Clip) -> (width: Double, height: Double) {
        if !clip.isGenerated, let video = project.item(clip.mediaID)?.info.video, video.width > 0, video.height > 0 {
            return (Double(video.width), Double(video.height))
        }
        let settings = activeSequence?.settings
        return (Double(max(settings?.width ?? 1920, 1)), Double(max(settings?.height ?? 1080, 1)))
    }

    /// A circle or square a quarter of the picture's smaller side across, in the middle.
    func addMask(_ shape: MaskShape, to target: MaskTarget) {
        guard let clip = activeSequence?.clip(target.clipID) else { return }
        let size = maskPictureSize(of: clip)
        let radius = 0.25 * min(size.width, size.height)
        let (rx, ry) = (radius / size.width, radius / size.height)
        let mask = shape == .ellipse ? Mask.ellipse(radiusX: rx, radiusY: ry)
            : Mask.rectangle(left: 0.5 - rx, top: 0.5 - ry, right: 0.5 + rx, bottom: 0.5 + ry)
        addMask(mask, to: target)
    }

    func addMask(_ mask: Mask, to target: MaskTarget) {
        var added: UUID?
        editSequence("Add Mask") { sequence, _ in added = sequence.addMask(mask, to: target.owner, of: target.clipID) }
        maskPen = nil
        if let added { selectedMask = MaskSelection(target: target, maskID: added) }
    }

    func removeMask(_ selection: MaskSelection) {
        editSequence("Delete Mask") { sequence, _ in
            sequence.removeMask(selection.maskID, of: selection.target.owner, in: selection.target.clipID)
        }
        if selectedMask == selection { selectedMask = nil }
    }

    func updateMask(_ selection: MaskSelection, _ actionName: String, _ change: @escaping (inout Mask) -> Void) {
        editSequence(actionName) { sequence, _ in
            sequence.updateMask(selection.maskID, of: selection.target.owner, in: selection.target.clipID, change)
        }
    }

    /// The mask as it is at the playhead.
    func mask(_ selection: MaskSelection) -> Mask? {
        activeSequence?.clip(selection.target.clipID)?.masks(of: selection.target.owner)
            .first { $0.id == selection.maskID }
    }

    /// The path's points at the playhead.
    func maskVertices(_ selection: MaskSelection) -> [Mask.Vertex] {
        guard let clip = activeSequence?.clip(selection.target.clipID), let mask = mask(selection) else { return [] }
        return mask.vertices(at: keyframeTime(in: clip, for: selection.ref(.path)))
    }

    /// Sets the path at the playhead (a keyframe there if Mask Path is animated). With `live`
    /// it's one undo step when the drag ends (`endLiveEdit`).
    func setMaskVertices(_ vertices: [Mask.Vertex], of selection: MaskSelection, live: Bool) {
        guard let clip = activeSequence?.clip(selection.target.clipID), let rate = activeSequence?.rate else { return }
        let time = keyframeTime(in: clip, for: selection.ref(.path))
        let change: (inout EditSequence) -> Void = { sequence in
            sequence.updateMask(selection.maskID, of: selection.target.owner, in: selection.target.clipID) { mask in
                mask.setVertices(vertices, at: time, tolerance: rate.frameDuration)
            }
        }
        if live {
            liveEdit(change)
        } else {
            editSequence("Mask Path") { sequence, _ in change(&sequence) }
        }
    }

    func insertMaskVertex(_ selection: MaskSelection, segment: Int, t: Double) {
        updateMask(selection, "Add Mask Point") { $0.insertVertex(segment: segment, t: t) }
    }

    func removeMaskVertex(_ selection: MaskSelection, at index: Int) {
        updateMask(selection, "Delete Mask Point") { $0.removeVertex(at: index) }
    }

    /// Starts drawing a new mask with the Pen in the Program monitor.
    func startMaskPen(_ target: MaskTarget) {
        selectedMask = nil
        maskPen = target
        activeTool = .selection
    }
}
