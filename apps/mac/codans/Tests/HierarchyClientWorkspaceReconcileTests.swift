import CodansCore
import Foundation
import Testing

@testable import Codans

/// End-to-end reconcile of a workspace against real git: the root is never
/// probed for a repository (even when nested inside one), and each manifest
/// entry becomes a child row with its live branch and owning repository.
@MainActor
struct HierarchyClientWorkspaceReconcileTests {
  private func makeLiveClient() -> (HierarchyClient, HierarchyManager) {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let manager = HierarchyManager(
      catalog: .default,
      store: CatalogStore(fileURL: tempURL),
      runtime: FakeHierarchyRuntime()
    )
    return (HierarchyClient.live(manager: manager), manager)
  }

  @discardableResult
  private func git(_ arguments: [String], cwd: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(bytes: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw TestError.git(arguments.joined(separator: " "), output)
    }
    return output
  }

  private enum TestError: Error {
    case git(String, String)
  }

  @Test
  func reconcileFillsChildRowsFromGitAndNeverProbesTheRoot() async throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-ws-reconcile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    // An outer repository the workspace root will sit inside — the exact
    // layout where folder-project auto-promotion would adopt it.
    try git(["init", "-q", "-b", "main"], cwd: base)
    try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "outer"], cwd: base)

    // A source repository with one commit so a worktree can be added.
    let source = base.appendingPathComponent("src-app", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"], cwd: source)
    try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], cwd: source)

    // The workspace: root folder + manifest + one child worktree checked out
    // on its own branch.
    let root = base.appendingPathComponent("ws", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let rootPath = root.path(percentEncoded: false)
    let childPath = root.appendingPathComponent("app").path(percentEncoded: false)
    try git(["worktree", "add", "-q", "-b", "feat/x", childPath, "main"], cwd: source)
    try WorkspaceManifestStore.save(
      WorkspaceManifest(
        title: "ws",
        repositories: [
          WorkspaceManifest.Entry(name: "app"),
          WorkspaceManifest.Entry(name: "missing"),
        ]),
      rootPath: rootPath)

    let (client, manager) = makeLiveClient()
    let projectID = client.addWorkspaceProject("ws", HierarchyManager.canonicalPath(rootPath))
    await client.reconcileDiscoveredWorktrees(projectID)

    let project = try #require(manager.catalog.projects.first { $0.id == projectID })
    #expect(project.kind == .workspace)
    #expect(project.gitRoot == nil)
    #expect(project.workspace?.title == "ws")
    let rows = project.worktrees
    #expect(rows.count == 2)
    #expect(rows[0].path == HierarchyManager.canonicalPath(rootPath))
    let child = try #require(rows.first { $0.name == "app" })
    #expect(child.branch == "feat/x")
    #expect(child.sourceGitRoot == HierarchyManager.canonicalPath(source.path(percentEncoded: false)))
    #expect(!child.archived)
    #expect(client.workspaceMembership(childPath)?.projectID == projectID)

    // A second pass is idempotent.
    await client.reconcileDiscoveredWorktrees(projectID)
    #expect(manager.catalog.projects[0].worktrees.count == 2)
  }
}
