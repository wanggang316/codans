import Foundation

/// Classifies a `Project` as git-managed or a plain filesystem directory.
/// Derived from `Project.gitRoot` (nil → `.dir`) — not persisted, not
/// surfaced in the UI. Callers use it to drive which Settings sub-panes
/// appear under a Project in the sidebar; the distinction is never
/// labelled, badged, or iconed.
///
/// Raw values are lowercase tokens so JSON written by external tooling
/// (e.g. a future `codans project show --json`) reads naturally.
public nonisolated enum ProjectKind: String, Codable, Hashable, Sendable {
  case gitRepo = "git_repo"
  case dir = "dir"
}

extension Project {
  /// Derived kind. Stays in sync with `gitRoot` automatically — an
  /// out-of-band `git init` surfaced by the next catalog refresh flips
  /// this without a separate migration.
  public var kind: ProjectKind { gitRoot == nil ? .dir : .gitRepo }
}
