import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import Codans

/// Wire-to-plan translation of the `workspace.*` handlers: member sources
/// resolve to repository roots, defaults fill in, and client errors map to
/// the IPC error the CLI turns into an exit code. The client is a stub that
/// records the plan; the real orchestration is covered by
/// `WorkspaceClientTests`.
@MainActor
struct WorkspaceHandlersTests {
  private final class Recorder: @unchecked Sendable {
    var plans: [WorkspacePlan] = []
    var added: [(ProjectID, WorkspacePlan.Member)] = []
  }

  private struct Fixture {
    let handlers: WorkspaceHandlers
    let manager: HierarchyManager
    let recorder: Recorder
  }

  private func makeFixture(
    createResult: @escaping @Sendable (WorkspacePlan) throws -> ProjectID = { _ in ProjectID() }
  ) -> Fixture {
    let manager = HierarchyManager(
      catalog: Catalog(),
      store: CatalogStore(
        fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent("codans-ws-handlers-\(UUID().uuidString).json")),
      runtime: FakeHierarchyRuntime()
    )
    let hierarchy = HierarchyClient.live(manager: manager)
    let recorder = Recorder()
    let client = WorkspaceClient(
      create: { plan in
        recorder.plans.append(plan)
        return try createResult(plan)
      },
      add: { projectID, member in
        recorder.added.append((projectID, member))
        return WorktreeID()
      },
      drop: { _, _, _ in nil },
      remove: { _, _ in WorkspaceRemovalOutcome(deletedFolder: false) }
    )
    let handlers = WorkspaceHandlers(hierarchy: hierarchy, workspace: client, gitCLI: GitWorktreeCLI())
    return Fixture(handlers: handlers, manager: manager, recorder: recorder)
  }

  @Test
  func createResolvesProjectMembersAndFillsDefaults() async throws {
    let fx = makeFixture()
    // The stub registers nothing, so `describe` after create needs a real
    // workspace row: register one whose id the stub returns.
    let appID = fx.manager.addProject(name: "app", rootPath: "/src/app", gitRoot: "/src/app")
    let workspaceRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-ws-handlers-root-\(UUID().uuidString)", isDirectory: true)
      .path(percentEncoded: false)
    try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }
    try WorkspaceManifestStore.save(
      WorkspaceManifest(title: "Checkout Flow", repositories: [WorkspaceManifest.Entry(name: "app")]),
      rootPath: workspaceRoot)
    let workspaceID = fx.manager.addProject(name: "ws", rootPath: workspaceRoot, isWorkspace: true)

    let fx2 = makeFixture(createResult: { _ in workspaceID })
    // Share the manager's catalog: rebuild the handler over the same manager.
    let handlers = WorkspaceHandlers(
      hierarchy: HierarchyClient.live(manager: fx.manager),
      workspace: WorkspaceClient(
        create: { plan in
          fx2.recorder.plans.append(plan)
          return workspaceID
        },
        add: { _, _ in WorktreeID() },
        drop: { _, _, _ in nil },
        remove: { _, _ in WorkspaceRemovalOutcome(deletedFolder: false) }),
      gitCLI: GitWorktreeCLI())

    let summary = try await handlers.create(
      IPC.WorkspaceCreateRequest(
        title: "Checkout Flow",
        members: [
          IPC.WorkspaceMemberRequest(projectID: appID),
          IPC.WorkspaceMemberRequest(name: "svc", projectID: appID, branch: "other", useExistingBranch: true),
        ]))

