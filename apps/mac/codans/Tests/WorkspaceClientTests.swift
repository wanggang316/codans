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

  private func makeFixture(gitWorktreeClient: GitWorktreeClient = .makeLive()) throws -> Fixture {
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
      hierarchy: hierarchy, gitWorktreeClient: gitWorktreeClient, gitCLI: GitWorktreeCLI())
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

  private func isDirectory(_ path: String) -> Bool {
    var flag = ObjCBool(false)
    return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
  }

  private func commit(_ message: String, in repo: String) throws {
    try git(
      ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", message],
      cwd: URL(fileURLWithPath: repo))
  }

  private func tip(_ ref: String, in repo: String) throws -> String {
    try git(["rev-parse", ref], cwd: URL(fileURLWithPath: repo)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A bare repository holding `source`'s history, wired up as `source`'s
  /// `origin` and fetched, so `origin/<branch>` refs exist locally.
  private func makeOrigin(for source: String, named name: String, under base: URL) throws -> String {
    let bare = base.appendingPathComponent(name, isDirectory: true).path(percentEncoded: false)
    try git(["clone", "-q", "--bare", source, bare], cwd: base)
    try git(["remote", "add", "origin", bare], cwd: URL(fileURLWithPath: source))
    try git(["fetch", "-q", "origin"], cwd: URL(fileURLWithPath: source))
    return HierarchyManager.canonicalPath(bare)
  }

  private func collect(
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
  func dropUnregistersTheCheckoutAndCleansManifestAndMirrorRows() async throws {
    let fx = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fx.base) }
    let app = try makeRepo(named: "app", under: fx.base)
    let api = try makeRepo(named: "api", under: fx.base)
    let appProjectID = fx.hierarchy.addProject("app", app, app)
    let root = fx.base.appendingPathComponent("ws").path(percentEncoded: false)
    let projectID = try await fx.client.create(
      WorkspacePlan(
        title: "T", rootPath: root,
        members: [
          WorkspacePlan.Member(name: "app", sourceGitRoot: app, checkout: .newBranch(branch: "t", baseRef: nil)),
          WorkspacePlan.Member(name: "api", sourceGitRoot: api, checkout: .newBranch(branch: "t", baseRef: nil)),
        ]))
    let canonicalRoot = HierarchyManager.canonicalPath(root)
    let appRow = try #require(
      fx.manager.catalog.projects.first { $0.id == projectID }?.worktrees.first { $0.name == "app" })
    #expect(fx.manager.catalog.projects.first { $0.id == appProjectID }?.worktrees.count == 2)

    let warning = try await fx.client.drop(projectID, appRow.id, true)
    #expect(warning == nil)
    #expect(!exists("\(canonicalRoot)/app"))
    #expect(!(try git(["branch", "--list", "t"], cwd: URL(fileURLWithPath: app))).contains("t"))
    let manifest = try WorkspaceManifestStore.load(rootPath: canonicalRoot)
    #expect(manifest.repositories.map(\.name) == ["api"])
    let workspace = try #require(fx.manager.catalog.projects.first { $0.id == projectID })
    #expect(workspace.worktrees.map(\.name).contains("app") == false)
    #expect(workspace.worktrees.count == 2)
    // The source Project's mirror row went with it.
    #expect(fx.manager.catalog.projects.first { $0.id == appProjectID }?.worktrees.count == 1)

    // The root row is never a member.
    let rootID = workspace.worktrees[0].id
    await #expect(throws: WorkspaceError.self) { try await fx.client.drop(projectID, rootID, false) }
  }

  @Test
  func removeEntryOnlyKeepsDiskAndCleanupDeletesCheckoutsAndFolder() async throws {
    let fx = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fx.base) }
    let app = try makeRepo(named: "app", under: fx.base)
    let api = try makeRepo(named: "api", under: fx.base)
    let members = [
      WorkspacePlan.Member(name: "app", sourceGitRoot: app, checkout: .newBranch(branch: "t", baseRef: nil)),
      WorkspacePlan.Member(name: "api", sourceGitRoot: api, checkout: .newBranch(branch: "t", baseRef: nil)),
    ]

    let keep = fx.base.appendingPathComponent("keep").path(percentEncoded: false)
    let keepID = try await fx.client.create(WorkspacePlan(title: "Keep", rootPath: keep, members: members))
    let kept = try await fx.client.remove(keepID, .entryOnly)
    #expect(!kept.deletedFolder)
    #expect(exists("\(HierarchyManager.canonicalPath(keep))/app/.git"))
    #expect(fx.manager.catalog.projects.contains { $0.id == keepID } == false)
    // Its worktrees still exist, so the same branch cannot be reused; drop them
    // through git before the second workspace takes the branch name again.
    try git(["worktree", "remove", "--force", "\(keep)/app"], cwd: URL(fileURLWithPath: app))
    try git(["worktree", "remove", "--force", "\(keep)/api"], cwd: URL(fileURLWithPath: api))
    try git(["branch", "-D", "t"], cwd: URL(fileURLWithPath: app))
    try git(["branch", "-D", "t"], cwd: URL(fileURLWithPath: api))

    let wipe = fx.base.appendingPathComponent("wipe").path(percentEncoded: false)
    let wipeID = try await fx.client.create(WorkspacePlan(title: "Wipe", rootPath: wipe, members: members))
    let outcome = try await fx.client.remove(
      wipeID, WorkspaceCleanup(deleteFiles: true, deleteBranches: true))
    #expect(outcome.deletedFolder)
    #expect(outcome.failures.isEmpty)
    #expect(!exists(wipe))
    #expect(!(try git(["worktree", "list"], cwd: URL(fileURLWithPath: app))).contains("wipe/app"))
    #expect(!(try git(["branch", "--list", "t"], cwd: URL(fileURLWithPath: app))).contains("t"))
    #expect(fx.manager.catalog.projects.contains { $0.id == wipeID } == false)
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

  // MARK: - Remote sources and refused sources

  @Test
  func remoteSourceIsClonedOnceAndCheckedOutAsAWorktree() async throws {
    let fx = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fx.base) }
    let app = try makeRepo(named: "app", under: fx.base)
    let upstream = try makeRepo(named: "upstream", under: fx.base)
    let remote = try makeOrigin(for: upstream, named: "lib-remote.git", under: fx.base)
    let remoteURL = "file://\(remote)"
    let sources = fx.base.appendingPathComponent("sources", isDirectory: true)
    let cloneDestination = sources.appendingPathComponent("lib").path(percentEncoded: false)
    let root = fx.base.appendingPathComponent("ws").path(percentEncoded: false)

    let plan = WorkspacePlan(
      title: "Remote",
      rootPath: root,
      members: [
        WorkspacePlan.Member(name: "app", sourceGitRoot: app, checkout: .newBranch(branch: "feat/r", baseRef: nil)),
        WorkspacePlan.Member(
          name: "lib", source: .remote(url: remoteURL, cloneDestination: cloneDestination),
          checkout: .newBranch(branch: "feat/r", baseRef: nil)),
      ])
    let token = UUID()
    let run = await collect(fx.client.createStream(plan, token))
    #expect(run.error == nil, "\(String(describing: run.error))")

    // The clone is a full repository; the member is a linked worktree of it.
    let canonicalClone = HierarchyManager.canonicalPath(cloneDestination)
    let canonicalRoot = HierarchyManager.canonicalPath(root)
    #expect(isDirectory("\(canonicalClone)/.git"))
    #expect(exists("\(canonicalRoot)/lib/.git") && !isDirectory("\(canonicalRoot)/lib/.git"))
    #expect(try git(["remote", "get-url", "origin"], cwd: URL(fileURLWithPath: canonicalClone)).contains(remote))
    // A new branch in a fresh clone starts from the remote's default branch.
    #expect(try tip("feat/r", in: canonicalClone) == tip("origin/main", in: canonicalClone))
    let manifest = try WorkspaceManifestStore.load(rootPath: canonicalRoot)
    let lib = try #require(manifest.repositories.first { $0.name == "lib" })
    #expect(lib.remoteURL == remoteURL)
    #expect(lib.sourceGitRoot == canonicalClone)
    #expect(lib.checkoutMode == .newBranch)
    #expect(lib.baseRef == "origin/main")
    let project = try #require(fx.manager.catalog.projects.first { $0.isWorkspace })
    #expect(project.worktrees.first { $0.name == "lib" }?.sourceGitRoot == canonicalClone)

    // Event order: app straight to checkout, lib cloned first, then the tail.
    let phases = run.events.compactMap { event -> String? in
      switch event {
      case .memberStarted(let name, let phase): return "\(name):\(phase)"
      case .memberFinished(let name): return "\(name):done"
      case .manifestWritten: return "manifest"
      case .registered: return "registered"
      case .progressLine, .memberFailed, .rollingBack, .rolledBack: return nil
      }
    }
    #expect(
      phases == [
        "app:checkingOut", "app:done", "lib:cloning", "lib:checkingOut", "lib:done", "manifest", "registered",
      ])

    // A second workspace naming the same remote and destination reuses the
    // clone instead of cloning again.
    let root2 = fx.base.appendingPathComponent("ws2").path(percentEncoded: false)
    _ = try await fx.client.create(
      WorkspacePlan(
        title: "Remote 2", rootPath: root2,
        members: [
          WorkspacePlan.Member(name: "app", sourceGitRoot: app, checkout: .newBranch(branch: "feat/r2", baseRef: nil)),
          WorkspacePlan.Member(
            name: "lib", source: .remote(url: remoteURL, cloneDestination: cloneDestination),
            checkout: .newBranch(branch: "feat/r2", baseRef: nil)),
        ]))
    let worktrees = try git(["worktree", "list"], cwd: URL(fileURLWithPath: canonicalClone))
    #expect(worktrees.contains("ws/lib") && worktrees.contains("ws2/lib"))

    // A destination holding some other repository is refused, not overwritten.
    let root3 = fx.base.appendingPathComponent("ws3").path(percentEncoded: false)
    await #expect(throws: WorkspaceError.cloneDestinationTaken(path: app, remoteURL: remoteURL)) {
      try await fx.client.create(
        WorkspacePlan(
          title: "Remote 3", rootPath: root3,
          members: [
            WorkspacePlan.Member(name: "up", sourceGitRoot: upstream, checkout: .newBranch(branch: "x", baseRef: nil)),
            WorkspacePlan.Member(
              name: "lib", source: .remote(url: remoteURL, cloneDestination: app),
              checkout: .newBranch(branch: "x", baseRef: nil)),
          ]))
    }
    #expect(!exists(root3))
  }

  @Test
  func preflightSkipsAnUnfilledBranchAndWordsFindingsForTheForm() async throws {
    let fx = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fx.base) }
    let app = try makeRepo(named: "app", under: fx.base)
    let lib = try makeRepo(named: "lib", under: fx.base)
    let preflight = await fx.client.preflight(
      WorkspacePlan(
        title: "T", rootPath: "\(app)/inside",
        members: [
          WorkspacePlan.Member(name: "app", sourceGitRoot: app, checkout: .newBranch(branch: "", baseRef: nil)),
          WorkspacePlan.Member(name: "lib", sourceGitRoot: lib, checkout: .newBranch(branch: "a..b", baseRef: nil)),
        ]))
    #expect(preflight.memberIssues["app"] == nil)
    #expect(
      preflight.memberIssues["lib"] == [
        .init(kind: .invalidBranchName, message: "\u{201C}a..b\u{201D} is not a valid branch name.")
      ])
    #expect(preflight.rootIssues.map(\.kind) == [.rootInsideRepository])
    #expect(preflight.rootIssues.first?.message.hasPrefix("This location is inside the repository at ") == true)
  }

  @Test
  func bareRepositoryIsRefusedAsASource() async throws {
    let fx = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fx.base) }
    let app = try makeRepo(named: "app", under: fx.base)
    let seed = try makeRepo(named: "seed", under: fx.base)
    let bare = fx.base.appendingPathComponent("lib.git", isDirectory: true).path(percentEncoded: false)
    try git(["clone", "-q", "--bare", seed, bare], cwd: fx.base)
    let root = fx.base.appendingPathComponent("ws").path(percentEncoded: false)
    let plan = WorkspacePlan(
      title: "Bare", rootPath: root,
      members: [
        WorkspacePlan.Member(name: "app", sourceGitRoot: app, checkout: .newBranch(branch: "b", baseRef: nil)),
        // Named through a path inside the bare directory, as a user might.
        WorkspacePlan.Member(
          name: "lib", sourceGitRoot: "\(bare)/refs", checkout: .newBranch(branch: "b", baseRef: nil)),
      ])

    let preflight = await fx.client.preflight(plan)
    #expect(preflight.memberIssues["lib"]?.map(\.kind) == [.sourceNotRepository])
    await #expect(throws: WorkspaceError.bareRepository(path: HierarchyManager.canonicalPath(bare))) {
      _ = try await fx.client.create(plan)
    }
    #expect(!exists(root))
    #expect(fx.manager.catalog.projects.allSatisfy { !$0.isWorkspace })
  }

  // MARK: - Remote-tracking refs

  @Test
  func remoteTrackingRefCreatesKeepsOrResetsTheLocalBranch() async throws {
    let fx = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fx.base) }
    let src = try makeRepo(named: "src", under: fx.base)
    try git(["branch", "fresh"], cwd: URL(fileURLWithPath: src))
    try git(["branch", "keep"], cwd: URL(fileURLWithPath: src))
    try git(["branch", "reset"], cwd: URL(fileURLWithPath: src))
    let origin = try makeOrigin(for: src, named: "src-origin.git", under: fx.base)
    // The remote has all three; locally `fresh` is gone and the other two
    // are ahead by one commit.
    try git(["branch", "-D", "fresh"], cwd: URL(fileURLWithPath: src))
    for branch in ["keep", "reset"] {
      try git(["switch", "-q", branch], cwd: URL(fileURLWithPath: src))
      try commit("local-only \(branch)", in: src)
    }
    try git(["switch", "-q", "main"], cwd: URL(fileURLWithPath: src))
    let keepTip = try tip("keep", in: src)
    let resetTip = try tip("reset", in: src)
    let remoteResetTip = try tip("origin/reset", in: src)
    #expect(resetTip != remoteResetTip)
    _ = origin

    let root = fx.base.appendingPathComponent("ws").path(percentEncoded: false)
    let projectID = try await fx.client.create(
      WorkspacePlan(
        title: "Tracking", rootPath: root,
        members: [
          WorkspacePlan.Member(
            name: "fresh", sourceGitRoot: src,
            checkout: .remoteTrackingRef(remoteRef: "origin/fresh", branch: "fresh", resetLocal: false)),
          WorkspacePlan.Member(
            name: "keep", sourceGitRoot: src,
            checkout: .remoteTrackingRef(remoteRef: "origin/keep", branch: "keep", resetLocal: false)),
          WorkspacePlan.Member(
            name: "reset", sourceGitRoot: src,
            checkout: .remoteTrackingRef(remoteRef: "origin/reset", branch: "reset", resetLocal: true)),
        ]))

    // fresh: created from the remote and tracking it.
    #expect(try tip("fresh", in: src) == tip("origin/fresh", in: src))
    #expect(
      try git(["rev-parse", "--abbrev-ref", "fresh@{upstream}"], cwd: URL(fileURLWithPath: src)).contains(
        "origin/fresh"))
    // keep: the local branch is checked out untouched.
    #expect(try tip("keep", in: src) == keepTip)
    // reset: the local branch now points at the remote tip.
    #expect(try tip("reset", in: src) == remoteResetTip)

    let canonicalRoot = HierarchyManager.canonicalPath(root)
    let manifest = try WorkspaceManifestStore.load(rootPath: canonicalRoot)
    #expect(manifest.repositories.map(\.checkoutMode) == [.remoteTrackingRef, .existingBranch, .remoteTrackingRef])
    #expect(manifest.repositories[0].baseRef == "origin/fresh")
    #expect(manifest.repositories[1].baseRef == nil)
    let project = try #require(fx.manager.catalog.projects.first { $0.id == projectID })
    #expect(project.worktrees.filter { $0.path != project.rootPath }.map(\.branch) == ["fresh", "keep", "reset"])
  }

  @Test
  func rollbackRestoresAResetBranchAndDeletesACreatedOne() async throws {
    let fx = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fx.base) }
    let src = try makeRepo(named: "src", under: fx.base)
    try git(["branch", "reset"], cwd: URL(fileURLWithPath: src))
    try git(["branch", "fresh"], cwd: URL(fileURLWithPath: src))
    _ = try makeOrigin(for: src, named: "src-origin.git", under: fx.base)
    try git(["branch", "-D", "fresh"], cwd: URL(fileURLWithPath: src))
    try git(["switch", "-q", "reset"], cwd: URL(fileURLWithPath: src))
    try commit("local-only", in: src)
    try git(["switch", "-q", "main"], cwd: URL(fileURLWithPath: src))
    let resetTip = try tip("reset", in: src)
    let other = try makeRepo(named: "other", under: fx.base)
    let root = fx.base.appendingPathComponent("ws").path(percentEncoded: false)

    let run = await collect(
      fx.client.createStream(
        WorkspacePlan(
          title: "Broken", rootPath: root,
          members: [
            WorkspacePlan.Member(
              name: "fresh", sourceGitRoot: src,
              checkout: .remoteTrackingRef(remoteRef: "origin/fresh", branch: "fresh", resetLocal: false)),
            WorkspacePlan.Member(
              name: "reset", sourceGitRoot: src,
              checkout: .remoteTrackingRef(remoteRef: "origin/reset", branch: "reset", resetLocal: true)),
            WorkspacePlan.Member(name: "other", sourceGitRoot: other, checkout: .existingBranch("does-not-exist")),
          ]), UUID()))
    #expect(run.error != nil)
    #expect(run.events.contains { if case .memberFailed("other", _) = $0 { return true } else { return false } })
    #expect(run.events.contains(.rollingBack))
    #expect(run.events.contains(.rolledBack(failures: [])))

    #expect(!exists(root))
    #expect(try tip("reset", in: src) == resetTip)
    #expect(!(try git(["branch", "--list", "fresh"], cwd: URL(fileURLWithPath: src))).contains("fresh"))
    #expect(!(try git(["worktree", "list"], cwd: URL(fileURLWithPath: src))).contains("ws/"))
    #expect(fx.manager.catalog.projects.isEmpty)
  }

  @Test
  func fetchFailureRollsBackTheWholeCreation() async throws {
    let fx = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fx.base) }
    let app = try makeRepo(named: "app", under: fx.base)
    let src = try makeRepo(named: "src", under: fx.base)
    let missing = fx.base.appendingPathComponent("gone.git").path(percentEncoded: false)
    try git(["remote", "add", "origin", missing], cwd: URL(fileURLWithPath: src))
    let root = fx.base.appendingPathComponent("ws").path(percentEncoded: false)

    await #expect(throws: GitWorktreeError.self) {
      try await fx.client.create(
        WorkspacePlan(
          title: "Fetch", rootPath: root,
          members: [
            WorkspacePlan.Member(name: "app", sourceGitRoot: app, checkout: .newBranch(branch: "f", baseRef: nil)),
            WorkspacePlan.Member(
              name: "src", sourceGitRoot: src, checkout: .newBranch(branch: "f", baseRef: "origin/main")),
          ]))
    }
    #expect(!exists(root))
    #expect(!(try git(["branch", "--list", "f"], cwd: URL(fileURLWithPath: app))).contains("f"))
    #expect(fx.manager.catalog.projects.isEmpty)
  }

  // MARK: - Cancellation

  @Test
  func cancelDuringCloneRollsBackAndLeavesNothing() async throws {
    // The live clone of a local remote is too quick to interrupt, so hold
    // the clone stream open until the run is cancelled.
    var slow = GitWorktreeClient.makeLive()
    let liveClone = slow.cloneStream
    slow.cloneStream = { url, destination in
      AsyncThrowingStream { continuation in
        let task = Task {
          do {
            try await Task.sleep(for: .seconds(30))
            for try await line in liveClone(url, destination) { continuation.yield(line) }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
    let fx = try makeFixture(gitWorktreeClient: slow)
    defer { try? FileManager.default.removeItem(at: fx.base) }
    let app = try makeRepo(named: "app", under: fx.base)
    let upstream = try makeRepo(named: "upstream", under: fx.base)
    let remote = try makeOrigin(for: upstream, named: "lib-remote.git", under: fx.base)
    let cloneDestination = fx.base.appendingPathComponent("sources/lib").path(percentEncoded: false)
    let root = fx.base.appendingPathComponent("ws").path(percentEncoded: false)
    let token = UUID()
    let client = fx.client

    let run = await collect(
      client.createStream(
        WorkspacePlan(
          title: "Cancel", rootPath: root,
          members: [
            WorkspacePlan.Member(name: "app", sourceGitRoot: app, checkout: .newBranch(branch: "c", baseRef: nil)),
            WorkspacePlan.Member(
              name: "lib", source: .remote(url: "file://\(remote)", cloneDestination: cloneDestination),
              checkout: .newBranch(branch: "c", baseRef: nil)),
          ]), token)
    ) { event in
      if case .memberStarted("lib", .cloning) = event {
        await client.cancelCreation(token)
      }
    }
    #expect(run.error as? WorkspaceError == .cancelled)
    #expect(run.events.contains(.memberFinished(name: "app")))
    #expect(run.events.contains(.rollingBack))
    #expect(run.events.contains(.rolledBack(failures: [])))
    #expect(!run.events.contains(.manifestWritten))

    #expect(!exists(cloneDestination))
    #expect(!exists(root))
    #expect(!(try git(["worktree", "list"], cwd: URL(fileURLWithPath: app))).contains("ws/app"))
    #expect(!(try git(["branch", "--list", "c"], cwd: URL(fileURLWithPath: app))).contains("c"))
    #expect(fx.manager.catalog.projects.isEmpty)
  }
}
