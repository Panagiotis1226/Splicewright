import AppKit
import SWCore

/// Keyframes on timeline clips, as in Premiere: a line through each clip at its Opacity (video)
/// or Volume (audio) over time, with that property's keyframes on the line where they really
/// are. Other properties' keyframes show as small marks along the clip's bottom. Drag a
/// keyframe to move it (⇧ keeps its time), drag the line to change the whole level, ⌘-click
/// the line (or click it with the Pen tool) to add a keyframe. Toggled per track kind.
extension TimelineCanvas {
    func showsKeyframes(_ kind: TrackKind) -> Bool {
        kind == .audio ? timeline.showsAudioKeyframes : timeline.showsVideoKeyframes
    }

    // MARK: - Geometry

    /// The band's drawing area inside a clip.
    private func bandRect(_ rect: CGRect) -> CGRect { rect.insetBy(dx: 0, dy: 5) }

    /// 0...1 up the band for a value: opacity in percent; volume in dB from -60 (bottom) to +15.
    private static func fraction(_ value: Double, _ property: ClipProperty) -> CGFloat {
        switch property {
        case .volume: return value <= -60 ? 0 : CGFloat(min((value + 60) / 75, 1))
        default: return CGFloat(min(max(value / 100, 0), 1))
        }
    }

    private static func value(_ fraction: CGFloat, _ property: ClipProperty) -> Double {
        let f = Double(min(max(fraction, 0), 1))
        switch property {
        case .volume: return f <= 0.001 ? Mixer.silentDB : f * 75 - 60
        default: return (f * 100).rounded()
        }
    }

    private func y(for value: Double, _ property: ClipProperty, in rect: CGRect) -> CGFloat {
        let band = bandRect(rect)
        return band.maxY - Self.fraction(value, property) * band.height
    }

    private func value(atY y: CGFloat, _ property: ClipProperty, in rect: CGRect) -> Double {
        let band = bandRect(rect)
        return Self.value((band.maxY - y) / max(band.height, 1), property)
    }

    private func bandValue(_ clip: Clip, _ property: ClipProperty, at frame: Int64, rate: FrameRate) -> Double {
        let clamped = min(max(frame, clip.start), clip.end - 1)
        let time = clip.keyframeTime(for: .clip(property), atSequenceFrame: clamped, rate: rate)
        return clip.property(property).value(at: time).first ?? 0
    }

    // MARK: - Drawing

    func drawKeyframes(_ clip: Clip, in rect: CGRect, kind: TrackKind, rate: FrameRate) {
        guard showsKeyframes(kind), rect.width > 6 else { return }
        let property = Clip.rubberBandProperty(isAudio: kind == .audio)
        let animated = clip.property(property)
        let visible = rect.intersection(CGRect(x: TimelineLayout.headerWidth, y: rect.minY,
                                               width: max(bounds.width - TimelineLayout.headerWidth, 0), height: rect.height))
        guard !visible.isEmpty else { return }
        let lineColor = kind == .audio ? NSColor.systemYellow.withAlphaComponent(0.85) : NSColor(white: 1, alpha: 0.7)
        // The level over time, sampled every few points so Bezier curves show.
        let line = NSBezierPath()
        var x = visible.minX
        while x <= visible.maxX + 0.5 {
            let point = CGPoint(x: x, y: y(for: bandValue(clip, property, at: frame(at: x), rate: rate), property, in: rect))
            if x == visible.minX { line.move(to: point) } else { line.line(to: point) }
            x += animated.isAnimated ? 3 : max(visible.width, 1)
        }
        lineColor.setStroke()
        line.lineWidth = 1
        line.stroke()

        // That property's keyframes on the line; the others along the bottom.
        var onLine: Set<Int64> = []
        for keyframe in animated.keyframes {
            let frame = clip.sequenceFrame(ofKeyframeTime: keyframe.time, for: .clip(property), rate: rate)
            guard clip.range.contains(frame) else { continue }
            onLine.insert(frame)
            let center = CGPoint(x: self.x(for: frame), y: y(for: keyframe.values.first ?? 0, property, in: rect))
            drawDiamond(at: center, size: 8, filled: true,
                        color: timeline.selectedKeyframes.contains(keyframe.id) ? NSColor(Theme.accent) : lineColor)
        }
        for frame in clip.keyframeFrames(rate: rate) where !onLine.contains(frame) {
            drawDiamond(at: CGPoint(x: self.x(for: frame), y: rect.maxY - 4), size: 6, filled: false,
                        color: NSColor(white: 1, alpha: 0.75))
        }
    }

