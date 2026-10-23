import CodansCore
import Foundation

@testable import Codans

/// Shared seam for `WorkspaceClient` tests: a temporary directory, real git
/// repositories in it, a real `CatalogStore`, and a `HierarchyManager` over
/// `FakeHierarchyRuntime`, wired to `WorkspaceClient.live`. Call `cleanUp()`
/// in a `defer`; nothing outside `base` is touched.
@MainActor
struct WorkspaceClientFixture {
  let base: URL
  let client: WorkspaceClient
  let hierarchy: HierarchyClient
  let manager: HierarchyManager
  let runtime: FakeHierarchyRuntime
  let store: CatalogStore

  /// Canonical (symlink-resolved) path of `base`.
  var basePath: String { base.path(percentEncoded: false) }

  enum Failure: Error {
    case git(String, String)
    case missingRow(String)
  }

  init(
    gitWorktreeClient: GitWorktreeClient = .makeLive(),
    fetchRemoteOnCreate: @escaping @MainActor @Sendable () -> Bool = { true }
  ) throws {
    let raw = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-ws-client-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    base = URL(fileURLWithPath: HierarchyManager.canonicalPath(raw.path), isDirectory: true)
    runtime = FakeHierarchyRuntime()
    store = CatalogStore(fileURL: base.appendingPathComponent("catalog.json"))
    manager = HierarchyManager(catalog: .default, store: store, runtime: runtime)
    hierarchy = HierarchyClient.live(manager: manager)
    client = WorkspaceClient.live(
      hierarchy: hierarchy, gitWorktreeClient: gitWorktreeClient, gitCLI: GitWorktreeCLI(),
      fetchRemoteOnCreate: fetchRemoteOnCreate)
  }

  func cleanUp() {
    // A debounced save still pending would recreate `catalog.json` (and so
    // `base`) after the removal; write it now so nothing is left to fire.
    store.flushPending()
    try? FileManager.default.removeItem(at: base)
  }

  // MARK: Git

  @discardableResult
  func git(_ arguments: [String], cwd: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(bytes: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw Failure.git(arguments.joined(separator: " "), output)
    }
    return output
  }

  /// A repository at `<base>/<name>` with one commit on `main`. Returns its
  /// canonical path.
  @discardableResult
  func makeRepo(named name: String) throws -> String {
    let path = path(name)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"], cwd: path)
    try commit("init", in: path)
    return path
  }

  func commit(_ message: String, in repo: String) throws {
    try git(
      ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", message],
      cwd: repo)
  }

  func tip(_ ref: String, in repo: String) throws -> String {
    try git(["rev-parse", ref], cwd: repo).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A bare repository at `<base>/<name>` holding `source`'s history, wired
  /// up as `source`'s `origin` and fetched, so `origin/<branch>` exists.
  @discardableResult
  func makeOrigin(for source: String, named name: String) throws -> String {
    let bare = path(name)
    try git(["clone", "-q", "--bare", source, bare], cwd: basePath)
    try git(["remote", "add", "origin", bare], cwd: source)
    try git(["fetch", "-q", "origin"], cwd: source)
    return HierarchyManager.canonicalPath(bare)
  }

  /// `git worktree add -b <branch> <path> main` in `source`.
  func addCheckout(of source: String, at path: String, branch: String) throws {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try git(["worktree", "add", "-q", "-b", branch, path, "main"], cwd: source)
  }

  // MARK: Workspace

  /// Writes `manifest` as the group manifest of `rootPath` (created when
  /// missing), registers the Workspace, and reconciles it — the state a
  /// finished `createWorkspace` / `createGroupStream` leaves, built without
  /// them. Checkouts the manifest names must exist first (`addCheckout`).
  @discardableResult
  func registerWorkspace(
    _ manifest: WorkspaceGroupsManifest, rootPath: String, name: String = "ws"
  ) async throws -> ProjectID {
    try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
    try WorkspaceManifestStore.saveGroups(manifest, rootPath: rootPath)
    let projectID = hierarchy.addWorkspaceProject(name, HierarchyManager.canonicalPath(rootPath))
    await hierarchy.reconcileDiscoveredWorktrees(projectID)
    return projectID
  }

  func project(_ id: ProjectID) -> Project? {
    manager.catalog.projects.first { $0.id == id }
  }

  /// The row of `projectID` at `path` (canonical comparison).
  func row(in projectID: ProjectID, at path: String) throws -> Worktree {
    let canonical = HierarchyManager.canonicalPath(path)
    guard
      let row = project(projectID)?.worktrees.first(where: { HierarchyManager.canonicalPath($0.path) == canonical })
    else { throw Failure.missingRow(path) }
    return row
  }

  // MARK: Files

  /// `<base>/<relative>`.
  func path(_ relative: String) -> String {
    (basePath as NSString).appendingPathComponent(relative)
  }

  func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  func isDirectory(_ path: String) -> Bool {
    var flag = ObjCBool(false)
    return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
  }

  /// Drains a creation stream; returns every event and the error it ended
  /// with, if any.
  func collect(
    _ stream: AsyncThrowingStream<WorkspaceCreationEvent, Error>,
    onEvent: (WorkspaceCreationEvent) async -> Void = { _ in }
  ) async -> (events: [WorkspaceCreationEvent], error: Error?) {
    var events: [WorkspaceCreationEvent] = []
    do {
      for try await event in stream {
        events.append(event)
        await onEvent(event)
      }
      return (events, nil)
    } catch {
      return (events, error)
    }
  }
}
