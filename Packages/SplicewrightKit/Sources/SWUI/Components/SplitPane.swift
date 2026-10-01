import AppKit
import SwiftUI

/// A two-pane split with a draggable divider.
///
/// Each pane gets an exact frame and is clipped to it. SwiftUI's `HSplitView`/`VSplitView`
/// let a pane whose content wants more room draw over its neighbour; this never does.
struct SplitPane<First: View, Second: View>: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    let minFirst: CGFloat
    let minSecond: CGFloat
    let first: First
    let second: Second
    /// The saved position (a workspace setting); written when a drag ends.
    @Binding private var savedFraction: CGFloat
    /// The position while dragging, so a drag doesn't save on every frame.
    @State private var dragFraction: CGFloat?
    @State private var dragStartFraction: CGFloat?

    private let handle: CGFloat = 5

    private var fraction: CGFloat { dragFraction ?? savedFraction }

    init(_ axis: Axis, fraction: Binding<CGFloat>, minFirst: CGFloat = 120, minSecond: CGFloat = 120,
         @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.axis = axis
        self.minFirst = minFirst
        self.minSecond = minSecond
        self.first = first()
        self.second = second()
        _savedFraction = fraction
    }

    var body: some View {
        GeometryReader { geometry in
            let total = axis == .vertical ? geometry.size.height : geometry.size.width
            let available = max(0, total - handle)
            let firstSize = clampedFirstSize(fraction * available, available: available)
            if axis == .vertical {
                VStack(spacing: 0) {
                    first.frame(width: geometry.size.width, height: firstSize).clipped()
                    divider(available: available)
                    second.frame(width: geometry.size.width, height: available - firstSize).clipped()
                }
            } else {
                HStack(spacing: 0) {
                    first.frame(width: firstSize, height: geometry.size.height).clipped()
                    divider(available: available)
                    second.frame(width: available - firstSize, height: geometry.size.height).clipped()
                }
            }
        }
    }

    private func clampedFirstSize(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        let upper = max(0, available - minSecond)
        return min(max(proposed, min(minFirst, upper)), upper)
    }

    private func divider(available: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: axis == .horizontal ? handle : nil, height: axis == .vertical ? handle : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (axis == .vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        guard available > 0 else { return }
                        let start = dragStartFraction ?? fraction
                        dragStartFraction = start
                        let delta = axis == .vertical ? value.translation.height : value.translation.width
                        let size = clampedFirstSize(start * available + delta, available: available)
                        dragFraction = size / available
                    }
                    .onEnded { _ in
                        if let dragFraction { savedFraction = dragFraction }
                        dragFraction = nil
                        dragStartFraction = nil
                    }
            )
    }
}
