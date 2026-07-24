import Foundation

/// Classifies a `Project` as a remote SSH host, a git-managed local repo, or a
/// plain local directory. Derived from `Project.remoteHost` / `Project.gitRoot` —
/// not persisted. Callers use it to drive which Settings sub-panes appear under a
/// Project in the sidebar and to gate local-filesystem-only affordances; the
/// distinction is otherwise never labelled, badged, or iconed.
///
/// Raw values are lowercase tokens so JSON written by external tooling (e.g. a
/// future `codans project show --json`) reads naturally.
public nonisolated enum ProjectKind: String, Codable, Hashable, Sendable {
  case gitRepo = "git_repo"
  case dir = "dir"
  case server = "server"
}

extension Project {
  /// Derived kind. A Server project (`remoteHost != nil`) always classifies as
  /// `.server` regardless of whether its remote root is a git repo — the
  /// remote/local split is the primary axis that gates local-FS operations.
  /// Otherwise stays in sync with `gitRoot` automatically — an out-of-band
  /// `git init` surfaced by the next catalog refresh flips `.dir` → `.gitRepo`
  /// without a separate migration.
  public var kind: ProjectKind {
    if remoteHost != nil { return .server }
    return gitRoot == nil ? .dir : .gitRepo
  }
}