    private func drawDiamond(at center: CGPoint, size: CGFloat, filled: Bool, color: NSColor) {
        let half = size / 2
        let path = NSBezierPath()
        path.move(to: CGPoint(x: center.x, y: center.y - half))
        path.line(to: CGPoint(x: center.x + half, y: center.y))
        path.line(to: CGPoint(x: center.x, y: center.y + half))
        path.line(to: CGPoint(x: center.x - half, y: center.y))
        path.close()
        if filled {
            color.setFill()
            path.fill()
            NSColor(white: 0, alpha: 0.6).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        } else {
            color.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    // MARK: - Hit testing

    struct KeyframeHit {
        var clip: Clip
        var property: ClipProperty
        var keyframe: Keyframe?
        var rect: CGRect
    }

    /// A keyframe diamond under the point, or else the line (within 4 pt), on a clip whose
    /// track shows keyframes.
    func keyframeHit(at point: CGPoint, in sequence: EditSequence) -> KeyframeHit? {
        guard let row = row(at: point, in: sequence), showsKeyframes(row.kind), let track = sequence.track(row.trackID),
              let clip = track.clips.first(where: { clipRect($0, in: row).insetBy(dx: -4, dy: 0).contains(point) })
        else { return nil }
        let rect = clipRect(clip, in: row)
        let property = Clip.rubberBandProperty(isAudio: row.kind == .audio)
        let rate = sequence.rate
        for keyframe in clip.property(property).keyframes {
            let frame = clip.sequenceFrame(ofKeyframeTime: keyframe.time, for: .clip(property), rate: rate)
            let center = CGPoint(x: x(for: frame), y: y(for: keyframe.values.first ?? 0, property, in: rect))
            if abs(center.x - point.x) <= 6 && abs(center.y - point.y) <= 6 {
                return KeyframeHit(clip: clip, property: property, keyframe: keyframe, rect: rect)
            }
        }
        // The line: not within the edge grab zones, where trims take over.
        guard point.x > rect.minX + TimelineLayout.edgeGrabWidth, point.x < rect.maxX - TimelineLayout.edgeGrabWidth else {
            return nil
        }
        let lineY = y(for: bandValue(clip, property, at: frame(at: point.x), rate: rate), property, in: rect)
        return abs(lineY - point.y) <= 4 ? KeyframeHit(clip: clip, property: property, keyframe: nil, rect: rect) : nil
    }

    // MARK: - Mouse

    /// Handles a click on a keyframe or the line; returns false to let the clip handle it.
    func keyframeMouseDown(at point: CGPoint, event: NSEvent, in sequence: EditSequence) -> Bool {
        let tool = workspace.activeTool
        guard tool == .selection || tool == .pen, let hit = keyframeHit(at: point, in: sequence) else {
            if !event.modifierFlags.contains(.shift) { timeline.selectedKeyframes = [] }
            return false
        }
        let adding = tool == .pen || event.modifierFlags.contains(.command)
        if let keyframe = hit.keyframe {
            if event.modifierFlags.contains(.shift) {
                timeline.selectedKeyframes.formSymmetricDifference([keyframe.id])
            } else if !timeline.selectedKeyframes.contains(keyframe.id) {
                timeline.selectedKeyframes = [keyframe.id]
            }
            timeline.selection = [hit.clip.id]
            drag = Drag(kind: .keyframe(clipID: hit.clip.id, keyframeID: keyframe.id, property: hit.property),
                        original: sequence, actionName: "Move Keyframe")
            return true
        }
        timeline.selection = [hit.clip.id]
        timeline.selectedKeyframes = []
        if adding {
            addKeyframe(on: hit, at: point, in: sequence)
            return true
        }
        drag = Drag(kind: .band(clipID: hit.clip.id, property: hit.property), original: sequence,
                    actionName: hit.property == .volume ? "Adjust Volume" : "Adjust Opacity")
        return true
    }

    /// ⌘-click or Pen tool click on the line: a keyframe there, at the line's current value.
    private func addKeyframe(on hit: KeyframeHit, at point: CGPoint, in sequence: EditSequence) {
        let property = hit.property
        let frame = min(max(frame(at: point.x), hit.clip.start), hit.clip.end - 1)
        let value = bandValue(hit.clip, property, at: frame, rate: sequence.rate)
        let time = hit.clip.keyframeTime(for: .clip(property), atSequenceFrame: frame, rate: sequence.rate)
        let tolerance = sequence.rate.frameDuration
        var added: UUID?
        workspace.editSequence("Add Keyframe") { sequence, _ in
            sequence.updateProperty(property, of: hit.clip.id) { animated in
                animated.setAnimated(true, at: time)
                animated.set([value], at: time, tolerance: tolerance)
                added = animated.keyframe(at: time, tolerance: tolerance)?.id
            }
        }
        if let added { timeline.selectedKeyframes = [added] }
    }

    /// The sequence while a keyframe or the line is being dragged.
    func keyframePreview(_ kind: DragKind, original: EditSequence, point: CGPoint) -> EditSequence {
        var copy = original
        let rate = original.rate
        switch kind {
        case .keyframe(let clipID, let keyframeID, let property):
            guard let clip = original.clip(clipID), let rect = clipRectOnScreen(clipID, in: original),
                  let keyframe = clip.property(property).keyframes.first(where: { $0.id == keyframeID }) else { return copy }
            let startFrame = clip.sequenceFrame(ofKeyframeTime: keyframe.time, for: .clip(property), rate: rate)
            var frame = startFrame + frameDelta(from: dragOrigin, to: point)
            if NSEvent.modifierFlags.contains(.shift) { frame = startFrame }
            let playhead = workspace.program.currentFrame
            if timeline.isSnapping, abs(frame - playhead) <= snapThreshold {
                frame = playhead
                timeline.snapFrame = playhead
            }
            frame = min(max(frame, clip.start), clip.end - 1)
            let time = clip.keyframeTime(for: .clip(property), atSequenceFrame: frame, rate: rate)
            let newValue = value(atY: point.y, property, in: rect)
            copy.updateProperty(property, of: clipID) { animated in
                animated.move(keyframeID, to: time, tolerance: rate.frameDuration)
                animated.setValue(newValue, component: 0, of: keyframeID)
            }
        case .band(let clipID, let property):
            guard let clip = original.clip(clipID), let rect = clipRectOnScreen(clipID, in: original) else { return copy }
            let change = value(atY: point.y, property, in: rect) - value(atY: dragOrigin.y, property, in: rect)
            let range = property.range
            copy.updateProperty(property, of: clipID) { animated in
                if animated.isAnimated {
                    // The whole curve moves, keyframes and all.
                    for keyframe in clip.property(property).keyframes {
                        let moved = min(max((keyframe.values.first ?? 0) + change, range.lowerBound), range.upperBound)
                        animated.setValue(moved, component: 0, of: keyframe.id)
                    }
                } else {
                    let base = clip.property(property).values.first ?? 0
                    animated.values = [min(max(base + change, range.lowerBound), range.upperBound)]
                }
            }
        default:
            break
        }
        return copy
    }

    private func clipRectOnScreen(_ clipID: UUID, in sequence: EditSequence) -> CGRect? {
        for row in rows(for: sequence) {
            if let clip = sequence.track(row.trackID)?.clips.first(where: { $0.id == clipID }) { return clipRect(clip, in: row) }
        }
        return nil
    }

    // MARK: - Menus

    /// Right-click on a keyframe: its interpolation and Delete.
    func keyframeMenu(at point: CGPoint, in sequence: EditSequence) -> NSMenu? {
        guard let hit = keyframeHit(at: point, in: sequence), let keyframe = hit.keyframe else { return nil }
        if !timeline.selectedKeyframes.contains(keyframe.id) { timeline.selectedKeyframes = [keyframe.id] }
        let ids = timeline.selectedKeyframes
        let menu = NSMenu()
        for interpolation in KeyframeInterpolation.allCases {
            let item = ActionMenuItem(interpolation.displayName) { [weak self] in
                self?.workspace.setInterpolation(interpolation, ids: ids, .clip(hit.property), of: hit.clip.id)
            }
            item.state = keyframe.interpolation == interpolation ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Delete") { [weak self] in
            self?.workspace.deleteKeyframes(ids, .clip(hit.property), of: hit.clip.id)
            self?.timeline.selectedKeyframes = []
        })
        return menu
    }

    /// "Show Video Keyframes" / "Show Audio Keyframes" items for timeline menus.
    func keyframeVisibilityItems() -> [NSMenuItem] {
        let video = ActionMenuItem("Show Video Keyframes") { [weak self] in self?.timeline.showsVideoKeyframes.toggle() }
        video.state = timeline.showsVideoKeyframes ? .on : .off
        let audio = ActionMenuItem("Show Audio Keyframes") { [weak self] in self?.timeline.showsAudioKeyframes.toggle() }
        audio.state = timeline.showsAudioKeyframes ? .on : .off
        return [video, audio]
    }
}
