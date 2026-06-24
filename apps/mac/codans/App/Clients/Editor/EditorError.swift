import Foundation
import CodansCore

/// Errors surfaced by `EditorService`. Three cases only — the NSWorkspace launch path has no
/// exit code, no timeout, and no child-process spawn failure mode. Each case maps to a UI toast
/// and to an `EditorIPCError` at the IPC boundary.
public nonisolated enum EditorError: LocalizedError, Equatable, Sendable {
  /// An explicit preferred editor was not resolvable via Launch Services. Raised only for
  /// strict (user-explicit) preferred requests; silent defaults fall through instead.
  case notInstalled(id: EditorID, bundleID: String)

  /// `NSWorkspace.open` reported an error via its completion handler — typically Gatekeeper
  /// denial, quarantine block, or LS misconfiguration.
  case launchFailed(reason: String)

  /// The directory passed to `open` does not exist or is not a directory.
  case notADirectory(path: String)

  public var errorDescription: String? {
    switch self {
    case .notInstalled(let id, _):
      return "\(id) is not installed."
    case .launchFailed(let reason):
      return "Could not launch editor: \(reason)"
    case .notADirectory(let path):
      return "Directory not found: \(path)"
    }
  }
}
