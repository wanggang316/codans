import Carbon.HIToolbox
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
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_Comma), modifiers: .command)
    ),
    .init(
      id: .commandPaletteToggle,
      title: "Quick Action",
      category: .general,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_P), modifiers: .command)
    ),
    .init(
      id: .showUnread,
      title: "Show Unread Notifications",
      category: .general,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_U), modifiers: .command)
    ),
    .init(
      id: .checkForUpdates,
      title: "Check for Updates",
      category: .general,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_U), modifiers: [.command, .shift])
    ),
  ]

  private static let projectAndWorktreeEntries: [Entry] = [
    // Project & Worktree — list, lifecycle, identity.
    .init(
      id: .addProject,
      title: "Add Project…",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_O), modifiers: [.command, .shift])
    ),
    .init(
      id: .newWorktree,
      title: "New Worktree…",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_N), modifiers: .command)
    ),
    .init(
      id: .toggleDiffInspector,
      title: "Toggle Git Viewer",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_G), modifiers: .command)
    ),
    .init(
      id: .revealCurrentWorktreeInFinder,
      title: "Reveal in Finder",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_O), modifiers: [.command, .option])
    ),
    .init(
      id: .archiveCurrentWorktree,
      title: "Archive Worktree",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_Delete), modifiers: .command)
    ),
    .init(
      id: .deleteCurrentWorktree,
      title: "Delete Worktree",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_Delete), modifiers: [.command, .shift])
    ),
    .init(
      id: .showArchivedWorktrees,
      title: "Show Archived Worktrees",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command, .control])
    ),
    .init(
      id: .copyCurrentWorktreePath,
      title: "Copy Worktree Path",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .shift])
    ),
    .init(
      id: .toggleSidebar,
      title: "Toggle Sidebar",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_S), modifiers: [.command, .option])
    ),
    .init(
      id: .revealCurrentWorktreeInSidebar,
      title: "Reveal in Sidebar",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_J), modifiers: [.command, .shift])
    ),
    .init(
      id: .selectPreviousWorktree,
      title: "Select Previous Worktree",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_UpArrow), modifiers: [.command, .control])
    ),
    .init(
      id: .selectNextWorktree,
      title: "Select Next Worktree",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_DownArrow), modifiers: [.command, .control])
    ),
    .init(
      id: .worktreeHistoryBack,
      title: "Back in Worktree History",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_LeftBracket), modifiers: [.command, .control])
    ),
    .init(
      id: .worktreeHistoryForward,
      title: "Forward in Worktree History",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_RightBracket), modifiers: [.command, .control])
    ),
    .init(
      id: .selectWorktreeAt1,
      title: "Select Worktree 1",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_1), modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt2,
      title: "Select Worktree 2",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_2), modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt3,
      title: "Select Worktree 3",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_3), modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt4,
      title: "Select Worktree 4",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_4), modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt5,
      title: "Select Worktree 5",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_5), modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt6,
      title: "Select Worktree 6",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_6), modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt7,
      title: "Select Worktree 7",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_7), modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt8,
      title: "Select Worktree 8",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_8), modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt9,
      title: "Select Worktree 9",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_9), modifiers: [.control])
    ),
    .init(
      id: .selectWorktreeAt10,
      title: "Select Worktree 10",
      category: .projectAndWorktree,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_0), modifiers: [.control])
    ),
  ]

  private static let terminalEntries: [Entry] = [
    // Terminal — tabs and split layout.
    .init(
      id: .newTab,
      title: "New Tab",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_T), modifiers: .command)
    ),
    .init(
      id: .closeTab,
      title: "Close Tab",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_W), modifiers: .command)
    ),
    .init(
      id: .renameActiveTab,
      title: "Rename Tab…",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_R), modifiers: [.command, .option])
    ),
    .init(
      id: .changeActiveTabColor,
      title: "Change Tab Color…",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .option])
    ),
    .init(
      id: .previousTab,
      title: "Previous Tab",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_LeftBracket), modifiers: [.command, .shift])
    ),
    .init(
      id: .nextTab,
      title: "Next Tab",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_RightBracket), modifiers: [.command, .shift])
    ),
    .init(
      id: .splitRight,
      title: "Split Right",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_D), modifiers: .command)
    ),
    .init(
      id: .splitDown,
      title: "Split Down",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_D), modifiers: [.command, .shift])
    ),
    .init(
      id: .focusSplitLeft,
      title: "Focus Pane Left",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_LeftArrow), modifiers: [.command, .option])
    ),
    .init(
      id: .focusSplitRight,
      title: "Focus Pane Right",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_RightArrow), modifiers: [.command, .option])
    ),
    .init(
      id: .focusSplitUp,
      title: "Focus Pane Up",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_UpArrow), modifiers: [.command, .option])
    ),
    .init(
      id: .focusSplitDown,
      title: "Focus Pane Down",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_DownArrow), modifiers: [.command, .option])
    ),
    .init(
      id: .switchToTab1,
      title: "Switch to Tab 1",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_1), modifiers: .command)
    ),
    .init(
      id: .switchToTab2,
      title: "Switch to Tab 2",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_2), modifiers: .command)
    ),
    .init(
      id: .switchToTab3,
      title: "Switch to Tab 3",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_3), modifiers: .command)
    ),
    .init(
      id: .switchToTab4,
      title: "Switch to Tab 4",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_4), modifiers: .command)
    ),
    .init(
      id: .switchToTab5,
      title: "Switch to Tab 5",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_5), modifiers: .command)
    ),
    .init(
      id: .switchToTab6,
      title: "Switch to Tab 6",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_6), modifiers: .command)
    ),
    .init(
      id: .switchToTab7,
      title: "Switch to Tab 7",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_7), modifiers: .command)
    ),
    .init(
      id: .switchToTab8,
      title: "Switch to Tab 8",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_8), modifiers: .command)
    ),
    .init(
      id: .switchToTab9,
      title: "Switch to Tab 9",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_9), modifiers: .command)
    ),
    .init(
      id: .switchToTab10,
      title: "Switch to Tab 10",
      category: .terminal,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_0), modifiers: .command)
    ),
  ]

  private static let actionEntries: [Entry] = [
    // Actions — verbs on the current worktree.
    .init(
      id: .openInEditor,
      title: "Open in Editor",
      category: .actions,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_O), modifiers: .command)
    ),
    .init(
      id: .openCurrentPR,
      title: "Open PR on GitHub",
      category: .actions,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_G), modifiers: [.command, .control])
    ),
    .init(
      id: .openProjectOnGitHub,
      title: "Open Project on GitHub",
      category: .actions,
      scope: .configurable,
      defaultBinding: .init(keyCode: UInt16(kVK_ANSI_G), modifiers: [.command, .shift])
    ),
  ]
}
