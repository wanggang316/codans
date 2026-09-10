import CodansCore
import Foundation
import Testing

@testable import Codans

/// `WorkspaceClient.create` / `.add` against real git repositories in a
/// temporary directory: checkouts land on disk, the manifest is written, the
/// catalog gains the workspace with its child rows, and a failure midway
/// leaves nothing behind.
@MainActor
struct WorkspaceClientTests {
  private struct Fixture {
    let base: URL
    let client: WorkspaceClient
    let hierarchy: HierarchyClient
    let manager: HierarchyManager

    var basePath: String { base.path(percentEncoded: false) }
  }

  private func makeFixture() throws -> Fixture {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-ws-client-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let manager = HierarchyManager(
      catalog: .default,
      store: CatalogStore(
        fileURL: base.appendingPathComponent("catalog.json")),
      runtime: FakeHierarchyRuntime()
    )
    let hierarchy = HierarchyClient.live(manager: manager)
    let client = WorkspaceClient.live(
      hierarchy: hierarchy, gitWorktreeClient: .makeLive(), gitCLI: GitWorktreeCLI())
    return Fixture(base: base, client: client, hierarchy: hierarchy, manager: manager)
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

  /// A repository with one commit on `main`, so worktrees can be added.
  private func makeRepo(named name: String, under base: URL) throws -> String {
    let url = base.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"], cwd: url)
    try git(
      ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"],
      cwd: url)
    return HierarchyManager.canonicalPath(url.path(percentEncoded: false))
  }

  private func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  @Test
  func createMaterializesCheckoutsWritesManifestAndRegistersRows() async throws {
    let fx = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fx.base) }
    let app = try makeRepo(named: "app", under: fx.base)
    let api = try makeRepo(named: "api", under: fx.base)
    let appProjectID = fx.hierarchy.addProject("app", app, app)
    let root = fx.base.appendingPathComponent("ws").path(percentEncoded: false)

    let plan = WorkspacePlan(
      title: "Checkout Flow",
      rootPath: root,
      members: [
        WorkspacePlan.Member(
          name: "app", sourceGitRoot: app, role: "macOS app",
          checkout: .newBranch(branch: "feat/checkout", baseRef: nil)),
        WorkspacePlan.Member(
          name: "api", sourceGitRoot: api, checkout: .newBranch(branch: "feat/checkout", baseRef: "main")),
      ])
    let projectID = try await fx.client.create(plan)

    let canonicalRoot = HierarchyManager.canonicalPath(root)
    #expect(WorkspaceManifestStore.hasManifest(rootPath: canonicalRoot))
    #expect(exists("\(canonicalRoot)/app/.git"))
    #expect(exists("\(canonicalRoot)/api/.git"))
    #expect(try git(["branch", "--list", "feat/checkout"], cwd: URL(fileURLWithPath: app)).contains("feat/checkout"))

    let manifest = try WorkspaceManifestStore.load(rootPath: canonicalRoot)
    #expect(manifest.title == "Checkout Flow")
    #expect(manifest.repositories.map(\.name) == ["app", "api"])
    #expect(manifest.repositories[0].role == "macOS app")
    #expect(manifest.repositories[0].sourceGitRoot == app)
    #expect(manifest.repositories[0].checkoutMode == .newBranch)

    let project = try #require(fx.manager.catalog.projects.first { $0.id == projectID })
    #expect(project.kind == .workspace)
    #expect(project.name == "Checkout Flow")
    #expect(project.rootPath == canonicalRoot)
    #expect(project.worktrees.count == 3)
    let appRow = try #require(project.worktrees.first { $0.name == "app" })
    #expect(appRow.branch == "feat/checkout")
    #expect(appRow.sourceGitRoot == app)

