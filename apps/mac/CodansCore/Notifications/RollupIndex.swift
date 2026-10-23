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
/// - L1 Content   — no chrome. A source Content the user can already see
///                  (its Tab is the selected Tab of a Pane in the active
///                  Worktree) is a sink: the entry stays unread in the
///                  inbox but emits no roll-up indicator.
///
/// `globalUnreadCount` is the total ungrouped unread count. Only the
/// status-bar bell badge and the Dock tile badge consume it.
public nonisolated struct RollupIndex: Equatable, Sendable {
  public let unreadProjects: Set<ProjectID>
  public let unreadWorktrees: Set<WorktreeID>
  /// Contents whose Tab chip shows the unread dot.
  public let unreadContents: Set<ContentID>
  public let globalUnreadCount: Int

  public init(
    unreadProjects: Set<ProjectID> = [],
    unreadWorktrees: Set<WorktreeID> = [],
    unreadContents: Set<ContentID> = [],
    globalUnreadCount: Int = 0
  ) {
    self.unreadProjects = unreadProjects
    self.unreadWorktrees = unreadWorktrees
    self.unreadContents = unreadContents
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
    var unreadContents: Set<ContentID> = []

    for entry in unread {
      switch deepestHiddenLevel(for: entry.source, focus: focus) {
      case .project:
        unreadProjects.insert(entry.source.projectID)
      case .worktree:
        unreadWorktrees.insert(entry.source.worktreeID)
      case .tab:
        unreadContents.insert(entry.source.contentID)
      case .content:
        // Sink: the source Content is on screen (its Tab is selected in
        // its Pane). There is no Content-level chrome, and surfacing it at
        // Tab / Worktree / Project would be wrong since the user is already
        // looking at it. The entry stays unread in the inbox (counted in
        // `globalUnreadCount`) but emits no indicator.
        break
      }
    }

    return RollupIndex(
      unreadProjects: unreadProjects,
      unreadWorktrees: unreadWorktrees,
      unreadContents: unreadContents,
      globalUnreadCount: unread.count
    )
  }

  // MARK: - Visibility logic

  enum Level { case project, worktree, tab, content }

  /// Decide which level renders the indicator for one source path. The
  /// rule is "deepest hidden ancestor": walk down from project, stop at
  /// the first level the user cannot see into. `.content` is the terminal
  /// case — everything above it is visible, so `compute` treats it as an
  /// indicator-less sink.
  private static func deepestHiddenLevel(
    for source: InboxEntry.SourcePath,
    focus: RollupFocusState
  ) -> Level {
    if !focus.expandedProjectIDs.contains(source.projectID),
      !focus.rowWorktreeIDs.contains(source.worktreeID)
    {
      return .project
    }
    let projectIsActive = focus.activeProjectID == source.projectID
    let worktreeIsActive = projectIsActive && focus.activeWorktreeID == source.worktreeID
    if !worktreeIsActive {
      return .worktree
    }
    if !focus.visibleContentIDs.contains(source.contentID) {
      return .tab
    }
    // The Content is on screen, so there is no deeper hidden level.
    // Classify as `.content`, which `compute` drops as an indicator-less
    // sink.
    return .content
  }
}

/// Snapshot of the data the user can currently see in the sidebar and
/// the Pane strips. Drives `RollupIndex.compute`'s visibility rule.
public nonisolated struct RollupFocusState: Equatable, Sendable {
  /// Contents on screen: the selected Tab of every Pane of the active
  /// Worktree.
  public let visibleContentIDs: Set<ContentID>
  public let activeWorktreeID: WorktreeID?
  public let activeProjectID: ProjectID?
  /// Projects whose disclosure row is currently expanded in the sidebar.
  /// Worktrees / Panes / Tabs inside a collapsed project are not visible
  /// to the user, so unread events for them roll up to project level.
  public let expandedProjectIDs: Set<ProjectID>
  /// Worktrees drawn as their Project's own row (`Project.rowWorktree`):
  /// on screen whether or not the Project is expanded, so their unread
  /// events stay at worktree level.
  public let rowWorktreeIDs: Set<WorktreeID>

  public init(
    visibleContentIDs: Set<ContentID> = [],
    activeWorktreeID: WorktreeID? = nil,
    activeProjectID: ProjectID? = nil,
    expandedProjectIDs: Set<ProjectID> = [],
    rowWorktreeIDs: Set<WorktreeID> = []
  ) {
    self.visibleContentIDs = visibleContentIDs
    self.activeWorktreeID = activeWorktreeID
    self.activeProjectID = activeProjectID
    self.expandedProjectIDs = expandedProjectIDs
    self.rowWorktreeIDs = rowWorktreeIDs
  }
}
