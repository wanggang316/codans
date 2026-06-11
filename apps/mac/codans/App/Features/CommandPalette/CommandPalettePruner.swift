import Foundation

/// Cleans up the recency dictionary before each palette open.
///
/// Two jobs:
///
/// 1. **Drop stale dynamic IDs.** Commands whose ID references a catalog
///    entity (`space.select.<uuid>`, `worktree.select.<uuid>`,
///    `editor.open.<id>`) accumulate in recency even after the user
///    deletes the space / worktree / editor. When the target entity is
///    no longer present in the live items list, the entry is removed so
///    the recency map does not grow unbounded over a long-lived install.
///    Static command IDs (`app.open-settings`, `git.toggle-viewer`, …)
///    are never pruned on this rule — they always resolve.
///
/// 2. **Cap the map at 200 entries** (LRU by timestamp). Belt-and-
///    suspenders against pathological pruning misses.
enum CommandPalettePruner {
  static let capacity = 200

  /// Known prefixes whose suffix references an entity whose presence we
  /// can verify against the current items list. Entries with any other
  /// prefix pass pruning unchanged.
  static let dynamicPrefixes = [
    "space.select.",
    "worktree.select.",
    "editor.open.",
  ]

  static func prune(
    recency: [String: TimeInterval],
    against items: [CommandPaletteItem]
  ) -> [String: TimeInterval] {
    let liveIDs = Set(items.map(\.id))
    var pruned = recency.filter { key, _ in
      if dynamicPrefixes.contains(where: { key.hasPrefix($0) }) {
        return liveIDs.contains(key)
      }
      return true
    }
    if pruned.count > capacity {
      let sorted = pruned.sorted { $0.value > $1.value }
      pruned = Dictionary(
        uniqueKeysWithValues: sorted.prefix(capacity).map { ($0.key, $0.value) }
      )
    }
    return pruned
  }
}
