import Foundation

/// Classifies a `Project` as a remote SSH host, a workspace of several
/// checkouts, a git-managed local repo, or a plain local directory. Derived
/// from `Project.remoteHost` / `Project.isWorkspace` / `Project.gitRoot` —
/// not persisted. Callers use it to drive which Settings sub-panes appear under
/// a Project in the sidebar and to gate local-filesystem-only and git-only
/// affordances.
///
/// Raw values are lowercase tokens so JSON written by external tooling
/// (`codans tree --json`) reads naturally.
public nonisolated enum ProjectKind: String, Codable, Hashable, Sendable {
  case gitRepo = "git_repo"
  case dir = "dir"
  case remote = "server"
  case workspace = "workspace"
}

extension Project {
  /// Derived kind. A Remote Project (`remoteHost != nil`) always classifies as
  /// `.remote` regardless of whether its remote root is a git repo — the
  /// remote/local split is the primary axis that gates local-FS operations.
  /// A workspace outranks `gitRoot` next: its root is a plain folder by
  /// construction, and the flag — not the absence of a git root — is what
  /// keeps the reconcile from ever probing the folder for one. Otherwise
  /// stays in sync with `gitRoot` automatically — an out-of-band `git init`
  /// surfaced by the next catalog refresh flips `.dir` → `.gitRepo` without a
  /// separate migration.
  public var kind: ProjectKind {
    if remoteHost != nil { return .remote }
    if isWorkspace { return .workspace }
    return gitRoot == nil ? .dir : .gitRepo
  }
}
