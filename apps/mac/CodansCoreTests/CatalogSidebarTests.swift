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
  func aWorkspaceRowIsItsRootAndListsItsCheckouts() {
    #expect(workspace.rowWorktree == workspaceRoot)
    #expect(workspace.childWorktrees == [checkout])
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
        == [folderRoot.id, workspaceRoot.id, main.id, pinned.id, feature.id])

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
}
