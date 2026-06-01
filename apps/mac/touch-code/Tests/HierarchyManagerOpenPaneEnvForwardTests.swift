import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Forwarding contract: the `env` argument passed to
/// `HierarchyManager.openPane` and `splitPane` reaches the runtime's
/// `ensureSurface` call, augmented with the per-worktree built-in path
/// variables (`TOUCHCODE_WORKTREE_PATH` / `TOUCHCODE_ROOT_PATH`) that
/// touch-code injects for every pane. FakeHierarchyRuntime records the env
/// on every call so we can assert the exact map made it across.
///
/// The fixture worktree lives at `/repo` and its Project root at `/tmp`,
/// so every spawned pane sees those two built-ins on top of the caller's
/// env.
@MainActor
struct HierarchyManagerOpenPaneEnvForwardTests {
  /// Built-ins injected for the `setupTab` fixture (worktree `/repo`,
  /// root `/tmp`). Merged into every expected env below.
  private let builtins: [String: String] = [
    BuiltinEnvVar.worktreePath.key: "/repo",
    BuiltinEnvVar.rootPath.key: "/tmp",
  ]

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
  func openPaneForwardsEnvToRuntime() async throws {
    let (manager, runtime) = makeManager()
    let (projectID, worktreeID, tabID) = try setupTab(manager)

    _ = try await manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil,
      env: ["A": "1", "B": "2"]
    )

    #expect(runtime.ensureSurfaceCalls.count == 1)
    #expect(runtime.ensureSurfaceCalls[0].env == ["A": "1", "B": "2"].merging(builtins) { _, b in b })
  }

  @Test
  func openPaneDefaultEnvIsBuiltinsOnly() async throws {
    let (manager, runtime) = makeManager()
    let (projectID, worktreeID, tabID) = try setupTab(manager)

    _ = try await manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    #expect(runtime.ensureSurfaceCalls.count == 1)
    // No caller env, so the recorded env is exactly the injected built-ins.
    #expect(runtime.ensureSurfaceCalls[0].env == builtins)
  }

  @Test
  func splitPaneForwardsEnvToRuntime() async throws {
    let (manager, runtime) = makeManager()
    let (projectID, worktreeID, tabID) = try setupTab(manager)
    let firstPaneID = try await manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil
    )

    _ = try await manager.splitPane(
      firstPaneID,
      direction: .right,
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil,
      env: ["SPLIT_VAR": "42"]
    )

    #expect(runtime.ensureSurfaceCalls.count == 2)
    #expect(
      runtime.ensureSurfaceCalls[1].env == ["SPLIT_VAR": "42"].merging(builtins) { _, b in b }
    )
  }

  @Test
  func openPaneEmptyEnvStillCarriesBuiltins() async throws {
    let (manager, runtime) = makeManager()
    let (projectID, worktreeID, tabID) = try setupTab(manager)

    _ = try await manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil,
      env: [:]
    )

    #expect(runtime.ensureSurfaceCalls[0].env == builtins)
  }

  /// The built-in path variables are written last, so a user-defined
  /// `envVars` entry of the same name cannot shadow the real path — the
  /// runtime mirror of the Environment editor's read-only rows.
  @Test
  func builtinPathVarsWinOverUserEnvOfSameName() async throws {
    let (manager, runtime) = makeManager()
    let (projectID, worktreeID, tabID) = try setupTab(manager)

    _ = try await manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/tmp",
      initialCommand: nil,
      env: [
        BuiltinEnvVar.worktreePath.key: "/tampered",
        BuiltinEnvVar.rootPath.key: "/tampered",
        "KEEP": "me",
      ]
    )

    let env = runtime.ensureSurfaceCalls[0].env
    #expect(env[BuiltinEnvVar.worktreePath.key] == "/repo")
    #expect(env[BuiltinEnvVar.rootPath.key] == "/tmp")
    #expect(env["KEEP"] == "me")
  }
}
