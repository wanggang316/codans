import Foundation

/// Which workspace a directory is a child checkout of.
///
/// A child checkout created from a registered Project is also a git worktree
/// of that Project, so the Project's own reconcile discovers it and lists it
/// a second time. Both rows point at one directory; this record lets the
/// second row (in the *source* Project) say so and keep its destructive
/// affordances off — removing or archiving a child is the workspace's call.
public nonisolated struct WorkspaceMembership: Equatable, Sendable {
  public let projectID: ProjectID
  public let worktreeID: WorktreeID
  /// The workspace Project's display name, for the badge.
  public let workspaceName: String

  public init(projectID: ProjectID, worktreeID: WorktreeID, workspaceName: String) {
    self.projectID = projectID
    self.worktreeID = worktreeID
    self.workspaceName = workspaceName
  }
}

extension Catalog {
  /// The workspace child row whose directory is `canonicalPath`, if any.
  /// Root rows never match — the workspace root is not a child of itself.
  /// `canonicalize` is applied to every stored row path so callers can
  /// compare in the form they already hold (the app passes its symlink-
  /// resolving canonicalizer; tests may pass identity).
  public func workspaceMembership(
    forCanonicalPath canonicalPath: String,
    canonicalize: (String) -> String
  ) -> WorkspaceMembership? {
    for project in projects where project.isWorkspace {
      let root = canonicalize(project.rootPath)
      for worktree in project.worktrees {
        let path = canonicalize(worktree.path)
        guard path != root, path == canonicalPath else { continue }
        return WorkspaceMembership(
          projectID: project.id, worktreeID: worktree.id, workspaceName: project.name)
      }
    }
    return nil
  }
}
