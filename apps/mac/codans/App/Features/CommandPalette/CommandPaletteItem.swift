import Foundation
import CodansCore

/// One row in the Command Palette.
///
/// Items are rebuilt from live state on every palette open; `id` is the
/// only field that persists across rebuilds (used as the recency map key),
/// so it must be stable across launches for parameterized Kinds — e.g.
/// `"worktree.select.<uuid>"` not `"worktree.select.<index>"`.
struct CommandPaletteItem: Equatable, Identifiable {
  let id: String
  let title: String
  let subtitle: String?
  /// Extra text matched by the fuzzy scorer at title-level priority but
  /// never shown in the row. Lets an item rank on terms absent from its
  /// visible title — e.g. a "Switch to Worktree: <name>" item carries its
  /// Project name here so a Project-name query surfaces it instead of
  /// burying it in the lower subtitle band. `nil` matches the title only.
  let searchText: String?
  let icon: String
  /// Hardcoded display hint, used as a fallback when `commandID` is unset or the env-injected
  /// resolved-shortcut map has no binding for that ID. Registry-tracked actions should pass
  /// `commandID` instead so users see their custom rebinds in the palette.
  let shortcut: KeyEquivalentDescriptor?
  /// Identifier into the shortcut registry. When set, the row view derives the chord display
  /// from `@Environment(\.resolvedShortcuts)` so user rebinds and disables flow through to
  /// the palette hint without rebuilding the items.
  let commandID: CommandID?
  let priorityTier: Int
  /// When true, the item is excluded from the empty-query list. Reserved
  /// for sharp-edge commands (e.g. "Close Current Worktree") that should
  /// not surface by accident the moment the user opens the palette.
  let hiddenWhenQueryEmpty: Bool
  let kind: Kind

  init(
    id: String,
    title: String,
    subtitle: String? = nil,
    searchText: String? = nil,
    icon: String,
    shortcut: KeyEquivalentDescriptor? = nil,
    commandID: CommandID? = nil,
    priorityTier: Int = 100,
    hiddenWhenQueryEmpty: Bool = false,
    kind: Kind
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.searchText = searchText
    self.icon = icon
    self.shortcut = shortcut
    self.commandID = commandID
    self.priorityTier = priorityTier
    self.hiddenWhenQueryEmpty = hiddenWhenQueryEmpty
    self.kind = kind
  }

  enum Kind: Equatable {
    // App
    case openSettings
    case checkForUpdates
    case quit

    // Worktree
    case selectWorktree(ProjectID, WorktreeID)
    case closeCurrentWorktree
    case refreshCurrentWorktree
    case toggleDiffInspector

    // Editor
    case openCurrentWorktreeInDefaultEditor
    case openCurrentWorktreeIn(EditorID)
    case revealCurrentWorktreeInFinder

    // Project Scripts (Phase 2 / M10) — one Kind per
    // `ProjectSettings.scripts` entry under the active Project. Carries the
    // selection's `(projectID, worktreeID)` so the route runs against the
    // exact selection that built the item, even if the user changes
    // selection between palette open and activation.
    case runProjectScript(ProjectID, WorktreeID, ScriptDefinition.ID)

    // Global Commands — one Kind per `GeneralSettings.globalScripts` entry.
    // Like `runProjectScript`, carries the selection's `(projectID,
    // worktreeID)` so the global command runs in the exact Worktree that
    // built the item even if the selection changes before activation.
    case runGlobalScript(ProjectID, WorktreeID, ScriptDefinition.ID)

    // Pane / Window (thin wrappers over the existing request enums)
    case paneAction(PaneActionRequest)
    case windowAction(WindowActionRequest)
  }
}
