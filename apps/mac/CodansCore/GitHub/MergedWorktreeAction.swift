import Foundation

/// What to do with a Worktree after its pull request merges. Resolved from the
/// per-Project `RepositorySettings.postMergeAction`, falling back to the global
/// `GeneralSettings.postMergeAction`, and finally `.ask` when neither is set.
public enum MergedWorktreeAction: String, Codable, Sendable, CaseIterable {
  /// Leave the Worktree alone. The row stays in the sidebar, the badge flips to merged.
  case doNothing = "do_nothing"
  /// Set `Worktree.archived = true`. Row disappears from the main list; reachable from
  /// the Archived view. Git worktree directory untouched.
  case archive = "archive"
  /// Remove the git worktree (via `HierarchyClient.removeWorktree`). Working-tree files
  /// are deleted from disk — destructive, guarded by a confirmation sheet when chosen
  /// inline (not when already configured as a default).
  case delete = "delete"
  /// Present a sheet with the three options above and a "Remember my choice for this
  /// Project" checkbox. The default value for users who have not picked a strategy yet.
  case ask = "ask"

  public var displayName: String {
    switch self {
    case .doNothing: return "Do nothing"
    case .archive: return "Archive the worktree"
    case .delete: return "Delete the worktree"
    case .ask: return "Ask each time"
    }
  }
}
