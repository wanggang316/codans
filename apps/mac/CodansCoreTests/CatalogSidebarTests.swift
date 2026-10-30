import Foundation
import Testing

@testable import CodansCore

/// Which worktree a Project row stands for, which rows it lists under it, and
/// the order the sidebar offers its selectable rows in (⌃1…⌃0, ⌘⌃↑/↓).
struct CatalogSidebarTests {
  private let folderRoot = Worktree(name: "notes", path: "/notes")
  private static let defaultGroup = WorkspaceGroupID()
  private static let fixGroup = WorkspaceGroupID()
  private let defaultTerminal = Worktree(
    name: "default", path: "/ws/flow/default",
    workspaceSlot: WorkspaceSlot(groupID: defaultGroup, role: .groupTerminal))
  private let reference = Worktree(
    name: "app", path: "/src/app", branch: "main", sourceGitRoot: "/src/app",
    workspaceSlot: WorkspaceSlot(groupID: defaultGroup, role: .reference))
  private let fixTerminal = Worktree(
    name: "fix", path: "/ws/flow/fix", workspaceSlot: WorkspaceSlot(groupID: fixGroup, role: .groupTerminal))
  private let checkout = Worktree(
    name: "app", path: "/ws/flow/fix/app", branch: "fix/login", sourceGitRoot: "/src/app",
    workspaceSlot: WorkspaceSlot(groupID: fixGroup, role: .member))
  private let libCheckout = Worktree(
    name: "lib", path: "/ws/flow/fix/lib", branch: "fix/login", sourceGitRoot: "/src/lib",
    workspaceSlot: WorkspaceSlot(groupID: fixGroup, role: .member))
  private let main = Worktree(name: "main", path: "/repo", branch: "main")
  private let feature = Worktree(name: "feat", path: "/repo-feat", branch: "feat")
  private let pinned = Worktree(name: "hotfix", path: "/repo-hotfix", branch: "hotfix", isPinned: true)

  private var folder: Project {
    Project(name: "notes", rootPath: "/notes", worktrees: [folderRoot])
  }

  private var workspace: Project {
    Project(
      name: "flow", rootPath: "/ws/flow",
      worktrees: [defaultTerminal, reference, fixTerminal, checkout, libCheckout],
      isWorkspace: true,
      workspaceGroups: [
        WorkspaceGroupRecord(id: Self.defaultGroup, name: "default", kind: .default),
        WorkspaceGroupRecord(id: Self.fixGroup, name: "fix", kind: .named, isExpanded: true),
      ])
  }

