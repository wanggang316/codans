import Foundation

/// Result of probing whether the GitHub integration can function on this machine.
///
/// `.unknown` is the initial state before the first probe — it means "we have not yet
/// asked `gh`", not "we have asked and do not know". Badges do not render in `.unknown`;
/// the popover shows a loading skeleton; Settings shows a neutral "Checking…" banner.
///
/// `.available` carries the host + user string extracted from `gh auth status`. The
/// Settings pane surfaces both so a user with multi-host `gh` configuration can see
/// which host the integration is talking to.
///
/// `.unavailable(reason)` carries a user-facing string. Rich error detail (install /
/// auth / network) stays at the app tier in `GitHubError`; the core-tier enum only
/// surfaces what the UI needs to paint the banner, so `CodansCore` does not take
/// a dependency on the app-layer error type. The app tier re-wraps `GitHubError` into
/// the string when building the `.unavailable` case.
public enum GitHubAvailability: Equatable, Sendable {
  case unknown
  case available(host: String, user: String)
  case unavailable(reason: String)

  public var isAvailable: Bool {
    if case .available = self { return true }
    return false
  }
}
