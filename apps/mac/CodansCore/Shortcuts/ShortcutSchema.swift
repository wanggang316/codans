import Foundation

/// Defaults table — the one place that maps `CommandID` cases to display title, category,
/// scope, and built-in chord. Reads at app launch only; never mutates. The override store
/// overlays this; resolution happens in `ShortcutResolver`.
///
/// `ShortcutSchema.app` is the production registry. Tests construct their own schemas via
/// `init(version:entries:)` for isolation.
public struct ShortcutSchema: Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let entries: [Entry]

  public init(version: Int = ShortcutSchema.currentVersion, entries: [Entry]) {
    self.version = version
    self.entries = entries
  }

  public struct Entry: Sendable, Equatable {
    public let id: CommandID
    public let title: String
    public let category: Category
    public let scope: ShortcutScope
    public let defaultBinding: ShortcutBinding?

    public init(
      id: CommandID,
      title: String,
      category: Category,
      scope: ShortcutScope,
      defaultBinding: ShortcutBinding?
    ) {
      self.id = id
      self.title = title
      self.category = category
      self.scope = scope
      self.defaultBinding = defaultBinding
    }
  }

  public enum Category: String, CaseIterable, Sendable, Codable {
    case general
    case projectAndWorktree
    case terminal
    case actions
  }
}

extension ShortcutSchema {
  /// Returns the entry for `id`, or `nil` if the schema is missing it. The schema audit test
  /// asserts this is never `nil` for any `CommandID.allCases` value in `ShortcutSchema.app`.
  public func entry(for id: CommandID) -> Entry? {
    entries.first { $0.id == id }
  }
}

extension ShortcutSchema {
  /// Production registry. Default chords mirror the literals previously written inline in
  /// `MainWindowCommands.swift` and `HierarchySidebarView.swift`. The schema audit test
  /// pins these against a golden table; updates require deliberate intent.
  ///
  /// Entries are partitioned by category into private sub-arrays and concatenated at use.
  /// A single literal of ~40 entries trips Swift's type-inference timeout on the array-of-
  /// `.init(...)` shorthand; partitioning keeps each sub-expression small enough to resolve.
  public static let app: ShortcutSchema = .init(
    entries: generalEntries + projectAndWorktreeEntries + terminalEntries + actionEntries
  )

