import CodansCore
import Foundation

/// Provider-neutral failure taxonomy for the Git Platform layer. Every `GitPlatform` method
/// throws this; UI code maps each case to a user-facing message via `userFacingMessage`.
///
/// Errors that depend on the CLI (missing, not logged in, outdated) carry the Git Platform
/// kind, so the message names the right CLI. See ADR 0004 item 14.
///
/// `.other` / `.network` compare full strings: these errors carry stderr / decoder text
/// that tests assert on.
enum GitPlatformError: Error, Equatable, Sendable {
  /// The Git Platform's CLI is not on `$PATH`. Remediation: install it.
  case cliNotInstalled(GitPlatformKind)

  /// The CLI reports no logged-in host (or the host of the repository is missing).
  /// `host` is `nil` when the probe could not determine which host was expected.
  case notAuthenticated(GitPlatformKind, host: String?)

  /// The CLI is older than the minimum version codans needs.
  case cliOutdated(GitPlatformKind, minVersion: String)

  /// The branch has no open, merged, or closed Pull Request. Not surfaced to the user as
  /// an error — the sidebar row simply has no badge.
  case notAPullRequest

  /// The CLI exited non-zero and stderr mentions a connectivity problem. The string
  /// carries the stderr line so logs and tooltips can show the original message.
  case network(String)

  /// The Git Platform's rate limit was hit. `retryAfter` is `nil` when unknown.
  case rateLimited(retryAfter: Duration?)

  /// The Git Platform reported the Pull Request cannot be merged (conflicts, protection).
  case mergeConflict

  /// The Git Platform refused a merge because the head of the source branch is no longer
  /// the commit the user saw: someone pushed new commits. See ADR 0004 item 17.
  case headMoved

  /// The CLI subprocess did not complete within the configured timeout.
  case timeout

  /// Anything else. The string carries stderr or a decoder description so the popover's
  /// error view can still surface something actionable.
  case other(String)

  /// The Git Platform's GraphQL endpoint returned an `errors` array. Usually a query or
  /// permission problem in our own query shape, not user-side misconfiguration.
  case graphQLError(String)

  /// Reading `git remote get-url origin` failed. Nothing in the fetch unit can fetch
  /// Pull Request data until the remote is fixed.
  case remoteInfoUnavailable

  /// CLI stdout exceeded the configured byte cap. Payload is the cap in bytes.
  case oversizeResponse(bytes: Int)

  /// A branch name submitted to the batched query failed validation (newline / null /
  /// other characters unsafe in a query string literal).
  case malformedBranchName(String)

  /// `true` for the errors the user fixes on the CLI itself: install it, log in, or
  /// upgrade it.
  var isCLIError: Bool {
    switch self {
    case .cliNotInstalled, .notAuthenticated, .cliOutdated: return true
    default: return false
    }
  }

  /// The availability that a probe reports when it fails with this error.
  var availability: GitPlatformAvailability {
    switch self {
    case .cliNotInstalled: return .notInstalled
    case .notAuthenticated(_, let host): return .notLoggedIn(host: host)
    default: return .unavailable(reason: userFacingMessage)
    }
  }

  /// One-line, user-facing string suitable for tooltip + popover banner.
  var userFacingMessage: String {
    switch self {
    case .cliNotInstalled(let kind):
      return
        "\(kind.cliDisplayName) is not installed. Run `\(kind.installCommand)` in a terminal to enable \(kind.pullRequestName.replacingOccurrences(of: " ", with: "-")) features."
    case .notAuthenticated(let kind, let host):
      return "Sign in to \(host ?? kind.displayName) by running `\(kind.cliName) auth login` in a terminal."
    case .cliOutdated(let kind, let minVersion):
      return
        "\(kind.cliDisplayName) is out of date. Run `brew upgrade \(kind.cliName)` — minimum required: \(minVersion)."
    case .notAPullRequest:
      return "This branch has no pull request yet."
    case .network(let detail):
      return "The Git Platform is unreachable: \(detail)"
    case .rateLimited:
      return "Git Platform rate limit hit. Try again in a few minutes."
    case .mergeConflict:
      return "This pull request cannot be merged cleanly. Resolve conflicts on the Git Platform first."
    case .headMoved:
      return "The branch has new commits. Review them, then merge again."
    case .timeout:
      return "The Git Platform CLI took too long to respond. Check your network and try again."
    case .other(let detail):
      return "Git Platform integration error: \(detail)"
    case .graphQLError(let detail):
      return "The Git Platform API rejected the query: \(detail)"
    case .remoteInfoUnavailable:
      return "Could not read the project's git remote. Ensure `origin` is set."
    case .oversizeResponse(let bytes):
      return "Git Platform response exceeded the \(bytes)-byte cap. Try fewer branches at once."
    case .malformedBranchName(let name):
      return "Branch name \"\(name)\" contains characters that cannot be queried."
    }
  }
}
