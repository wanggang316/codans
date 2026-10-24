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

extension Worktree {
  /// Whether this row is a checkout a Workspace group owns. Only these rows
  /// make a directory a Workspace member: a reference shares the source main
  /// checkout's path but does not own it, and a group row is a plain folder.
  public var isWorkspaceMember: Bool {
    workspaceSlot?.role == .member
  }
}

extension Catalog {
  /// The Workspace member row whose directory is `canonicalPath`, if any.
  /// Group rows, references, and rows the reconcile has not placed never
  /// match. `canonicalize` is applied to every stored row path so callers
  /// can compare in the form they already hold (the app passes its symlink-
  /// resolving canonicalizer; tests may pass identity).
  public func workspaceMembership(
    forCanonicalPath canonicalPath: String,
    canonicalize: (String) -> String
  ) -> WorkspaceMembership? {
    for project in projects where project.isWorkspace {
      for worktree in project.worktrees where worktree.isWorkspaceMember {
        guard canonicalize(worktree.path) == canonicalPath else { continue }
        return WorkspaceMembership(
          projectID: project.id, worktreeID: worktree.id, workspaceName: project.name)
      }
    }
    return nil
  }
}

/// Display-only membership for registered local rows. Command guards use the
/// live path lookup above. Rebuilding depends on identity, paths, and
/// Workspace slots, not terminal state.
public nonisolated struct WorkspaceMembershipIndex {
  private struct Row: Equatable {
    let id: WorktreeID
    let path: String
    let isMember: Bool
  }

  private struct Source: Equatable {
    let id: ProjectID
    let workspaceName: String?
    let rows: [Row]
  }

  private var sources: [Source] = []
  public private(set) var memberships: [WorktreeID: WorkspaceMembership] = [:]

  public init() {}

  public mutating func update(catalog: Catalog, canonicalize: (String) -> String) {
    guard catalog.projects.contains(where: { $0.isWorkspace && !$0.isRemote }) else {
      sources = []
      memberships = [:]
      return
    }
    let next = catalog.projects.filter { !$0.isRemote }.map { project in
      Source(
        id: project.id,
        workspaceName: project.isWorkspace ? project.name : nil,
        rows: project.worktrees.map {
          Row(id: $0.id, path: $0.path, isMember: project.isWorkspace && $0.isWorkspaceMember)
        })
    }
    guard next != sources else { return }
    sources = next
    // Resolve each distinct path once, including aliases in source projects.
    var paths: [String: String] = [:]
    func resolve(_ path: String) -> String {
      if let cached = paths[path] { return cached }
      let resolved = canonicalize(path)
      paths[path] = resolved
      return resolved
    }
    var byPath: [String: WorkspaceMembership] = [:]
    for source in next {
      guard let name = source.workspaceName else { continue }
      for row in source.rows where row.isMember {
        let path = resolve(row.path)
        guard byPath[path] == nil else { continue }
        byPath[path] = WorkspaceMembership(
          projectID: source.id, worktreeID: row.id, workspaceName: name)
      }
    }
    guard !byPath.isEmpty else {
      memberships = [:]
      return
    }
    var result: [WorktreeID: WorkspaceMembership] = [:]
    for source in next {
      for row in source.rows {
        result[row.id] = byPath[resolve(row.path)]
      }
    }
    memberships = result
  }
}
