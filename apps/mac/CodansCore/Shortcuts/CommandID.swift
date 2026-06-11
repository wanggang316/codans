import Foundation

/// Stable identifier for every user-bindable in-app keyboard command.
///
/// The closed enum is the single source of truth for what the registry can rebind. Adding a
/// new shortcut means adding a `case`, an entry in `ShortcutSchema.app`, and a routing call
/// site that reads the resolved binding via the SwiftUI environment. Renaming a case is a
/// compile-time error at every consumer.
///
/// Raw values are stable JSON keys for `ShortcutOverrideStore.overrides`. They are part of
/// the persisted format and must not change once shipped — a rename here orphans every
/// existing user override for that command. New cases use lowerCamelCase identifiers that
/// double as their raw value.
public enum CommandID: String, CaseIterable, Hashable, Sendable, Codable, CodingKeyRepresentable {
  // App scope.
  case openSettings
  case checkForUpdates
  case showUnread

  // Quick action.
  case commandPaletteToggle

  // Window — main commands.
  // Raw value pinned to the original `openInDefaultEditor` string — the
  // Swift identifier was shortened, but the JSON raw value is part of the
  // persisted shortcut-overrides format and must not change once shipped
  // (see this enum's docstring).
  case openInEditor = "openInDefaultEditor"
  // Raw value pinned to the original `toggleGitViewer` string — the Swift
  // identifier renamed during M1 of the Diff inspector work, but the JSON
  // raw value is part of the persisted shortcut-overrides format and must
  // not change once shipped (see this enum's docstring). Renaming it would
  // orphan every existing user override of the ⌘⇧G binding.
  case toggleDiffInspector = "toggleGitViewer"
  case addProject
  case openCurrentPR
  case openProjectOnGitHub
  case newWorktree
  case splitRight
  case splitDown
  case focusSplitLeft
  case focusSplitRight
  case focusSplitUp
  case focusSplitDown

  // Worktree row operations.
  case revealCurrentWorktreeInFinder
  case archiveCurrentWorktree
  case deleteCurrentWorktree
  case showArchivedWorktrees
  case copyCurrentWorktreePath

  // Sidebar.
  case toggleSidebar
  case revealCurrentWorktreeInSidebar
  case selectNextWorktree
  case selectPreviousWorktree
  case worktreeHistoryBack
  case worktreeHistoryForward

  // Window — tabs.
  case newTab
  case closeTab
  case renameActiveTab
  case changeActiveTabColor
  case previousTab
  case nextTab
  case switchToTab1
  case switchToTab2
  case switchToTab3
  case switchToTab4
  case switchToTab5
  case switchToTab6
  case switchToTab7
  case switchToTab8
  case switchToTab9
  case switchToTab10

  // Sidebar row hotkeys.
  case selectWorktreeAt1
  case selectWorktreeAt2
  case selectWorktreeAt3
  case selectWorktreeAt4
  case selectWorktreeAt5
  case selectWorktreeAt6
  case selectWorktreeAt7
  case selectWorktreeAt8
  case selectWorktreeAt9
  case selectWorktreeAt10
}

extension CommandID {
  /// Maps a 1-based tab index to the matching `switchToTabN` case, or `nil` if `index` is
  /// outside `1...10`. Used by `MainWindowCommands` when wiring the `⌘1`–`⌘9` / `⌘0` row
  /// from a single `ForEach`. The 10th slot is keyed under digit `0` per the macOS / Safari
  /// convention.
  public static func switchToTab(index: Int) -> CommandID? {
    switch index {
    case 1: return .switchToTab1
    case 2: return .switchToTab2
    case 3: return .switchToTab3
    case 4: return .switchToTab4
    case 5: return .switchToTab5
    case 6: return .switchToTab6
    case 7: return .switchToTab7
    case 8: return .switchToTab8
    case 9: return .switchToTab9
    case 10: return .switchToTab10
    default: return nil
    }
  }

  /// Maps a 1-based sidebar row index to the matching `selectWorktreeAtN` case. Rows beyond
  /// 10 receive no hotkey. The 10th slot is keyed under digit `0` per the macOS / Safari
  /// convention.
  public static func selectWorktreeAt(index: Int) -> CommandID? {
    switch index {
    case 1: return .selectWorktreeAt1
    case 2: return .selectWorktreeAt2
    case 3: return .selectWorktreeAt3
    case 4: return .selectWorktreeAt4
    case 5: return .selectWorktreeAt5
    case 6: return .selectWorktreeAt6
    case 7: return .selectWorktreeAt7
    case 8: return .selectWorktreeAt8
    case 9: return .selectWorktreeAt9
    case 10: return .selectWorktreeAt10
    default: return nil
    }
  }
}
