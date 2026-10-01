import SwiftUI
import SWCore

/// Premiere's vertical Tools panel. Shortcuts switch tools even before the timeline exists.
struct ToolsPanel: View {
    @ObservedObject var workspace: WorkspaceController
    @ObservedObject private var keys = KeyBindingsStore.shared

    private let groups: [[EditTool]] = [
        [.selection, .trackSelectForward],
        [.rippleEdit, .rollingEdit, .rateStretch],
        [.razor],
        [.slip, .slide],
        [.pen],
        [.hand, .zoom],
        [.type],
    ]

    var body: some View {
        // Scrolls rather than overflowing when the panel is shorter than the tool column.
        ScrollView(.vertical, showsIndicators: false) {
            tools
        }
        .frame(width: 34)
        .background(Theme.panelBackground)
    }

    private var tools: some View {
        VStack(spacing: 6) {
            ForEach(groups.indices, id: \.self) { index in
                VStack(spacing: 2) {
                    ForEach(groups[index]) { tool in
                        Button { workspace.activeTool = tool } label: {
                            Image(systemName: symbol(for: tool))
                                .frame(width: 26, height: 24)
                                .background(workspace.activeTool == tool ? Theme.accent.opacity(0.6) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 3))
                        }
                        .buttonStyle(.plain)
                        .help(keys.hint(tool.displayName, CommandID.command(for: tool)))
                    }
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.textPrimary)
        .padding(.vertical, 8)
        .frame(width: 34)
    }

    private func symbol(for tool: EditTool) -> String {
        switch tool {
        case .selection: return "cursorarrow"
        case .trackSelectForward: return "arrow.right.to.line.compact"
        case .rippleEdit: return "arrow.left.and.right.square"
        case .rollingEdit: return "arrow.left.arrow.right"
        case .rateStretch: return "timer"
        case .razor: return "scissors"
        case .slip: return "arrow.left.and.right"
        case .slide: return "rectangle.portrait.arrowtriangle.2.outward"
        case .pen: return "pencil.tip"
        case .hand: return "hand.raised"
        case .zoom: return "plus.magnifyingglass"
        case .type: return "textformat"
        }
    }
}
