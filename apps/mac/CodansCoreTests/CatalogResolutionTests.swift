import Foundation
import Testing

@testable import CodansCore

struct CatalogResolutionTests {
  @Test
  func worktreeIDForPaneFindsAcrossTabs() throws {
    let paneA = Pane(workingDirectory: "/a")
    let paneB = Pane(workingDirectory: "/b")
    let paneC = Pane(workingDirectory: "/c")

    let tab1 = Tab(splitTree: SplitTree(leaf: paneA.id), panes: [paneA])
    let tab2 = Tab(
      splitTree: try SplitTree(leaf: paneB.id).inserting(paneC.id, at: paneB.id, direction: .right),
      panes: [paneB, paneC]
    )
    let worktree = Worktree(name: "main", path: "/repo", tabs: [tab1, tab2])
    let project = Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [worktree])
    let catalog = Catalog(projects: [project])

    #expect(catalog.worktreeID(forPane: paneA.id) == worktree.id)
    #expect(catalog.worktreeID(forPane: paneB.id) == worktree.id)
    #expect(catalog.worktreeID(forPane: paneC.id) == worktree.id)
  }

  @Test
  func worktreeIDForPaneMissingReturnsNil() {
    let catalog = Catalog(projects: [
      Project(name: "p", rootPath: "/p", worktrees: [
        Worktree(name: "w", path: "/p"),
      ]),
    ])
    #expect(catalog.worktreeID(forPane: PaneID()) == nil)
  }

  @Test
  func visiblePaneIDsExcludesArchivedWorktrees() {
    let visiblePane = Pane(workingDirectory: "/v")
    let archivedPane = Pane(workingDirectory: "/a")
    let visible = Worktree(
      name: "visible", path: "/repo",
      tabs: [Tab(splitTree: SplitTree(leaf: visiblePane.id), panes: [visiblePane])]
    )
    let archived = Worktree(
      name: "archived", path: "/repo/arch",
      tabs: [Tab(splitTree: SplitTree(leaf: archivedPane.id), panes: [archivedPane])],
      archived: true
    )
    let catalog = Catalog(projects: [
      Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [visible, archived]),
    ])

    // allPaneIDs() sees both; visiblePaneIDs() drops the archived worktree's
    // pane — archive kills its daemon, so its agent row must retire even
    // though the Pane stays in the catalog for restore.
    #expect(catalog.allPaneIDs() == [visiblePane.id, archivedPane.id])
    #expect(catalog.visiblePaneIDs() == [visiblePane.id])
  }

  @Test
  func paneIDsInWorktreeReturnsAllLeaves() throws {
    let paneA = Pane(workingDirectory: "/a")
    let paneB = Pane(workingDirectory: "/b")
    let paneC = Pane(workingDirectory: "/c")
    let paneD = Pane(workingDirectory: "/d")

    let tab1 = Tab(
      splitTree: try SplitTree(leaf: paneA.id).inserting(paneB.id, at: paneA.id, direction: .right),
      panes: [paneA, paneB]
    )
    let tab2 = Tab(
      splitTree: try SplitTree(leaf: paneC.id).inserting(paneD.id, at: paneC.id, direction: .down),
      panes: [paneC, paneD]
    )
    let worktree = Worktree(name: "main", path: "/repo", tabs: [tab1, tab2])
    let project = Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [worktree])
    let catalog = Catalog(projects: [project])

    #expect(catalog.paneIDs(inWorktree: worktree.id) == Set([paneA.id, paneB.id, paneC.id, paneD.id]))
  }

  @Test
  func paneIDsInWorktreeUnknownReturnsEmpty() {
    let catalog = Catalog()
    #expect(catalog.paneIDs(inWorktree: WorktreeID()).isEmpty)
  }
}
