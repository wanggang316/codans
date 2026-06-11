import Foundation
import Testing

@testable import CodansCore

/// The audit pins every `CommandID` case to the chord literal that lived inline in
/// `MainWindowCommands.swift` and `HierarchySidebarView.swift` before the registry migration.
/// It exists to catch silent drift during the M6/M7 rewrite — if a chord changes in
/// `ShortcutSchema.app`, this test fails and the change has to be deliberate.
struct ShortcutSchemaAuditTests {
  @Test
  func everyCommandIDHasExactlyOneSchemaEntry() {
    let schema = ShortcutSchema.app
    let ids = schema.entries.map(\.id)

    for id in CommandID.allCases {
      let occurrences = ids.filter { $0 == id }.count
      #expect(occurrences == 1, "CommandID \(id) appears \(occurrences) times in schema; expected 1.")
    }

    #expect(Set(ids).count == ids.count, "Schema contains duplicate CommandID entries.")
  }

  @Test
  func defaultsMatchGoldenTable() {
    for (id, expected) in Self.golden {
      guard let entry = ShortcutSchema.app.entry(for: id) else {
        Issue.record("Missing schema entry for \(id).")
        continue
      }
      let binding = entry.defaultBinding
      if let expected {
        #expect(binding?.keyCode == expected.keyCode, "keyCode mismatch for \(id).")
        #expect(binding?.modifiers == expected.modifiers, "modifiers mismatch for \(id).")
        #expect(binding?.isEnabled == true, "default binding for \(id) must be enabled.")
      } else {
        #expect(binding == nil, "expected no default binding for \(id).")
      }
    }
  }

  @Test
  func goldenCoversEveryCommandID() {
    let coveredIDs = Set(Self.golden.map(\.0))
    for id in CommandID.allCases {
      #expect(coveredIDs.contains(id), "Golden table missing \(id); update audit when adding cases.")
    }
  }

  /// Pinned chord defaults. Numeric `keyCode` literals are deliberate — using `kVK_ANSI_*`
  /// would make the audit a tautology against the production schema. The values are taken
  /// from `Carbon.HIToolbox.Events.h` and from the call sites that lived inline before the
  /// migration (see commits before `feature/shotcuts`). Updating an entry here is the
  /// deliberate signal that a default chord moved; the corresponding `ShortcutSchema.app`
  /// edit fails the audit unless this table is updated in the same commit.
  private static let golden: [(CommandID, (keyCode: UInt16, modifiers: ModifierMask)?)] = [
    (.openSettings, (0x2B, [.command])),  // ,
    (.commandPaletteToggle, (0x23, [.command])),  // p
    (.showUnread, (0x20, [.command])),  // ⌘U
    (.checkForUpdates, (0x20, [.command, .shift])),  // ⌘⇧U
    (.openInEditor, (0x1F, [.command])),  // o
    (.toggleDiffInspector, (0x05, [.command, .option])),  // g
    (.addProject, (0x1F, [.command, .shift])),  // ⇧O
    (.openCurrentPR, (0x05, [.command, .control])),  // ⌃g
    (.openProjectOnGitHub, (0x05, [.command, .shift])),  // ⌘⇧G
    (.newWorktree, (0x2D, [.command])),  // n
    (.splitRight, (0x02, [.command])),  // d
    (.splitDown, (0x02, [.command, .shift])),  // ⇧d
    (.focusSplitLeft, (0x7B, [.command, .option])),  // ⌘⌥←
    (.focusSplitRight, (0x7C, [.command, .option])),  // ⌘⌥→
    (.focusSplitUp, (0x7E, [.command, .option])),  // ⌘⌥↑
    (.focusSplitDown, (0x7D, [.command, .option])),  // ⌘⌥↓
    (.revealCurrentWorktreeInFinder, (0x1F, [.command, .option])),  // ⌥O
    (.archiveCurrentWorktree, (0x33, [.command])),  // ⌘⌫
    (.deleteCurrentWorktree, (0x33, [.command, .shift])),  // ⌘⇧⌫
    (.showArchivedWorktrees, (0x00, [.command, .control])),  // ⌃A
    (.copyCurrentWorktreePath, (0x08, [.command, .shift])),  // ⌘⇧C
    (.toggleSidebar, (0x01, [.command, .option])),  // ⌘⌥S
    (.revealCurrentWorktreeInSidebar, (0x26, [.command, .shift])),  // ⌘⇧J
    (.selectPreviousWorktree, (0x7E, [.command, .control])),  // ⌘⌃↑
    (.selectNextWorktree, (0x7D, [.command, .control])),  // ⌘⌃↓
    (.worktreeHistoryBack, (0x21, [.command, .control])),  // ⌘⌃[
    (.worktreeHistoryForward, (0x1E, [.command, .control])),  // ⌘⌃]
    (.newTab, (0x11, [.command])),  // t
    (.closeTab, (0x0D, [.command])),  // w
    (.renameActiveTab, (0x0F, [.command, .shift])),  // ⌘⇧R
    (.previousTab, (0x21, [.command, .shift])),  // [
    (.nextTab, (0x1E, [.command, .shift])),  // ]
    (.switchToTab1, (0x12, [.command])),
    (.switchToTab2, (0x13, [.command])),
    (.switchToTab3, (0x14, [.command])),
    (.switchToTab4, (0x15, [.command])),
    (.switchToTab5, (0x17, [.command])),  // kVK_ANSI_5 == 0x17 (not 0x16!)
    (.switchToTab6, (0x16, [.command])),  // kVK_ANSI_6 == 0x16
    (.switchToTab7, (0x1A, [.command])),
    (.switchToTab8, (0x1C, [.command])),
    (.switchToTab9, (0x19, [.command])),
    (.switchToTab10, (0x1D, [.command])),  // 0
    (.selectWorktreeAt1, (0x12, [.control])),
    (.selectWorktreeAt2, (0x13, [.control])),
    (.selectWorktreeAt3, (0x14, [.control])),
    (.selectWorktreeAt4, (0x15, [.control])),
    (.selectWorktreeAt5, (0x17, [.control])),
    (.selectWorktreeAt6, (0x16, [.control])),
    (.selectWorktreeAt7, (0x1A, [.control])),
    (.selectWorktreeAt8, (0x1C, [.control])),
    (.selectWorktreeAt9, (0x19, [.control])),
    (.selectWorktreeAt10, (0x1D, [.control])),  // 0
  ]
}
