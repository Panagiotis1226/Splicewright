import AppKit
import Combine
import SwiftUI
import SWCore
import SWMedia

/// The timeline surface: an AppKit view drawn with Core Graphics. Clips, headers and the
/// ruler redraw when the document or view state changes; the playhead is a separate layer
/// so playback doesn't redraw everything each frame.
final class TimelineCanvas: NSView {
    // Strong: the controller never references the canvas, and AppKit may draw the view
    // briefly after SwiftUI releases the workspace.
    let workspace: WorkspaceController
    var cancellables = Set<AnyCancellable>()
    let playheadLayer = CALayer()
    let playheadHead = CALayer()
    var drag: Drag?
    var dragOrigin: CGPoint = .zero
    var symbolCache: [String: NSImage] = [:]

    enum TrimMode { case normal, ripple, roll }

    enum DragKind {
        case scrub
        case hand(startScroll: CGPoint)
        case move(ids: Set<UUID>, startRow: TimelineLayout.Row)
        case trim(clipID: UUID, edge: TrimEdge, mode: TrimMode)
        case slip(UUID)
        case slide(UUID)
    }

    struct Drag {
        var kind: DragKind
        var original: EditSequence?
        var actionName: String
    }

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        playheadLayer.backgroundColor = NSColor(Theme.playhead).cgColor
        playheadLayer.zPosition = 10
        playheadHead.backgroundColor = NSColor(Theme.playhead).cgColor
        playheadHead.cornerRadius = 2
        playheadLayer.addSublayer(playheadHead)
        layer?.addSublayer(playheadLayer)
        registerForDraggedTypes([.string])
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var timeline: TimelineState { workspace.timeline }
    var sequence: EditSequence? { timeline.preview ?? workspace.activeSequence }
    var pixelsPerFrame: CGFloat { timeline.pixelsPerFrame }
    var laneWidth: CGFloat { max(0, bounds.width - TimelineLayout.headerWidth) }

    private func observe() {
        workspace.objectWillChange
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &cancellables)
        timeline.objectWillChange
            .sink { [weak self] _ in
                self?.needsDisplay = true
                DispatchQueue.main.async { self?.updatePlayhead() }
            }
            .store(in: &cancellables)
        workspace.program.$currentFrame
            .receive(on: RunLoop.main)
            .sink { [weak self] frame in self?.playheadMoved(to: frame) }
            .store(in: &cancellables)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        TimelineLayout.lastLaneWidth = laneWidth
        updatePlayhead()
    }

    // MARK: - Coordinates

    func x(for frame: Int64) -> CGFloat {
        TimelineLayout.headerWidth + CGFloat(frame) * pixelsPerFrame - timeline.scrollX
    }

    /// The frame boundary nearest `x`.
    func frame(at x: CGFloat) -> Int64 {
        max(0, Int64(((x - TimelineLayout.headerWidth + timeline.scrollX) / pixelsPerFrame).rounded()))
    }

    func frameDelta(from start: CGPoint, to end: CGPoint) -> Int64 {
        Int64(((end.x - start.x) / pixelsPerFrame).rounded())
    }

    /// Rows positioned in view coordinates (vertical scroll applied).
    func rows(for sequence: EditSequence) -> [TimelineLayout.Row] {
        TimelineLayout.rows(for: sequence, width: bounds.width).map { row in
            var row = row
            row.rect.origin.y -= timeline.scrollY
            return row
        }
    }

    func row(at point: CGPoint, in sequence: EditSequence) -> TimelineLayout.Row? {
        guard point.y >= TimelineLayout.rulerHeight else { return nil }
        return rows(for: sequence).first { $0.rect.minY <= point.y && point.y < $0.rect.maxY + 1 }
    }

    func clipRect(_ clip: Clip, in row: TimelineLayout.Row) -> CGRect {
        CGRect(x: x(for: clip.start), y: row.rect.minY + 2,
               width: max(1, CGFloat(clip.duration) * pixelsPerFrame), height: row.rect.height - 4)
    }

    var snapThreshold: Int64 { max(1, Int64((8 / pixelsPerFrame).rounded(.up))) }

    // MARK: - Playhead

    private func playheadMoved(to frame: Int64) {
        if workspace.program.isPlaying, drag == nil {
            let position = x(for: frame)
            if position > bounds.width - 16 {
                timeline.scrollX += laneWidth * 0.85
            } else if position < TimelineLayout.headerWidth {
                timeline.scrollX = max(0, CGFloat(frame) * pixelsPerFrame - 16)
            }
        }
        updatePlayhead()
        setNeedsDisplay(Self.timecodeCorner)
    }

    static let timecodeCorner = CGRect(x: 0, y: 0, width: TimelineLayout.headerWidth, height: TimelineLayout.rulerHeight)

    func updatePlayhead() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let position = x(for: workspace.program.currentFrame)
        let visible = workspace.activeSequence != nil && position >= TimelineLayout.headerWidth
        playheadLayer.isHidden = !visible
        playheadLayer.frame = CGRect(x: position - 0.75, y: 6, width: 1.5, height: max(0, bounds.height - 6))
        playheadHead.frame = CGRect(x: -5, y: 0, width: 11.5, height: 12)
        CATransaction.commit()
    }
}
