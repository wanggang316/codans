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
  /// Project, whose worktrees come and go; for a folder, only once it has
  /// rows besides its own; for a workspace, once it has a group row.
  public var hasChildRows: Bool {
    if isWorkspace { return !workspaceSidebarRows.isEmpty }
    return gitRoot != nil || !childWorktrees.isEmpty
  }
}

/// One row under a Workspace header, in sidebar order.
public nonisolated enum WorkspaceSidebarRow: Equatable, Sendable {
  /// A group. `terminal` is the group directory's row, which selecting the
  /// group selects; nil until the reconcile has added it.
  case group(WorkspaceGroupRecord, terminal: Worktree?)
  /// A reference or member row of an expanded group.
  case member(Worktree, groupID: WorkspaceGroupID)

  /// The catalog row a click on this sidebar row selects.
  public var worktreeID: WorktreeID? {
    switch self {
    case .group(_, let terminal): terminal?.id
    case .member(let worktree, _): worktree.id
    }
  }
}

/// What a group row says about its members.
public nonisolated struct WorkspaceGroupSummary: Equatable, Sendable {
  public enum Branch: Equatable, Sendable {
    /// Every member is on this branch.
    case single(String)
    /// The members are on this many different branches.
    case several(Int)
  }

  public let memberCount: Int
  public let branch: Branch?

  public init(memberCount: Int, branch: Branch?) {
    self.memberCount = memberCount
    self.branch = branch
  }
}

extension Project {
  /// The rows under a Workspace header: each group (`default` first, as
  /// `workspaceGroups` orders them) followed, while it is expanded, by its
  /// references or members. Archived rows and rows without a slot are left
  /// out; `codans tree` still lists the latter.
  public var workspaceSidebarRows: [WorkspaceSidebarRow] {
    guard isWorkspace else { return [] }
    return workspaceGroups.flatMap { group -> [WorkspaceSidebarRow] in
      let terminal = listedWorkspaceRows(in: group.id).first { $0.workspaceSlot?.role == .groupTerminal }
      var rows: [WorkspaceSidebarRow] = [.group(group, terminal: terminal)]
      if group.isExpanded {
        rows += workspaceGroupMembers(group.id).map { .member($0, groupID: group.id) }
      }
      return rows
    }
  }

  /// The listed references or members of one group, in catalog order.
  public func workspaceGroupMembers(_ groupID: WorkspaceGroupID) -> [Worktree] {
    listedWorkspaceRows(in: groupID).filter { $0.workspaceSlot?.role != .groupTerminal }
  }

  public func workspaceGroupSummary(_ groupID: WorkspaceGroupID) -> WorkspaceGroupSummary {
    let members = workspaceGroupMembers(groupID)
    var branches: [String] = []
    for branch in members.compactMap(\.branch) where !branches.contains(branch) {
      branches.append(branch)
    }
    let branch: WorkspaceGroupSummary.Branch? =
      switch branches.count {
      case 0: nil
      case 1: .single(branches[0])
      default: .several(branches.count)
      }
    return WorkspaceGroupSummary(memberCount: members.count, branch: branch)
  }

  /// The collapsed group to expand so `worktreeID` is on screen, if it is a
  /// reference or member there. Group rows show while their group is
  /// collapsed, so they need none.
  public func collapsedWorkspaceGroup(revealing worktreeID: WorktreeID) -> WorkspaceGroupID? {
    guard isWorkspace,
      let slot = worktrees.first(where: { $0.id == worktreeID })?.workspaceSlot,
      slot.role != .groupTerminal,
      workspaceGroups.first(where: { $0.id == slot.groupID })?.isExpanded == false
    else { return nil }
    return slot.groupID
  }

  private func listedWorkspaceRows(in groupID: WorkspaceGroupID) -> [Worktree] {
    worktrees.filter { !$0.archived && $0.workspaceSlot?.groupID == groupID }
  }

  /// The filtered copy of a Workspace for the pin and pull-request views:
  /// matching rows, plus the row of every group with a match. A group with
  /// a matching member opens in this copy only.
  fileprivate func filteringWorkspaceRows(_ matches: (Worktree) -> Bool) -> Project {
    var filtered = self
    let matched = worktrees.filter { !$0.archived && $0.workspaceSlot != nil && matches($0) }
    let openGroups = Set(
      matched.compactMap { $0.workspaceSlot?.role == .groupTerminal ? nil : $0.workspaceSlot?.groupID })
    let shownGroups = Set(matched.compactMap(\.workspaceSlot?.groupID))
    let matchedIDs = Set(matched.map(\.id))
    filtered.worktrees = worktrees.filter { row in
      guard !row.archived, let slot = row.workspaceSlot else { return false }
      return matchedIDs.contains(row.id) || (slot.role == .groupTerminal && shownGroups.contains(slot.groupID))
    }
    for index in filtered.workspaceGroups.indices where openGroups.contains(filtered.workspaceGroups[index].id) {
      filtered.workspaceGroups[index].isExpanded = true
    }
    return filtered
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
          let matches: (Worktree) -> Bool = {
            self.sidebarFilter == .pin ? $0.isPinned : pullRequestWorktreeIDs.contains($0.id)
          }
          var filtered = project
          if project.isWorkspace {
            filtered = project.filteringWorkspaceRows(matches)
          } else {
            filtered.worktrees = project.worktrees.filter { !$0.archived && matches($0) }
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
      var rows: [WorktreeID] = []
      if let row = project.rowWorktree { rows.append(row.id) }
      if project.isExpanded {
        rows +=
          project.isWorkspace
          ? project.workspaceSidebarRows.compactMap(\.worktreeID)
          : project.childWorktrees.map(\.id)
      }
      return rows.map { SidebarRowAddress(projectID: project.id, worktreeID: $0) }
    }
  }

  /// Rows hidden inside a collapsed Workspace group, each mapped to the
  /// group row that stands in for it in the sidebar (unread roll-up).
  public var workspaceRowStandIns: [WorktreeID: WorktreeID] {
    var standIns: [WorktreeID: WorktreeID] = [:]
    for project in projects where project.isWorkspace {
      for case .group(let group, let terminal?) in project.workspaceSidebarRows where !group.isExpanded {
        for member in project.workspaceGroupMembers(group.id) {
          standIns[member.id] = terminal.id
        }
      }
    }
    return standIns
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
