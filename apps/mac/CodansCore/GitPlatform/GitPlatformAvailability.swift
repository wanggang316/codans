import Foundation

/// Result of probing whether a Git Platform's CLI can function on this machine.
///
/// `.unknown` is the initial state before the first probe — it means "we have not yet
/// asked the CLI", not "we have asked and do not know". Settings shows a neutral
/// "Checking…" banner.
///
/// `.available` carries the host + user string reported by the CLI's auth status. The
/// Settings pane surfaces both so a user with a multi-host configuration can see which
/// host the integration is talking to.
///
/// `.notInstalled` means the CLI executable was not found. It is a separate case so the
/// Settings pane can show the install command on its own row, apart from the warning text.
///
/// `.unavailable(reason)` carries a user-facing string for every other failure. Rich error detail (install /
/// auth / network) stays at the app tier in `GitPlatformError`; this enum only surfaces what
/// the UI needs to paint the banner, so `CodansCore` does not depend on the app-layer
/// error type.
public enum GitPlatformAvailability: Equatable, Sendable {
  case unknown
  case available(host: String, user: String)
  case notInstalled
  case unavailable(reason: String)

  public var isAvailable: Bool {
    if case .available = self { return true }
    return false
  }
}
