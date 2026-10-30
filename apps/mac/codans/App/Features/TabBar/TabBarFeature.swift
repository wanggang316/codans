import CodansCore
import ComposableArchitecture
import Foundation

/// Tab bar reducer. State-free controller: Worktree.tabs is read from the
/// environment `HierarchyManager` at render time; actions dispatch create /
/// select / close / rename / reorder / bulk-close commands through
/// `HierarchyClient`. Errors are swallowed (logged via the client's own
/// channels) — tab-bar failures are rare and not worth modal UX today.
@Reducer
struct TabBarFeature {
  /// Sheet payload while the user is editing a tab's name. Lifted into the reducer
  /// (rather than left as `@State` in the view) so the global ⌘⇧R menu chord can
  /// surface the same sheet without a parallel presentation channel — the chord
  /// path resolves the active TabID in `RootFeature`, then dispatches
  /// `.renameRequested(...)` here, identical to the chip's right-click → Rename.
  struct RenameTarget: Identifiable, Equatable {
    let id: TabID
    let currentName: String
  }

  struct ColorTarget: Identifiable, Equatable {
    let id: TabID
    let currentColor: TabColor?
  }

  struct IconTarget: Identifiable, Equatable {
    let id: TabID
    let currentIcon: String?
  }

  @ObservableState
  struct State: Equatable {
    var renameTarget: RenameTarget?
    var colorTarget: ColorTarget?
    var iconTarget: IconTarget?
  }

  enum Action: Equatable {
    case newTabButtonTapped(inWorktree: WorktreeID, inProject: ProjectID)
    case tabButtonTapped(TabID, inWorktree: WorktreeID, inProject: ProjectID)
    case closeButtonTapped(TabID, inWorktree: WorktreeID, inProject: ProjectID)

    /// Open the rename sheet for `tabID`. Sources: chip context-menu Rename
    /// (any tab) and `RootFeature.renameActiveTabForCurrentWorktreeRequested`
    /// (active tab via ⌘⇧R menu chord).
    case renameRequested(TabID, currentName: String)
    /// Sheet dismissal — driven by the user closing the sheet without
    /// committing. Commit path clears `renameTarget` inside `renameSubmitted`
    /// so the sheet animates away on Enter.
    case renameDismissed
    case renameSubmitted(
      TabID, name: String?, inWorktree: WorktreeID, inProject: ProjectID)
    case colorRequested(TabID, currentColor: TabColor?)
    case colorDismissed
    case colorSubmitted(
      TabID, color: TabColor?, inWorktree: WorktreeID, inProject: ProjectID)
    case iconRequested(TabID, currentIcon: String?)
    case iconDismissed
    case iconSubmitted(
      TabID, icon: String?, inWorktree: WorktreeID, inProject: ProjectID)
    case contextMenuCloseOthers(TabID, inWorktree: WorktreeID, inProject: ProjectID)
    case contextMenuCloseToRight(TabID, inWorktree: WorktreeID, inProject: ProjectID)
    case contextMenuCloseAll(inWorktree: WorktreeID, inProject: ProjectID)
    case dragReorderEnded(
      orderedIDs: [TabID], inWorktree: WorktreeID, inProject: ProjectID)
    case middleClicked(TabID, inWorktree: WorktreeID, inProject: ProjectID)
    /// Trailing split button click. Anchors on the active tab's
    /// last-focused pane (falling back to the leftmost leaf for tabs
    /// that haven't been focused since launch) and splits it in
    /// `direction`. Silent no-op if the worktree has no active tab or
    /// the tab has no panes.
    case trailingSplitRequested(
      direction: SplitTree<PaneID>.NewDirection,
      inWorktree: WorktreeID, inProject: ProjectID)
    /// Play button on an Agent Session History row (trailing-accessory or
    /// empty-terminal popover). Runs the agent's resume invocation (e.g.
    /// `claude --resume <id>`) at `placement` through the shared script
    /// pipeline, so the agent process owns its pane exactly like a
    /// manually-launched agent and AgentBinder classifies it as usual.
    case resumeAgentSessionTapped(
      agent: AgentKind, sessionID: String, placement: AgentResumePlacement,
      inWorktree: WorktreeID, inProject: ProjectID)
    /// An agent picked from the `+` button's press-and-hold / right-click
    /// menu. Starts the profile in a new tab whatever its saved placement —
    /// the user reached it from the new-tab button.
    case launchAgentInNewTabTapped(
      profileID: UUID, inWorktree: WorktreeID, inProject: ProjectID)
    /// "Manage Agents…" footer of the same menu.
    case manageAgentsTapped
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(\.continuousClock) private var clock
  @Dependency(SettingsWriter.self) private var settingsWriter
  @Dependency(SettingsWindowPresenter.self) private var settingsWindowPresenter

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .renameRequested(let tabID, let currentName):
        state.renameTarget = RenameTarget(id: tabID, currentName: currentName)
        return .none

