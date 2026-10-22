import Foundation
import Testing

@testable import Codans
@testable import CodansCore

@MainActor
struct HierarchyManagerLivePwdTests {
  @Test
  func writesNewPathIntoCatalog() throws {
    let (manager, contentID) = try Self.makeManagerWithContent(initialPath: "/repo")
    manager.updateWorkingDirectory(for: contentID, to: "/repo/sub")
    #expect(Self.readWorkingDirectory(manager, contentID: contentID) == "/repo/sub")
  }

  @Test
  func equalPathIsNoOpAndSkipsSave() throws {
    let (manager, contentID, url) = try Self.makeManagerWithContentOnDisk(initialPath: "/repo")
    manager.updateWorkingDirectory(for: contentID, to: "/repo")
    // No catalog file should exist — the equal-path write must not schedule
    // a save and must not even prime the writer.
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test
  func emptyPathIsIgnored() throws {
    let (manager, contentID) = try Self.makeManagerWithContent(initialPath: "/repo")
    manager.updateWorkingDirectory(for: contentID, to: "")
    #expect(Self.readWorkingDirectory(manager, contentID: contentID) == "/repo")
  }

  @Test
  func unknownContentIDIsSilentNoOp() throws {
    let (manager, contentID) = try Self.makeManagerWithContent(initialPath: "/repo")
    manager.updateWorkingDirectory(for: ContentID(), to: "/elsewhere")
    #expect(Self.readWorkingDirectory(manager, contentID: contentID) == "/repo")
  }

  // MARK: - Helpers

  static func makeManagerWithContent(initialPath: String) throws -> (HierarchyManager, ContentID) {
    let (manager, contentID, _) = try makeManagerWithContentOnDisk(initialPath: initialPath)
    return (manager, contentID)
  }

  static func makeManagerWithContentOnDisk(
    initialPath: String
  ) throws -> (HierarchyManager, ContentID, URL) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codans-pwd-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("catalog.json")

    let tab = Tab(content: .terminal(workingDirectory: initialPath))
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
    return (manager, tab.contentID, url)
  }

  static func readWorkingDirectory(_ manager: HierarchyManager, contentID: ContentID) -> String? {
    manager.catalog.content(contentID)?.terminal?.workingDirectory
  }
}