    let plan = try #require(fx2.recorder.plans.first)
    #expect(plan.title == "Checkout Flow")
    #expect(plan.rootPath.hasSuffix("/.codans/workspaces/checkout-flow"))
    #expect(plan.members.count == 2)
    #expect(plan.members[0].name == "app")
    #expect(plan.members[0].sourceGitRoot == "/src/app")
    #expect(plan.members[0].checkout == .newBranch(branch: "checkout-flow", baseRef: nil))
    #expect(plan.members[1].name == "svc")
    #expect(plan.members[1].checkout == .existingBranch("other"))
    #expect(summary.projectID == workspaceID)
    #expect(summary.title == "Checkout Flow")
    #expect(summary.members.map(\.name) == ["app"])
  }

  @Test
  func createRejectsAmbiguousOrRemoteMembers() async throws {
    let fx = makeFixture()
    let dirID = fx.manager.addProject(name: "plain", rootPath: "/tmp/plain", gitRoot: nil)

    await #expect(throws: IPCError.self) {
      try await fx.handlers.create(
        IPC.WorkspaceCreateRequest(
          title: "T", members: [IPC.WorkspaceMemberRequest(projectID: dirID, path: "/x")]))
    }
    await #expect(throws: IPCError.self) {
      try await fx.handlers.create(
        IPC.WorkspaceCreateRequest(title: "T", members: [IPC.WorkspaceMemberRequest(projectID: dirID)]))
    }
    await #expect(throws: IPCError.self) {
      try await fx.handlers.create(
        IPC.WorkspaceCreateRequest(
          title: "T", members: [IPC.WorkspaceMemberRequest(projectID: ProjectID())]))
    }
    #expect(fx.recorder.plans.isEmpty)
  }

  @Test
  func describeRefusesNonWorkspaces() throws {
    let fx = makeFixture()
    let repoID = fx.manager.addProject(name: "repo", rootPath: "/src/repo", gitRoot: "/src/repo")
    #expect(throws: IPCError.self) {
      try fx.handlers.describe(IPC.WorkspaceDescribeRequest(projectID: repoID))
    }
    #expect(throws: IPCError.self) {
      try fx.handlers.describe(IPC.WorkspaceDescribeRequest(projectID: ProjectID()))
    }
  }

  @Test
  func uniqueDefaultRootPathSuffixesTakenFolders() {
    let base = URL(fileURLWithPath: "/tmp/workspaces", isDirectory: true)
    let taken: Set<String> = ["/tmp/workspaces/checkout-flow", "/tmp/workspaces/checkout-flow-2"]
    let path = WorkspaceHandlers.uniqueDefaultRootPath(
      forTitle: "Checkout Flow", base: base, exists: { taken.contains($0) })
    #expect(path == "/tmp/workspaces/checkout-flow-3")
    let free = WorkspaceHandlers.uniqueDefaultRootPath(
      forTitle: "Checkout Flow", base: base, exists: { _ in false })
    #expect(free == "/tmp/workspaces/checkout-flow")
  }

  @Test
  func errorMappingFollowsTheExitCodeContract() {
    #expect(
      WorkspaceHandlers.ipcError(for: WorkspaceError.invalidPlan([.emptyTitle])).code == "invalidParams")
    #expect(
      WorkspaceHandlers.ipcError(for: WorkspaceError.rootAlreadyWorkspace(path: "/x")).code == "conflict")
    #expect(
      WorkspaceHandlers.ipcError(for: WorkspaceError.memberExists(name: "x")).code == "conflict")
    #expect(
      WorkspaceHandlers.ipcError(for: WorkspaceError.notWorkspace(ProjectID())).code == "notFound")
    #expect(
      WorkspaceHandlers.ipcError(for: GitWorktreeError.branchExists("x")).code == "conflict")
    #expect(
      WorkspaceHandlers.ipcError(for: WorkspaceError.memberNotFound(name: "x")).code == "notFound")
    #expect(
      WorkspaceHandlers.ipcError(for: WorkspaceError.cannotDropRoot).code == "conflict")
    #expect(
      WorkspaceHandlers.ipcError(for: IPCError.overloaded) == .overloaded)
  }

  // MARK: - Remote, bare, and remote-tracking members

  @Test
  func createResolvesRemoteAndBareSources() async throws {
    let fx = makeFixture()
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-ws-handlers-src-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    // A bare repository, reached through a path inside it.
    let bare = base.appendingPathComponent("lib.git", isDirectory: true).path(percentEncoded: false)
    try run(["init", "-q", "--bare", bare], cwd: base)
    let sources = base.appendingPathComponent("sources", isDirectory: true).path(percentEncoded: false)

    // The stub returns an unregistered id, so the trailing `describe` fails;
    // the recorded plan is what this test is about.
    _ = try? await fx.handlers.create(
      IPC.WorkspaceCreateRequest(
        title: "Mixed",
        cloneBaseDirectory: sources,
        members: [
          IPC.WorkspaceMemberRequest(path: "\(bare)/refs"),
          IPC.WorkspaceMemberRequest(remoteURL: "git@github.com:org/svc.git", remoteRef: "origin/release"),
          IPC.WorkspaceMemberRequest(
            name: "pinned", remoteURL: "https://example.com/team/tool", cloneDestination: "~/src/tool",
            branch: "mine", remoteRef: "origin/main", resetLocalBranch: true),
        ]))
    let plan = try #require(fx.recorder.plans.first)
    #expect(plan.members.count == 3)
    // Bare: resolved to the bare root, folder name without `.git`.
    #expect(plan.members[0].name == "lib")
    #expect(plan.members[0].source == .local(gitRoot: HierarchyManager.canonicalPath(bare)))
    #expect(plan.members[0].checkout == .newBranch(branch: "mixed", baseRef: nil))
    // Remote with a default destination under the request's clone base.
    #expect(plan.members[1].name == "svc")
    #expect(
      plan.members[1].source
        == .remote(
          url: "git@github.com:org/svc.git",
          cloneDestination: (sources as NSString).appendingPathComponent("svc")))
    // A remote ref defaults the branch to its branch part.
    #expect(
      plan.members[1].checkout
        == .remoteTrackingRef(remoteRef: "origin/release", branch: "release", resetLocal: false))
    // Named destination is tilde-expanded; explicit branch and reset kept.
    #expect(plan.members[2].name == "pinned")
    #expect(
      plan.members[2].source
        == .remote(
          url: "https://example.com/team/tool",
          cloneDestination: ("~/src/tool" as NSString).expandingTildeInPath))
    #expect(
      plan.members[2].checkout
        == .remoteTrackingRef(remoteRef: "origin/main", branch: "mine", resetLocal: true))
  }

  @Test
  func createRejectsConflictingCheckoutFlags() async throws {
    let fx = makeFixture()
    let appID = fx.manager.addProject(name: "app", rootPath: "/src/app", gitRoot: "/src/app")
    // Reset without a tracking ref.
    await #expect(throws: IPCError.self) {
      try await fx.handlers.create(
        IPC.WorkspaceCreateRequest(
          title: "T", members: [IPC.WorkspaceMemberRequest(projectID: appID, resetLocalBranch: true)]))
    }
    // Existing branch and a remote ref on one member.
    await #expect(throws: IPCError.self) {
      try await fx.handlers.create(
        IPC.WorkspaceCreateRequest(
          title: "T",
          members: [
            IPC.WorkspaceMemberRequest(projectID: appID, useExistingBranch: true, remoteRef: "origin/x")
          ]))
    }
    // Request-level exclusivity.
    await #expect(throws: IPCError.self) {
      try await fx.handlers.create(
        IPC.WorkspaceCreateRequest(
          title: "T", useExistingBranch: true, trackRemote: true,
          members: [IPC.WorkspaceMemberRequest(projectID: appID)]))
    }
    // Two sources on one member.
    await #expect(throws: IPCError.self) {
      try await fx.handlers.create(
        IPC.WorkspaceCreateRequest(
          title: "T", members: [IPC.WorkspaceMemberRequest(path: "/x", remoteURL: "https://h/r")]))
    }
    // A malformed remote ref.
    await #expect(throws: IPCError.self) {
      try await fx.handlers.create(
        IPC.WorkspaceCreateRequest(
          title: "T", members: [IPC.WorkspaceMemberRequest(projectID: appID, remoteRef: "nobranch")]))
    }
    #expect(fx.recorder.plans.isEmpty)

    // Request-level trackRemote applies origin/<branch> to every member.
    _ = try? await fx.handlers.create(
      IPC.WorkspaceCreateRequest(
        title: "Track", branch: "feat", trackRemote: true,
        members: [
          IPC.WorkspaceMemberRequest(projectID: appID), IPC.WorkspaceMemberRequest(name: "b", projectID: appID),
        ]))
    let plan = try #require(fx.recorder.plans.first)
    #expect(
      plan.members.map(\.checkout)
        == [
          .remoteTrackingRef(remoteRef: "origin/feat", branch: "feat", resetLocal: false),
          .remoteTrackingRef(remoteRef: "origin/feat", branch: "feat", resetLocal: false),
        ])
  }

  @Test
  func sourceKindTellsLocalBareAndRemoteApart() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-ws-handlers-kind-\(UUID().uuidString)", isDirectory: true)
    let local = base.appendingPathComponent("local", isDirectory: true)
    let bare = base.appendingPathComponent("bare.git", isDirectory: true)
    try FileManager.default.createDirectory(
      at: local.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(WorkspaceHandlers.sourceKind(sourceGitRoot: local.path(percentEncoded: false), remoteURL: nil) == .local)
    #expect(WorkspaceHandlers.sourceKind(sourceGitRoot: bare.path(percentEncoded: false), remoteURL: nil) == .bare)
    #expect(WorkspaceHandlers.sourceKind(sourceGitRoot: local.path(percentEncoded: false), remoteURL: "x") == .remote)
    #expect(WorkspaceHandlers.sourceKind(sourceGitRoot: "/nope", remoteURL: nil) == nil)
  }

  private func run(_ arguments: [String], cwd: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    try process.run()
    process.waitUntilExit()
  }
}
