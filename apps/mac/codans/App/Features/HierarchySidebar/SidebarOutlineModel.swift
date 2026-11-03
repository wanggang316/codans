import CodansCore
import Foundation

/// What one row of the sidebar outline shows.
enum SidebarOutlineRow {
  /// A Host row (This Mac or a Host record) above its Projects. Not
  /// selectable: a click opens or closes it.
  case host(SidebarHostGroup)
  /// A Project's own row. A Project that failed to load has only this row.
  case project(Project)
  /// A Project row in the reorder session: a drag handle and the name.
  case reorderProject(Project)
  /// A worktree under a git or folder Project. `segment` is nil for the main
  /// checkout, which cannot move.
  case worktree(Worktree, project: Project, segment: WorktreeSegment?)
  /// A worktree creation that is still running.
  case pending(PendingWorktree)
  /// A Workspace group. `terminal` is the group directory's row.
  case workspaceGroup(WorkspaceGroupRecord, terminal: Worktree?, project: Project)
  /// A reference or member row of a Workspace group.
  case workspaceMember(Worktree, project: Project)
}

/// One node of the sidebar outline: a row and the rows under it.
struct SidebarOutlineNode {
  /// Stable identity across updates, unique in the tree.
  let id: String
  let row: SidebarOutlineRow
  var children: [SidebarOutlineNode] = []
  /// Whether the rows under this node show. The catalog owns this state.
  var isExpanded = false

  /// The selection a click on this row makes, nil for a row that cannot be
  /// selected (a Host row, a git Project row, a failed Project, a group
  /// without its directory row, a reorder row).
  var selection: SidebarSelection? {
    switch row {
    case .host: return nil
    case .project(let project):
      if case .failed = project.loadState { return nil }
      return project.rowWorktree.map { .worktree($0.id) }
    case .reorderProject: return nil
    case .worktree(let worktree, _, _), .workspaceMember(let worktree, _): return .worktree(worktree.id)
    case .pending(let pending): return .pending(pending.id)
    case .workspaceGroup(_, let terminal, _): return terminal.map { .worktree($0.id) }
    }
  }

  /// The Project this row is listed under.
  var projectID: ProjectID? {
    switch row {
    case .host: nil
    case .project(let project), .reorderProject(let project): project.id
    case .worktree(_, let project, _), .workspaceGroup(_, _, let project), .workspaceMember(_, let project):
      project.id
    case .pending(let pending): pending.projectID
    }
  }
}

/// Maps the filtered catalog to the sidebar outline, and outline drops back to
/// catalog moves. Pure, so the mapping is tested without AppKit.
enum SidebarOutlineModel {
  /// The live-match filters show a subset of each segment, so its indices
  /// cannot drive a reorder, and pending creations match neither filter.
  static func isLiveMatch(_ filter: SidebarFilter) -> Bool {
    filter == .notifications || filter == .pullRequests
  }

  /// The outline for `projects` (already filtered and sorted, see
  /// `Catalog.sidebarProjects`). With a `hostLevel` the top level is the
  /// Host rows, each over its Projects (ADR 0002, decision 2). In the reorder
  /// session every Project is one row with nothing under it.
  static func nodes(
    projects: [Project],
    hostLevel: SidebarHostLevel? = nil,
    pendingWorktrees: [PendingWorktree],
    filter: SidebarFilter,
    isReordering: Bool
  ) -> [SidebarOutlineNode] {
    if isReordering {
      return projects.map { SidebarOutlineNode(id: "reorder:\($0.id.raw)", row: .reorderProject($0)) }
    }
    let pendings = isLiveMatch(filter) ? [] : pendingWorktrees
    guard let hostLevel else { return projects.map { projectNode($0, pendings: pendings) } }
    return hostLevel.groups(projects).map { group in
      var node = SidebarOutlineNode(id: hostNodeID(group.host), row: .host(group))
      node.isExpanded = group.isExpanded
      node.children = group.projects.map { projectNode($0, pendings: pendings) }
      return node
    }
  }

