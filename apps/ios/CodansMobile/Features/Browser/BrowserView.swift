import CodansIPC
import ComposableArchitecture
import SwiftUI

/// Project → Worktree → Tab → Pane in a three-column split view: projects
/// in the sidebar, the selected project's worktrees, tabs and panes in the
/// content column, the selected pane in the detail column. In compact
/// width the columns collapse into a navigation stack.
struct BrowserView: View {
  let store: StoreOf<AppFeature>
  let openSettings: () -> Void

  @SceneStorage("browse.selectedProject") private var selectedProjectID: String?
  @SceneStorage("browse.selectedPane") private var selectedPaneID: String?

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationTitle("Projects")
    } content: {
      if let project = store.browser.project(id: selectedProjectID) {
        ProjectContentList(project: project, selectedPaneID: $selectedPaneID)
          .navigationTitle(project.name)
      } else {
        ContentUnavailableView("Select a Project", systemImage: "folder")
      }
    } detail: {
      if let paneID = selectedPaneID {
        PaneDetailContainer(store: store, paneID: paneID)
      } else {
        ContentUnavailableView("Select a Pane", systemImage: "terminal")
      }
    }
    .onChange(of: selectedProjectID) { _, _ in
      // A pane from another project would leave the columns disagreeing.
      if let paneID = selectedPaneID,
        store.browser.location(ofPane: paneID)?.project.id != selectedProjectID
      {
        selectedPaneID = nil
      }
    }
  }

  @ViewBuilder
  private var sidebar: some View {
    if store.browser.hierarchy == nil {
      ConnectionPlaceholderView(connection: store.connection, openSettings: openSettings)
    } else {
      List(store.browser.projects, id: \.id, selection: $selectedProjectID) { project in
        VStack(alignment: .leading, spacing: 2) {
          Text(project.name)
          Text(worktreeCount(project))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .tag(project.id)
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        ConnectionBanner(connection: store.connection)
      }
    }
  }

  private func worktreeCount(_ project: IPC.ProjectSummary) -> String {
    project.worktrees.count == 1 ? "1 worktree" : "\(project.worktrees.count) worktrees"
  }
}

/// One section per worktree; within it, each tab's panes. Panes are the
/// selectable leaves.
private struct ProjectContentList: View {
  let project: IPC.ProjectSummary
  @Binding var selectedPaneID: String?

  var body: some View {
    List(selection: $selectedPaneID) {
      ForEach(project.worktrees, id: \.id) { worktree in
        Section {
          ForEach(worktree.tabs, id: \.id) { tab in
            ForEach(tab.panes, id: \.id) { pane in
              PaneRow(tab: tab, pane: pane, showsTab: tab.panes.count > 1)
                .tag(pane.id)
            }
          }
        } header: {
          HStack {
            Text(worktree.name)
            if let branch = worktree.branch, branch != worktree.name {
              Text(branch)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }
}

private struct PaneRow: View {
  let tab: IPC.TabSummary
  let pane: IPC.PaneSummary
  let showsTab: Bool

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(pane.title ?? tab.title ?? pane.handle ?? "Pane")
          .lineLimit(1)
        if showsTab, let tabTitle = tab.title {
          Text(tabTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    } icon: {
      Image(systemName: pane.agent == nil ? "terminal" : "sparkles")
        .accessibilityHidden(true)
    }
  }
}
