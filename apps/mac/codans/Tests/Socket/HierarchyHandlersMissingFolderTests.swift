import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// A Tab or Pane cannot start in a folder that is gone. Over IPC the request
/// fails with a `directory` not-found error, nothing is added to the catalog,
/// and a missing project root flags the Project failed.
@MainActor
struct HierarchyHandlersMissingFolderTests {
  private struct Fixture {
    let manager: HierarchyManager
    let handlers: HierarchyHandlers
    let runtime: FakeHierarchyRuntime
    let project: Project
    let worktree: Worktree
    let tab: Tab
  }

  private func makeFixture(rootPath: String) -> Fixture {
    let runtime = FakeHierarchyRuntime()
    let tab = Tab(name: "dev")
    let worktree = Worktree(name: "main", path: rootPath, branch: "main", tabs: [tab])
    let project = Project(
      name: "repo", rootPath: rootPath, gitRoot: rootPath, worktrees: [worktree])
    let manager = HierarchyManager(
      catalog: Catalog(projects: [project]),
      store: CatalogStore(
        fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent("codans-missing-folder-\(UUID().uuidString).json")
      ),
      runtime: runtime
    )
    return Fixture(
      manager: manager, handlers: HierarchyHandlers(manager: manager), runtime: runtime,
      project: project, worktree: worktree, tab: tab)
  }

  private func missingPath() -> String {
    NSTemporaryDirectory() + "codans-missing-\(UUID().uuidString)"
  }

  @Test
  func openPaneInMissingFolderFailsAndFlagsProject() async throws {
    let root = missingPath()
    let fixture = makeFixture(rootPath: root)
    let params = try JSONValue.encoded(
      HierarchyHandlers.OpenPaneParams(
        projectID: fixture.project.id, worktreeID: fixture.worktree.id,
        tabID: fixture.tab.id, workingDirectory: root, initialCommand: nil, labels: []))

    let outcome = await fixture.handlers.openPane(params)

    guard case .failed(let error) = outcome else {
      Issue.record("expected failure, got \(outcome)")
      return
    }
    #expect(error == .notFound(kind: "directory", id: root))
    #expect(fixture.runtime.ensureSurfaceCalls.isEmpty)
    #expect(
      fixture.manager.catalog.projects[0].loadState
        == ProjectReconciler.missingFolderState(rootPath: root))
  }

  @Test
  func createTabInMissingFolderFailsWithoutAddingTab() async throws {
    let root = missingPath()
    let fixture = makeFixture(rootPath: root)
    let params = try JSONValue.encoded(
      HierarchyHandlers.CreateTabParams(
        projectID: fixture.project.id, worktreeID: fixture.worktree.id, name: nil))

    let outcome = await fixture.handlers.createTab(params)

    guard case .failed(let error) = outcome else {
      Issue.record("expected failure, got \(outcome)")
      return
    }
    #expect(error == .notFound(kind: "directory", id: root))
    #expect(fixture.manager.catalog.projects[0].worktrees[0].tabs.count == 1)
  }
}
