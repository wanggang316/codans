import CodansCore

/// The one rule that decides where Back / Forward can land. The header
/// segments, their press-and-hold menus, the Go menu commands, and the
/// reducer step all read it, so a surface never offers an entry the step
/// would refuse.
///
/// An entry is landable when its Worktree is in the catalog, is not
/// archived, and is not the Worktree selected now. Entries that are not
/// landable stay in the stacks: an archived Worktree that is unarchived
/// later becomes landable again.
nonisolated enum WorktreeHistoryLanding {
  /// The Worktrees a history entry can land on: every catalog Worktree that
  /// is not archived. The current selection is excluded per check, not here,
  /// because it changes more often than the catalog.
  static func landableWorktreeIDs(in catalog: Catalog) -> Set<WorktreeID> {
    var ids = Set<WorktreeID>()
    for project in catalog.projects {
      for worktree in project.worktrees where !worktree.archived {
        ids.insert(worktree.id)
      }
    }
    return ids
  }

  static func isLandable(
    _ entry: HierarchySelection,
    landable: Set<WorktreeID>,
    current: HierarchySelection
  ) -> Bool {
    guard entry.projectID != nil, let worktreeID = entry.worktreeID else { return false }
    return worktreeID != current.worktreeID && landable.contains(worktreeID)
  }

  /// The offset (0 = top of `stack`, which is oldest first) of the nearest
  /// landable entry at or past `offset`. Nil when there is none.
  static func nearestLandableOffset(
    in stack: [HierarchySelection],
    from offset: Int = 0,
    landable: Set<WorktreeID>,
    current: HierarchySelection
  ) -> Int? {
    guard offset >= 0, offset < stack.count else { return nil }
    for candidate in offset..<stack.count
    where isLandable(stack[stack.count - 1 - candidate], landable: landable, current: current) {
      return candidate
    }
    return nil
  }
}
