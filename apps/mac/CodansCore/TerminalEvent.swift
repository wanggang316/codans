import Foundation

/// Path-scoped identifier for `TerminalEvent.hierarchyMutated`. Lets TCA
/// consumers invalidate only the affected subtree instead of refreshing the
/// whole catalog.
public nonisolated enum HierarchyMutationScope: Sendable, Equatable {
  case catalog
  case project(ProjectID)
  case worktree(ProjectID, WorktreeID)
  case pane(ProjectID, WorktreeID, PaneID)
  case tab(ProjectID, WorktreeID, PaneID, TabID)
  case selection
  /// Tag CRUD or filter-state mutation. Sidebar uses this to refresh the
  /// chip footer + filtered project list without recomputing the whole
  /// hierarchy.
  case tags
}

public nonisolated enum TabAutoCloseCause: Sendable, Equatable {
  case crashLoop(count: Int, window: TimeInterval)
  case other(reason: String)
}

/// Runtime events. Session-scoped cases carry the `ContentID` of the
/// terminal Content they concern.
public nonisolated enum TerminalEvent: Sendable {
  case paneCreated(ContentID, TabID)
  case paneReady(ContentID)
  /// Coalesced bytes batch. Note: `data` may split a UTF-8 codepoint at the
  /// 16 KB buffer boundary — consumers that decode text (scrollback viewer,
  /// hook matchers) must buffer across batches per Content.
  case paneOutput(ContentID, Data)
  case paneViewportChanged(ContentID, text: String)
  case paneIdle(ContentID, duration: TimeInterval)
  /// Clean child exit. `code` is the exit status; `signal` is non-nil when
  /// the child was terminated by a signal (SIGKILL / SIGTERM / etc.) and
  /// exists to disambiguate from a normal non-zero return.
  case paneExited(ContentID, code: Int32, signal: Int32?)
  case paneCrashed(ContentID, reason: String)
  /// The Content was forcibly closed because its Tab was auto-closed
  /// (e.g. by crash-loop). Distinct from `paneExited(code: 0)` because the
  /// child did not exit cleanly — persistence and hook consumers should not
  /// treat this as a clean exit.
  case paneClosedByTab(ContentID, cause: TabAutoCloseCause)
  case tabActivated(TabID)
  case tabAutoClosed(TabID, cause: TabAutoCloseCause)
  case worktreeActivated(WorktreeID)
  case hierarchyMutated(HierarchyMutationScope)

  /// Runtime decoded a libghostty info-family action (title, pwd, mouse,
  /// search, progress, bell, child-exited). Applied to `PaneSurface.info`
  /// before emission so subscribers can choose between reading the
  /// `@Observable` state or reacting to the delta directly.
  case paneInfoChanged(ContentID, PaneInfoDelta)
  /// The Content's OSC 7501 program status records changed. Carries the
  /// summary the agent-state machine needs, nil when the Content has no
  /// records left. The runtime owns the records (see `ProgramStatusRecords`).
  case paneProgramStatusChanged(ContentID, ProgramStatusSummary?)
  case foregroundJobChanged(ContentID, ForegroundJob)
  /// Runtime decoded a tab / split intent. Consumed exclusively by
  /// `PaneActionRouterFeature` — other features must not subscribe.
  case paneActionRequested(ContentID, PaneActionRequest)
  /// Runtime decoded a window / app-level intent. Consumed exclusively by
  /// `WindowActionRouterFeature`.
  case windowActionRequested(WindowActionRequest)
  /// Runtime applied a `CONFIG_CHANGE` / `RELOAD_CONFIG` action to its
  /// `ghostty_config_t`. Emitted for features that cache configuration-
  /// dependent state (e.g. appearance, keybindings).
  case configChanged
}
