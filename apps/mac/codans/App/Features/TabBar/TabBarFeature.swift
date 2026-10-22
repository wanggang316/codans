import CodansCore
import ComposableArchitecture
import Foundation

/// Tab bar reducer, one instance shared by every Pane's strip of the
/// selected Worktree. State-free controller: a Pane's Tabs are read from
/// the environment `HierarchyManager` at render time; actions dispatch new /
/// select / close / rename / reorder / bulk-close commands through
/// `HierarchyClient`. Tab ids are catalog-unique, so a chip action names
/// its Tab alone; strip-level actions name their Pane. Errors are swallowed
/// (logged via the client's own channels) — tab-bar failures are rare and
/// not worth modal UX today.
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
    /// "+" on a strip. `inPane == nil` means the focused Pane (⌘T), or the
    /// first Pane of a Worktree that has none.
    case newTabButtonTapped(inPane: PaneID?, inWorktree: WorktreeID, inProject: ProjectID)
    case tabButtonTapped(TabID)
    case closeButtonTapped(TabID)
    /// A click on the strip outside its chips and controls: focuses the
    /// Pane and hands its selected Tab the keyboard.
    case stripTapped(PaneID)

    /// Open the rename sheet for `tabID`. Sources: chip context-menu Rename
    /// (any tab) and `RootFeature.renameActiveTabForCurrentWorktreeRequested`
    /// (active tab via ⌘⇧R menu chord).
    case renameRequested(TabID, currentName: String)
    /// Sheet dismissal — driven by the user closing the sheet without
    /// committing. Commit path clears `renameTarget` inside `renameSubmitted`
    /// so the sheet animates away on Enter.
    case renameDismissed
    case renameSubmitted(TabID, name: String?)
    case colorRequested(TabID, currentColor: TabColor?)
    case colorDismissed
    case colorSubmitted(TabID, color: TabColor?)
    case iconRequested(TabID, currentIcon: String?)
    case iconDismissed
    case iconSubmitted(TabID, icon: String?)
    case contextMenuCloseOthers(TabID)
    case contextMenuCloseToRight(TabID)
    case contextMenuCloseAll(inPane: PaneID)
    case dragReorderEnded(orderedIDs: [TabID], inPane: PaneID)
    case middleClicked(TabID)
    /// Trailing split button click, or the ⌘D / ⌘⇧D chords. Splits
    /// `fromPane` (nil = the focused Pane) in `direction`, creating a Pane
    /// with a fresh Tab in the anchor's directory. Silent no-op when the
    /// Worktree has no Pane.
    case trailingSplitRequested(
      direction: SplitTree<PaneID>.NewDirection,
      fromPane: PaneID?, inWorktree: WorktreeID, inProject: ProjectID)
    /// Play button on an Agent Session History row (trailing-accessory
    /// popover). Opens a fresh Tab whose session runs the agent's resume
    /// invocation (e.g. `claude --resume <id>`) as `initialCommand`, so the
    /// agent process owns the session exactly like a manually-launched agent
    /// — AgentBinder classifies it from the foreground job as usual.
    case resumeAgentSessionTapped(
      agent: AgentKind, sessionID: String,
      inPane: PaneID?, inWorktree: WorktreeID, inProject: ProjectID)
    /// An agent picked from the `+` button's press-and-hold / right-click
    /// menu. Starts the profile in a new Tab of that Pane whatever its saved
    /// placement — the user reached it from the new-tab button.
    case launchAgentInNewTabTapped(
      profileID: UUID, inPane: PaneID?, inWorktree: WorktreeID, inProject: ProjectID)
    /// "Manage Agents…" footer of the same menu.
    case manageAgentsTapped
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
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

      case .newTabButtonTapped(let paneID, let worktreeID, let projectID):
        // Resolve worktree.path from the catalog so the session starts in
        // the Worktree's directory instead of `$HOME`. Silent no-op if the
        // Worktree vanished.
        guard let cwd = worktreePath(worktreeID, projectID) else { return .none }
        guard
          let created = try? hierarchyClient.newTab(
            paneID, worktreeID, projectID, .terminal(workingDirectory: cwd), nil, nil, true)
        else { return .none }
        return bringUpAndFocus(created.contentID)

      case .tabButtonTapped(let tabID):
        try? hierarchyClient.selectTab(tabID)
        return .none

      case .closeButtonTapped(let tabID):
        try? hierarchyClient.closeTab(tabID)
        return .none

      case .stripTapped(let paneID):
        try? hierarchyClient.focusPane(paneID)
        guard let contentID = hierarchyClient.snapshot().pane(paneID)?.selectedTab?.contentID
        else { return .none }
        hierarchyClient.focusSurfaceView(contentID)
        return .none

      case .renameSubmitted(let tabID, let name):
        try? hierarchyClient.renameTab(tabID, name)
        state.renameTarget = nil
        return .none

      case .colorRequested(let tabID, let currentColor):
        state.colorTarget = ColorTarget(id: tabID, currentColor: currentColor)
        return .none

      case .colorDismissed:
        state.colorTarget = nil
        return .none

      case .colorSubmitted(let tabID, let color):
        try? hierarchyClient.setTabColor(tabID, color)
        state.colorTarget = nil
        return .none

      case .iconRequested(let tabID, let currentIcon):
        state.iconTarget = IconTarget(id: tabID, currentIcon: currentIcon)
        return .none

      case .iconDismissed:
        state.iconTarget = nil
        return .none

      case .iconSubmitted(let tabID, let icon):
        try? hierarchyClient.setTabIcon(tabID, icon, .user)
        state.iconTarget = nil
        return .none

      case .contextMenuCloseOthers(let tabID):
        try? hierarchyClient.closeOtherTabs(tabID)
        return .none

      case .contextMenuCloseToRight(let tabID):
        try? hierarchyClient.closeTabsToRight(tabID)
        return .none

      case .contextMenuCloseAll(let paneID):
        try? hierarchyClient.closeAllTabs(paneID)
        return .none

      case .dragReorderEnded(let orderedIDs, let paneID):
        try? hierarchyClient.reorderTabs(paneID, orderedIDs)
        return .none

      case .middleClicked(let tabID):
        try? hierarchyClient.closeTab(tabID)
        return .none

      case .trailingSplitRequested(let direction, let fromPane, let worktreeID, let projectID):
        let catalog = hierarchyClient.snapshot()
        // Anchor on the requested Pane, else the focused one, so the menu
        // chord ("Split Right/Down") and the strip's split button both
        // fork from where the user actually is.
        guard let anchor = fromPane ?? hierarchyClient.focusedContent(worktreeID)?.paneID,
          let pane = catalog.pane(anchor)
        else { return .none }
        // The new session starts where the anchor's selected session is.
        let cwd =
          pane.selectedTab?.content.terminal?.workingDirectory
          ?? worktreePath(worktreeID, projectID) ?? NSHomeDirectory()
        guard
          let created = try? hierarchyClient.splitPane(
            anchor, direction, .terminal(workingDirectory: cwd), nil, nil)
        else { return .none }
        return bringUpAndFocus(created.contentID)

      case .resumeAgentSessionTapped(let agent, let sessionID, let paneID, let worktreeID, let projectID):
        // Same catalog resolution as `newTabButtonTapped`: the session must
        // spawn in the Worktree's directory for the agent CLI to find the
        // session it recorded against that cwd.
        // The scanner only emits summaries for agents whose adapter can
        // resume, so a nil here signals a programming error upstream, not
        // a user-visible state.
        guard
          let command = AgentRuntimeAdapters.adapter(for: agent)
            .resumeCommand(sessionID: sessionID),
          let cwd = worktreePath(worktreeID, projectID)
        else { return .none }
        // No tab name: a name is a sticky rename, and the chip must follow
        // the agent's live title like a command typed in a session.
        guard
          let created = try? hierarchyClient.newTab(
            paneID, worktreeID, projectID,
            .terminal(workingDirectory: cwd, initialCommand: command), nil, nil, true)
        else { return .none }
        return bringUpAndFocus(created.contentID)

      case .launchAgentInNewTabTapped(let profileID, let paneID, let worktreeID, let projectID):
        // A profile removed between opening the menu and picking it is a
        // silent no-op, like the rest of the tab bar's rare failures.
        guard let profile = settingsWriter.readSnapshotSync().agents.profile(id: profileID)
        else { return .none }
        // `.newTab` lands in the focused Pane; the menu belongs to a
        // specific strip, so focus that Pane first.
        if let paneID {
          try? hierarchyClient.focusPane(paneID)
        }
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

  private func worktreePath(_ worktreeID: WorktreeID, _ projectID: ProjectID) -> String? {
    hierarchyClient.snapshot().worktree(worktreeID, in: projectID)?.path
  }

  /// Spawn the new Tab's session, then promote its surface to first
  /// responder so the Tab opens with keyboard focus. Dispatched async so
  /// SwiftUI has time to attach the surface view to the window before
  /// `makeFirstResponder` runs — `focusSurfaceView` retries with backoff
  /// if the window isn't ready yet.
  private func bringUpAndFocus(_ contentID: ContentID) -> Effect<Action> {
    .run { [client = hierarchyClient] _ in
      guard (try? await client.ensureSurface(contentID)) != nil else { return }
      await MainActor.run { client.focusSurfaceView(contentID) }
    }
  }
}
