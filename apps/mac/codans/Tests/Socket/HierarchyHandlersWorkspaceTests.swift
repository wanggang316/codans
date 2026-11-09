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
    guard case .invalidParams(let message, _) = error else {
      Issue.record("expected invalidParams, got \(error)")
      return
    }
    #expect(message.contains("workspace group create"))
    #expect(manager.catalog.projects[0].worktrees.isEmpty)
  }

  @Test
  func describeWorktreeReportsTheGroupAndRole() async throws {
    let (handlers, manager) = Self.makeFixture()
    let workspaceID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    Self.reconcile(manager, workspaceID, member: "/tmp/ws/app")
    let project = manager.catalog.projects[0]
    let group = try #require(project.workspaceGroups.first)
    let sourceID = manager.addProject(name: "app", rootPath: "/src/app", gitRoot: "/src/app")

    var refs: [IPC.WorkspaceGroupRef?] = []
    for id in project.worktrees.map(\.id)
      + (manager.catalog.projects.first { $0.id == sourceID }?.worktrees.map(\.id) ?? [])
    {
      let outcome = await handlers.describeWorktree(try JSONValue.encoded(IPC.DescribeRequest(id: id.raw)))
      guard case .unary(let value) = outcome else {
        Issue.record("expected unary, got \(outcome)")
        return
      }
      refs.append(try value.decoded(as: IPC.WorktreeDescription.self).workspaceGroup)
    }
    #expect(
      Array(refs.prefix(2)) == [
        IPC.WorkspaceGroupRef(id: group.id, name: "existing", role: .groupTerminal),
        IPC.WorkspaceGroupRef(id: group.id, name: "existing", role: .member),
      ])
    #expect(refs.dropFirst(2).allSatisfy { $0 == nil })
  }

  @Test
  func removeWorktreeRefusesTheWorkspaceRoot() async throws {
    let (handlers, manager) = Self.makeFixture()
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    Self.reconcile(manager, projectID, member: nil)
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
    Self.reconcile(manager, workspaceID, member: "/tmp/ws/app")
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

  /// The migrated layout: a group row at the root, plus one member.
  private static func reconcile(_ manager: HierarchyManager, _ projectID: ProjectID, member: String?) {
    var rows = [
      HierarchyManager.WorkspaceRowObservation(name: "existing", path: "/tmp/ws", role: .groupTerminal, exists: true)
    ]
    if let member {
      rows.append(
        HierarchyManager.WorkspaceRowObservation(
          name: "app", path: member, role: .member, exists: true, branch: "feat", sourceGitRoot: "/src/app"))
    }
    manager.reconcileWorkspaceGroups(
      projectID: projectID,
      groups: [
        HierarchyManager.WorkspaceGroupObservation(
          id: WorkspaceGroupID(), name: "existing", kind: .named, deletion: nil, rows: rows)
      ])
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
    let manager = HierarchyManager(catalog: Catalog(), store: .detached(), runtime: FakeHierarchyRuntime())
    let handlers = HierarchyHandlers(manager: manager, settingsProvider: { Settings() })
    return (handlers, manager)
  }
}
