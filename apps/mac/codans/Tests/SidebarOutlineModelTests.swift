import CodansCore
import Foundation
import Testing

@testable import Codans

/// The sidebar outline's rows: catalog → outline nodes, the filter result, and
/// outline drops → catalog moves.
@MainActor
struct SidebarOutlineModelTests {
  private static let defaultGroup = WorkspaceGroupID()
  private static let fixGroup = WorkspaceGroupID()
  // Fixed ids: each computed Project below is built fresh on every read.
  private static let repositoryID = ProjectID()
  private static let folderID = ProjectID()
  private static let workspaceID = ProjectID()
  private let main = Worktree(name: "main", path: "/repo", branch: "main")
  private let pinnedA = Worktree(name: "pin-a", path: "/repo-pa", branch: "pin-a", isPinned: true)
  private let pinnedB = Worktree(name: "pin-b", path: "/repo-pb", branch: "pin-b", isPinned: true)
  private let restA = Worktree(name: "rest-a", path: "/repo-ra", branch: "rest-a")
  private let restB = Worktree(name: "rest-b", path: "/repo-rb", branch: "rest-b")
  private let archived = Worktree(name: "old", path: "/repo-old", branch: "old", archived: true)
  private let folderRoot = Worktree(name: "notes", path: "/notes")
  private let defaultTerminal = Worktree(
    name: "default", path: "/ws/default",
    workspaceSlot: WorkspaceSlot(groupID: defaultGroup, role: .groupTerminal))
  private let reference = Worktree(
    name: "app", path: "/src/app", branch: "main", sourceGitRoot: "/src/app",
    workspaceSlot: WorkspaceSlot(groupID: defaultGroup, role: .reference))
  private let fixTerminal = Worktree(
    name: "fix", path: "/ws/fix", workspaceSlot: WorkspaceSlot(groupID: fixGroup, role: .groupTerminal))
  private let member = Worktree(
    name: "app", path: "/ws/fix/app", branch: "fix", sourceGitRoot: "/src/app",
    workspaceSlot: WorkspaceSlot(groupID: fixGroup, role: .member))

  private var repository: Project {
    Project(
      id: Self.repositoryID, name: "repo", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [restA, pinnedA, main, archived, restB, pinnedB], loadState: .ready)
  }

  private var folder: Project {
    Project(id: Self.folderID, name: "notes", rootPath: "/notes", worktrees: [folderRoot], isExpanded: false, loadState: .ready)
  }

  private var failed: Project {
    Project(
      name: "gone", rootPath: "/gone", gitRoot: "/gone", worktrees: [Worktree(name: "main", path: "/gone")],
      loadState: .failed(reason: "missing"))
  }

  private var workspace: Project {
    Project(
      id: Self.workspaceID, name: "flow", rootPath: "/ws", worktrees: [defaultTerminal, reference, fixTerminal, member],
      isWorkspace: true,
      workspaceGroups: [
        WorkspaceGroupRecord(id: Self.defaultGroup, name: "default", kind: .default),
        WorkspaceGroupRecord(id: Self.fixGroup, name: "fix", kind: .named, isExpanded: true),
      ],
      loadState: .ready)
  }

  private func pending(in project: Project) -> PendingWorktree {
    PendingWorktree(
      id: PendingWorktreeID(), projectID: project.id,
      spec: CreateWorktreeSpec(
        repoRoot: URL(fileURLWithPath: "/repo"), baseDirectory: URL(fileURLWithPath: "/repo/.worktrees"),
        name: "new", baseRef: "origin/main", fetchOrigin: false, copyIgnored: false, copyUntracked: false),
      displayName: "new", status: .running, lastProgressLine: nil, startedAt: Date(timeIntervalSince1970: 0))
  }

  private func nodes(
    _ projects: [Project], hostLevel: SidebarHostLevel? = nil, pendings: [PendingWorktree] = [],
    filter: SidebarFilter = .all
  ) -> [SidebarOutlineNode] {
    SidebarOutlineModel.nodes(
      projects: projects, hostLevel: hostLevel, pendingWorktrees: pendings, filter: filter)
  }

  /// A row's kind and name, so a test reads as the sidebar does.
  private func label(_ node: SidebarOutlineNode) -> String {
    switch node.row {
    case .host(let group): "host \(group.displayName)"
    case .project(let project): "project \(project.name)"
    case .worktree(let worktree, _, let segment): "worktree \(worktree.name) \(segment.map { "\($0)" } ?? "main")"
    case .pending(let pending): "pending \(pending.displayName)"
    case .workspaceGroup(let group, _, _): "group \(group.name)"
    case .workspaceMember(let worktree, _): "member \(worktree.name) \(worktree.path)"
    }
  }

