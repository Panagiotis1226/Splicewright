import AppKit
import SwiftUI
import SWCore
import SWPlayback
import SWMedia

extension TimelineCanvas {
    override func draw(_ dirtyRect: NSRect) {
        // During playback only the playhead timecode in the corner changes.
        if Self.timecodeCorner.contains(dirtyRect), let sequence {
            drawPlayheadTimecode(rate: sequence.rate)
            return
        }
        NSColor(Theme.panelBackground).setFill()
        bounds.fill()
        guard let sequence else {
            drawEmptyState()
            return
        }
        let rows = rows(for: sequence)
        let lanes = CGRect(x: TimelineLayout.headerWidth, y: TimelineLayout.rulerHeight,
                           width: laneWidth, height: max(0, bounds.height - TimelineLayout.rulerHeight))

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: lanes).addClip()
        for row in rows {
            drawLane(row, sequence: sequence)
        }
        drawCaptionLanes(sequence)
        drawMarkedRange(sequence, in: lanes)
        drawDropTarget(rows)
        drawSnapLine(in: lanes)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CGRect(x: 0, y: TimelineLayout.rulerHeight, width: TimelineLayout.headerWidth,
                                  height: lanes.height)).addClip()
        for row in rows {
            drawHeader(row, track: sequence.track(row.trackID))
        }
        drawCaptionHeaders(sequence)
        NSGraphicsContext.restoreGraphicsState()

        drawRuler(sequence)
    }

    private func drawEmptyState() {
        let text = "Drag clips here to create a sequence, or choose Sequence ▸ New Sequence…"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(Theme.textSecondary),
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                withAttributes: attributes)
        if timeline.dropTarget != nil {
            NSColor(Theme.accent).setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 4, yRadius: 4)
            path.lineWidth = 2
            path.stroke()
        }
    }

    // MARK: - Lanes and clips

    private func drawLane(_ row: TimelineLayout.Row, sequence: EditSequence) {
        guard row.rect.maxY >= TimelineLayout.rulerHeight, row.rect.minY <= bounds.height,
              let track = sequence.track(row.trackID) else { return }
        NSColor(white: row.kind == .video ? 0.125 : 0.115, alpha: 1).setFill()
        CGRect(x: TimelineLayout.headerWidth, y: row.rect.minY, width: laneWidth, height: row.rect.height).fill()
        let firstVisible = frame(at: TimelineLayout.headerWidth) - 1
        let lastVisible = frame(at: bounds.width) + 1
        for clip in track.clips where clip.end >= firstVisible && clip.start <= lastVisible {
            drawClip(clip, in: row, track: track)
        }
        for transition in track.resolvedTransitions
        where transition.range.end >= firstVisible && transition.range.start <= lastVisible {
            drawTransition(transition, in: row)
        }
        if track.isLocked {
            NSColor(white: 0, alpha: 0.35).setFill()
            CGRect(x: TimelineLayout.headerWidth, y: row.rect.minY, width: laneWidth, height: row.rect.height)
                .fill(using: .sourceOver)
        }
    }

    private func drawClip(_ clip: Clip, in row: TimelineLayout.Row, track: Track) {
        let rect = clipRect(clip, in: row)
        let item = workspace.project.item(clip.mediaID)
        let online = clip.isGenerated || (item.map { MediaLocator.isOnline($0) } ?? false)
        let selected = timeline.selection.contains(clip.id)
        var base = row.kind == .video ? NSColor(Theme.videoTrack) : NSColor(Theme.audioTrack)
        if clip.isTitle { base = NSColor(Theme.titleClip) }
        if clip.isAdjustment { base = NSColor(Theme.adjustmentClip) }
        if !online { base = NSColor(Theme.offline) }
        if !clip.isEnabled || !track.isOutputEnabled { base = base.blended(withFraction: 0.6, of: .darkGray) ?? base }
        if selected { base = base.blended(withFraction: 0.35, of: .white) ?? base }

        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        base.setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        var textX = rect.minX + 4
        if let item, row.kind == .video, rect.width > 24, let image = timeline.thumbnail(for: item) {
            let height = rect.height
            let width = min(rect.width, height * CGFloat(image.width) / CGFloat(max(image.height, 1)))
            // NSImage respects the flipped coordinate system; a raw CGContext draw would not.
            NSImage(cgImage: image, size: NSSize(width: width, height: height))
                .draw(in: CGRect(x: rect.minX, y: rect.minY, width: width, height: height), from: .zero,
                      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            textX += width
        }
        if let item, row.kind == .audio, let peaks = timeline.waveform(for: item) {
            drawWaveform(peaks, clip: clip, in: rect)
        }
        drawClipLabel(clip, at: CGPoint(x: textX, y: rect.minY + 2), maxX: rect.maxX - 4, online: online,
                      marksKeyframes: !showsKeyframes(row.kind))
        if let rate = sequence?.rate {
            drawClipMarkers(clip, in: rect, rate: rate)
            drawKeyframes(clip, in: rect, kind: row.kind, rate: rate)
        }
        NSGraphicsContext.restoreGraphicsState()

        if selected {
            NSColor.white.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    /// A transition is a band across the top of its clips, so the clips below stay clickable.
    private func drawTransition(_ transition: ResolvedTransition, in row: TimelineLayout.Row) {
        let rect = transitionRect(transition, in: row)
        let selected = timeline.selectedTransition == transition.id
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        NSColor(white: selected ? 0.85 : 0.62, alpha: 0.92).setFill()
        path.fill()
        NSColor(white: 0, alpha: 0.5).setStroke()
        path.lineWidth = 1
        path.stroke()
        // A diagonal shows the mix direction, as in Premiere.
        let diagonal = NSBezierPath()
        diagonal.move(to: CGPoint(x: rect.minX + 1, y: rect.maxY - 1))
        diagonal.line(to: CGPoint(x: rect.maxX - 1, y: rect.minY + 1))
        NSColor(white: 0, alpha: 0.35).setStroke()
        diagonal.stroke()
        if repeatsFrames(transition) {
            // Not enough source media beyond the cut: frames are held. Mark the corner red.
            let corner = NSBezierPath()
            corner.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            corner.line(to: CGPoint(x: rect.maxX - 7, y: rect.minY))
            corner.line(to: CGPoint(x: rect.maxX, y: rect.minY + 7))
            corner.close()
            NSColor.systemRed.setFill()
            corner.fill()
        }
        guard rect.width > 40 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.8),
        ]
        (transition.kind.displayName as NSString).draw(in: rect.insetBy(dx: 4, dy: 1), withAttributes: attributes)
    }

    /// True when a side of the transition has to hold its first or last frame.
    func repeatsFrames(_ transition: ResolvedTransition) -> Bool {
        guard let sequence else { return false }
        let rate = sequence.rate
        func mediaFrames(_ clip: Clip) -> Int64? {
            workspace.project.item(clip.mediaID)?.info.duration.frameIndex(at: rate)
        }
        if let left = transition.right != nil ? transition.left : nil, let total = mediaFrames(left) {
            let tail = total - left.sourceStart.frameIndex(at: rate) - left.duration
            if tail < transition.after { return true }
        }
        if let right = transition.left != nil ? transition.right : nil {
            if right.sourceStart.frameIndex(at: rate) < transition.before { return true }
        }
        return false
    }

    private func drawClipLabel(_ clip: Clip, at point: CGPoint, maxX: CGFloat, online: Bool, marksKeyframes: Bool) {
        guard maxX - point.x > 14 else { return }
        var label = online ? clip.name : "\(clip.name) (offline)"
        // With keyframes hidden on the timeline, ◆ says the clip has some.
        if marksKeyframes && clip.isAnimated { label = "◆ " + label }
        // fx marks clips with video effects, as in Premiere.
        if !clip.effects.isEmpty { label = "fx " + label }
        if clip.opacity < 1 && !clip.motion.opacity.isAnimated { label += "  \(Int((clip.opacity * 100).rounded()))%" }
        if clip.gainDB != 0 { label += String(format: "  %+.1f dB", clip.gainDB) }
        // Premiere shows the speed after the name.
        if clip.speed.isAnimated {
            label += "  [Time Remap]"
        } else if clip.isRetimed {
            let percent = clip.speedPercent
            let text = percent == percent.rounded() ? String(Int(percent)) : String(format: "%.1f", percent)
            label += "  [\(clip.isReversed ? "-" : "")\(text)%]"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        (label as NSString).draw(in: CGRect(x: point.x, y: point.y, width: maxX - point.x, height: 14),
                                 withAttributes: attributes)
    }

    private func drawWaveform(_ peaks: WaveformPeaks, clip: Clip, in rect: CGRect) {
        guard let sequence else { return }
        let visibleMin = max(rect.minX, TimelineLayout.headerWidth)
        let visibleMax = min(rect.maxX, bounds.width)
        guard visibleMax > visibleMin else { return }
        let secondsPerPoint = sequence.rate.frameDuration.seconds / Double(pixelsPerFrame)
        let clipSource = clip.sourceStart.seconds
        let midY = rect.midY + 4
        let halfHeight = (rect.height - 16) / 2
        let gain = Float(RenderPlan.linearGain(dB: clip.gainDB))
        let path = NSBezierPath()
        var column = visibleMin.rounded(.down)
        while column < visibleMax {
            let start = clipSource + Double(column - rect.minX) * secondsPerPoint
            let amplitude = CGFloat(min(1, peaks.peak(from: start, to: start + secondsPerPoint) * gain))
            let half = max(0.5, amplitude * halfHeight)
            path.appendRect(CGRect(x: column, y: midY - half, width: 1, height: half * 2))
            column += 1
        }
        NSColor.white.withAlphaComponent(0.45).setFill()
        path.fill()
    }

    private func drawMarkedRange(_ sequence: EditSequence, in lanes: CGRect) {
        guard let range = sequence.marks.range else { return }
        NSColor(white: 1, alpha: 0.06).setFill()
        CGRect(x: x(for: range.start), y: lanes.minY, width: CGFloat(range.length) * pixelsPerFrame,
               height: lanes.height).fill(using: .sourceOver)
    }

    private func drawDropTarget(_ rows: [TimelineLayout.Row]) {
        guard let target = timeline.dropTarget, let row = rows.first(where: { $0.trackID == target.trackID }) else {
            return
        }
        let rect = CGRect(x: x(for: target.frame), y: row.rect.minY + 2,
                          width: max(2, CGFloat(target.length) * pixelsPerFrame), height: row.rect.height - 4)
        NSColor(Theme.accent).withAlphaComponent(0.35).setFill()
        rect.fill(using: .sourceOver)
        NSColor(Theme.accent).setStroke()
        NSBezierPath(rect: rect).stroke()
    }

    private func drawSnapLine(in lanes: CGRect) {
        guard let frame = timeline.snapFrame else { return }
        NSColor.systemYellow.setFill()
        CGRect(x: x(for: frame) - 0.5, y: lanes.minY, width: 1, height: lanes.height).fill()
    }

    // MARK: - Headers

    private func drawHeader(_ row: TimelineLayout.Row, track: Track?) {
        guard let track else { return }
        let rect = CGRect(x: 0, y: row.rect.minY, width: TimelineLayout.headerWidth, height: row.rect.height)
        NSColor(Theme.panelHeader).setFill()
        rect.fill()
        NSColor(Theme.divider).setFill()
        CGRect(x: TimelineLayout.headerWidth - 1, y: rect.minY, width: 1, height: rect.height).fill()

        for control in TimelineLayout.HeaderControl.controls(for: row.kind) {
            let controlRect = control.rect(in: row.rect, kind: row.kind)
            switch control {
            case .target:
                let fill = track.isTargeted ? NSColor(Theme.accent) : NSColor(white: 0.25, alpha: 1)
                fill.setFill()
                NSBezierPath(roundedRect: controlRect, xRadius: 3, yRadius: 3).fill()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
                ]
                let size = (row.name as NSString).size(withAttributes: attributes)
                (row.name as NSString).draw(at: CGPoint(x: controlRect.midX - size.width / 2,
                                                        y: controlRect.midY - size.height / 2),
                                            withAttributes: attributes)
            default:
                let (symbol, active) = symbolName(for: control, track: track, kind: row.kind)
                let color = active ? NSColor(Theme.textPrimary) : NSColor(Theme.textSecondary).withAlphaComponent(0.6)
                drawSymbol(symbol, in: controlRect, color: color)
            }
        }
    }

    func symbolName(for control: TimelineLayout.HeaderControl, track: Track, kind: TrackKind) -> (String, Bool) {
        switch control {
        case .target: return ("", track.isTargeted)
        case .lock: return (track.isLocked ? "lock.fill" : "lock.open", track.isLocked)
        case .syncLock: return ("arrow.triangle.2.circlepath", track.isSyncLocked)
        case .output:
            if kind == .video { return (track.isOutputEnabled ? "eye" : "eye.slash", track.isOutputEnabled) }
            return (track.isOutputEnabled ? "speaker.wave.2" : "speaker.slash.fill", track.isOutputEnabled)
        case .solo: return (track.isSolo ? "s.circle.fill" : "s.circle", track.isSolo)
        }
    }

    private func drawSymbol(_ name: String, in rect: CGRect, color: NSColor) {
        let key = "\(name)|\(color.description)"
        let image: NSImage? = symbolCache[key] ?? {
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
            let made = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            symbolCache[key] = made
            return made
        }()
        guard let image else { return }
        let size = image.size
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: - Ruler

    private func drawRuler(_ sequence: EditSequence) {
        let ruler = CGRect(x: 0, y: 0, width: bounds.width, height: TimelineLayout.rulerHeight)
        NSColor(Theme.panelHeader).setFill()
        ruler.fill()
        NSColor(Theme.divider).setFill()
        CGRect(x: 0, y: ruler.maxY - 1, width: bounds.width, height: 1).fill()

        let rate = sequence.rate
        let step = TimelineLayout.tickStep(pixelsPerFrame: pixelsPerFrame, rate: rate)
        let minor = max(1, step / 5)
        let first = (frame(at: TimelineLayout.headerWidth) / minor) * minor
        let last = frame(at: bounds.width)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(Theme.textSecondary),
        ]
        NSColor(Theme.textSecondary).withAlphaComponent(0.7).setFill()
        var tick = first
        while tick <= last {
            let position = x(for: tick)
            if position >= TimelineLayout.headerWidth {
                let major = tick % step == 0
                CGRect(x: position, y: ruler.maxY - (major ? 10 : 5), width: 1, height: major ? 10 : 5).fill()
                if major {
                    let label = Timecode(frame: tick, rate: rate).description as NSString
                    label.draw(at: CGPoint(x: position + 3, y: 3), withAttributes: attributes)
                }
            }
            tick += minor
        }
        drawMarks(sequence.marks, rulerMaxY: ruler.maxY)
        drawMarkers(sequence, rulerMaxY: ruler.maxY)

        drawPlayheadTimecode(rate: rate)
    }

    private func drawPlayheadTimecode(rate: FrameRate) {
        NSColor(Theme.panelHeader).setFill()
        CGRect(x: 0, y: 0, width: TimelineLayout.headerWidth, height: TimelineLayout.rulerHeight - 1).fill()
        let timecode = Timecode(frame: workspace.program.currentFrame, rate: rate).description as NSString
        timecode.draw(at: CGPoint(x: 10, y: 5), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor(Theme.timecode),
        ])
    }

    private func drawMarks(_ marks: SequenceMarks, rulerMaxY: CGFloat) {
        NSColor(Theme.accent).setFill()
        if let inFrame = marks.inFrame {
            let position = x(for: inFrame)
            if position >= TimelineLayout.headerWidth {
                CGRect(x: position, y: rulerMaxY - 12, width: 2, height: 12).fill()
                CGRect(x: position, y: rulerMaxY - 12, width: 6, height: 2).fill()
            }
        }
        if let outFrame = marks.outFrame {
            let position = x(for: outFrame + 1)
            if position >= TimelineLayout.headerWidth {
                CGRect(x: position - 2, y: rulerMaxY - 12, width: 2, height: 12).fill()
                CGRect(x: position - 6, y: rulerMaxY - 12, width: 6, height: 2).fill()
            }
        }
        if let range = marks.range {
            NSColor(Theme.accent).withAlphaComponent(0.25).setFill()
            CGRect(x: max(TimelineLayout.headerWidth, x(for: range.start)), y: rulerMaxY - 4,
                   width: CGFloat(range.length) * pixelsPerFrame, height: 3).fill(using: .sourceOver)
        }
    }
}
