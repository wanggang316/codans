import Foundation

/// Wire-safe error code table for the `editor.*` IPC surface.
///
/// Maps 1:1 to the App-tier `EditorError` enum. `EditorHandlers` translates at the handler
/// boundary so the app-tier type never crosses the socket — callers only see a
/// `{ code, message }` JSON-RPC error envelope with numeric codes from this table.
///
/// Numeric codes are stable wire contract; do NOT renumber. Gaps left for future additions.
/// The retired `unresolvedWorktree` / `nonZeroExit` / `timedOut` / `spawnFailed` /
/// `badTemplate` codes have no analogue on the NSWorkspace launch path — it has no exit code,
/// no timeout, no child process, no custom template, and no Worktree resolution step (callers
/// pass a path directly).
public nonisolated enum EditorIPCError: Int, Error, Equatable, Sendable {
  /// The explicit preferred editor is not installed per Launch Services. Raised only when a
  /// user-explicit `preferred` was supplied; silent defaults fall through instead.
  case notInstalled = 101

  /// `NSWorkspace.open` callback surfaced an error (Gatekeeper, quarantine, LS misconfig), OR
  /// the `.shellEditor` branch could not acquire a Pane context.
  case launchFailed = 104

  /// The directory passed to `open` does not exist or is a file, not a directory.
  case notADirectory = 106

  /// Request referenced a `projectID` that does not exist in the catalog. Used by
  /// `editor.setProjectDefault` so the CLI's error message says "project" rather than
  /// something off-topic.
  case unknownProject = 107
}

extension EditorIPCError {
  /// Human-readable short description used in the JSON-RPC error envelope's `message` slot.
  /// Callers in `codans` CLI can log this verbatim; in-app toasts should use
  /// `EditorFeature.editorErrorDescription` which surfaces more context.
  public var shortMessage: String {
    switch self {
    case .notInstalled:
      return "Editor not installed."
    case .launchFailed:
      return "Failed to launch editor."
    case .notADirectory:
      return "Path is not a directory."
    case .unknownProject:
      return "Project not found."
    }
  }
}
