import AppKit
import SWCore

/// Sequence markers in the ruler (drag to move, double-click to edit, right-click for more)
/// and clip markers on the clips that use them.
extension TimelineCanvas {
    static func color(_ marker: MarkerColor, alpha: CGFloat = 1) -> NSColor {
        let rgb = marker.rgb
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }

    // MARK: - Drawing

    func drawMarkers(_ sequence: EditSequence, rulerMaxY: CGFloat) {
        for marker in sequence.markers {
            let x = self.x(for: marker.frame)
            guard x >= TimelineLayout.headerWidth - 8, x <= bounds.width + 8 else { continue }
            let color = Self.color(marker.color)
            if marker.duration > 0 {
                color.withAlphaComponent(0.45).setFill()
                CGRect(x: max(TimelineLayout.headerWidth, x), y: rulerMaxY - 8,
                       width: CGFloat(marker.duration) * pixelsPerFrame, height: 7).fill(using: .sourceOver)
            }
            // A notch like Premiere's: a small pentagon pointing at the frame.
            let notch = NSBezierPath()
            notch.move(to: CGPoint(x: x - 5, y: rulerMaxY - 14))
            notch.line(to: CGPoint(x: x + 5, y: rulerMaxY - 14))
            notch.line(to: CGPoint(x: x + 5, y: rulerMaxY - 6))
            notch.line(to: CGPoint(x: x, y: rulerMaxY - 1))
            notch.line(to: CGPoint(x: x - 5, y: rulerMaxY - 6))
            notch.close()
            color.setFill()
            notch.fill()
            if workspace.selectedMarkerID == marker.id {
                NSColor.white.setStroke()
                notch.lineWidth = 1.5
                notch.stroke()
            }
            if !marker.name.isEmpty, pixelsPerFrame * 30 > 40 {
                (marker.name as NSString).draw(at: CGPoint(x: x + 7, y: rulerMaxY - 26), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: color,
                ])
            }
        }
    }

    /// Small triangles on a clip where its source has markers.
    func drawClipMarkers(_ clip: Clip, in rect: CGRect, rate: FrameRate) {
        guard let item = workspace.project.item(clip.mediaID), !item.markers.isEmpty else { return }
        for (frame, marker) in clip.sourceMarkers(item.markers, rate: rate) {
            let x = self.x(for: frame)
            guard x >= rect.minX, x <= rect.maxX else { continue }
            let triangle = NSBezierPath()
            triangle.move(to: CGPoint(x: x - 4, y: rect.minY))
            triangle.line(to: CGPoint(x: x + 4, y: rect.minY))
            triangle.line(to: CGPoint(x: x, y: rect.minY + 6))
            triangle.close()
            Self.color(marker.color).setFill()
            triangle.fill()
        }
    }

    // MARK: - Mouse

    func markerHit(at point: CGPoint, in sequence: EditSequence) -> Marker? {
        guard point.y < TimelineLayout.rulerHeight, point.x >= TimelineLayout.headerWidth - 6 else { return nil }
        return sequence.markers.min { abs(x(for: $0.frame) - point.x) < abs(x(for: $1.frame) - point.x) }
            .flatMap { abs(x(for: $0.frame) - point.x) <= 6 ? $0 : nil }
    }

    /// A click on a marker notch: select and drag it, or edit it on a double-click.
    func markerMouseDown(at point: CGPoint, event: NSEvent, in sequence: EditSequence) -> Bool {
        guard let marker = markerHit(at: point, in: sequence) else { return false }
        workspace.selectedMarkerID = marker.id
        if event.clickCount == 2 {
            workspace.editingMarkerID = marker.id
            return true
        }
        drag = Drag(kind: .marker(id: marker.id, startFrame: marker.frame), original: sequence, actionName: "Move Marker")
        return true
    }

    func markerPreview(_ id: UUID, startFrame: Int64, original: EditSequence, delta: Int64) -> EditSequence {
        var copy = original
        var frame = max(0, startFrame + delta)
        if timeline.isSnapping {
            let targets = [workspace.program.currentFrame] + original.editPoints
            if let nearest = targets.min(by: { abs($0 - frame) < abs($1 - frame) }), abs(nearest - frame) <= snapThreshold {
                frame = nearest
                timeline.snapFrame = nearest
            }
        }
        copy.updateMarker(id) { $0.frame = frame }
        return copy
    }

    func rulerMenu(at point: CGPoint, in sequence: EditSequence) -> NSMenu? {
        guard point.y < TimelineLayout.rulerHeight, point.x >= TimelineLayout.headerWidth else { return nil }
        let menu = NSMenu()
        if let marker = markerHit(at: point, in: sequence) {
            workspace.selectedMarkerID = marker.id
            menu.addItem(ActionMenuItem("Edit Marker…") { [weak self] in self?.workspace.editingMarkerID = marker.id })
            let colors = NSMenu()
            for color in MarkerColor.allCases {
                let item = ActionMenuItem(color.displayName) { [weak self] in
                    self?.workspace.updateMarker(marker.id, "Marker Color") { $0.color = color }
                }
                item.state = marker.color == color ? .on : .off
                colors.addItem(item)
            }
            let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            colorItem.submenu = colors
            menu.addItem(colorItem)
            menu.addItem(ActionMenuItem("Delete Marker") { [weak self] in self?.workspace.deleteMarkers([marker.id]) })
        } else {
            let frame = self.frame(at: point.x)
            menu.addItem(ActionMenuItem("Add Marker Here") { [weak self] in
                self?.workspace.editSequence("Add Marker") { sequence, _ in sequence.addMarker(at: frame) }
            })
        }
        menu.addItem(.separator())
        let clear = ActionMenuItem("Clear All Markers") { [weak self] in self?.workspace.clearAllMarkers() }
        clear.isEnabled = !sequence.markers.isEmpty
        menu.addItem(clear)
        return menu
    }
}