  // MARK: - Catalog → outline

  @Test
  func aGitProjectListsMainPinnedPendingThenTheRestUnderIt() throws {
    let project = repository
    let creation = pending(in: project)
    let tree = nodes([project], pendings: [creation, pending(in: folder)])
    let root = try #require(tree.first)
    #expect(label(root) == "project repo")
    #expect(root.isExpanded)
    #expect(root.selection == nil)
    #expect(
      root.children.map(label) == [
        "worktree main main", "worktree pin-a pinned", "worktree pin-b pinned", "pending new",
        "worktree rest-a unpinned", "worktree rest-b unpinned",
      ])
    #expect(root.children.map(\.projectID) == Array(repeating: project.id, count: 6))
    #expect(root.children[3].selection == .pending(creation.id))
    #expect(root.children[0].selection == .worktree(main.id))
  }

  @Test
  func aFolderRowIsSelectableAndKeepsItsExpansion() throws {
    let root = try #require(nodes([folder]).first)
    #expect(root.selection == .worktree(folderRoot.id))
    #expect(root.children.isEmpty)
    #expect(!root.isExpanded)
  }

  @Test
  func aFailedProjectIsOneRowThatCannotBeSelected() throws {
    let root = try #require(nodes([failed]).first)
    #expect(label(root) == "project gone")
    #expect(root.children.isEmpty)
    #expect(root.selection == nil)
  }

  @Test
  func aWorkspaceNestsMembersUnderTheirGroupWithTheGroupsExpansion() throws {
    let root = try #require(nodes([workspace]).first)
    #expect(root.children.map(label) == ["group default", "group fix"])
    let defaultGroup = root.children[0]
    let fixGroup = root.children[1]
    // A collapsed group still has its rows; the outline keeps them closed.
    #expect(!defaultGroup.isExpanded)
    #expect(defaultGroup.children.map(label) == ["member app /src/app"])
    #expect(fixGroup.isExpanded)
    #expect(fixGroup.children.map(label) == ["member app /ws/fix/app"])
    #expect(defaultGroup.selection == .worktree(defaultTerminal.id))
    #expect(fixGroup.children[0].selection == .worktree(member.id))
  }

  @Test
  func everyNodeIDIsUniqueAcrossTheTree() {
    var ids: [String] = []
    func collect(_ nodes: [SidebarOutlineNode]) {
      for node in nodes {
        ids.append(node.id)
        collect(node.children)
      }
    }
    collect(nodes([repository, folder, failed, workspace], pendings: [pending(in: repository)]))
    #expect(ids.count == 14)
    #expect(Set(ids).count == ids.count)
  }

  // MARK: - Filter result

  @Test
  func liveMatchFiltersLeavePendingCreationsOut() throws {
    let project = repository
    for filter in [SidebarFilter.notifications, .pullRequests] {
      let root = try #require(nodes([project], pendings: [pending(in: project)], filter: filter).first)
      #expect(!root.children.contains { if case .pending = $0.row { true } else { false } })
    }
    let root = try #require(nodes([project], pendings: [pending(in: project)], filter: .remote).first)
    #expect(root.children.contains { if case .pending = $0.row { true } else { false } })
  }

  @Test
  func theOutlineShowsTheFilteredCatalog() throws {
    let tag = Tag(name: "web", color: .blue)
    var tagged = repository
    tagged.tagIDs = [tag.id]
    var catalog = Catalog(projects: [tagged, folder, workspace], tags: [tag])

    catalog.sidebarFilter = .workspace
    #expect(nodes(catalog.sidebarProjects).map(label) == ["project flow"])

    catalog.sidebarFilter = .all
    catalog.activeTagFilter = .tags([tag.id])
    #expect(nodes(catalog.sidebarProjects).map(label) == ["project repo"])

    catalog.activeTagFilter = .untagged
    #expect(nodes(catalog.sidebarProjects).map(label) == ["project notes", "project flow"])

    // The pull-request view lists only matching rows, and opens the group
    // that holds a matching member.
    catalog.activeTagFilter = .all
    catalog.sidebarFilter = .pullRequests
    let matches = catalog.sidebarProjects(pullRequestWorktreeIDs: [restB.id, member.id], notifiedWorktreeIDs: [])
    let tree = nodes(matches, filter: .pullRequests)
    #expect(tree.map(label) == ["project repo", "project flow"])
    #expect(tree[0].children.map(label) == ["worktree rest-b unpinned"])
    // Every group keeps its row; only the one with a match opens.
    #expect(tree[1].children.map(label) == ["group default", "group fix"])
    #expect(tree[1].children[0].children.isEmpty)
    #expect(tree[1].children[1].isExpanded)
    #expect(tree[1].children[1].children.map(label) == ["member app /ws/fix/app"])
  }

  // MARK: - Host level

  private static let box = HostRecord(address: "box")
  private static let mini = HostRecord(address: "mini", name: "Mac mini")

  private func remote(_ project: Project, on host: HostRecord) -> Project {
    var project = project
    project.hostID = host.id
    project.remoteHost = host.endpoint
    return project
  }

  @Test
  func onlyLocalProjectsKeepProjectsAtTheTop() {
    let catalog = Catalog(projects: [repository, folder], hosts: [Self.box])
    #expect(catalog.sidebarHostLevel == nil)
    let tree = nodes(catalog.sidebarProjects, hostLevel: catalog.sidebarHostLevel)
    #expect(tree.map(label) == ["project repo", "project notes"])
  }

  @Test
  func hostRowsGroupProjectsThisMacFirst() throws {
    let catalog = Catalog(
      projects: [remote(folder, on: Self.mini), repository, remote(workspace, on: Self.box)],
      hosts: [Self.box, Self.mini])
    let tree = nodes(catalog.sidebarProjects, hostLevel: catalog.sidebarHostLevel)
    #expect(tree.map(label) == ["host This Mac", "host box", "host Mac mini"])
    #expect(tree.map { $0.children.map(label) } == [["project repo"], ["project flow"], ["project notes"]])
    #expect(tree.allSatisfy { $0.selection == nil && $0.projectID == nil && $0.isExpanded })
    #expect(tree[0].id == "host:this-mac")
    // The rows under a Project stay as they are without Hosts.
    #expect(tree[0].children[0].children.count == 5)
  }

  @Test
  func aRemoteOnlyCatalogShowsAnEmptyThisMacRow() {
    let catalog = Catalog(projects: [remote(folder, on: Self.box)], hosts: [Self.box])
    let tree = nodes(catalog.sidebarProjects, hostLevel: catalog.sidebarHostLevel)
    #expect(tree.map(label) == ["host This Mac", "host box"])
    #expect(tree[0].children.isEmpty)
    #expect(tree[1].children.map(label) == ["project notes"])
  }

  @Test
  func aClosedHostKeepsItsRowsClosed() throws {
    var catalog = Catalog(projects: [repository, remote(folder, on: Self.box)], hosts: [Self.box])
    catalog.collapsedSidebarHosts = [.host(Self.box.id)]
    let tree = nodes(catalog.sidebarProjects, hostLevel: catalog.sidebarHostLevel)
    #expect(tree.map(\.isExpanded) == [true, false])
    #expect(tree[1].children.map(label) == ["project notes"])
  }

  @Test
  func filtersHideHostsWithNoMatchButNotTheLevel() throws {
    let tag = Tag(name: "web", color: .blue)
    var tagged = repository
    tagged.tagIDs = [tag.id]
    var catalog = Catalog(
      projects: [tagged, remote(folder, on: Self.box), remote(workspace, on: Self.mini)],
      hosts: [Self.box, Self.mini], tags: [tag])

    catalog.sidebarFilter = .remote
    #expect(
      nodes(catalog.sidebarProjects, hostLevel: catalog.sidebarHostLevel).map(label) == [
        "host box", "host Mac mini",
      ])

    catalog.sidebarFilter = .all
    catalog.activeTagFilter = .tags([tag.id])
    let tree = nodes(catalog.sidebarProjects, hostLevel: catalog.sidebarHostLevel)
    #expect(tree.map(label) == ["host This Mac"])
    #expect(tree[0].children.map(label) == ["project repo"])
  }

  // MARK: - Drops

  @Test
  func aWorktreeMovesInsideItsSegmentInOnMoveTerms() throws {
    let siblings = try #require(nodes([repository]).first).children
    // main, pin-a, pin-b, (no pending), rest-a, rest-b
    let restA = siblings[3].id
    #expect(
      SidebarOutlineModel.worktreeMove(siblings: siblings, draggedID: restA, childIndex: 5)
        == .init(projectID: repository.id, segment: .unpinned, source: [0], destination: 2))
    let pinB = siblings[2].id
    #expect(
      SidebarOutlineModel.worktreeMove(siblings: siblings, draggedID: pinB, childIndex: 1)
        == .init(projectID: repository.id, segment: .pinned, source: [1], destination: 0))
  }

  @Test
  func aWorktreeDropOutsideItsSegmentOrOnARowIsRefused() throws {
    let siblings = try #require(nodes([repository], pendings: [pending(in: repository)]).first).children
    // main, pin-a, pin-b, pending, rest-a, rest-b
    let restA = siblings[4].id
    #expect(SidebarOutlineModel.worktreeMove(siblings: siblings, draggedID: restA, childIndex: 1) == nil)
    #expect(SidebarOutlineModel.worktreeMove(siblings: siblings, draggedID: restA, childIndex: -1) == nil)
    // The main checkout and a pending creation do not move.
    #expect(SidebarOutlineModel.worktreeMove(siblings: siblings, draggedID: siblings[0].id, childIndex: 0) == nil)
    #expect(SidebarOutlineModel.worktreeMove(siblings: siblings, draggedID: siblings[3].id, childIndex: 4) == nil)
  }

  @Test
  func aProjectDropResolvesToAVisibleNeighborInItsOwnParent() throws {
    let roots = nodes([repository, folder, failed, workspace])
    // Before the first, between two, and after the last Project.
    #expect(
      SidebarOutlineModel.projectDrop(siblings: roots, draggedID: roots[3].id, childIndex: 0)
        == .init(projectID: workspace.id, placement: .before(repository.id)))
    #expect(
      SidebarOutlineModel.projectDrop(siblings: roots, draggedID: roots[0].id, childIndex: 3)
        == .init(projectID: repository.id, placement: .before(workspace.id)))
    #expect(
      SidebarOutlineModel.projectDrop(siblings: roots, draggedID: roots[1].id, childIndex: 4)
        == .init(projectID: folder.id, placement: .after(workspace.id)))
  }

  @Test
  func aProjectDropNextToItselfIsValidButMovesNothing() throws {
    let roots = nodes([repository, folder, workspace])
    for index in [1, 2] {
      #expect(
        SidebarOutlineModel.projectDrop(siblings: roots, draggedID: roots[1].id, childIndex: index)
          == .init(projectID: folder.id, placement: nil))
    }
  }

  @Test
  func aProjectDropOnARowIntoWorktreesOrAtTheHostLevelIsRefused() throws {
    let roots = nodes([repository, folder])
    #expect(SidebarOutlineModel.projectDrop(siblings: roots, draggedID: roots[0].id, childIndex: -1) == nil)
    // Into the worktree segment of a Project.
    #expect(
      SidebarOutlineModel.projectDrop(siblings: roots[0].children, draggedID: roots[1].id, childIndex: 1) == nil)
    // Among the Host rows, with a Host level.
    let catalog = Catalog(projects: [repository, remote(folder, on: Self.box)], hosts: [Self.box])
    let hosts = nodes(catalog.projects, hostLevel: catalog.sidebarHostLevel)
    let local = try #require(hosts.first?.children.first)
    #expect(SidebarOutlineModel.projectDrop(siblings: hosts, draggedID: local.id, childIndex: 0) == nil)
  }

  @Test
  func aProjectDropUnderAnotherHostIsRefused() throws {
    let catalog = Catalog(
      projects: [repository, remote(folder, on: Self.box), remote(workspace, on: Self.box)], hosts: [Self.box])
    let hosts = nodes(catalog.projects, hostLevel: catalog.sidebarHostLevel)
    let thisMac = try #require(hosts.first { $0.id == SidebarOutlineModel.hostNodeID(.thisMac) })
    let box = try #require(hosts.first { $0.id != thisMac.id })
    let local = try #require(thisMac.children.first)
    #expect(SidebarOutlineModel.projectDrop(siblings: box.children, draggedID: local.id, childIndex: 0) == nil)
    // Inside its own Host the same drag is valid.
    let boxFirst = box.children[0]
    #expect(
      SidebarOutlineModel.projectDrop(siblings: box.children, draggedID: box.children[1].id, childIndex: 0)?
        .placement == .before(projectID(of: boxFirst)))
  }

  @Test
  func aProjectDropUnderAFilterResolvesInTheFullOrder() throws {
    // `failed` and `folder` are hidden; the drop lands next to the visible
    // `workspace`, and the hidden Projects keep their places.
    let gone = failed
    var catalog = Catalog(projects: [repository, gone, folder, workspace])
    let roots = nodes([repository, workspace])
    let drop = try #require(
      SidebarOutlineModel.projectDrop(siblings: roots, draggedID: roots[0].id, childIndex: 2))
    let placement = try #require(drop.placement)
    catalog.moveProject(drop.projectID, to: placement)
    #expect(catalog.projects.map(\.id) == [gone.id, folder.id, workspace.id, repository.id])
  }

  private func projectID(of node: SidebarOutlineNode) -> ProjectID {
    guard case .project(let project) = node.row else { return ProjectID() }
    return project.id
  }
}
