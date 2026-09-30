import SwiftUI

struct PanelTab: Identifiable {
    var id: PanelID
    var title: String
}

/// A dockable-looking panel: a tab strip over content, outlined when active.
/// Clicking anywhere in the panel makes it the active panel.
struct PanelContainer<Content: View>: View {
    let tabs: [PanelTab]
    @Binding var selectedTab: PanelID
    @ObservedObject var workspace: WorkspaceController
    @ViewBuilder var content: () -> Content

    init(tabs: [PanelTab], selectedTab: Binding<PanelID>, workspace: WorkspaceController,
         @ViewBuilder content: @escaping () -> Content) {
        self.tabs = tabs
        self._selectedTab = selectedTab
        self.workspace = workspace
        self.content = content
    }

    /// A panel with a single, fixed tab.
    init(_ id: PanelID, title: String, workspace: WorkspaceController, @ViewBuilder content: @escaping () -> Content) {
        self.init(tabs: [PanelTab(id: id, title: title)], selectedTab: .constant(id), workspace: workspace, content: content)
    }

    private var isActive: Bool { tabs.contains { $0.id == workspace.activePanel } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ForEach(tabs) { tab in
                    Button {
                        selectedTab = tab.id
                        workspace.activePanel = tab.id
                    } label: {
                        Text(tab.title)
                            .font(.system(size: 11, weight: selectedTab == tab.id ? .semibold : .regular))
                            .foregroundStyle(selectedTab == tab.id ? Theme.textPrimary : Theme.textSecondary)
                            .overlay(alignment: .bottom) {
                                if selectedTab == tab.id {
                                    Rectangle().fill(Theme.accent).frame(height: 2).offset(y: 5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.panelHeader)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.panelBackground)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(isActive ? Theme.activeOutline : Color.clear, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            workspace.activePanel = selectedTab
        })
        .padding(2)
    }
}
