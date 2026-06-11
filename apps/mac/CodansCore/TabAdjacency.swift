import Foundation

/// Direction of an adjacent-tab jump within a Worktree. Used by the
/// `selectAdjacentTab` manager method + `selectAdjacentTabForCurrentWorktree`
/// Root resolver, plus the menu-bar `⌘⇧[` / `⌘⇧]` bindings.
public enum TabAdjacency: Sendable, Equatable {
  case previous
  case next
}
