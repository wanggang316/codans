import CodansCore
import Foundation

/// Provider-neutral failure taxonomy for the Code Host layer. Every `CodeHost` method
/// throws this; UI code maps each case to a user-facing message via `userFacingMessage`.
///
/// Errors that depend on the CLI (missing, not logged in, outdated) carry the Code Host
/// kind, so the message names the right CLI. See ADR 0004 item 14.
///
/// `.other` / `.network` compare full strings: these errors carry stderr / decoder text
/// that tests assert on.
enum CodeHostError: Error, Equatable, Sendable {
  /// The Code Host's CLI is not on `$PATH`. Remediation: install it.
  case cliNotInstalled(CodeHostKind)

  /// The CLI reports no logged-in host (or the host of the repository is missing).
  /// `host` is `nil` when the probe could not determine which host was expected.
  case notAuthenticated(CodeHostKind, host: String?)

  /// The CLI is older than the minimum version codans needs.
  case cliOutdated(CodeHostKind, minVersion: String)

  /// The branch has no open, merged, or closed Pull Request. Not surfaced to the user as
  /// an error — the sidebar row simply has no badge.
  case notAPullRequest

  /// The CLI exited non-zero and stderr mentions a connectivity problem. The string
  /// carries the stderr line so logs and tooltips can show the original message.
  case network(String)

  /// The Code Host's rate limit was hit. `retryAfter` is `nil` when unknown.
  case rateLimited(retryAfter: Duration?)

  /// The Code Host reported the Pull Request cannot be merged (conflicts, protection).
  case mergeConflict

  /// The CLI subprocess did not complete within the configured timeout.
  case timeout

  /// Anything else. The string carries stderr or a decoder description so the popover's
  /// error view can still surface something actionable.
  case other(String)

  /// The Code Host's GraphQL endpoint returned an `errors` array. Usually a query or
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

  /// One-line, user-facing string suitable for tooltip + popover banner.
  var userFacingMessage: String {
    switch self {
    case .cliNotInstalled(let kind):
      return
        "\(kind.cliDisplayName) is not installed. Run `brew install \(kind.cliName)` in a terminal to enable pull-request features."
    case .notAuthenticated(let kind, let host):
      return "Sign in to \(host ?? kind.displayName) by running `\(kind.cliName) auth login` in a terminal."
    case .cliOutdated(let kind, let minVersion):
      return
        "\(kind.cliDisplayName) is out of date. Run `brew upgrade \(kind.cliName)` — minimum required: \(minVersion)."
    case .notAPullRequest:
      return "This branch has no pull request yet."
    case .network(let detail):
      return "The Code Host is unreachable: \(detail)"
    case .rateLimited:
      return "Code Host rate limit hit. Try again in a few minutes."
    case .mergeConflict:
      return "This pull request cannot be merged cleanly. Resolve conflicts on the Code Host first."
    case .timeout:
      return "The Code Host CLI took too long to respond. Check your network and try again."
    case .other(let detail):
      return "Code Host integration error: \(detail)"
    case .graphQLError(let detail):
      return "The Code Host API rejected the query: \(detail)"
    case .remoteInfoUnavailable:
      return "Could not read the project's git remote. Ensure `origin` is set."
    case .oversizeResponse(let bytes):
      return "Code Host response exceeded the \(bytes)-byte cap. Try fewer branches at once."
    case .malformedBranchName(let name):
      return "Branch name \"\(name)\" contains characters that cannot be queried."
    }
  }
}
