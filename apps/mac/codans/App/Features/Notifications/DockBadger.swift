import AppKit
import Foundation

/// Mirrors a global unread count onto the Dock tile badge.
///
/// `setBadge(_:)` is idempotent — repeated calls with the same count
/// are no-ops at the AppKit layer. Counts ≥ 100 render as `99+` to
/// match the status-bar bell.
@MainActor
public enum DockBadger {
  public static func setBadge(_ count: Int) {
    NSApp.dockTile.badgeLabel = formatBadge(count)
  }

  /// Pure formatter; exposed for unit tests. `nil` clears the badge.
  public static func formatBadge(_ count: Int) -> String? {
    if count <= 0 { return nil }
    if count >= 100 { return "99+" }
    return String(count)
  }
}
