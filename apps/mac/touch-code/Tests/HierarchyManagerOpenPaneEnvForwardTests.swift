import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Forwarding contract: the `env` argument passed to
/// `HierarchyManager.openPane` and `splitPane` reaches the runtime's
/// `ensureSurface` call unchanged. FakeHierarchyRuntime records the env on
/// every call so we can assert the exact map made it across.
@MainActor
struct HierarchyManagerOpenPaneEnvForwardTests {
  private func makeManager() -> (HierarchyManager, FakeHierarchyRuntime) {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let runtime = FakeHierarchyRuntime()
    let store = CatalogStore(fileURL: tempURL)
    let manager = HierarchyManager(catalog: .default, store: store, runtime: runtime)
    return (manager, runtime)
  }

  private func setupTab(_ manager: HierarchyManager) throws -> (
    ProjectID, WorktreeID, TabID
  ) {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let tabID = try manager.createTab(
      in: worktreeID, in: projectID, name: nil
    )
    return (projectID, worktreeID, tabID)
  }

  @Test
  func openPaneForwardsEnvToRuntime() throws {
    let (manager, runtime) = makeManager()
    let (projectID, worktreeID, tabID) = try setupTab(manager)

    _ = try manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil,
      env: ["A": "1", "B": "2"]
    )

    #expect(runtime.ensureSurfaceCalls.count == 1)
    #expect(runtime.ensureSurfaceCalls[0].env == ["A": "1", "B": "2"])
  }

  @Test
  func openPaneDefaultEnvIsEmpty() throws {
    let (manager, runtime) = makeManager()
    let (projectID, worktreeID, tabID) = try setupTab(manager)

    _ = try manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    #expect(runtime.ensureSurfaceCalls.count == 1)
    #expect(runtime.ensureSurfaceCalls[0].env.isEmpty)
  }

  @Test
  func splitPaneForwardsEnvToRuntime() throws {
    let (manager, runtime) = makeManager()
    let (projectID, worktreeID, tabID) = try setupTab(manager)
    let firstPaneID = try manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    _ = try manager.splitPane(
      firstPaneID,
      direction: .right,
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil,
      env: ["SPLIT_VAR": "42"]
    )

    #expect(runtime.ensureSurfaceCalls.count == 2)
    #expect(runtime.ensureSurfaceCalls[1].env == ["SPLIT_VAR": "42"])
  }

  @Test
  func openPaneEmptyEnvProducesEmptyRecordedEnv() throws {
    let (manager, runtime) = makeManager()
    let (projectID, worktreeID, tabID) = try setupTab(manager)

    _ = try manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil,
      env: [:]
    )

    #expect(runtime.ensureSurfaceCalls[0].env.isEmpty)
  }
}
