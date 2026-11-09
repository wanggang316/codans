import CodansCore

/// The most recently selected worktrees, newest first, bounded by `limit`.
/// Feeds the recency input of `SurfaceReclaimPolicy`.
nonisolated struct WorktreeSelectionHistory: Equatable, Sendable {
  let limit: Int
  private(set) var worktrees: [WorktreeID] = []

  init(limit: Int) {
    self.limit = max(0, limit)
  }

  mutating func record(_ id: WorktreeID) {
    worktrees.removeAll { $0 == id }
    worktrees.insert(id, at: 0)
    if worktrees.count > limit { worktrees.removeLast(worktrees.count - limit) }
  }

  /// 0 for the latest selection; nil when the worktree is not in the history.
  func rank(of id: WorktreeID) -> Int? {
    worktrees.firstIndex(of: id)
  }
}
