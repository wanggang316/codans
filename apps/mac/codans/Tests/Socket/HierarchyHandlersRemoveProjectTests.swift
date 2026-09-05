import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// `codans project rm` reaches `HierarchyHandlers`, which calls the manager
/// directly and never passes through `HierarchyClient`. Any per-removal
/// cleanup hung off the client seam is invisible to this path, so the
/// settings cleanup lives on the manager and these tests cover it from the
/// RPC side.
@MainActor
struct HierarchyHandlersRemoveProjectTests {
  @Test
  func removeProjectDropsItsSettingsEntry() async throws {
    let f = Fixture()
    let projectID = f.manager.addProject(name: "p", rootPath: "/repo", gitRoot: "/repo")
    f.settings.mutateProject(projectID) { $0.defaultEditor = "vscode" }
    #expect(f.settings.settings.projects[projectID] != nil)

    let params = try JSONValue.encoded(RemoveProjectRequest(id: projectID))
    let outcome = await f.handlers.removeProject(params)

    guard case .unary = outcome else {
      Issue.record("expected unary success, got \(outcome)")
      return
    }
    #expect(f.manager.catalog.projects.isEmpty)
    #expect(f.settings.settings.projects[projectID] == nil)
  }

  @Test
  func removeProjectOfUnknownIDLeavesSettingsIntact() async throws {
    let f = Fixture()
    let projectID = f.manager.addProject(name: "p", rootPath: "/repo", gitRoot: "/repo")
    f.settings.mutateProject(projectID) { $0.defaultEditor = "vscode" }

    let params = try JSONValue.encoded(RemoveProjectRequest(id: ProjectID()))
    let outcome = await f.handlers.removeProject(params)

    guard case .failed = outcome else {
      Issue.record("expected failure for an unknown project, got \(outcome)")
      return
    }
    #expect(f.manager.catalog.projects.count == 1)
    #expect(f.settings.settings.projects[projectID] != nil)
  }

  /// Mirrors `HierarchyHandlers.RemoveProjectParams`, which is not visible
  /// from the test target's encode path.
  private struct RemoveProjectRequest: Encodable {
    let id: ProjectID
  }

  @MainActor
  private struct Fixture {
    let manager: HierarchyManager
    let settings: SettingsStore
    let handlers: HierarchyHandlers

    init() {
      let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
      let manager = HierarchyManager(
        catalog: Catalog(projects: []),
        store: CatalogStore(
          fileURL: tmp.appendingPathComponent("codans-rm-project-\(UUID().uuidString).json")
        ),
        runtime: FakeHierarchyRuntime()
      )
      let settings = SettingsStore(
        fileURL: tmp.appendingPathComponent("codans-rm-settings-\(UUID().uuidString).json")
      )
      manager.onProjectRemoved = { [weak settings] projectID in
        settings?.removeProjectSettings(projectID)
      }
      self.manager = manager
      self.settings = settings
      self.handlers = HierarchyHandlers(manager: manager)
    }
  }
}
