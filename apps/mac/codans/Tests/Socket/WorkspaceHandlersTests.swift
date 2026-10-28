import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import Codans

/// Contract of the `workspace.*` handlers: wire-to-client translation, the
/// summaries they return, and the IPC error each client error becomes. The
/// client is a stub that records what it was asked; the workspace is a real
/// manifest in a temporary folder with rows from the reconcile.
@MainActor
struct WorkspaceHandlersTests {
  private final class Recorder: @unchecked Sendable {
    var sourcePlans: [WorkspaceSourcePlan] = []
    var added: [(ProjectID, WorkspaceSource)] = []
    var removedSources: [String] = []
    var removals: [WorkspaceRemovalRequest] = []
    var groupPlans: [WorkspaceGroupPlan] = []
    var checked: [WorkspaceGroupID] = []
    var deletions: [(WorkspaceGroupID, GroupDeletionRequest)] = []
  }

  /// A workspace with source `app`, the `default` group, and the named
  /// group `feat` with member `app` on `feat/x`.
  @MainActor
  private struct Fixture {
    let manager: HierarchyManager
    let hierarchy: HierarchyClient
    let recorder = Recorder()
    let root: String
    let projectID: ProjectID
    let defaultID = WorkspaceGroupID()
    let featID = WorkspaceGroupID()
    let source = "/src/app"

    var featPath: String { (root as NSString).appendingPathComponent("feat") }
    var memberPath: String { (root as NSString).appendingPathComponent("feat/app") }
    var defaultPath: String { (root as NSString).appendingPathComponent("default") }

    func handlers(_ client: WorkspaceClient) -> WorkspaceHandlers {
      WorkspaceHandlers(hierarchy: hierarchy, workspace: client, gitCLI: GitWorktreeCLI())
    }

    func row(_ path: String) throws -> Worktree {
      try #require(manager.catalog.projects.first { $0.id == projectID }?.worktrees.first { $0.path == path })
    }

    func check(uncommitted: Int = 0, failure: String? = nil) throws -> GroupDeletionCheck {
      GroupDeletionCheck(
        projectID: projectID, groupID: featID, groupName: "feat",
        members: [
          .init(
            name: "app", worktreeID: try row(memberPath).id, path: memberPath, branch: "feat/x",
            uncommittedCount: uncommitted, unpushedCount: 1, checkFailure: failure)
        ],
        busyContentIDs: [ContentID()], extraEntries: ["notes.txt"])
    }

    func cleanUp() {
      try? FileManager.default.removeItem(atPath: root)
    }
  }

  private func makeFixture() throws -> Fixture {
    let manager = HierarchyManager(catalog: Catalog(), store: .detached(), runtime: FakeHierarchyRuntime())
    let root = HierarchyManager.canonicalPath(
      FileManager.default.temporaryDirectory
        .appendingPathComponent("codans-ws-handlers-\(UUID().uuidString)", isDirectory: true).path)
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let projectID = manager.addProject(name: "Checkout", rootPath: root, isWorkspace: true)
    let fixture = Fixture(
      manager: manager, hierarchy: HierarchyClient.live(manager: manager), root: root, projectID: projectID)
    try WorkspaceManifestStore.saveGroups(
      WorkspaceGroupsManifest(
        title: "Checkout",
        projects: [.init(name: "app", sourceGitRoot: fixture.source)],
        groups: [
          .init(id: fixture.defaultID, name: "default", kind: .default, path: "default"),
          .init(
            id: fixture.featID, name: "feat", kind: .named, path: "feat", branch: "feat/x",
            members: [
              .init(
                id: WorkspaceMemberID(), name: "app", path: "feat/app", sourceGitRoot: fixture.source,
                branch: "feat/x", createdBranch: true)
            ]),
        ]),
      rootPath: root)
    manager.reconcileWorkspaceGroups(
      projectID: projectID,
      groups: [
        .init(
          id: fixture.defaultID, name: "default", kind: .default, deletion: nil,
          rows: [
            .init(name: "default", path: fixture.defaultPath, role: .groupTerminal, exists: true),
            .init(
              name: "app", path: fixture.source, role: .reference, exists: true, branch: "main",
              sourceGitRoot: fixture.source),
          ]),
        .init(
          id: fixture.featID, name: "feat", kind: .named, deletion: nil,
          rows: [
            .init(name: "feat", path: fixture.featPath, role: .groupTerminal, exists: true),
            .init(
              name: "app", path: fixture.memberPath, role: .member, exists: true, branch: "feat/x",
              sourceGitRoot: fixture.source),
          ]),
      ])
    return fixture
  }

