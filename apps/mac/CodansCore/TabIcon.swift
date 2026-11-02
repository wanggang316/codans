import Foundation

/// Authority of the icon stored in `Tab.icon`:
///
/// - `.auto` — no stored icon; the chip shows the selected pane's glyph.
/// - `.user` — picked from the tab context menu's "Change Icon…"
///   action. Sticky until the user resets it back to `.auto`.
///
/// `Tab.applyingIcon(_:lock:)` only applies a write whose lock is at or
/// above the current one.
public enum TabIconLock: String, Codable, Sendable, Comparable {
  case auto
  case user

  private var rank: Int {
    switch self {
    case .auto: 0
    case .user: 1
    }
  }

  public static func < (lhs: TabIconLock, rhs: TabIconLock) -> Bool {
    lhs.rank < rhs.rank
  }
}
