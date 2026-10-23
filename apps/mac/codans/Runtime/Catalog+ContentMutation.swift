import CodansCore
import Foundation

/// In-place writers for terminal Content state. The catalog nests a
/// session four levels deep (project → worktree → pane → tab → content);
/// these walk it once so the manager's session-field verbs do not each
/// spell out the index chain.
extension Catalog {
  /// Applies `body` to the terminal state of `contentID`. Returns `body`'s
  /// result, or `nil` when no terminal Content carries that id.
  @discardableResult
  mutating func withTerminalContent<R>(
    _ contentID: ContentID,
    _ body: (inout TerminalContentState) -> R
  ) -> R? {
    for projectIndex in projects.indices {
      for worktreeIndex in projects[projectIndex].worktrees.indices {
        for paneIndex in projects[projectIndex].worktrees[worktreeIndex].panes.indices {
          let tabs = projects[projectIndex].worktrees[worktreeIndex].panes[paneIndex].tabs
          guard let tabIndex = tabs.firstIndex(where: { $0.content.id == contentID }),
            var state = tabs[tabIndex].content.terminal
          else { continue }
          let result = body(&state)
          projects[projectIndex].worktrees[worktreeIndex].panes[paneIndex].tabs[tabIndex].content.terminal = state
          return result
        }
      }
    }
    return nil
  }

  /// Applies `body` to every terminal Content in the catalog.
  mutating func forEachTerminalContent(_ body: (inout TerminalContentState) -> Void) {
    for projectIndex in projects.indices {
      for worktreeIndex in projects[projectIndex].worktrees.indices {
        for paneIndex in projects[projectIndex].worktrees[worktreeIndex].panes.indices {
          for tabIndex in projects[projectIndex].worktrees[worktreeIndex].panes[paneIndex].tabs.indices {
            guard
              var state = projects[projectIndex].worktrees[worktreeIndex].panes[paneIndex].tabs[tabIndex].content
                .terminal
            else { continue }
            body(&state)
            projects[projectIndex].worktrees[worktreeIndex].panes[paneIndex].tabs[tabIndex].content.terminal = state
          }
        }
      }
    }
  }
}
