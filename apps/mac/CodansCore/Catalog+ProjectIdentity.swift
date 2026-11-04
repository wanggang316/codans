import Foundation

/// Project identity is `(hostID, rootPath)` (ADR 0006). Every lookup that
/// finds a Project by path goes through this file, so no caller compares
/// root paths without the Host.
extension Project {
  /// `true` for a Project on This Mac: no Host record and no SSH endpoint.
  /// A legacy Server project can carry an endpoint before it gets a Host
  /// record, so both fields are checked.
  public var isOnThisMac: Bool { hostID == nil && remoteHost == nil }

  /// String-only form of a path on a Host: the trailing slash is removed
  /// (except for `/`). A remote path is never resolved against the local
  /// file system, where `/tmp` would become `/private/tmp`.
  public static func normalizeRemotePath(_ path: String) -> String {
    var trimmed = path
    while trimmed.count > 1, trimmed.hasSuffix("/") {
      trimmed.removeLast()
    }
    return trimmed
  }
}

extension Catalog {
  /// The Project on `hostID` (`nil` = This Mac) whose root is `path`.
  /// Local paths compare in the form `canonicalizeLocal` returns (the app
  /// passes its symlink-resolving canonicalizer); remote paths compare in
  /// `Project.normalizeRemotePath` form. When existing duplicates match,
  /// the first in Project order wins.
  public func project(
    onHost hostID: HostID?,
    rootPath path: String,
    canonicalizeLocal: (String) -> String
  ) -> Project? {
    guard let hostID else { return localProject(rootPath: path, canonicalize: canonicalizeLocal) }
    let target = Project.normalizeRemotePath(path)
    return projects.first {
      $0.hostID == hostID && Project.normalizeRemotePath($0.rootPath) == target
    }
  }

  /// The Project on This Mac whose root is `path`. Server projects never
  /// match, also when their remote path is the same string.
  public func localProject(
    rootPath path: String,
    canonicalize: (String) -> String
  ) -> Project? {
    let target = canonicalize(path)
    return projects.first { $0.isOnThisMac && canonicalize($0.rootPath) == target }
  }

  /// The Project on This Mac whose root is `path` or an ancestor of it, on
  /// path-segment boundaries (`/repo` contains `/repo/src`, not
  /// `/repository`). When roots nest, the deepest root wins; on equal roots
  /// the first in Project order wins. Server projects never match.
  public func localProject(
    containing path: String,
    canonicalize: (String) -> String
  ) -> Project? {
    let target = canonicalize(path)
    var best: (project: Project, length: Int)?
    for project in projects where project.isOnThisMac {
      let root = canonicalize(project.rootPath)
      guard target == root || target.hasPrefix(root + "/") else { continue }
      if root.count > best?.length ?? -1 {
        best = (project, root.count)
      }
    }
    return best?.project
  }

  /// The Project on This Mac whose git root is `gitRoot`. Used to find the
  /// source Project of a Workspace reference.
  public func localProject(
    gitRoot: String,
    canonicalize: (String) -> String
  ) -> Project? {
    let target = canonicalize(gitRoot)
    return projects.first { project in
      guard project.isOnThisMac, !project.isWorkspace, let root = project.gitRoot else { return false }
      return canonicalize(root) == target
    }
  }
}
