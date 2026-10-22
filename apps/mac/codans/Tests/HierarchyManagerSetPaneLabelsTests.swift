import Foundation
import Testing

@testable import Codans
@testable import CodansCore

@MainActor
struct HierarchyManagerSetPaneLabelsTests {
  @Test
  func replaceOverwritesExistingLabels() throws {
    let (manager, contentID) = try Self.makeManagerWithContent(initialLabels: ["old"])
    try manager.setContentLabels(contentID, labels: ["new"], replace: true)
    #expect(Self.readLabels(manager, contentID: contentID) == Set(["new"]))
  }

  @Test
  func mergeUnionsWithExistingLabels() throws {
    let (manager, contentID) = try Self.makeManagerWithContent(initialLabels: ["old"])
    try manager.setContentLabels(contentID, labels: ["new"], replace: false)
    #expect(Self.readLabels(manager, contentID: contentID) == Set(["old", "new"]))
  }

  @Test
  func unknownContentIDThrows() throws {
    let (manager, _) = try Self.makeManagerWithContent(initialLabels: [])
    let foreign = ContentID()
    #expect(throws: HierarchyError.self) {
      try manager.setContentLabels(foreign, labels: ["x"])
    }
  }

  // MARK: - Helpers

  static func makeManagerWithContent(initialLabels: Set<String>) throws -> (HierarchyManager, ContentID) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codans-labels-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("catalog.json")

    let tab = Tab(content: .terminal(workingDirectory: "/tmp", labels: initialLabels))
    let pane = Pane(tabs: [tab])
    let worktree = Worktree(
      name: "main", path: "/repo", splitTree: SplitTree(leaf: pane.id), panes: [pane], focusedPaneID: pane.id
    )
    let project = Project(
      name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree], selectedWorktreeID: worktree.id
    )
    let catalog = Catalog(projects: [project])

    let store = CatalogStore(fileURL: url)
    let runtime = FakeHierarchyRuntime()
    let manager = HierarchyManager(catalog: catalog, store: store, runtime: runtime)
    return (manager, tab.contentID)
  }

  static func readLabels(_ manager: HierarchyManager, contentID: ContentID) -> Set<String> {
    manager.catalog.content(contentID)?.terminal?.labels ?? []
  }
}
