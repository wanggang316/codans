import Foundation

/// Per-level unread roll-up over the inbox + current focus state.
///
/// Each unread entry contributes to **exactly one** level: the deepest
/// hierarchy ancestor that is currently *hidden* from the user. If the
/// user can already see deeper into a level, the indicator at the higher
/// level is suppressed and shown only at the deepest still-hidden
/// ancestor.
///
/// Per-level visuals (boolean):
/// - L4 Project   — small unread dot to the right of the project name
/// - L3 Worktree  — leading row icon swaps to a bell glyph
/// - L2 Tab       — small unread dot prefixed before the tab title
/// - L1 Pane      — no chrome. A source pane the user can already see
///                  (its tab is active — the pane is either focused or a
///                  visible sibling split) is a sink: the entry stays
///                  unread in the inbox but emits no roll-up indicator.
///
/// `globalUnreadCount` is the total ungrouped unread count. Only the
/// status-bar bell badge and the Dock tile badge consume it.
public nonisolated struct RollupIndex: Equatable, Sendable {
  public let unreadProjects: Set<ProjectID>
  public let unreadWorktrees: Set<WorktreeID>
  public let unreadTabs: Set<TabID>
  public let globalUnreadCount: Int

  public init(
    unreadProjects: Set<ProjectID> = [],
    unreadWorktrees: Set<WorktreeID> = [],
    unreadTabs: Set<TabID> = [],
    globalUnreadCount: Int = 0
  ) {
    self.unreadProjects = unreadProjects
    self.unreadWorktrees = unreadWorktrees
    self.unreadTabs = unreadTabs
    self.globalUnreadCount = globalUnreadCount
  }

  public static let empty = RollupIndex()

  /// Walk every unread entry, decide which level emits its indicator
  /// per the visibility rules in the design doc, and accumulate.
  public static func compute(
    unread: [InboxEntry],
    focus: RollupFocusState
  ) -> RollupIndex {
    var unreadProjects: Set<ProjectID> = []
    var unreadWorktrees: Set<WorktreeID> = []
    var unreadTabs: Set<TabID> = []

    for entry in unread {
      switch deepestHiddenLevel(for: entry.source, focus: focus) {
      case .project:
        unreadProjects.insert(entry.source.projectID)
      case .worktree:
        unreadWorktrees.insert(entry.source.worktreeID)
      case .tab:
        unreadTabs.insert(entry.source.tabID)
      case .pane:
        // Sink: the source pane is already the deepest level the user can
        // see (its tab is active — the pane is either focused or a visible
        // sibling split). There is no pane-level chrome, and surfacing it
        // at Tab / Worktree / Project would be wrong since the user is
        // already looking into this tab. The entry stays unread in the
        // inbox (counted in `globalUnreadCount`) but emits no indicator.
        break
      }
    }

    return RollupIndex(
      unreadProjects: unreadProjects,
      unreadWorktrees: unreadWorktrees,
      unreadTabs: unreadTabs,
      globalUnreadCount: unread.count
    )
  }

  // MARK: - Visibility logic

  enum Level { case project, worktree, tab, pane }

  /// Decide which level renders the indicator for one source path. The
  /// rule is "deepest hidden ancestor": walk down from project, stop at
  /// the first level the user cannot see into. `.pane` is the terminal
  /// case — everything above it is visible, so `compute` treats it as an
  /// indicator-less sink.
  private static func deepestHiddenLevel(
    for source: InboxEntry.SourcePath,
    focus: RollupFocusState
  ) -> Level {
    if !focus.expandedProjectIDs.contains(source.projectID) {
      return .project
    }
    let projectIsActive = focus.activeProjectID == source.projectID
    let worktreeIsActive = projectIsActive && focus.activeWorktreeID == source.worktreeID
    if !worktreeIsActive {
      return .worktree
    }
    let tabIsActive = focus.activeTabID == source.tabID
    if !tabIsActive {
      return .tab
    }
    // Tab is active: the source pane is visible (focused or a sibling
    // split), so there is no deeper hidden level. Classify as `.pane`,
    // which `compute` drops as an indicator-less sink.
    return .pane
  }
}

/// Snapshot of the data the user can currently see in the sidebar /
/// tab-bar / pane chrome. Drives `RollupIndex.compute`'s visibility rule.
public nonisolated struct RollupFocusState: Equatable, Sendable {
  public let focusedPaneID: PaneID?
  public let activeTabID: TabID?
  public let activeWorktreeID: WorktreeID?
  public let activeProjectID: ProjectID?
  /// Projects whose disclosure row is currently expanded in the sidebar.
  /// Worktrees / tabs / panes inside a collapsed project are not visible
  /// to the user, so unread events for them roll up to project level.
  public let expandedProjectIDs: Set<ProjectID>

  public init(
    focusedPaneID: PaneID? = nil,
    activeTabID: TabID? = nil,
    activeWorktreeID: WorktreeID? = nil,
    activeProjectID: ProjectID? = nil,
    expandedProjectIDs: Set<ProjectID> = []
  ) {
    self.focusedPaneID = focusedPaneID
    self.activeTabID = activeTabID
    self.activeWorktreeID = activeWorktreeID
    self.activeProjectID = activeProjectID
    self.expandedProjectIDs = expandedProjectIDs
  }
}