  // MARK: - workspace.create / add / drop

  @Test
  func createSendsSourcesOnlyAndReturnsTheSummary() async throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let recorder = fx.recorder
    let projectID = fx.projectID
    let handlers = fx.handlers(
      WorkspaceClient(createWorkspace: { plan in
        recorder.sourcePlans.append(plan)
        return projectID
      }))
    let appID = fx.manager.addProject(name: "app", rootPath: "/src/app", gitRoot: "/src/app")

    let summary = try await handlers.create(
      IPC.WorkspaceCreateRequest(
        title: "Checkout Flow",
        projects: [
          IPC.WorkspaceSourceRequest(projectID: appID),
          IPC.WorkspaceSourceRequest(name: "svc", remoteURL: "git@github.com:org/svc.git", cloneDestination: "~/s"),
        ]))

    let plan = try #require(recorder.sourcePlans.first)
    #expect(plan.title == "Checkout Flow")
    #expect(plan.rootPath.hasSuffix("/.codans/workspaces/checkout-flow"))
    #expect(
      plan.sources == [
        WorkspaceSource(location: .local(path: "/src/app")),
        WorkspaceSource(
          location: .remote(
            url: "git@github.com:org/svc.git", cloneDestination: ("~/s" as NSString).expandingTildeInPath),
          name: "svc"),
      ])
    #expect(summary.projectID == projectID)
    #expect(summary.projects.map(\.name) == ["app"])
    #expect(summary.groups.map(\.name) == ["default", "feat"])
  }

  @Test
  func retiredBranchFieldsFailWithAClearMessage() throws {
    let legacy = [
      #"{"title":"T","branch":"feat/x","projects":[]}"#,
      #"{"title":"T","members":[{"path":"/x"}]}"#,
      #"{"title":"T","projects":[{"path":"/x","useExistingBranch":true}]}"#,
    ]
    for json in legacy {
      #expect {
        _ = try JSONDecoder().decode(IPC.WorkspaceCreateRequest.self, from: Data(json.utf8))
      } throws: { error in
        guard case .invalidParams(let message, _) = error as? IPCError else { return false }
        return message.contains("workspace group create")
      }
    }
    let projectID = ProjectID()
    let add = #"{"projectID":\#(try Self.json(projectID)),"member":{"path":"/x","branch":"b"}}"#
    #expect(throws: IPCError.self) {
      _ = try JSONDecoder().decode(IPC.WorkspaceAddRequest.self, from: Data(add.utf8))
    }
    let drop = #"{"projectID":\#(try Self.json(projectID)),"project":"app","keepBranch":true}"#
    #expect(throws: IPCError.self) {
      _ = try JSONDecoder().decode(IPC.WorkspaceDropRequest.self, from: Data(drop.utf8))
    }
    // The current shape still decodes.
    let current = #"{"title":"T","projects":[{"path":"/x"}]}"#
    let decoded = try JSONDecoder().decode(IPC.WorkspaceCreateRequest.self, from: Data(current.utf8))
    #expect(decoded.projects == [IPC.WorkspaceSourceRequest(path: "/x")])
  }

  @Test
  func createRejectsAmbiguousOrUnknownSources() async throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let recorder = fx.recorder
    let handlers = fx.handlers(
      WorkspaceClient(createWorkspace: { plan in
        recorder.sourcePlans.append(plan)
        return ProjectID()
      }))
    let dirID = fx.manager.addProject(name: "plain", rootPath: "/tmp/plain", gitRoot: nil)
    for source in [
      IPC.WorkspaceSourceRequest(projectID: dirID, path: "/x"),
      IPC.WorkspaceSourceRequest(projectID: dirID),
      IPC.WorkspaceSourceRequest(projectID: ProjectID()),
    ] {
      await #expect(throws: IPCError.self) {
        try await handlers.create(IPC.WorkspaceCreateRequest(title: "T", projects: [source]))
      }
    }
    #expect(recorder.sourcePlans.isEmpty)
  }

  @Test
  func addReturnsTheNewReference() async throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let recorder = fx.recorder
    let referenceID = try fx.row(fx.source).id
    let handlers = fx.handlers(
      WorkspaceClient(addSource: { projectID, source in
        recorder.added.append((projectID, source))
        return referenceID
      }))
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-ws-handlers-src-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let lib = base.appendingPathComponent("lib", isDirectory: true).path(percentEncoded: false)
    try run(["init", "-q", lib], cwd: base)
    try FileManager.default.createDirectory(atPath: "\(lib)/docs", withIntermediateDirectories: true)

    let added = try await handlers.add(
      IPC.WorkspaceAddRequest(projectID: fx.projectID, project: IPC.WorkspaceSourceRequest(path: "\(lib)/docs")))

    #expect(recorder.added.map(\.1) == [WorkspaceSource(location: .local(path: HierarchyManager.canonicalPath(lib)))])
    #expect(added.name == "app")
    #expect(added.worktreeID == referenceID)
    #expect(added.branch == "main")
  }

  @Test
  func dropRemovesASourceByNameOrPathAndRefusesGroupMembers() async throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let recorder = fx.recorder
    let handlers = fx.handlers(
      WorkspaceClient(removeSource: { _, sourceGitRoot in recorder.removedSources.append(sourceGitRoot) }))

    let byName = try await handlers.drop(IPC.WorkspaceDropRequest(projectID: fx.projectID, project: "app"))
    _ = try await handlers.drop(IPC.WorkspaceDropRequest(projectID: fx.projectID, project: fx.source))
    #expect(byName == IPC.WorkspaceDropResponse(name: "app", path: fx.source))
    #expect(recorder.removedSources == [fx.source, fx.source])

    await #expect {
      _ = try await handlers.drop(IPC.WorkspaceDropRequest(projectID: fx.projectID, project: fx.memberPath))
    } throws: { error in
      guard case .conflict(let reason) = error as? IPCError else { return false }
      return reason.contains("delete its group")
    }
    await #expect {
      _ = try await handlers.drop(IPC.WorkspaceDropRequest(projectID: fx.projectID, project: "nope"))
    } throws: { error in
      guard case .notFound = error as? IPCError else { return false }
      return true
    }
    #expect(recorder.removedSources.count == 2)
  }

  // MARK: - workspace.remove / describe

  @Test
  func removeForwardsTheModeAndReportsUnacknowledgedRisks() async throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let recorder = fx.recorder
    let check = try fx.check(uncommitted: 2)
    let handlers = fx.handlers(
      WorkspaceClient(removeWorkspace: { _, request in
        recorder.removals.append(request)
        if case .deleteOwnedFiles(let deletion) = request, !deletion.acknowledgeRisks {
          throw WorkspaceError.risksNotAcknowledged(check)
        }
        return WorkspaceRemovalOutcome(deletedFolder: true)
      }))

    let response = try await handlers.remove(
      IPC.WorkspaceRemoveRequest(
        projectID: fx.projectID, cleanup: WorkspaceCleanup(deleteFiles: true, deleteBranches: true),
        acknowledgeRisks: true))
    #expect(response.outcome.deletedFolder)
    _ = try await handlers.remove(IPC.WorkspaceRemoveRequest(projectID: fx.projectID))

    await #expect {
      _ = try await handlers.remove(
        IPC.WorkspaceRemoveRequest(projectID: fx.projectID, cleanup: WorkspaceCleanup(deleteFiles: true)))
    } throws: { error in
      guard case .conflict(let reason) = error as? IPCError else { return false }
      return reason.contains("app: 2 uncommitted files") && reason.contains("notes.txt")
    }
    #expect(
      recorder.removals == [
        .deleteOwnedFiles(GroupDeletionRequest(deleteBranches: true, acknowledgeRisks: true)),
        .sidebarOnly,
        .deleteOwnedFiles(GroupDeletionRequest(deleteBranches: false, acknowledgeRisks: false)),
      ])
  }

  @Test
  func describeReportsProjectsAndGroupsWithRoles() throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let summary = try fx.handlers(WorkspaceClient()).describe(IPC.WorkspaceDescribeRequest(projectID: fx.projectID))

    #expect(summary.title == "Checkout")
    #expect(
      summary.projects == [
        IPC.WorkspaceProjectSummary(
          name: "app", sourceGitRoot: fx.source, sourceKind: .local, branch: "main",
          worktreeID: try fx.row(fx.source).id)
      ])
    let defaultGroup = try #require(summary.groups.first)
    #expect(defaultGroup.isDefault && defaultGroup.id == fx.defaultID && defaultGroup.path == fx.defaultPath)
    #expect(defaultGroup.worktreeID == (try fx.row(fx.defaultPath).id))
    #expect(defaultGroup.members.map(\.role) == [.reference])
    #expect(defaultGroup.members.map(\.path) == [fx.source])
    let feat = try #require(summary.groups.last)
    #expect(!feat.isDefault && feat.name == "feat" && feat.path == fx.featPath)
    #expect(
      feat.members == [
        IPC.WorkspaceGroupMemberSummary(
          name: "app", path: fx.memberPath, branch: "feat/x", sourceGitRoot: fx.source, role: .member,
          worktreeID: try fx.row(fx.memberPath).id)
      ])
  }

  @Test
  func describeRefusesNonWorkspaces() throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let handlers = fx.handlers(WorkspaceClient())
    let repoID = fx.manager.addProject(name: "repo", rootPath: "/src/repo", gitRoot: "/src/repo")
    #expect(throws: IPCError.self) { try handlers.describe(IPC.WorkspaceDescribeRequest(projectID: repoID)) }
    #expect(throws: IPCError.self) { try handlers.describe(IPC.WorkspaceDescribeRequest(projectID: ProjectID())) }
  }

  // MARK: - workspace.createGroup

  @Test
  func createGroupAppliesOverridesOnTheProjectDefaults() async throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let recorder = fx.recorder
    let result = GroupCreationResult(
      projectID: fx.projectID, groupID: fx.featID, groupWorktreeID: try fx.row(fx.featPath).id,
      members: [.init(name: "app", worktreeID: try fx.row(fx.memberPath).id)],
      setupFailures: [.init(name: "app", reason: "exit 1")])
    let source = fx.source
    let handlers = fx.handlers(
      WorkspaceClient(
        groupCreationDefaults: { _ in
          [MemberCreationOptions(sourceGitRoot: source, name: "app", baseRef: "origin/main", setupCommand: "make")]
        },
        createGroupStream: { plan, _ in
          recorder.groupPlans.append(plan)
          return AsyncThrowingStream { continuation in
            continuation.yield(.groupCreated(result))
            continuation.finish()
          }
        }))

    let response = try await handlers.createGroup(
      IPC.WorkspaceGroupCreateRequest(
        projectID: fx.projectID, name: " feat ", branch: "feat/x", baseRefs: ["app": "origin/dev"], fetch: false,
        copyIgnored: true))

    #expect(
      recorder.groupPlans == [
        WorkspaceGroupPlan(
          projectID: fx.projectID, name: "feat", branch: "feat/x",
          members: [
            MemberCreationOptions(
              sourceGitRoot: source, name: "app", baseRef: "origin/dev", fetch: false, copyIgnored: true,
              setupCommand: "make")
          ])
      ])
    #expect(response.group.id == fx.featID)
    #expect(response.group.members.map(\.worktreeID) == [try fx.row(fx.memberPath).id])
    #expect(response.setupFailures == [.init(name: "app", reason: "exit 1")])
  }

  @Test
  func createGroupRefusesUnknownBaseProjectsAndMapsPreflightFailures() async throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let recorder = fx.recorder
    let source = fx.source
    var preflight = WorkspacePreflight()
    preflight.memberIssues["app"] = [.init(kind: .localBranchExists, message: "app already has branch feat/x")]
    let failure = preflight
    let handlers = fx.handlers(
      WorkspaceClient(
        groupCreationDefaults: { _ in [MemberCreationOptions(sourceGitRoot: source, name: "app")] },
        createGroupStream: { plan, _ in
          recorder.groupPlans.append(plan)
          return AsyncThrowingStream { $0.finish(throwing: WorkspaceError.groupPreflightFailed(failure)) }
        }))

    await #expect {
      _ = try await handlers.createGroup(
        IPC.WorkspaceGroupCreateRequest(
          projectID: fx.projectID, name: "g", branch: "b", baseRefs: ["web": "origin/main"]))
    } throws: { error in
      guard case .invalidParams(let message, _) = error as? IPCError else { return false }
      return message.contains("web")
    }
    #expect(recorder.groupPlans.isEmpty)

    await #expect {
      _ = try await handlers.createGroup(
        IPC.WorkspaceGroupCreateRequest(projectID: fx.projectID, name: "g", branch: "feat/x"))
    } throws: { error in
      guard case .conflict(let reason) = error as? IPCError else { return false }
      return reason.contains("app already has branch feat/x")
    }
  }

  // MARK: - workspace.checkGroupDeletion / deleteGroup

  @Test
  func checkGroupDeletionResolvesTheGroupByNameOrID() async throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let recorder = fx.recorder
    let check = try fx.check()
    let handlers = fx.handlers(
      WorkspaceClient(checkGroupDeletion: { _, groupID in
        recorder.checked.append(groupID)
        return check
      }))

    #expect(
      try await handlers.checkGroupDeletion(IPC.WorkspaceGroupRequest(projectID: fx.projectID, group: "feat")) == check)
    _ = try await handlers.checkGroupDeletion(
      IPC.WorkspaceGroupRequest(projectID: fx.projectID, group: fx.featID.raw.uuidString))
    #expect(recorder.checked == [fx.featID, fx.featID])

    await #expect {
      _ = try await handlers.checkGroupDeletion(IPC.WorkspaceGroupRequest(projectID: fx.projectID, group: "default"))
    } throws: { error in
      guard case .conflict = error as? IPCError else { return false }
      return true
    }
    await #expect {
      _ = try await handlers.checkGroupDeletion(IPC.WorkspaceGroupRequest(projectID: fx.projectID, group: "nope"))
    } throws: { error in
      guard case .notFound = error as? IPCError else { return false }
      return true
    }
    #expect(recorder.checked.count == 2)
  }

  @Test
  func deleteGroupReturnsConflictWithTheRisksUntilAcknowledged() async throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let recorder = fx.recorder
    let risky = try fx.check(uncommitted: 3)
    let failed = try fx.check(failure: "git status failed")
    let handlers = fx.handlers(
      WorkspaceClient(deleteGroup: { _, groupID, request in
        recorder.deletions.append((groupID, request))
        if !request.deleteBranches { throw WorkspaceError.checkFailed(failed) }
        guard request.acknowledgeRisks else { throw WorkspaceError.risksNotAcknowledged(risky) }
        return GroupDeletionOutcome(deletedGroup: true, removedMembers: ["app"], deletedBranches: ["feat/x"])
      }))

    await #expect {
      _ = try await handlers.deleteGroup(
        IPC.WorkspaceGroupDeleteRequest(projectID: fx.projectID, group: "feat", deleteBranches: true))
    } throws: { error in
      guard case .conflict(let reason) = error as? IPCError else { return false }
      return reason.contains("app: 3 uncommitted files") && reason.contains("app: 1 unpushed commit")
        && reason.contains("1 running terminal") && reason.contains("notes.txt")
    }
    await #expect {
      _ = try await handlers.deleteGroup(IPC.WorkspaceGroupDeleteRequest(projectID: fx.projectID, group: "feat"))
    } throws: { error in
      guard case .conflict(let reason) = error as? IPCError else { return false }
      return reason.contains("git status failed")
    }
    let response = try await handlers.deleteGroup(
      IPC.WorkspaceGroupDeleteRequest(
        projectID: fx.projectID, group: "feat", deleteBranches: true, acknowledgeRisks: true))

    #expect(response.groupID == fx.featID && response.groupName == "feat")
    #expect(response.outcome.deletedBranches == ["feat/x"])
    #expect(recorder.deletions.last?.1 == GroupDeletionRequest(deleteBranches: true, acknowledgeRisks: true))
  }

  // MARK: - Live client

  /// The handlers over the real client and real git: create, add a group,
  /// refuse an unacknowledged delete, delete, and keep the sources.
  @Test
  func groupLifecycleRunsThroughTheLiveClient() async throws {
    let fx = try WorkspaceClientFixture(fetchRemoteOnCreate: { false })
    defer { fx.cleanUp() }
    let app = try fx.makeRepo(named: "app")
    let api = try fx.makeRepo(named: "api")
    let handlers = WorkspaceHandlers(hierarchy: fx.hierarchy, workspace: fx.client, gitCLI: GitWorktreeCLI())

    let summary = try await handlers.create(
      IPC.WorkspaceCreateRequest(
        title: "Flow", rootPath: fx.path("ws"),
        projects: [IPC.WorkspaceSourceRequest(path: app), IPC.WorkspaceSourceRequest(path: api)]))
    #expect(summary.projects.map(\.name) == ["app", "api"])
    #expect(summary.groups.map(\.isDefault) == [true])

    let created = try await handlers.createGroup(
      IPC.WorkspaceGroupCreateRequest(projectID: summary.projectID, name: "feat", branch: "feat/x"))
    #expect(created.group.members.map(\.name) == ["app", "api"])
    #expect(created.group.members.allSatisfy { $0.worktreeID != nil && $0.branch == "feat/x" })
    #expect(created.group.worktreeID != nil)

    let appCheckout = try #require(created.group.members.first).path
    try "x".write(
      toFile: (appCheckout as NSString).appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
    await #expect {
      _ = try await handlers.deleteGroup(IPC.WorkspaceGroupDeleteRequest(projectID: summary.projectID, group: "feat"))
    } throws: { error in
      guard case .conflict(let reason) = error as? IPCError else { return false }
      return reason.contains("app: 1 uncommitted file")
    }
    #expect(fx.exists(appCheckout))

    let deleted = try await handlers.deleteGroup(
      IPC.WorkspaceGroupDeleteRequest(
        projectID: summary.projectID, group: "feat", deleteBranches: true, acknowledgeRisks: true))
    #expect(deleted.outcome.deletedGroup)
    #expect(
      try handlers.describe(IPC.WorkspaceDescribeRequest(projectID: summary.projectID)).groups.map(\.name) == [
        "default"
      ])
    #expect(!fx.exists(appCheckout))
    #expect(fx.exists(app) && fx.exists(api))
  }

  // MARK: - Helpers

  @Test
  func uniqueDefaultRootPathSuffixesTakenFolders() {
    let base = URL(fileURLWithPath: "/tmp/workspaces", isDirectory: true)
    let taken: Set<String> = ["/tmp/workspaces/checkout-flow", "/tmp/workspaces/checkout-flow-2"]
    let path = WorkspaceHandlers.uniqueDefaultRootPath(
      forTitle: "Checkout Flow", base: base, exists: { taken.contains($0) })
    #expect(path == "/tmp/workspaces/checkout-flow-3")
  }

  @Test
  func errorMappingFollowsTheExitCodeContract() {
    #expect(WorkspaceHandlers.ipcError(for: WorkspaceError.invalidSourcePlan(reason: "x")).code == "invalidParams")
    #expect(WorkspaceHandlers.ipcError(for: WorkspaceError.rootAlreadyWorkspace(path: "/x")).code == "conflict")
    #expect(WorkspaceHandlers.ipcError(for: WorkspaceError.sourceExists(path: "/x")).code == "conflict")
    #expect(WorkspaceHandlers.ipcError(for: WorkspaceError.cannotDeleteDefault).code == "conflict")
    #expect(WorkspaceHandlers.ipcError(for: WorkspaceError.notWorkspace(ProjectID())).code == "notFound")
    #expect(WorkspaceHandlers.ipcError(for: WorkspaceError.groupNotFound(WorkspaceGroupID())).code == "notFound")
    #expect(WorkspaceHandlers.ipcError(for: GitWorktreeError.branchExists("x")).code == "conflict")
    #expect(WorkspaceHandlers.ipcError(for: IPCError.overloaded) == .overloaded)
  }

  private static func json(_ id: ProjectID) throws -> String {
    String(bytes: try JSONEncoder().encode(id), encoding: .utf8) ?? ""
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
