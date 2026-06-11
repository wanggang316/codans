import Foundation

/// Errors surfaced by `GitService` and the pure parser layer. Mapped 1:1 to UI error banners
/// by the C7 TCA feature in M3.
///
/// `nonisolated` so the error crosses actor boundaries freely (the type is `Sendable` by
/// virtue of every associated value being `Sendable`).
public nonisolated enum GitError: Error, Equatable, Sendable {
  /// Worktree path is not a git repository (no `.git` directory resolvable). No retry.
  case notARepo
  /// `git` binary not found in `$PATH`. Indicates missing Xcode Command Line Tools. No retry.
  case gitMissing
  /// A `git` invocation exceeded the 16 MiB output cap.
  case outputTooLarge
  /// A parsed diff exceeded the 50 000-line soft cap. The UI surfaces a "Copy command"
  /// placeholder instead of a rendered diff.
  case diffTooLarge
  /// A `git` invocation exceeded the 10 s wall-clock timeout.
  case timedOut
  /// A `git` invocation returned a non-zero exit code. `stderr` is the captured text (first
  /// line of which is what the UI shows).
  case exec(code: Int32, stderr: String)
  /// Invalid input (e.g. a commit SHA that fails `GitShaValidator.isValid`).
  case invalidInput(String)
  /// The parser encountered output it could not interpret. `context` is a short description
  /// useful to a developer reading logs; the UI falls back to a "Unrecognised diff format"
  /// banner and shows the raw text.
  case unparsable(context: String)
  /// `git remote get-url origin` returned a URL the `RemoteInfo` parser could not interpret.
  /// The GitHub integration's batched fetcher treats this as a per-Project error (the whole
  /// Project is stuck on PR data until the remote is fixed). Payload is the raw URL so logs
  /// and user-facing banners can echo it.
  case malformedRemoteURL(String)
}
