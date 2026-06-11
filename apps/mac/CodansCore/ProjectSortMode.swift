import Foundation

/// Sidebar-wide ordering policy for the Project list. Persisted on
/// `Catalog`; the default `.joinOrder` is the historical behaviour
/// (display Projects in the order they were added).
///
/// `.manual` does not introduce a separate stored order — the
/// `catalog.projects` array IS the manual order. `.joinOrder` and
/// `.activeFirst` are view-only sorts derived from `Project.addedAt`
/// and `Project.lastActiveAt`.
public nonisolated enum ProjectSortMode: String, Codable, Sendable, Equatable {
  /// Sort by `Project.addedAt` ascending — first added is first shown.
  case joinOrder
  /// Sort by recent activity (unread notification arrival or pane
  /// input), most recent first; inactive projects fall through to a
  /// stable `addedAt` tiebreaker.
  case activeFirst
  /// Display in the user-curated `catalog.projects` array order.
  case manual

  public static let `default`: ProjectSortMode = .joinOrder
}
