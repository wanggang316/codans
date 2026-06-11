import Foundation

/// Pure (nonisolated, value-typed) functions that drive `NotificationStore`'s
/// non-trivial inbox-mutation policies: dedup window, age sweep, cap sweep.
///
/// The MainActor-isolated `NotificationStore` in the app target is a thin
/// wrapper around this type plus persistence and observation. Splitting the
/// pure logic out keeps it testable in `CodansCoreTests` (the app-target
/// test bundle has unrelated pre-existing build issues).
public nonisolated enum InboxStorage {
  /// Maximum number of entries retained globally. When the inbox is at the
  /// cap, `appending` evicts the oldest read entry first; if all entries
  /// are unread, evicts the oldest unread.
  public static let cap: Int = 500

  /// Maximum age of any entry. `aged(_:asOf:)` removes entries strictly
  /// older than this regardless of read state.
  public static let maxAge: TimeInterval = 7 * 24 * 60 * 60

  /// Window inside which a new entry from the same `(paneID, kind)` pair
  /// updates the prior entry in place rather than appending a fresh row.
  public static let dedupWindow: TimeInterval = 30

  // MARK: - Append / dedup

  /// Apply the dedup window: if the most recent entry from the same
  /// `(paneID, kind)` pair is within `dedupWindow` seconds of `incoming`,
  /// return an array where that entry has been replaced (preserving its
  /// id and prior `readAt`) by an updated copy with the incoming
  /// `title`, `body`, and `createdAt`. Otherwise prepend the incoming
  /// entry. Then enforce the cap. Newest-first ordering is maintained.
  public static func appending(
    _ incoming: InboxEntry,
    to existing: [InboxEntry]
  ) -> [InboxEntry] {
    var result = existing

    if let dedupIndex = result.firstIndex(where: { entry in
      entry.source.paneID == incoming.source.paneID
        && entry.kind == incoming.kind
        && abs(entry.createdAt.timeIntervalSince(incoming.createdAt)) <= dedupWindow
    }) {
      let prior = result[dedupIndex]
      let merged = InboxEntry(
        id: prior.id,
        kind: incoming.kind,
        title: incoming.title,
        body: incoming.body,
        createdAt: incoming.createdAt,
        readAt: prior.readAt,
        source: incoming.source
      )
      result.remove(at: dedupIndex)
      result.insert(merged, at: 0)
    } else {
      result.insert(incoming, at: 0)
    }

    return capped(result)
  }

  // MARK: - Sweeps

  /// Drop entries strictly older than `maxAge` relative to `now`.
  public static func aged(_ entries: [InboxEntry], asOf now: Date = Date()) -> [InboxEntry] {
    entries.filter { now.timeIntervalSince($0.createdAt) <= maxAge }
  }

  /// Enforce the row cap. Eviction priority: oldest read entries first; if
  /// none are read, oldest unread.
  public static func capped(_ entries: [InboxEntry]) -> [InboxEntry] {
    guard entries.count > cap else { return entries }

    let overflow = entries.count - cap
    var indicesToDrop: Set<Int> = []

    // Oldest entries are at the tail of the newest-first array.
    let tailFirst: [(offset: Int, element: InboxEntry)] = entries.enumerated().reversed().map {
      ($0.offset, $0.element)
    }

    // Pass 1: read entries, oldest first.
    for (offset, entry) in tailFirst {
      if indicesToDrop.count == overflow { break }
      if !entry.isUnread { indicesToDrop.insert(offset) }
    }

    // Pass 2: unread entries, oldest first, fill the remaining quota.
    if indicesToDrop.count < overflow {
      for (offset, _) in tailFirst {
        if indicesToDrop.count == overflow { break }
        indicesToDrop.insert(offset)
      }
    }

    return entries.enumerated().compactMap { offset, entry in
      indicesToDrop.contains(offset) ? nil : entry
    }
  }

  // MARK: - Read state

  /// Mark a single entry read at `readAt`. No-op if the entry is missing
  /// or already read.
  public static func markingRead(
    id: NotificationID,
    in entries: [InboxEntry],
    at readAt: Date = Date()
  ) -> [InboxEntry] {
    entries.map { entry in
      guard entry.id == id, entry.isUnread else { return entry }
      var updated = entry
      updated.readAt = readAt
      return updated
    }
  }

  /// Mark every unread entry read at `readAt`.
  public static func markingAllRead(
    in entries: [InboxEntry],
    at readAt: Date = Date()
  ) -> [InboxEntry] {
    entries.map { entry in
      guard entry.isUnread else { return entry }
      var updated = entry
      updated.readAt = readAt
      return updated
    }
  }

  /// Mark every unread entry whose source pane is **not** in `livePaneIDs`
  /// as read. Used to clear roll-up indicators left behind when a pane (or
  /// its enclosing tab / worktree / project) is closed without the user
  /// ever focusing it — the entry has nowhere to surface and would
  /// otherwise keep the worktree/project bell lit indefinitely.
  public static func markingReadForOrphanPanes(
    livePaneIDs: Set<PaneID>,
    in entries: [InboxEntry],
    at readAt: Date = Date()
  ) -> [InboxEntry] {
    entries.map { entry in
      guard entry.isUnread, !livePaneIDs.contains(entry.source.paneID) else { return entry }
      var updated = entry
      updated.readAt = readAt
      return updated
    }
  }

  /// Number of unread entries. Cheap derivation; the live store caches it.
  public static func unreadCount(_ entries: [InboxEntry]) -> Int {
    entries.reduce(0) { $0 + ($1.isUnread ? 1 : 0) }
  }
}