  private var repository: Project {
    Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [feature, main, pinned])
  }

  @Test
  func aFolderRowIsItsRootAndListsNothingUnderIt() {
    #expect(folder.rowWorktree == folderRoot)
    #expect(folder.childWorktrees.isEmpty)
    #expect(!folder.hasChildRows)
  }

  @Test
  func aWorkspaceHeaderStandsForNoRowAndListsItsGroups() {
    #expect(workspace.rowWorktree == nil)
    #expect(workspace.hasChildRows)
    #expect(
      workspace.workspaceSidebarRows == [
        .group(workspace.workspaceGroups[0], terminal: defaultTerminal),
        .group(workspace.workspaceGroups[1], terminal: fixTerminal),
        .member(checkout, groupID: Self.fixGroup),
        .member(libCheckout, groupID: Self.fixGroup),
      ])
    // A group row is selectable through its terminal row; members by their own.
    #expect(
      workspace.workspaceSidebarRows.map(\.worktreeID)
        == [defaultTerminal.id, fixTerminal.id, checkout.id, libCheckout.id])
  }

  @Test
  func onlyAGroupFolderRowStandsForItsGroup() {
    #expect(workspace.workspaceGroup(standingFor: defaultTerminal) == workspace.workspaceGroups[0])
    #expect(workspace.workspaceGroup(standingFor: fixTerminal) == workspace.workspaceGroups[1])
    // References and checkouts are repositories with their own branch.
    #expect(workspace.workspaceGroup(standingFor: reference) == nil)
    #expect(workspace.workspaceGroup(standingFor: checkout) == nil)
    #expect(repository.workspaceGroup(standingFor: main) == nil)
  }

  @Test
  func workspaceGroupsExpandIndependently() {
    var project = workspace
    project.workspaceGroups[0].isExpanded = true
    project.workspaceGroups[1].isExpanded = false
    #expect(
      project.workspaceSidebarRows.map(\.worktreeID) == [defaultTerminal.id, reference.id, fixTerminal.id])
  }

  @Test
  func workspaceProjectionSkipsArchivedAndUnslottedRows() {
    var project = workspace
    project.worktrees[3].archived = true
    project.worktrees.append(Worktree(name: "stray", path: "/ws/flow/stray"))
    #expect(
      project.workspaceSidebarRows.map(\.worktreeID) == [defaultTerminal.id, fixTerminal.id, libCheckout.id])
  }

  @Test
  func aGroupWithoutATerminalRowStillListsItsMembers() {
    var project = workspace
    project.worktrees.removeAll { $0.id == defaultTerminal.id }
    project.workspaceGroups[0].isExpanded = true
    #expect(project.workspaceSidebarRows.first == .group(project.workspaceGroups[0], terminal: nil))
    #expect(project.workspaceSidebarRows.compactMap(\.worktreeID).first == reference.id)
  }

  @Test
  func groupSummaryCountsMembersAndBranches() {
    var project = workspace
    #expect(
      project.workspaceGroupSummary(Self.fixGroup)
        == WorkspaceGroupSummary(memberCount: 2, branch: .single("fix/login")))
    project.worktrees[4].branch = "feat/lib"
    #expect(
      project.workspaceGroupSummary(Self.fixGroup) == WorkspaceGroupSummary(memberCount: 2, branch: .several(2)))
    #expect(
      project.workspaceGroupSummary(Self.defaultGroup)
        == WorkspaceGroupSummary(memberCount: 1, branch: .single("main")))
    #expect(
      project.workspaceGroupSummary(WorkspaceGroupID()) == WorkspaceGroupSummary(memberCount: 0, branch: nil))
  }

  @Test
  func revealingAMemberNamesItsCollapsedGroupOnly() {
    #expect(workspace.collapsedWorkspaceGroup(revealing: reference.id) == Self.defaultGroup)
    // Expanded group, group row, and unknown rows need no reveal.
    #expect(workspace.collapsedWorkspaceGroup(revealing: checkout.id) == nil)
    #expect(workspace.collapsedWorkspaceGroup(revealing: defaultTerminal.id) == nil)
    #expect(workspace.collapsedWorkspaceGroup(revealing: WorktreeID()) == nil)
    #expect(repository.collapsedWorkspaceGroup(revealing: main.id) == nil)
  }

  @Test
  func rowsInACollapsedGroupStandBehindTheGroupRow() {
    let catalog = Catalog(projects: [repository, workspace])
    #expect(catalog.workspaceRowStandIns == [reference.id: defaultTerminal.id])
  }

  @Test
  func aRepositoryKeepsItsMainCheckoutAsARow() {
    #expect(repository.rowWorktree == nil)
    #expect(repository.childWorktrees == [main, pinned, feature])
    #expect(repository.hasChildRows)
    // Before its first reconcile a repository has no rows yet but still opens.
    #expect(Project(name: "new", rootPath: "/new", gitRoot: "/new").hasChildRows)
  }

  @Test
  func anArchivedRootIsNotTheRow() {
    var archived = folderRoot
    archived.archived = true
    #expect(Project(name: "notes", rootPath: "/notes", worktrees: [archived]).rowWorktree == nil)
  }

  @Test
  func selectionOrderFollowsTheRowsOnScreen() {
    var collapsedWorkspace = workspace
    collapsedWorkspace.isExpanded = false
    var catalog = Catalog(projects: [folder, collapsedWorkspace, repository], projectSortMode: .manual)
    #expect(
      catalog.sidebarSelectionOrder.map(\.worktreeID)
        == [folderRoot.id, main.id, pinned.id, feature.id])

    catalog.projects[1].isExpanded = true
    catalog.projects[2].isExpanded = false
    #expect(
      catalog.sidebarSelectionOrder.map(\.worktreeID)
        == [folderRoot.id, defaultTerminal.id, fixTerminal.id, checkout.id, libCheckout.id])
  }

  @Test
  func selectionOrderSkipsFilteredAndFailedProjects() {
    let tag = TagID()
    var tagged = folder
    tagged.tagIDs = [tag]
    var failed = repository
    failed.loadState = .failed(reason: "gone")
    let catalog = Catalog(
      projects: [tagged, workspace, failed], activeTagFilter: .tags([tag]), projectSortMode: .manual)
    #expect(catalog.sidebarProjects.map(\.id) == [tagged.id])
    #expect(catalog.sidebarSelectionOrder.map(\.worktreeID) == [folderRoot.id])

    let unfiltered = Catalog(projects: [tagged, workspace, failed], projectSortMode: .manual)
    #expect(
      unfiltered.sidebarSelectionOrder.map(\.worktreeID)
        == [folderRoot.id, defaultTerminal.id, fixTerminal.id, checkout.id, libCheckout.id])
  }

  @Test
  func categoryFiltersShareSelectionOrder() {
    let repository = self.repository
    let workspace = self.workspace
    var remote = folder
    remote.remoteHost = RemoteHost(alias: "server")
    var catalog = Catalog(projects: [repository, remote, workspace], projectSortMode: .manual)
    catalog.sidebarFilter = .remote
    #expect(catalog.sidebarProjects.map(\.id) == [remote.id])
    catalog.sidebarFilter = .workspace
    #expect(catalog.sidebarProjects.map(\.id) == [workspace.id])
  }

  @Test
  func notificationFilterUsesLiveMatchesAndExcludesArchivedRows() {
    var catalog = Catalog(projects: [repository, workspace], projectSortMode: .manual)
    catalog.sidebarFilter = .notifications
    #expect(catalog.sidebarProjects(pullRequestWorktreeIDs: [], notifiedWorktreeIDs: []).isEmpty)
    let notified: Set<WorktreeID> = [pinned.id, checkout.id]
    // Pull-request matches do not leak into the notification view.
    #expect(
      catalog.sidebarSelectionOrder(pullRequestWorktreeIDs: [feature.id], notifiedWorktreeIDs: notified)
        .map(\.worktreeID) == [pinned.id, fixTerminal.id, checkout.id])
    catalog.projects[0].worktrees[2].archived = true
    #expect(
      catalog.sidebarSelectionOrder(pullRequestWorktreeIDs: [], notifiedWorktreeIDs: notified).map(\.worktreeID)
        == [fixTerminal.id, checkout.id])
    catalog.activeTagFilter = .tags([TagID()])
    #expect(catalog.sidebarProjects(pullRequestWorktreeIDs: [], notifiedWorktreeIDs: notified).isEmpty)
  }

  @Test
  func notificationFilterListsOnlyNotifiedRows() {
    var catalog = Catalog(projects: [repository, workspace], projectSortMode: .manual)
    catalog.sidebarFilter = .notifications
    catalog.selectedProjectID = repository.id
    catalog.projects[0].selectedWorktreeID = feature.id
    #expect(
      catalog.sidebarSelectionOrder(pullRequestWorktreeIDs: [], notifiedWorktreeIDs: [checkout.id])
        .map(\.worktreeID) == [fixTerminal.id, checkout.id])
  }

  @Test
  func aNotifiedGroupRowShowsWithoutItsMembers() {
    let catalog = {
      var catalog = Catalog(projects: [workspace])
      catalog.sidebarFilter = .notifications
      return catalog
    }()
    #expect(
      catalog.sidebarSelectionOrder(pullRequestWorktreeIDs: [], notifiedWorktreeIDs: [fixTerminal.id])
        .map(\.worktreeID) == [fixTerminal.id])
  }

  @Test
  func notifiedMembersKeepTheirGroupAndRespectTags() {
    var tagged = workspace
    let tag = TagID()
    tagged.tagIDs = [tag]
    let catalog = {
      var catalog = Catalog(projects: [repository, tagged], activeTagFilter: .tags([tag]))
      catalog.sidebarFilter = .notifications
      return catalog
    }()
    let notified: Set<WorktreeID> = [reference.id, feature.id]
    #expect(
      catalog.sidebarProjects(pullRequestWorktreeIDs: [], notifiedWorktreeIDs: notified).map(\.id) == [tagged.id])
    // The matching member's group stays visible and opens for the filtered
    // view only; the catalog keeps the group collapsed.
    #expect(
      catalog.sidebarSelectionOrder(pullRequestWorktreeIDs: [], notifiedWorktreeIDs: notified).map(\.worktreeID)
        == [defaultTerminal.id, reference.id])
    #expect(catalog.projects[1].workspaceGroups[0].isExpanded == false)
  }

  @Test
  func filterPersistsAndOldCatalogDefaultsToAll() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    var catalog = Catalog(projects: [folder])
    let original = try encoder.encode(catalog)
    #expect(try decoder.decode(Catalog.self, from: original).sidebarFilter == .all)
    catalog.sidebarFilter = .notifications
    #expect(try decoder.decode(Catalog.self, from: encoder.encode(catalog)) == catalog)
  }

  @Test
  func pullRequestFilterUsesLiveMatchesAndExcludesArchivedRows() {
    var catalog = Catalog(projects: [repository, workspace], projectSortMode: .manual)
    catalog.sidebarFilter = .pullRequests
    #expect(catalog.sidebarProjects(pullRequestWorktreeIDs: [], notifiedWorktreeIDs: []).isEmpty)
    let matches: Set<WorktreeID> = [feature.id, checkout.id]
    #expect(
      catalog.sidebarSelectionOrder(pullRequestWorktreeIDs: matches, notifiedWorktreeIDs: []).map(\.worktreeID)
        == [feature.id, fixTerminal.id, checkout.id])
    catalog.projects[0].worktrees[0].archived = true
    #expect(
      catalog.sidebarSelectionOrder(pullRequestWorktreeIDs: matches, notifiedWorktreeIDs: []).map(\.worktreeID)
        == [fixTerminal.id, checkout.id])
    #expect(
      catalog.sidebarSelectionOrder(pullRequestWorktreeIDs: [pinned.id], notifiedWorktreeIDs: [])
        .map(\.worktreeID) == [pinned.id])
    catalog.activeTagFilter = .tags([TagID()])
    #expect(catalog.sidebarProjects(pullRequestWorktreeIDs: matches, notifiedWorktreeIDs: []).isEmpty)
  }

  @Test
  func legacyCategoriesMigrate() throws {
    let decoder = JSONDecoder()
    #expect(try decoder.decode(SidebarFilter.self, from: Data(#""local""#.utf8)) == .all)
    #expect(try decoder.decode(SidebarFilter.self, from: Data(#""favorites""#.utf8)) == .all)
    #expect(try decoder.decode(SidebarFilter.self, from: Data(#""pin""#.utf8)) == .all)
    #expect(SidebarFilter.allCases == [.all, .remote, .workspace, .pullRequests, .notifications])
  }
}