  static func hostNodeID(_ host: SidebarHost) -> String {
    switch host {
    case .thisMac: "host:this-mac"
    case .host(let id): "host:\(id.raw)"
    }
  }

  private static func projectNode(_ project: Project, pendings: [PendingWorktree]) -> SidebarOutlineNode {
    var node = SidebarOutlineNode(id: "project:\(project.id.raw)", row: .project(project))
    if case .failed = project.loadState { return node }
    node.isExpanded = project.isExpanded
    node.children = project.isWorkspace ? workspaceNodes(project) : worktreeNodes(project, pendings: pendings)
    return node
  }

  /// Main checkout → pinned → pending creations → the rest.
  private static func worktreeNodes(_ project: Project, pendings: [PendingWorktree]) -> [SidebarOutlineNode] {
    let children = project.childWorktrees
    func node(_ worktree: Worktree, _ segment: WorktreeSegment?) -> SidebarOutlineNode {
      SidebarOutlineNode(
        id: "wt:\(project.id.raw):\(worktree.id.raw)", row: .worktree(worktree, project: project, segment: segment))
    }
    let main = children.filter { $0.path == project.rootPath }.map { node($0, nil) }
    let pinned = children.filter { $0.isPinned && $0.path != project.rootPath }.map { node($0, .pinned) }
    let rest = children.filter { !$0.isPinned && $0.path != project.rootPath }.map { node($0, .unpinned) }
    let pending = pendings.filter { $0.projectID == project.id }.map {
      SidebarOutlineNode(id: "pending:\($0.id.raw)", row: .pending($0))
    }
    return main + pinned + pending + rest
  }

  private static func workspaceNodes(_ project: Project) -> [SidebarOutlineNode] {
    project.workspaceSidebarRows.compactMap { row -> SidebarOutlineNode? in
      guard case .group(let group, let terminal) = row else { return nil }
      var node = SidebarOutlineNode(
        id: "group:\(project.id.raw):\(group.id.raw)",
        row: .workspaceGroup(group, terminal: terminal, project: project))
      node.isExpanded = group.isExpanded
      node.children = project.workspaceGroupMembers(group.id).map {
        SidebarOutlineNode(id: "wt:\(project.id.raw):\($0.id.raw)", row: .workspaceMember($0, project: project))
      }
      return node
    }
  }

  // MARK: - Drops

  /// A worktree move inside its segment, in `reorderWorktrees` terms.
  struct WorktreeMove: Equatable {
    let projectID: ProjectID
    let segment: WorktreeSegment
    let source: IndexSet
    let destination: Int
  }

  /// The move for dropping the row `draggedID` between `siblings` at
  /// `childIndex`, nil when the drop leaves its segment or lands on a row.
  /// `childIndex` counts rows before the drag removes the dragged one, as
  /// `ForEach.onMove` does.
  static func worktreeMove(
    siblings: [SidebarOutlineNode], draggedID: String, childIndex: Int
  ) -> WorktreeMove? {
    guard childIndex >= 0,
      let from = siblings.firstIndex(where: { $0.id == draggedID }),
      case .worktree(_, let project, let segment?) = siblings[from].row
    else { return nil }
    let range = siblings.indices.filter {
      guard case .worktree(_, _, let other) = siblings[$0].row else { return false }
      return other == segment
    }
    guard let start = range.first, let end = range.last, (start...end + 1).contains(childIndex) else { return nil }
    return WorktreeMove(
      projectID: project.id, segment: segment, source: IndexSet(integer: from - start),
      destination: childIndex - start)
  }

  /// The move for dropping the reorder row `draggedID` at `childIndex` of the
  /// top level, nil for a drop on a row.
  static func projectMove(
    roots: [SidebarOutlineNode], draggedID: String, childIndex: Int
  ) -> (source: IndexSet, destination: Int)? {
    guard childIndex >= 0, childIndex <= roots.count,
      let from = roots.firstIndex(where: { $0.id == draggedID }),
      case .reorderProject = roots[from].row
    else { return nil }
    return (IndexSet(integer: from), childIndex)
  }
}