  private static let generalEntries: [Entry] = [
    // General — app shell.
    .init(
      id: .openSettings,
      title: "Open Settings",
      category: .general,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiComma, modifiers: .command)
    ),
    .init(
      id: .commandPaletteToggle,
      title: "Quick Action",
      category: .general,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiP, modifiers: .command)
    ),
    .init(
      id: .showUnread,
      title: "Show Unread Notifications",
      category: .general,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiU, modifiers: .command)
    ),
    .init(
      id: .checkForUpdates,
      title: "Check for Updates",
      category: .general,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiU, modifiers: [.command, .shift])
    ),
  ]

  private static let projectAndWorktreeEntries: [Entry] = [
    // Project & Worktree — list, lifecycle, identity.
    .init(
      id: .addProject,
      title: "Add Project…",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiO, modifiers: [.command, .shift])
    ),
    .init(
      id: .newWorktree,
      title: "New Worktree…",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiN, modifiers: .command)
    ),
    // Unbound by default: creating a workspace is rare enough that no chord
    // is worth reserving; the palette and the Add menu are the entry points.
    .init(
      id: .newWorkspace,
      title: "New Workspace…",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: nil
    ),
    .init(
      id: .toggleDiffInspector,
      title: "Toggle Git Viewer",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiG, modifiers: .command)
    ),
    .init(
      id: .revealCurrentWorktreeInFinder,
      title: "Reveal in Finder",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiO, modifiers: [.command, .option])
    ),
    .init(
      id: .archiveCurrentWorktree,
      title: "Archive Worktree",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.delete, modifiers: .command)
    ),
    .init(
      id: .deleteCurrentWorktree,
      title: "Delete Worktree",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.delete, modifiers: [.command, .shift])
    ),
    .init(
      id: .showArchivedWorktrees,
      title: "Show Archived Worktrees",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiA, modifiers: [.command, .control])
    ),
    .init(
      id: .copyCurrentWorktreePath,
      title: "Copy Worktree Path",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiC, modifiers: [.command, .shift])
    ),
    .init(
      id: .toggleSidebar,
      title: "Toggle Sidebar",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiS, modifiers: [.command, .option])
    ),
    .init(
      id: .revealCurrentWorktreeInSidebar,
      title: "Reveal in Sidebar",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiJ, modifiers: [.command, .shift])
    ),
    .init(
      id: .selectPreviousWorktree,
      title: "Select Previous Worktree",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.upArrow, modifiers: [.command, .control])
    ),
    .init(
      id: .selectNextWorktree,
      title: "Select Next Worktree",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.downArrow, modifiers: [.command, .control])
    ),
    .init(
      id: .worktreeHistoryBack,
      title: "Back in Worktree History",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiLeftBracket, modifiers: [.command, .control])
    ),
    .init(
      id: .worktreeHistoryForward,
      title: "Forward in Worktree History",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiRightBracket, modifiers: [.command, .control])
    ),
    .init(
      id: .selectWorktreeAt1,
      title: "Select Worktree 1",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi1, modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt2,
      title: "Select Worktree 2",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi2, modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt3,
      title: "Select Worktree 3",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi3, modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt4,
      title: "Select Worktree 4",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi4, modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt5,
      title: "Select Worktree 5",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi5, modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt6,
      title: "Select Worktree 6",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi6, modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt7,
      title: "Select Worktree 7",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi7, modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt8,
      title: "Select Worktree 8",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi8, modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt9,
      title: "Select Worktree 9",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi9, modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt10,
      title: "Select Worktree 10",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi0, modifiers: [.control])
    ),
  ]

  private static let terminalEntries: [Entry] = [
    // Terminal — tabs and split layout.
    .init(
      id: .newTab,
      title: "New Tab",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiT, modifiers: .command)
    ),
    .init(
      id: .closeTab,
      title: "Close Tab",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiW, modifiers: .command)
    ),
    .init(
      id: .renameActiveTab,
      title: "Rename Tab…",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiR, modifiers: [.command, .option])
    ),
    .init(
      id: .changeActiveTabColor,
      title: "Change Tab Color…",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiC, modifiers: [.command, .option])
    ),
    .init(
      id: .previousTab,
      title: "Previous Tab",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiLeftBracket, modifiers: [.command, .shift])
    ),
    .init(
      id: .nextTab,
      title: "Next Tab",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiRightBracket, modifiers: [.command, .shift])
    ),
    .init(
      id: .splitRight,
      title: "Split Right",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiD, modifiers: .command)
    ),
    .init(
      id: .splitDown,
      title: "Split Down",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiD, modifiers: [.command, .shift])
    ),
    .init(
      id: .focusSplitLeft,
      title: "Focus Pane Left",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.leftArrow, modifiers: [.command, .option])
    ),
    .init(
      id: .focusSplitRight,
      title: "Focus Pane Right",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.rightArrow, modifiers: [.command, .option])
    ),
    .init(
      id: .focusSplitUp,
      title: "Focus Pane Up",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.upArrow, modifiers: [.command, .option])
    ),
    .init(
      id: .focusSplitDown,
      title: "Focus Pane Down",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.downArrow, modifiers: [.command, .option])
    ),
    .init(
      id: .switchToTab1,
      title: "Switch to Tab 1",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi1, modifiers: .command)
    ),
    .init(
      id: .switchToTab2,
      title: "Switch to Tab 2",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi2, modifiers: .command)
    ),
    .init(
      id: .switchToTab3,
      title: "Switch to Tab 3",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi3, modifiers: .command)
    ),
    .init(
      id: .switchToTab4,
      title: "Switch to Tab 4",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi4, modifiers: .command)
    ),
    .init(
      id: .switchToTab5,
      title: "Switch to Tab 5",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi5, modifiers: .command)
    ),
    .init(
      id: .switchToTab6,
      title: "Switch to Tab 6",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi6, modifiers: .command)
    ),
    .init(
      id: .switchToTab7,
      title: "Switch to Tab 7",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi7, modifiers: .command)
    ),
    .init(
      id: .switchToTab8,
      title: "Switch to Tab 8",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi8, modifiers: .command)
    ),
    .init(
      id: .switchToTab9,
      title: "Switch to Tab 9",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi9, modifiers: .command)
    ),
    .init(
      id: .switchToTab10,
      title: "Switch to Tab 10",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansi0, modifiers: .command)
    ),
    // ⌘⌥L is unclaimed by AppKit and by ghostty's default keybinds, so the
    // chord reaches the menu item even while a terminal pane holds
    // first responder.
    .init(
      id: .toggleCommandQueue,
      title: "Command Queue…",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiL, modifiers: [.command, .option])
    ),
  ]

  private static let actionEntries: [Entry] = [
    // Actions — verbs on the current worktree.
    .init(
      id: .openInEditor,
      title: "Open in Editor",
      category: .actions,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiO, modifiers: .command)
    ),
    .init(
      id: .openCurrentPR,
      title: "Open PR on GitHub",
      category: .actions,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiG, modifiers: [.command, .control])
    ),
    .init(
      id: .openProjectOnGitHub,
      title: "Open Project on GitHub",
      category: .actions,
      scope: .configurable,
      defaultBinding: .init(keyCode: KeyCode.ansiG, modifiers: [.command, .shift])
    ),
  ]
}
