import Foundation

/// Where a `ScriptDefinition` materializes when invoked.
///
/// - `.newTab`   — open a fresh tab in the worktree and run as the new pane's
///                 `initialCommand`.
/// - `.focused`  — write the command into the worktree's currently focused
///                 pane via `TerminalClient.sendInput`. No new pane / tab.
/// - `.split`    — split the focused pane in `ScriptDefinition.direction` and
///                 run as the split's `initialCommand`.
///
/// Stable lowercase raw values land in `settings.json`. Default is `.newTab`
/// so a fresh script keeps the existing behaviour without writing the field.
public enum ScriptTarget: String, Codable, Sendable, CaseIterable {
  case focused
  case newTab
  case split
}
