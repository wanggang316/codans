import Foundation
import Testing

@testable import TouchCodeCore
@testable import TouchCode

@MainActor
struct HierarchyManagerSetPaneLabelsTests {
  @Test
  func replaceOverwritesExistingLabels() throws {
    let (manager, paneID) = try Self.makeManagerWithPane(initialLabels: ["old"])
    try manager.setPaneLabels(paneID, labels: ["new"], replace: true)
    #expect(Self.readLabels(manager, paneID: paneID) == Set(["new"]))
  }

  @Test
  func mergeUnionsWithExistingLabels() throws {
    let (manager, paneID) = try Self.makeManagerWithPane(initialLabels: ["old"])
    try manager.setPaneLabels(paneID, labels: ["new"], replace: false)
    #expect(Self.readLabels(manager, paneID: paneID) == Set(["old", "new"]))
  }

  @Test
  func unknownPaneIDThrows() throws {
    let (manager, _) = try Self.makeManagerWithPane(initialLabels: [])
    let foreign = PaneID()
    #expect(throws: HierarchyError.self) {
      try manager.setPaneLabels(foreign, labels: ["x"])
    }
  }

  // MARK: - Helpers

  static func makeManagerWithPane(initialLabels: Set<String>) throws -> (HierarchyManager, PaneID) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("touch-code-labels-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("catalog.json")

    let pane = Pane(workingDirectory: "/tmp", labels: initialLabels)
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let worktree = Worktree(
      name: "main", path: "/repo", tabs: [tab], selectedTabID: tab.id
    )
    let project = Project(
      name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree], selectedWorktreeID: worktree.id
    )
    let catalog = Catalog(projects: [project])

    let store = CatalogStore(fileURL: url)
    let runtime = FakeHierarchyRuntime()
    let manager = HierarchyManager(catalog: catalog, store: store, runtime: runtime)
    return (manager, pane.id)
  }

  static func readLabels(_ manager: HierarchyManager, paneID: PaneID) -> Set<String> {
    for project in manager.catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          if let pane = tab.panes.first(where: { $0.id == paneID }) {
            return pane.labels
          }
        }
      }
    }
    return []
  }
}
