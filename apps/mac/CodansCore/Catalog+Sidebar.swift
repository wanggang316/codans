import Foundation

public nonisolated enum SidebarFilter: String, Codable, CaseIterable, Sendable {
  case all, remote, workspace, pin, pullRequests

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    switch value {
    case "local": self = .all
    case "favorites": self = .pin
    default: self = Self(rawValue: value) ?? .all
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

extension Project {
  /// The worktree the Project's own sidebar row stands for, when the Project
  /// has no repository of its own — a plain folder or a remote folder: the
  /// synthetic worktree at `rootPath`. Such a Project opens by selecting its
  /// row and lists no child row for its root. A git Project answers nil: its
  /// main checkout stays a child row, like every other worktree of the
  /// repository. A workspace answers nil too: its header is not a terminal,
  /// and every row of it belongs to a group.
  public var rowWorktree: Worktree? {
    guard gitRoot == nil, !isWorkspace else { return nil }
    return worktrees.first { !$0.archived && $0.path == rootPath }
  }

  /// The worktrees listed under the Project row, in sidebar order: the main
  /// checkout, pinned rows, then the rest. Leaves out archived rows and the
  /// worktree the Project row itself stands for.
  public var childWorktrees: [Worktree] {
    let rowID = rowWorktree?.id
    let listed = worktrees.filter { !$0.archived && $0.id != rowID }
    let main = listed.filter { $0.path == rootPath }
    let pinned = listed.filter { $0.isPinned && $0.path != rootPath }
    let rest = listed.filter { !$0.isPinned && $0.path != rootPath }
    return main + pinned + rest
  }

  /// Whether the Project row can open onto child rows: always for a git
  /// Project, whose worktrees come and go; for a folder or workspace, only
  /// once it has rows besides its own.
  public var hasChildRows: Bool {
    gitRoot != nil || !childWorktrees.isEmpty
  }
}

/// One selectable sidebar row: a worktree and the Project it is listed under.
public nonisolated struct SidebarRowAddress: Equatable, Sendable {
  public let projectID: ProjectID
  public let worktreeID: WorktreeID

  public init(projectID: ProjectID, worktreeID: WorktreeID) {
    self.projectID = projectID
    self.worktreeID = worktreeID
  }
}

extension Catalog {
  /// Projects in sidebar order after category and tag filtering. Pin results
  /// contain only pinned, unarchived worktrees; the catalog stays unchanged.
  public var sidebarProjects: [Project] {
    sidebarProjects(pullRequestWorktreeIDs: [])
  }

  public func sidebarProjects(pullRequestWorktreeIDs: Set<WorktreeID>) -> [Project] {
    sorted(
      tagFilteredProjects.compactMap { project in
        switch sidebarFilter {
        case .all: return project
        case .remote: return project.isRemote ? project : nil
        case .workspace: return project.isWorkspace ? project : nil
        case .pin, .pullRequests:
          var filtered = project
          filtered.worktrees = project.worktrees.filter {
            !$0.archived && (sidebarFilter == .pin ? $0.isPinned : pullRequestWorktreeIDs.contains($0.id))
          }
          return filtered.worktrees.isEmpty ? nil : filtered
        }
      })
  }

  /// Every row a user can select, in the order the sidebar shows them: a
  /// Project row that stands for a worktree, then — while the Project is
  /// expanded — its child rows. Rows inside a collapsed Project and the rows
  /// of a Project that failed to load are not on screen, so they are left
  /// out. Drives the ⌃1…⌃0 slots and ⌘⌃↑ / ⌘⌃↓.
  public var sidebarSelectionOrder: [SidebarRowAddress] {
    sidebarSelectionOrder(pullRequestWorktreeIDs: [])
  }

  public func sidebarSelectionOrder(pullRequestWorktreeIDs: Set<WorktreeID>) -> [SidebarRowAddress] {
    sidebarProjects(pullRequestWorktreeIDs: pullRequestWorktreeIDs).flatMap { project -> [SidebarRowAddress] in
      if case .failed = project.loadState { return [] }
      var rows: [Worktree] = []
      if let row = project.rowWorktree { rows.append(row) }
      if project.isExpanded { rows += project.childWorktrees }
      return rows.map { SidebarRowAddress(projectID: project.id, worktreeID: $0.id) }
    }
  }

  private var tagFilteredProjects: [Project] {
    switch activeTagFilter {
    case .all:
      return projects
    case .tags(let set) where set.isEmpty:
      // Empty `.tags` is normalized to `.all` by the manager but defend
      // here too — a corrupted catalog shouldn't hide every project.
      return projects
    case .tags(let set):
      return projects.filter { !$0.tagIDs.isDisjoint(with: set) }
    case .untagged:
      return projects.filter { $0.tagIDs.isEmpty }
    }
  }
}
