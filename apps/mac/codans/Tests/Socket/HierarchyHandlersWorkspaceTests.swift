import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import Codans

/// Workspace-aware behaviour of the hierarchy IPC handlers: a folder that
/// carries a manifest registers as a workspace, and catalog-only worktree
/// creation is refused on one.
@MainActor
struct HierarchyHandlersWorkspaceTests {
  @Test
  func addProjectDetectsAManifestAndIgnoresTheSentGitRoot() async throws {
    let dir = try Self.makeWorkspaceRoot()
    defer { try? FileManager.default.removeItem(at: dir) }
    let rootPath = dir.path(percentEncoded: false)
    let (handlers, manager) = Self.makeFixture()

    let params = try JSONValue.encoded(
      HierarchyHandlers.AddProjectParams(name: "ws", rootPath: rootPath, gitRoot: "/tmp"))
    let outcome = await handlers.addProject(params)
    guard case .unary = outcome else {
      Issue.record("expected unary, got \(outcome)")
      return
    }
    let canonical = HierarchyManager.canonicalPath(rootPath)
    let project = try #require(manager.catalog.projects.first { $0.rootPath == canonical })
    #expect(project.isWorkspace)
    #expect(project.gitRoot == nil)
    #expect(project.kind == .workspace)
  }

  @Test
  func createWorktreeIsRefusedOnAWorkspace() async throws {
    let (handlers, manager) = Self.makeFixture()
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)

    let params = try JSONValue.encoded(
      HierarchyHandlers.CreateWorktreeParams(
        projectID: projectID, name: "app", path: "/tmp/ws/app", branch: "main",
        reuseExisting: nil))
    let outcome = await handlers.createWorktree(params)
    guard case .failed(let error) = outcome else {
      Issue.record("expected failure, got \(outcome)")
      return
    }
    guard case .invalidParams = error else {
      Issue.record("expected invalidParams, got \(error)")
      return
    }
    #expect(manager.catalog.projects[0].worktrees.count == 1)
  }

  @Test
  func removeWorktreeRefusesTheWorkspaceRoot() async throws {
    let (handlers, manager) = Self.makeFixture()
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    let rootID = manager.catalog.projects[0].worktrees[0].id

    let params = try JSONValue.encoded(
      HierarchyHandlers.RemoveWorktreeParams(id: rootID, projectID: projectID))
    let outcome = await handlers.removeWorktree(params)
    guard case .failed(let error) = outcome else {
      Issue.record("expected failure, got \(outcome)")
      return
    }
    guard case .conflict = error else {
      Issue.record("expected conflict, got \(error)")
      return
    }
    #expect(manager.catalog.projects[0].worktrees.count == 1)
  }

  @Test
  func removeWorktreeRefusesWorkspaceChildrenAndTheirMirrorRows() async throws {
    let (handlers, manager) = Self.makeFixture()
    let workspaceID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    _ = manager.reconcileWorkspaceChildren(
      projectID: workspaceID,
      observations: [
        HierarchyManager.WorkspaceChildObservation(
          name: "app", path: "/tmp/ws/app", exists: true, branch: "feat", sourceGitRoot: "/src/app")
      ])
    let childID = manager.catalog.projects[0].worktrees[1].id
    let sourceID = manager.addProject(name: "app", rootPath: "/src/app", gitRoot: "/src/app")
    let mirrorID = try manager.createWorktree(in: sourceID, name: "feat", path: "/tmp/ws/app", branch: "feat")

    for (id, projectID) in [(childID, workspaceID), (mirrorID, sourceID)] {
      let params = try JSONValue.encoded(
        HierarchyHandlers.RemoveWorktreeParams(id: id, projectID: projectID))
      let outcome = await handlers.removeWorktree(params)
      guard case .failed(let error) = outcome, case .conflict = error else {
        Issue.record("expected conflict, got \(outcome)")
        continue
      }
    }
    #expect(manager.catalog.projects[0].worktrees.count == 2)
    #expect(manager.catalog.projects[1].worktrees.count == 1)
  }

  private static func makeWorkspaceRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-ws-handlers-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try WorkspaceManifestStore.save(
      WorkspaceManifest(title: "ws"), rootPath: dir.path(percentEncoded: false))
    return dir
  }

  private static func makeFixture() -> (HierarchyHandlers, HierarchyManager) {
    let manager = HierarchyManager(
      catalog: Catalog(),
      store: CatalogStore(
        fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent("codans-ws-handlers-\(UUID().uuidString).json")),
      runtime: FakeHierarchyRuntime()
    )
    let handlers = HierarchyHandlers(manager: manager, settingsProvider: { Settings() })
    return (handlers, manager)
  }
}
