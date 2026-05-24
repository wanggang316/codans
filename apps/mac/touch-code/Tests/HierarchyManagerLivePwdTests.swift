import Foundation
import Testing

@testable import TouchCodeCore
@testable import touch_code

@MainActor
struct HierarchyManagerLivePwdTests {
  @Test
  func writesNewPathIntoCatalog() throws {
    let (manager, paneID) = try Self.makeManagerWithPane(initialPath: "/repo")
    manager.updatePaneWorkingDirectory(paneID, to: "/repo/sub")
    #expect(Self.readWorkingDirectory(manager, paneID: paneID) == "/repo/sub")
  }

  @Test
  func equalPathIsNoOpAndSkipsSave() throws {
    let (manager, paneID, url) = try Self.makeManagerWithPaneOnDisk(initialPath: "/repo")
    manager.updatePaneWorkingDirectory(paneID, to: "/repo")
    // No catalog file should exist — the equal-path write must not schedule
    // a save and must not even prime the writer.
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test
  func emptyPathIsIgnored() throws {
    let (manager, paneID) = try Self.makeManagerWithPane(initialPath: "/repo")
    manager.updatePaneWorkingDirectory(paneID, to: "")
    #expect(Self.readWorkingDirectory(manager, paneID: paneID) == "/repo")
  }

  @Test
  func unknownPaneIDIsSilentNoOp() throws {
    let (manager, paneID) = try Self.makeManagerWithPane(initialPath: "/repo")
    manager.updatePaneWorkingDirectory(PaneID(), to: "/elsewhere")
    #expect(Self.readWorkingDirectory(manager, paneID: paneID) == "/repo")
  }

  // MARK: - Helpers

  static func makeManagerWithPane(initialPath: String) throws -> (HierarchyManager, PaneID) {
    let (manager, paneID, _) = try makeManagerWithPaneOnDisk(initialPath: initialPath)
    return (manager, paneID)
  }

  static func makeManagerWithPaneOnDisk(
    initialPath: String
  ) throws -> (HierarchyManager, PaneID, URL) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("touch-code-pwd-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("catalog.json")

    let pane = Pane(workingDirectory: initialPath)
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
    return (manager, pane.id, url)
  }

  static func readWorkingDirectory(_ manager: HierarchyManager, paneID: PaneID) -> String? {
    for project in manager.catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          if let pane = tab.panes.first(where: { $0.id == paneID }) {
            return pane.workingDirectory
          }
        }
      }
    }
    return nil
  }
}
