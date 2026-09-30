import SwiftUI
import SWCore

/// Premiere's vertical Tools panel. Shortcuts switch tools even before the timeline exists.
struct ToolsPanel: View {
    @ObservedObject var workspace: WorkspaceController

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
                        .help("\(tool.displayName) (\(String(tool.shortcut).uppercased()))")
                    }
                }
            }
            Spacer()
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.textPrimary)
        .padding(.vertical, 8)
        .frame(width: 34)
        .background(Theme.panelBackground)
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

/// Effects browser. Transitions and titles are implemented in M6.
struct EffectsPanel: View {
    var body: some View {
        List {
            Section("Video Transitions") {
                Label("Cross Dissolve", systemImage: "square.on.square")
                Label("Dip to Black", systemImage: "square.fill")
                Label("Dip to White", systemImage: "square")
                Label("Film Dissolve", systemImage: "square.on.square.dashed")
            }
            Section("Graphics") {
                Label("Title", systemImage: "textformat")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textSecondary)
        .scrollContentBackground(.hidden)
        .disabled(true)
        .overlay(alignment: .bottom) {
            Text("Available in a later milestone").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                .padding(8)
        }
    }
}

/// Effect Controls for the selected timeline clip (Motion, Opacity, …) — later milestones.
struct EffectControlsPanel: View {
    var body: some View {
        Text("(no clip selected)")
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
