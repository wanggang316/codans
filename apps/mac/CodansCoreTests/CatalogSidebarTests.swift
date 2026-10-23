import Foundation
import Testing

@testable import CodansCore

/// Which worktree a Project row stands for, which rows it lists under it, and
/// the order the sidebar offers its selectable rows in (⌃1…⌃0, ⌘⌃↑/↓).
struct CatalogSidebarTests {
  private let folderRoot = Worktree(name: "notes", path: "/notes")
  private let workspaceRoot = Worktree(name: "flow", path: "/ws/flow")
  private let checkout = Worktree(name: "app", path: "/ws/flow/app", branch: "flow", sourceGitRoot: "/src/app")
  private let main = Worktree(name: "main", path: "/repo", branch: "main")
  private let feature = Worktree(name: "feat", path: "/repo-feat", branch: "feat")
  private let pinned = Worktree(name: "hotfix", path: "/repo-hotfix", branch: "hotfix", isPinned: true)

  private var folder: Project {
    Project(name: "notes", rootPath: "/notes", worktrees: [folderRoot])
  }

  private var workspace: Project {
    Project(name: "flow", rootPath: "/ws/flow", worktrees: [workspaceRoot, checkout], isWorkspace: true)
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
  func aWorkspaceHeaderStandsForNoRowAndListsEveryRow() {
    #expect(workspace.rowWorktree == nil)
    #expect(workspace.childWorktrees == [workspaceRoot, checkout])
    #expect(workspace.hasChildRows)
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
      catalog.sidebarSelectionOrder.map(\.worktreeID) == [folderRoot.id, workspaceRoot.id, checkout.id])
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
    #expect(unfiltered.sidebarSelectionOrder.map(\.worktreeID) == [folderRoot.id, workspaceRoot.id, checkout.id])
  }

  @Test
  func categoryFiltersAndPinShareSelectionOrder() {
    let repository = self.repository
    let workspace = self.workspace
    var remote = folder
    remote.remoteHost = RemoteHost(alias: "server")
    var catalog = Catalog(projects: [repository, remote, workspace], projectSortMode: .manual)
    catalog.sidebarFilter = .remote
    #expect(catalog.sidebarProjects.map(\.id) == [remote.id])
    catalog.sidebarFilter = .workspace
    #expect(catalog.sidebarProjects.map(\.id) == [workspace.id])
    catalog.sidebarFilter = .pin
    #expect(catalog.sidebarProjects.map(\.id) == [repository.id])
    #expect(catalog.sidebarSelectionOrder.map(\.worktreeID) == [pinned.id])
    catalog.projects[0].worktrees[2].archived = true
    #expect(catalog.sidebarProjects.isEmpty)
  }

  @Test
  func pinsKeepWorkspaceMembersAndRespectTags() {
    var starredWorkspace = workspace
    starredWorkspace.worktrees[1].isPinned = true
    let tag = TagID()
    starredWorkspace.tagIDs = [tag]
    var catalog = Catalog(projects: [repository, starredWorkspace], activeTagFilter: .tags([tag]))
    catalog.sidebarFilter = .pin
    #expect(catalog.sidebarProjects.map(\.id) == [starredWorkspace.id])
    #expect(catalog.sidebarSelectionOrder.map(\.worktreeID) == [checkout.id])
    catalog.projects[1].isExpanded = false
    #expect(catalog.sidebarSelectionOrder.isEmpty)
  }

  @Test
  func filterPersistsAndOldCatalogDefaultsToAll() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    var catalog = Catalog(projects: [folder])
    let original = try encoder.encode(catalog)
    #expect(try decoder.decode(Catalog.self, from: original).sidebarFilter == .all)
    catalog.sidebarFilter = .pin
    #expect(try decoder.decode(Catalog.self, from: encoder.encode(catalog)) == catalog)
  }

  @Test
  func pullRequestFilterUsesLiveMatchesAndExcludesArchivedRows() {
    var catalog = Catalog(projects: [repository, workspace], projectSortMode: .manual)
    catalog.sidebarFilter = .pullRequests
    #expect(catalog.sidebarProjects(pullRequestWorktreeIDs: []).isEmpty)
    let matches: Set<WorktreeID> = [feature.id, checkout.id]
    #expect(
      catalog.sidebarSelectionOrder(pullRequestWorktreeIDs: matches).map(\.worktreeID)
        == [feature.id, checkout.id])
    catalog.projects[0].worktrees[0].archived = true
    #expect(catalog.sidebarSelectionOrder(pullRequestWorktreeIDs: matches).map(\.worktreeID) == [checkout.id])
    #expect(catalog.sidebarSelectionOrder(pullRequestWorktreeIDs: [pinned.id]).map(\.worktreeID) == [pinned.id])
    catalog.activeTagFilter = .tags([TagID()])
    #expect(catalog.sidebarProjects(pullRequestWorktreeIDs: matches).isEmpty)
  }

  @Test
  func legacyCategoriesMigrate() throws {
    let decoder = JSONDecoder()
    #expect(try decoder.decode(SidebarFilter.self, from: Data(#""local""#.utf8)) == .all)
    #expect(try decoder.decode(SidebarFilter.self, from: Data(#""favorites""#.utf8)) == .pin)
    #expect(SidebarFilter.allCases == [.all, .remote, .workspace, .pin, .pullRequests])
  }
}