    // The source Project's reconcile ran too: its mirror row is present and
    // resolves to the workspace child.
    let appProject = try #require(fx.manager.catalog.projects.first { $0.id == appProjectID })
    let mirror = appProject.worktrees.first { HierarchyManager.canonicalPath($0.path) == "\(canonicalRoot)/app" }
    #expect(mirror != nil)
    let membership = fx.hierarchy.workspaceMembership("\(canonicalRoot)/app")
    #expect(membership?.projectID == projectID)
    #expect(membership?.worktreeID == appRow.id)
  }

  @Test
  func createRollsBackEverythingWhenAMemberFails() async throws {
    let fx = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fx.base) }
    let app = try makeRepo(named: "app", under: fx.base)
    let api = try makeRepo(named: "api", under: fx.base)
    let root = fx.base.appendingPathComponent("ws").path(percentEncoded: false)

    let plan = WorkspacePlan(
      title: "Broken",
      rootPath: root,
      members: [
        WorkspacePlan.Member(
          name: "app", sourceGitRoot: app, checkout: .newBranch(branch: "feat/broken", baseRef: nil)),
        // No such branch → `git worktree add` fails on the second member.
        WorkspacePlan.Member(name: "api", sourceGitRoot: api, checkout: .existingBranch("does-not-exist")),
      ])
    await #expect(throws: (any Error).self) {
      try await fx.client.create(plan)
    }

    // Root folder gone (this creation made it), first worktree unregistered
    // and its branch deleted, nothing in the catalog.
    #expect(!exists(root))
    #expect(!(try git(["worktree", "list"], cwd: URL(fileURLWithPath: app))).contains("ws/app"))
    #expect(!(try git(["branch", "--list", "feat/broken"], cwd: URL(fileURLWithPath: app))).contains("feat/broken"))
    #expect(fx.manager.catalog.projects.isEmpty)
  }

  @Test
  func createRefusesARootInsideARepositoryOrAlreadyAWorkspace() async throws {
    let fx = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fx.base) }
    let app = try makeRepo(named: "app", under: fx.base)
    let api = try makeRepo(named: "api", under: fx.base)
    let members = [
      WorkspacePlan.Member(name: "app", sourceGitRoot: app, checkout: .newBranch(branch: "f", baseRef: nil)),
      WorkspacePlan.Member(name: "api", sourceGitRoot: api, checkout: .newBranch(branch: "f", baseRef: nil)),
    ]

    // Nested inside a repository (the not-yet-existing folder's parent is `app`).
    let nested = WorkspacePlan(title: "N", rootPath: "\(app)/ws", members: members)
    await #expect(throws: WorkspaceError.self) { try await fx.client.create(nested) }

    // Already a workspace.
    let existing = fx.base.appendingPathComponent("existing").path(percentEncoded: false)
    try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: true)
    try WorkspaceManifestStore.save(WorkspaceManifest(title: "x"), rootPath: existing)
    let taken = WorkspacePlan(title: "E", rootPath: existing, members: members)
    await #expect(throws: WorkspaceError.self) { try await fx.client.create(taken) }
    #expect(fx.manager.catalog.projects.isEmpty)
  }

  @Test
  func addAppendsAMemberAndRefusesDuplicates() async throws {
    let fx = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fx.base) }
    let app = try makeRepo(named: "app", under: fx.base)
    let api = try makeRepo(named: "api", under: fx.base)
    let lib = try makeRepo(named: "lib", under: fx.base)
    // An existing branch that is not checked out anywhere, so `existingBranch`
    // can take it (git refuses a branch another worktree holds).
    try git(["branch", "lib-feat"], cwd: URL(fileURLWithPath: lib))
    let root = fx.base.appendingPathComponent("ws").path(percentEncoded: false)
    let projectID = try await fx.client.create(
      WorkspacePlan(
        title: "T", rootPath: root,
        members: [
          WorkspacePlan.Member(name: "app", sourceGitRoot: app, checkout: .newBranch(branch: "t", baseRef: nil)),
          WorkspacePlan.Member(name: "api", sourceGitRoot: api, checkout: .newBranch(branch: "t", baseRef: nil)),
        ]))

    let worktreeID = try await fx.client.add(
      projectID,
      WorkspacePlan.Member(name: "lib", sourceGitRoot: lib, checkout: .existingBranch("lib-feat")))
    let canonicalRoot = HierarchyManager.canonicalPath(root)
    #expect(exists("\(canonicalRoot)/lib/.git"))
    let manifest = try WorkspaceManifestStore.load(rootPath: canonicalRoot)
    #expect(manifest.repositories.map(\.name) == ["app", "api", "lib"])
    let project = try #require(fx.manager.catalog.projects.first { $0.id == projectID })
    let row = try #require(project.worktrees.first { $0.id == worktreeID })
    #expect(row.name == "lib")
    #expect(row.branch == "lib-feat")

    await #expect(throws: WorkspaceError.self) {
      try await fx.client.add(
        projectID,
        WorkspacePlan.Member(name: "lib", sourceGitRoot: lib, checkout: .existingBranch("lib-feat")))
    }
    #expect(try WorkspaceManifestStore.load(rootPath: canonicalRoot).repositories.count == 3)
  }
}
