import CodansIPC
import ComposableArchitecture
import SwiftUI

/// The home screen: Project → Worktree in the sidebar, the selected
/// worktree's tabs and panes in the content column, the selected pane in
/// the detail column. In compact width the columns collapse into a
/// navigation stack. Agents and Settings are one toolbar tap away rather
/// than top-level tabs; agent state also shows on the rows themselves.
struct WorkspaceView: View {
  let store: StoreOf<AppFeature>
  let openAgents: () -> Void
  let openSettings: () -> Void
  @Binding var selectedWorktreeID: String?
  @Binding var selectedPaneID: String?

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationTitle(store.connection.activeGateway?.displayName ?? "Codans")
        .toolbar { toolbar }
    } content: {
      if let found = store.browser.worktree(id: selectedWorktreeID) {
        WorktreeContentList(worktree: found.worktree, agents: store.agents, selectedPaneID: $selectedPaneID)
          .navigationTitle(found.worktree.name)
          .navigationSubtitle(found.project.name)
      } else {
        ContentUnavailableView("Select a Worktree", systemImage: "arrow.triangle.branch")
      }
    } detail: {
      if let paneID = selectedPaneID {
        PaneDetailContainer(store: store, paneID: paneID)
      } else {
        ContentUnavailableView("Select a Pane", systemImage: "terminal")
      }
    }
    .onChange(of: selectedWorktreeID) { _, _ in
      followSelection()
      // A pane from another worktree would leave the columns disagreeing.
      if let paneID = selectedPaneID,
        store.browser.location(ofPane: paneID)?.worktree.id != selectedWorktreeID
      {
        selectedPaneID = nil
      }
    }
  }

  @ViewBuilder
  private var sidebar: some View {
    if store.browser.hierarchy == nil {
      ConnectionPlaceholderView(connection: store.connection, openSettings: openSettings)
    } else if store.browser.projects.isEmpty {
      ContentUnavailableView(
        "No Projects",
        systemImage: "folder",
        description: Text("Projects added in Codans on your Mac appear here."))
    } else {
      List(selection: $selectedWorktreeID) {
        ForEach(store.browser.projects, id: \.id) { project in
          Section(project.name) {
            ForEach(project.worktrees, id: \.id) { worktree in
              WorktreeRow(worktree: worktree, agents: store.agents.summary(forWorktree: worktree.id))
                .tag(worktree.id)
            }
          }
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        ConnectionBanner(connection: store.connection)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if store.connection.permission == .interactive {
          ComposerView(
            store: store.scope(state: \.composer, action: \.composer),
            projects: store.browser.projects,
            macName: store.connection.activeGateway?.displayName ?? "Mac",
            onLaunched: { launch in
              selectedWorktreeID = launch.worktreeID
              if let paneID = launch.paneID { selectedPaneID = paneID }
            }
          )
        }
      }
      .task(id: store.browser.hierarchy?.projects.count) { followSelection() }
    }
  }

  /// The composer sends into the worktree selected in the sidebar, else the
  /// Mac's own selection; an explicit pick in the composer stays until the
  /// sidebar selection changes.
  private func followSelection() {
    let browser = store.browser
    if let found = browser.worktree(id: selectedWorktreeID) {
      store.send(.composer(.targetSelected(.worktree(projectID: found.project.id, worktreeID: found.worktree.id))))
      return
    }
    // Keep a target that still exists on the Mac (including a pending new
    // worktree in a project that still exists).
    if let target = store.composer.target, Self.exists(target, in: browser) { return }
    let project = browser.project(id: browser.hierarchy?.selectedProjectID) ?? browser.projects.first
    guard let project else { return }
    let worktree = project.worktrees.first { $0.id == project.selectedWorktreeID } ?? project.worktrees.first
    store.send(
      .composer(
        .targetSelected(
          worktree.map { .worktree(projectID: project.id, worktreeID: $0.id) } ?? .newWorktree(projectID: project.id))))
  }

  private static func exists(_ target: ComposerFeature.Target, in browser: BrowserFeature.State) -> Bool {
    switch target {
    case .worktree(_, let worktreeID): return browser.worktree(id: worktreeID) != nil
    case .newWorktree(let projectID): return browser.project(id: projectID) != nil
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Button(action: openAgents) {
        AgentsButtonLabel(needsInput: store.agents.needsInputCount)
      }
      .accessibilityIdentifier("open-agents")
      Button("Settings", systemImage: "gearshape", action: openSettings)
        .accessibilityIdentifier("open-settings")
    }
  }
}

/// Plain sparkles normally; tinted, with the count, while agents wait for
/// input, so the toolbar carries what the Agents tab badge used to.
private struct AgentsButtonLabel: View {
  let needsInput: Int

  var body: some View {
    if needsInput > 0 {
      Label {
        Text("Agents")
      } icon: {
        HStack(spacing: 2) {
          Image(systemName: AgentGroup.Kind.needsInput.symbol)
          Text("\(needsInput)")
            .font(.caption.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.orange)
      }
      .accessibilityValue("\(needsInput) need input")
    } else {
      Label("Agents", systemImage: "sparkles")
    }
  }
}

private struct WorktreeRow: View {
  let worktree: IPC.WorktreeSummary
  let agents: AgentSummary?

  var body: some View {
    HStack {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(worktree.name)
            .lineLimit(1)
          if let branch = worktree.branch, branch != worktree.name {
            Text(branch)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
      } icon: {
        Image(systemName: "arrow.triangle.branch")
          .accessibilityHidden(true)
      }
      Spacer(minLength: 8)
      if let agents, agents.kind != .idle {
        AgentBadge(kind: agents.kind, count: agents.count)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("worktree-row")
  }
}

/// Tabs as sections, panes as the selectable leaves.
private struct WorktreeContentList: View {
  let worktree: IPC.WorktreeSummary
  let agents: AgentsFeature.State
  @Binding var selectedPaneID: String?

  var body: some View {
    if worktree.tabs.allSatisfy(\.panes.isEmpty) {
      ContentUnavailableView(
        "No Panes",
        systemImage: "terminal",
        description: Text("This worktree has no open terminals on your Mac."))
    } else {
      List(selection: $selectedPaneID) {
        ForEach(worktree.tabs, id: \.id) { tab in
          Section(tab.title ?? "Tab") {
            ForEach(tab.panes, id: \.id) { pane in
              PaneRow(tab: tab, pane: pane, agent: agents.kind(ofPane: pane.id))
                .tag(pane.id)
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
  let agent: AgentGroup.Kind?

  var body: some View {
    HStack {
      Label {
        Text(pane.title ?? tab.title ?? pane.handle ?? "Pane")
          .lineLimit(1)
      } icon: {
        Image(systemName: pane.agent == nil ? "terminal" : "sparkles")
          .accessibilityHidden(true)
      }
      Spacer(minLength: 8)
      if let agent, agent != .idle {
        AgentBadge(kind: agent, count: nil)
      }
    }
    // One element per row; the identifier is the UI-test probe, since the
    // title is whatever the shell sets.
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("pane-row")
  }
}

/// Needs-input or working indicator for a worktree or pane row.
struct AgentBadge: View {
  let kind: AgentGroup.Kind
  let count: Int?

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: kind.symbol)
      if let count, count > 1 {
        Text("\(count)")
          .monospacedDigit()
      }
    }
    .font(.caption)
    .foregroundStyle(kind.tint)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(kind.title)
  }
}

extension AgentGroup.Kind {
  var tint: Color {
    switch self {
    case .needsInput: return .orange
    case .working: return .blue
    case .idle: return .secondary
    }
  }
}
