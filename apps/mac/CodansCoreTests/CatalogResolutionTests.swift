import Foundation
import Testing

@testable import CodansCore

struct CatalogResolutionTests {
  private func tab(_ directory: String) -> Tab {
    Tab(content: .terminal(workingDirectory: directory))
  }

  /// `[[tabs of pane 1], [tabs of pane 2], …]` laid out left to right.
  private func worktree(name: String = "main", path: String = "/repo", archived: Bool = false, _ strips: [[Tab]])
    throws -> Worktree
  {
    let panes = strips.map { Pane(tabs: $0) }
    var tree = SplitTree<PaneID>()
    for pane in panes {
      tree =
        tree.isEmpty
        ? SplitTree(leaf: pane.id) : try tree.inserting(pane.id, at: tree.leaves().last!, direction: .right)
    }
    return Worktree(
      name: name, path: path, splitTree: tree, panes: panes, focusedPaneID: panes.first?.id, archived: archived)
  }

  @Test
  func addressResolvesEveryIDOfATab() throws {
    let a = tab("/a")
    let b = tab("/b")
    let c = tab("/c")
    let worktree = try worktree([[a], [b, c]])
    let project = Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [worktree])
    let catalog = Catalog(projects: [project])
    let paneOfC = try #require(worktree.pane(forTab: c.id))

    let byContent = try #require(catalog.address(forContent: c.content.id))
    #expect(byContent == catalog.address(forTab: c.id))
    #expect(byContent.projectID == project.id)
    #expect(byContent.worktreeID == worktree.id)
    #expect(byContent.paneID == paneOfC.id)
    #expect(byContent.tabID == c.id)
    #expect(byContent.contentID == c.content.id)

    #expect(catalog.worktreeID(forContent: a.content.id) == worktree.id)
    #expect(catalog.paneID(forTab: b.id) == paneOfC.id)
    #expect(catalog.tabID(forContent: b.content.id) == b.id)
    #expect(catalog.contentID(forTab: a.id) == a.content.id)
    #expect(catalog.projectID(forPane: paneOfC.id) == project.id)
    #expect(catalog.worktreeID(forPane: paneOfC.id) == worktree.id)
    #expect(catalog.tab(forContent: c.content.id) == c)
    #expect(catalog.tab(c.id) == c)
    #expect(catalog.pane(paneOfC.id) == paneOfC)
    #expect(catalog.content(a.content.id) == a.content)
  }

  @Test
  func projectAndWorktreeResolveByID() throws {
    let first = try worktree(name: "a", path: "/a", [[tab("/a")]])
    let second = try worktree(name: "b", path: "/b", [[tab("/b")]])
    let p1 = Project(name: "p1", rootPath: "/a", gitRoot: "/a", worktrees: [first])
    let p2 = Project(name: "p2", rootPath: "/b", gitRoot: "/b", worktrees: [second])
    let catalog = Catalog(projects: [p1, p2])

    #expect(catalog.project(p2.id) == p2)
    #expect(catalog.project(ProjectID()) == nil)
    let found = try #require(catalog.worktree(second.id))
    #expect(found.project.id == p2.id)
    #expect(found.worktree == second)
    #expect(catalog.worktree(WorktreeID()) == nil)
    #expect(catalog.worktree(second.id, in: p2.id) == second)
    // A Worktree is only found under the Project that holds it.
    #expect(catalog.worktree(second.id, in: p1.id) == nil)
  }

  @Test
  func unknownIDsResolveToNil() {
    let catalog = Catalog(projects: [
      Project(name: "p", rootPath: "/p", worktrees: [Worktree(name: "w", path: "/p")])
    ])
    #expect(catalog.address(forContent: ContentID()) == nil)
    #expect(catalog.address(forTab: TabID()) == nil)
    #expect(catalog.address(forPane: PaneID()) == nil)
    #expect(catalog.worktreeID(forContent: ContentID()) == nil)
    #expect(catalog.tab(TabID()) == nil)
  }

  @Test
  func visibleContentIDsExcludesArchivedWorktrees() throws {
    let visibleTab = tab("/v")
    let archivedTab = tab("/a")
    let visible = try worktree(name: "visible", [[visibleTab]])
    let archived = try worktree(name: "archived", path: "/repo/arch", archived: true, [[archivedTab]])
    let catalog = Catalog(projects: [
      Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [visible, archived])
    ])

    // allContentIDs() sees both; visibleContentIDs() drops the archived
    // worktree's Content — archive kills its daemon, so its agent row must
    // retire even though the record stays in the catalog for restore.
    #expect(catalog.allContentIDs() == [visibleTab.content.id, archivedTab.content.id])
    #expect(catalog.visibleContentIDs() == [visibleTab.content.id])
  }

  @Test
  func contentIDsInWorktreeSpanEveryPane() throws {
    let a = tab("/a")
    let b = tab("/b")
    let c = tab("/c")
    let d = tab("/d")
    let worktree = try worktree([[a, b], [c], [d]])
    let catalog = Catalog(projects: [
      Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [worktree])
    ])

    #expect(catalog.contentIDs(inWorktree: worktree.id) == Set([a, b, c, d].map(\.content.id)))
    #expect(catalog.contentIDs(inWorktree: WorktreeID()).isEmpty)
  }

  @Test
  func displayedSelectedProjectFallsBackToTheFirstRememberedWorktree() {
    let bare = Project(name: "a", rootPath: "/a")
    let remembered = Project(name: "b", rootPath: "/b", selectedWorktreeID: WorktreeID())
    let other = Project(name: "c", rootPath: "/c", selectedWorktreeID: WorktreeID())
    var catalog = Catalog(projects: [bare, remembered, other])
    #expect(catalog.displayedSelectedProjectID == remembered.id)
    catalog.selectedProjectID = other.id
    #expect(catalog.displayedSelectedProjectID == other.id)
    // A stale id falls back as if nothing were picked.
    catalog.selectedProjectID = ProjectID()
    #expect(catalog.displayedSelectedProjectID == remembered.id)
    #expect(Catalog(projects: [bare]).displayedSelectedProjectID == nil)
  }
}
