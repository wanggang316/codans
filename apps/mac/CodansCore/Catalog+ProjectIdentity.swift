import Foundation

/// Project identity is `(hostID, rootPath)` (ADR 0006). Every lookup that
/// finds a Project by path goes through this file, so no caller compares
/// root paths without the Host.
extension Project {
  /// `true` for a Project on This Mac: no Host record and no SSH endpoint.
  /// A legacy Remote Project can carry an endpoint before it gets a Host
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

  /// The other Project that `projectID` would duplicate if its Host and
  /// root became `hostID` and `path` (Edit Remote Project). `nil` when the
  /// Project already has that Host and root: keeping its own identity is
  /// never a conflict, also when an existing duplicate shares it, because
  /// existing duplicates stay as they are (ADR 0006).
  public func projectConflicting(
    withEditOf projectID: ProjectID,
    onHost hostID: HostID?,
    rootPath path: String,
    canonicalizeLocal: (String) -> String
  ) -> Project? {
    var others = self
    others.projects.removeAll { $0.id == projectID }
    guard let conflict = others.project(onHost: hostID, rootPath: path, canonicalizeLocal: canonicalizeLocal)
    else { return nil }
    var edited = self
    edited.projects.removeAll { $0.id != projectID }
    let keepsOwnIdentity =
      edited.project(onHost: hostID, rootPath: path, canonicalizeLocal: canonicalizeLocal) != nil
    return keepsOwnIdentity ? nil : conflict
  }

  /// The Project on This Mac whose root is `path`. Remote Projects never
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
  /// the first in Project order wins. Remote Projects never match.
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

// MARK: - Git transport

/// The URL form a git call uses for a repository path. A path on This Mac is
/// a file URL. A path on a Host is a `codans-host://<host-id>/<path>` URL, so
/// the git transport picks the Host from the Project, not from the path
/// string: a local Project and a Remote Project can have the same path
/// (ADR 0006). `URL.path` of both forms is the repository path.
public enum GitLocation {
  public static let hostScheme = "codans-host"

  public static func url(path: String, hostID: HostID?) -> URL {
    guard let hostID, path.hasPrefix("/") else { return URL(fileURLWithPath: path) }
    var components = URLComponents()
    components.scheme = hostScheme
    components.host = hostID.raw.uuidString.lowercased()
    components.path = path
    return components.url ?? URL(fileURLWithPath: path)
  }

  /// The Host a Host-form URL names, or `nil` for any other URL.
  public static func hostID(of url: URL) -> HostID? {
    guard url.scheme == hostScheme, let host = url.host(), let raw = UUID(uuidString: host) else { return nil }
    return HostID(raw: raw)
  }
}

extension Project {
  /// The URL for a git call on `path` of this Project: a file URL on This
  /// Mac, a Host-form URL on a Host. A legacy Remote Project without a Host
  /// record keeps a file URL and is routed by path.
  public func gitURL(_ path: String) -> URL {
    GitLocation.url(path: path, hostID: isOnThisMac ? nil : hostID)
  }

  /// `true` when `path` is this Project's root, git root, or a worktree.
  fileprivate func ownsGitPath(_ path: String, normalize: (String) -> String) -> Bool {
    if normalize(rootPath) == path { return true }
    if let gitRoot, normalize(gitRoot) == path { return true }
    return worktrees.contains { normalize($0.path) == path }
  }
}

extension Catalog {
  /// The SSH endpoint a git call on `url` runs on, or `nil` for This Mac.
  ///
  /// - A Host-form URL (`GitLocation`) runs on that Host.
  /// - A file URL runs on This Mac when a Project on This Mac owns the
  ///   path (root, git root, or worktree), also when a Remote Project has
  ///   the same path. Otherwise a Remote Project that owns the path gives
  ///   its Host; this keeps callers that pass a plain path for a Server
  ///   project working.
  ///
  /// Stored local paths are already canonical, so only the input goes
  /// through `canonicalizeLocal`; this keeps the lookup free of file-system
  /// calls per stored path.
  public func gitRemoteHost(for url: URL, canonicalizeLocal: (String) -> String) -> RemoteHost? {
    if let hostID = GitLocation.hostID(of: url) {
      return host(id: hostID)?.endpoint ?? projects.first { $0.hostID == hostID }?.remoteHost
    }
    let path = url.path(percentEncoded: false)
    let local = canonicalizeLocal(path)
    let onThisMac = projects.contains {
      $0.isOnThisMac && $0.ownsGitPath(local, normalize: Project.normalizeRemotePath)
    }
    if onThisMac { return nil }
    let remote = Project.normalizeRemotePath(path)
    return projects.first {
      $0.remoteHost != nil && $0.ownsGitPath(remote, normalize: Project.normalizeRemotePath)
    }?.remoteHost
  }
}
