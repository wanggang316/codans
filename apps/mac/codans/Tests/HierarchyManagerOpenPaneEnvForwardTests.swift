import Foundation
import Testing
import CodansCore

@testable import Codans

/// Forwarding contract: the `env` argument passed to
/// `HierarchyManager.ensureSurface(for:env:)` reaches the runtime's
/// `ensureSurface` call, augmented with the per-worktree built-in path
/// variables (`CODANS_WORKTREE_PATH` / `CODANS_ROOT_PATH`) that
/// codans injects for every Content. FakeHierarchyRuntime records the env
/// on every call so we can assert the exact map made it across.
///
/// The fixture worktree lives at `/repo` and its Project root at `/tmp`,
/// so every spawned Content sees those two built-ins on top of the
/// caller's env.
@MainActor
struct HierarchyManagerOpenPaneEnvForwardTests {
  /// Built-ins injected for the `setupWorktree` fixture (worktree `/repo`,
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

  private func setupWorktree(_ manager: HierarchyManager) throws -> (ProjectID, WorktreeID) {
    let projectID = manager.addProject(name: "project", rootPath: "/tmp", gitRoot: "/tmp")
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    return (projectID, worktreeID)
  }

  private func newTab(_ manager: HierarchyManager, in worktreeID: WorktreeID, in projectID: ProjectID) throws
    -> TabAddress
  {
    try manager.newTab(
      in: nil, worktreeID: worktreeID, projectID: projectID, content: .terminal(workingDirectory: "/tmp"))
  }

  @Test
  func ensureSurfaceForwardsEnvToRuntime() async throws {
    let (manager, runtime) = makeManager()
    let (projectID, worktreeID) = try setupWorktree(manager)
    let created = try newTab(manager, in: worktreeID, in: projectID)

    try await manager.ensureSurface(for: created.contentID, env: ["A": "1", "B": "2"])

    #expect(runtime.ensureSurfaceCalls.count == 1)
    #expect(runtime.ensureSurfaceCalls[0].env == ["A": "1", "B": "2"].merging(builtins) { _, b in b })
  }

  @Test
  func ensureSurfaceDefaultEnvIsBuiltinsOnly() async throws {
    let (manager, runtime) = makeManager()
    let (projectID, worktreeID) = try setupWorktree(manager)
    let created = try newTab(manager, in: worktreeID, in: projectID)

    try await manager.ensureSurface(for: created.contentID)

    #expect(runtime.ensureSurfaceCalls.count == 1)
    // No caller env, so the recorded env is exactly the injected built-ins.
    #expect(runtime.ensureSurfaceCalls[0].env == builtins)
  }

  @Test
  func splitPaneContentForwardsEnvToRuntime() async throws {
    let (manager, runtime) = makeManager()
    let (projectID, worktreeID) = try setupWorktree(manager)
    let first = try newTab(manager, in: worktreeID, in: projectID)
    try await manager.ensureSurface(for: first.contentID)

    let second = try manager.splitPane(
      from: first.paneID, direction: .right, content: .terminal(workingDirectory: "/tmp"))
    try await manager.ensureSurface(for: second.contentID, env: ["SPLIT_VAR": "42"])

    #expect(runtime.ensureSurfaceCalls.count == 2)
    #expect(
      runtime.ensureSurfaceCalls[1].env == ["SPLIT_VAR": "42"].merging(builtins) { _, b in b }
    )
  }

  @Test
  func ensureSurfaceEmptyEnvStillCarriesBuiltins() async throws {
    let (manager, runtime) = makeManager()
    let (projectID, worktreeID) = try setupWorktree(manager)
    let created = try newTab(manager, in: worktreeID, in: projectID)

    try await manager.ensureSurface(for: created.contentID, env: [:])

    #expect(runtime.ensureSurfaceCalls[0].env == builtins)
  }

  /// The built-in path variables are written last, so a user-defined
  /// `envVars` entry of the same name cannot shadow the real path — the
  /// runtime mirror of the Environment editor's read-only rows.
  @Test
  func builtinPathVarsWinOverUserEnvOfSameName() async throws {
    let (manager, runtime) = makeManager()
    let (projectID, worktreeID) = try setupWorktree(manager)
    let created = try newTab(manager, in: worktreeID, in: projectID)

    try await manager.ensureSurface(
      for: created.contentID,
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
