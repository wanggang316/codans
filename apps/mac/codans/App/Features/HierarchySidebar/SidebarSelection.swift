import CodansCore

/// The selection the sidebar outline (`SidebarOutline`) shows and reports. Pending rows are
/// selectable targets too, so the system source-list renderer paints their
/// highlight with the same geometry and focus-aware emphasis as worktree rows.
nonisolated enum SidebarSelection: Hashable, Sendable {
  case worktree(WorktreeID)
  case pending(PendingWorktreeID)

  /// A real worktree selection wins: selecting one clears the followed
  /// creation, and following a creation nils the worktree selection.
  static func resolve(
    selectedWorktreeID: WorktreeID?, activePendingWorktreeID: PendingWorktreeID?
  ) -> SidebarSelection? {
    if let selectedWorktreeID { return .worktree(selectedWorktreeID) }
    return activePendingWorktreeID.map(SidebarSelection.pending)
  }
}
