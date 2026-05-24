import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// `CommandPalettePruner` drops dynamic-ID entries whose target entity is
/// no longer live, and caps the dictionary at 200 entries by recency.
@MainActor
struct CommandPalettePrunerTests {
  private static func staticItem(_ id: String) -> CommandPaletteItem {
    CommandPaletteItem(id: id, title: id, icon: "x", kind: .openSettings)
  }

  @Test
  func staticIDsAreNeverPruned() {
    let items = [Self.staticItem("app.open-settings")]
    let recency: [String: TimeInterval] = [
      "app.open-settings": 100,
      "git.toggle-viewer": 200,  // not in items, but a static ID — keep
      "app.check-for-updates": 300,
    ]
    let pruned = CommandPalettePruner.prune(recency: recency, against: items)
    #expect(pruned.count == 3)
  }

  @Test
  func staleDynamicIDsAreDropped() {
    let items = [Self.staticItem("worktree.select.alive")]
    let recency: [String: TimeInterval] = [
      "worktree.select.alive": 100,
      "worktree.select.gone": 200,
      "space.select.also-gone": 300,
      "editor.open.vscode-absent": 400,
      "app.open-settings": 500,
    ]
    let pruned = CommandPalettePruner.prune(recency: recency, against: items)
    #expect(pruned["worktree.select.alive"] == 100)
    #expect(pruned["app.open-settings"] == 500)
    #expect(pruned["worktree.select.gone"] == nil)
    #expect(pruned["space.select.also-gone"] == nil)
    #expect(pruned["editor.open.vscode-absent"] == nil)
  }

  @Test
  func capacityEvictsOldestByTimestamp() {
    let items = (0..<250).map { Self.staticItem("static.\($0)") }
    var recency: [String: TimeInterval] = [:]
    for i in 0..<250 {
      recency["static.\(i)"] = TimeInterval(i)
    }
    let pruned = CommandPalettePruner.prune(recency: recency, against: items)
    #expect(pruned.count == CommandPalettePruner.capacity)
    // Oldest timestamps (0…49) must be gone; newest (200…249) must survive.
    #expect(pruned["static.0"] == nil)
    #expect(pruned["static.49"] == nil)
    #expect(pruned["static.249"] == 249)
    #expect(pruned["static.200"] == 200)
  }
}