      case .renameDismissed:
        state.renameTarget = nil
        return .none

      case .newTabButtonTapped(let worktreeID, let projectID):
        guard let tabID = try? hierarchyClient.createTab(worktreeID, projectID, nil)
        else { return .none }
        // Resolve worktree.path from the catalog so the auto-spawned pane
        // starts in the Worktree's directory instead of `$HOME`. Silent no-op
        // if the Worktree vanished between createTab and this lookup.
        let catalog = hierarchyClient.snapshot()
        guard
          let worktree = catalog.projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID })
        else { return .none }
        let cwd = worktree.path
        // Promote the new pane's surface to first responder so the new tab
        // opens with keyboard focus on its lone pane. Dispatched async so
        // SwiftUI has time to attach the surface view to the window before
        // `makeFirstResponder` runs — `focusSurfaceView` retries with
        // backoff if the window isn't ready yet. Mirrors the focus flow
        // in `PaneActionRouterFeature.newSplit`.
        return .run { [client = hierarchyClient, clock] _ in
          // Let the tab bar's insertion animation play first; see
          // `TabBarMetrics.firstPaneDelay`.
          try? await clock.sleep(for: TabBarMetrics.firstPaneDelay)
          guard
            let newPaneID = try? await client.openPane(
              tabID, worktreeID, projectID, cwd, nil
            )
          else { return }
          await MainActor.run { client.focusSurfaceView(newPaneID) }
        }

      case .tabButtonTapped(let tabID, let worktreeID, let projectID):
        try? hierarchyClient.selectTab(tabID, worktreeID, projectID)
        return .none

      case .closeButtonTapped(let tabID, let worktreeID, let projectID):
        try? hierarchyClient.closeTab(tabID, worktreeID, projectID)
        return .none

      case .renameSubmitted(let tabID, let name, let worktreeID, let projectID):
        try? hierarchyClient.renameTab(tabID, worktreeID, projectID, name)
        state.renameTarget = nil
        return .none

      case .colorRequested(let tabID, let currentColor):
        state.colorTarget = ColorTarget(id: tabID, currentColor: currentColor)
        return .none

      case .colorDismissed:
        state.colorTarget = nil
        return .none

      case .colorSubmitted(let tabID, let color, let worktreeID, let projectID):
        try? hierarchyClient.setTabColor(tabID, worktreeID, projectID, color)
        state.colorTarget = nil
        return .none

      case .iconRequested(let tabID, let currentIcon):
        state.iconTarget = IconTarget(id: tabID, currentIcon: currentIcon)
        return .none

      case .iconDismissed:
        state.iconTarget = nil
        return .none

      case .iconSubmitted(let tabID, let icon, let worktreeID, let projectID):
        try? hierarchyClient.setTabIcon(tabID, worktreeID, projectID, icon, .user)
        state.iconTarget = nil
        return .none

      case .contextMenuCloseOthers(let tabID, let worktreeID, let projectID):
        try? hierarchyClient.closeOtherTabs(tabID, worktreeID, projectID)
        return .none

      case .contextMenuCloseToRight(let tabID, let worktreeID, let projectID):
        try? hierarchyClient.closeTabsToRight(tabID, worktreeID, projectID)
        return .none

      case .contextMenuCloseAll(let worktreeID, let projectID):
        try? hierarchyClient.closeAllTabs(worktreeID, projectID)
        return .none

      case .dragReorderEnded(let orderedIDs, let worktreeID, let projectID):
        try? hierarchyClient.reorderTabs(worktreeID, projectID, orderedIDs)
        return .none

      case .middleClicked(let tabID, let worktreeID, let projectID):
        try? hierarchyClient.closeTab(tabID, worktreeID, projectID)
        return .none

      case .trailingSplitRequested(let direction, let worktreeID, let projectID):
        let catalog = hierarchyClient.snapshot()
        guard
          let worktree = catalog.projects.first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID }),
          let activeTabID = worktree.selectedTabID,
          let activeTab = worktree.tabs.first(where: { $0.id == activeTabID })
        else { return .none }
        // Anchor on the tab's last-focused pane so the menu chord ("Split
        // Right/Down") and the toolbar split button both fork from where
        // the user actually is. `leaves().first` is the safety net for
        // tabs that haven't been focused since launch.
        guard
          let anchor = hierarchyClient.lastFocusedPane(activeTabID)
            ?? activeTab.splitTree.leaves().first,
          let anchorPane = activeTab.panes.first(where: { $0.id == anchor })
        else { return .none }
        let cwd = anchorPane.workingDirectory
        return .run { [client = hierarchyClient] _ in
          guard
            let newPaneID = try? await client.splitPane(
              anchor, direction,
              activeTabID, worktreeID, projectID,
              cwd, nil
            )
          else { return }
          await MainActor.run { client.focusSurfaceView(newPaneID) }
        }

      case .resumeAgentSessionTapped(
        let agent, let sessionID, let placement, let worktreeID, let projectID):
        // The scanner only emits summaries for agents whose adapter can
        // resume, so a nil here signals a programming error upstream, not
        // a user-visible state.
        guard
          let command = AgentRuntimeAdapters.adapter(for: agent)
            .resumeCommand(sessionID: sessionID),
          let worktree = hierarchyClient.snapshot().projects
            .first(where: { $0.id == projectID })?
            .worktrees.first(where: { $0.id == worktreeID })
        else { return .none }
        // Re-check the placement against the worktree as it is now: the
        // focused pane may have started an agent while the popover was open,
        // and the empty-terminal entry has no pane to type into or split.
        let context = AgentResumePlacement.Context(
          worktree: worktree, lastFocusedPane: { hierarchyClient.lastFocusedPane($0) })
        let resolved = placement.resolved(in: context)
        // A session, not a job: a fresh id per resume, and no onFinished
        // policy. A new tab or split spawns in the worktree's directory, which
        // the agent CLI needs to find the session it recorded against that
        // cwd. In Place types into the pane's shell as is, the same as a
        // Project Command with that target, so it runs in the shell's cwd.
        let script = ScriptDefinition(
          kind: .custom,
          name: agent.displayName,
          command: command,
          systemImage: TabIconRef.icon(for: agent),
          target: resolved.target,
          direction: resolved.direction ?? .right
        )
        return .run { [client = hierarchyClient] _ in
          try? await client.runAgentCommand(script, projectID, worktreeID)
        }

      case .launchAgentInNewTabTapped(let profileID, let worktreeID, let projectID):
        // A profile removed between opening the menu and picking it is a
        // silent no-op, like the rest of the tab bar's rare failures.
        guard let profile = settingsWriter.readSnapshotSync().agents.profile(id: profileID)
        else { return .none }
        let spec = AgentLaunchSpec(
          profile: profile, projectID: projectID, worktreeID: worktreeID, target: .newTab)
        return .run { [client = hierarchyClient] _ in
          _ = try? await client.launchAgent(spec)
        }

      case .manageAgentsTapped:
        let presenter = settingsWindowPresenter
        return .run { _ in
          await MainActor.run { presenter.openAt(.agents) }
        }
      }
    }
  }
}
