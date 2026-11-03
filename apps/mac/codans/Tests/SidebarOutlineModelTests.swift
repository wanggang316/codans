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
    _ projects: [Project], pendings: [PendingWorktree] = [], filter: SidebarFilter = .all,
    isReordering: Bool = false
  ) -> [SidebarOutlineNode] {
    SidebarOutlineModel.nodes(
      projects: projects, pendingWorktrees: pendings, filter: filter, isReordering: isReordering)
  }

  /// A row's kind and name, so a test reads as the sidebar does.
  private func label(_ node: SidebarOutlineNode) -> String {
    switch node.row {
    case .project(let project): "project \(project.name)"
    case .reorderProject(let project): "reorder \(project.name)"
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

  @Test
  func theReorderSessionShowsOneRowPerProjectAndNothingUnderIt() {
    let tree = nodes([repository, failed, workspace], isReordering: true)
    #expect(tree.map(label) == ["reorder repo", "reorder gone", "reorder flow"])
    #expect(tree.allSatisfy { $0.children.isEmpty && $0.selection == nil })
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
  func aProjectMovesInTheTopLevelOfTheReorderSession() throws {
    let roots = nodes([repository, folder, workspace], isReordering: true)
    let move = try #require(SidebarOutlineModel.projectMove(roots: roots, draggedID: roots[2].id, childIndex: 0))
    #expect(move.source == [2])
    #expect(move.destination == 0)
    #expect(SidebarOutlineModel.projectMove(roots: roots, draggedID: roots[0].id, childIndex: -1) == nil)
    // Outside the reorder session a Project row does not move.
    let rows = nodes([repository, folder])
    #expect(SidebarOutlineModel.projectMove(roots: rows, draggedID: rows[0].id, childIndex: 2) == nil)
  }
}
