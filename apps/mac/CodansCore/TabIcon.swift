import Foundation

/// Authority level of the SF Symbol stored in `Tab.icon`. Higher values
/// take precedence over lower ones at write time:
///
/// - `.auto` — derived from the runtime (foreground job, OSC-2 title,
///   shell default). Auto writes leave the icon untouched when a higher
///   lock is already in place.
/// - `.script` — set when a Run Script spawns the tab. Survives auto
///   re-derivation but yields to an explicit user choice.
/// - `.user` — picked from the tab context menu's "Change Icon…"
///   action. Sticky until the user resets it back to `.auto`.
///
/// The numeric ordering is load-bearing for write-precedence comparisons:
/// `setIcon` only applies a new icon when the incoming lock is at or
/// above the current lock.
public enum TabIconLock: String, Codable, Sendable, Comparable {
  case auto
  case script
  case user

  private var rank: Int {
    switch self {
    case .auto: 0
    case .script: 1
    case .user: 2
    }
  }

  public static func < (lhs: TabIconLock, rhs: TabIconLock) -> Bool {
    lhs.rank < rhs.rank
  }
}
