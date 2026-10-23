import CodansCore
import Foundation
import Testing

@testable import Codans

/// Named group creation through `WorkspaceClient` on real git: defaults per
/// source project, preflight, the all-or-nothing checkout phase, and the
/// setup phase that runs only after every checkout exists.
@MainActor
struct WorkspaceGroupCreationTests {
  private struct Setup {
    let projectID: ProjectID
    let root: String
    let app: String
    let lib: String
  }

  /// A Workspace over two repositories, `app` and `lib`, each with an
  /// ignored file in its main checkout.
  private func makeWorkspace(_ fx: WorkspaceClientFixture, client: WorkspaceClient? = nil) async throws -> Setup {
    let app = try fx.makeRepo(named: "src/app")
    let lib = try fx.makeRepo(named: "src/lib")
    for repo in [app, lib] {
      try "secret.env\n".write(toFile: "\(repo)/.gitignore", atomically: true, encoding: .utf8)
      try fx.git(["add", ".gitignore"], cwd: repo)
      try fx.commit("ignore", in: repo)
      try "token".write(toFile: "\(repo)/secret.env", atomically: true, encoding: .utf8)
    }
    let root = fx.path("ws")
    let projectID = try await (client ?? fx.client).createWorkspace(
      WorkspaceSourcePlan(
        title: "ws", rootPath: root,
        sources: [.init(location: .local(path: app)), .init(location: .local(path: lib))]))
    return Setup(projectID: projectID, root: root, app: app, lib: lib)
  }

  private func plan(_ setup: Setup, name: String = "fix", branch: String = "fix/login") -> WorkspaceGroupPlan {
    WorkspaceGroupPlan(
      projectID: setup.projectID, name: name, branch: branch,
      members: [
        MemberCreationOptions(sourceGitRoot: setup.app, name: "app", fetch: false),
        MemberCreationOptions(sourceGitRoot: setup.lib, name: "lib", fetch: false),
      ])
  }

  private func localBranches(_ fx: WorkspaceClientFixture, _ repo: String) throws -> Set<String> {
    Set(
      try fx.git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], cwd: repo)
        .split(separator: "\n").map(String.init))
  }

  private func worktreeCount(_ fx: WorkspaceClientFixture, _ repo: String) throws -> Int {
    try fx.git(["worktree", "list", "--porcelain"], cwd: repo)
      .split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count
  }

  // MARK: Defaults

  @Test
  func defaultsComeFromEachSourceProjectsSettings() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let app = try fx.makeRepo(named: "src/app")
    let lib = try fx.makeRepo(named: "src/lib")
    try fx.git(["branch", "release"], cwd: app)
    let appProjectID = fx.hierarchy.addProject("app", app, app)
    var settings = Settings.default
    settings.worktree.copyIgnoredOnCreate = false
    settings.worktree.copyUntrackedOnCreate = false
    settings.projects[appProjectID] = ProjectSettings(
      git: GitProjectSettings(
        worktreeBaseRef: "release", copyIgnoredOnWorktreeCreate: true, fetchRemoteOnWorktreeCreate: false,
        createScript: ScriptDefinition(command: "make setup")))
    let client = WorkspaceClient.live(
      hierarchy: fx.hierarchy, gitWorktreeClient: .makeLive(), gitCLI: GitWorktreeCLI(),
      fetchRemoteOnCreate: { true }, settings: { settings })
    let projectID = try await client.createWorkspace(
      WorkspaceSourcePlan(
        title: "ws", rootPath: fx.path("ws"),
        sources: [.init(location: .local(path: app)), .init(location: .local(path: lib))]))

    let defaults = await client.groupCreationDefaults(projectID)

    #expect(
      defaults == [
        MemberCreationOptions(
          sourceGitRoot: app, name: "app", baseRef: "release", fetch: false, copyIgnored: true,
          copyUntracked: false, setupCommand: "make setup"),
        // Not a registered Project: global settings, git's default base.
        MemberCreationOptions(
          sourceGitRoot: lib, name: "lib", baseRef: nil, fetch: true, copyIgnored: false, copyUntracked: false),
      ])
  }

  // MARK: Preflight

  @Test
  func anExistingLocalBranchBlocksCreationAndNamesTheProject() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let setup = try await makeWorkspace(fx)
    try fx.git(["branch", "fix/login"], cwd: setup.lib)

    let preflight = await fx.client.preflightGroup(plan(setup))

    #expect(preflight.memberIssues["lib"]?.map(\.kind) == [.localBranchExists])
    #expect(preflight.memberIssues["app"] == nil)
    let (_, error) = await fx.collect(fx.client.createGroupStream(plan(setup), UUID()))
    #expect(error as? WorkspaceError == .groupPreflightFailed(preflight))
    #expect(!fx.exists("\(setup.root)/fix"))
    #expect(try !localBranches(fx, setup.app).contains("fix/login"))
  }

  @Test
  func preflightRejectsTheReservedAndDuplicateGroupNames() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let setup = try await makeWorkspace(fx)

    let reserved = await fx.client.preflightGroup(plan(setup, name: "default"))
    #expect(reserved.groupIssues.map(\.kind).contains(.reservedGroupName))

    _ = try await fx.client.createGroup(plan(setup, name: "fix", branch: "fix/one"))
    let duplicate = await fx.client.preflightGroup(plan(setup, name: "fix", branch: "fix/two"))
    #expect(duplicate.groupIssues.map(\.kind).contains(.duplicateGroupName))
  }

  // MARK: Creation

  @Test
  func createsEveryMemberOnOneBranchWithItsOwnOptions() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let setup = try await makeWorkspace(fx)
    try fx.git(["branch", "release"], cwd: setup.app)
    try fx.commit("after release", in: setup.app)
    var groupPlan = plan(setup)
    groupPlan.members[0].baseRef = "release"
    groupPlan.members[0].copyIgnored = true
    let profile = UUID()
    groupPlan.members[1].agentProfileID = profile

    let result = try await fx.client.createGroup(groupPlan)

    let appCheckout = "\(setup.root)/fix/app"
    let libCheckout = "\(setup.root)/fix/lib"
    #expect(try fx.git(["branch", "--show-current"], cwd: appCheckout) == "fix/login\n")
    #expect(try fx.git(["branch", "--show-current"], cwd: libCheckout) == "fix/login\n")
    #expect(try fx.tip("HEAD", in: appCheckout) == fx.tip("release", in: setup.app))
    #expect(try fx.tip("HEAD", in: libCheckout) == fx.tip("main", in: setup.lib))
    #expect(fx.exists("\(appCheckout)/secret.env"))
    #expect(!fx.exists("\(libCheckout)/secret.env"))
    // Source main checkouts stay where they were.
    #expect(try fx.git(["branch", "--show-current"], cwd: setup.app) == "main\n")

    let manifest = try WorkspaceManifestStore.loadGroups(rootPath: setup.root)
    let group = try #require(manifest.groups.first { $0.name == "fix" })
    #expect(group.id == result.groupID)
    #expect(group.kind == .named)
    #expect(group.path == "fix")
    #expect(group.branch == "fix/login")
    #expect(group.members.map(\.path) == ["fix/app", "fix/lib"])
    #expect(group.members.map(\.sourceGitRoot) == [setup.app, setup.lib])
    #expect(group.members.allSatisfy { $0.createdBranch == true && $0.branch == "fix/login" })
    #expect(group.members.first?.baseRef == "release")

    let groupRow = try fx.row(in: setup.projectID, at: "\(setup.root)/fix")
    #expect(groupRow.id == result.groupWorktreeID)
    #expect(groupRow.workspaceSlot == WorkspaceSlot(groupID: group.id, role: .groupTerminal))
    let appRow = try fx.row(in: setup.projectID, at: appCheckout)
    let libRow = try fx.row(in: setup.projectID, at: libCheckout)
    #expect(appRow.workspaceSlot == WorkspaceSlot(groupID: group.id, role: .member))
    #expect(
      result.members == [
        .init(name: "app", worktreeID: appRow.id),
        .init(name: "lib", worktreeID: libRow.id, agentProfileID: profile),
      ])
    #expect(result.setupFailures.isEmpty)
  }

  @Test
  func aCheckoutFailureRollsBackEveryEarlierMember() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let setup = try await makeWorkspace(fx)
    let client = WorkspaceClient.live(
      hierarchy: fx.hierarchy,
      gitWorktreeClient: failingCheckout(of: setup.lib),
      gitCLI: GitWorktreeCLI())

    let (events, error) = await fx.collect(client.createGroupStream(plan(setup), UUID()))

    #expect(error != nil)
    #expect(events.contains(.memberFinished(name: "app")))
    #expect(events.contains { if case .memberFailed(name: "lib", _) = $0 { true } else { false } })
    #expect(events.last == .rolledBack(failures: []))
    #expect(!fx.exists("\(setup.root)/fix"))
    #expect(try !localBranches(fx, setup.app).contains("fix/login"))
    #expect(try worktreeCount(fx, setup.app) == 1)
    let manifest = try WorkspaceManifestStore.loadGroups(rootPath: setup.root)
    #expect(!manifest.groups.contains { $0.name == "fix" })
    #expect(try #require(fx.project(setup.projectID)).workspaceGroups.count == 1)
  }

  @Test
  func rollbackReportsWhatItCouldNotUndoWithPathAndReason() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let setup = try await makeWorkspace(fx)
    let appCheckout = "\(setup.root)/fix/app"
    var git = failingCheckout(of: setup.lib)
    git.removeWorktree = { _, path in
      throw GitWorktreeError.commandFailed(command: "git worktree remove", stderr: "locked by test at \(path.path)")
    }
    let client = WorkspaceClient.live(hierarchy: fx.hierarchy, gitWorktreeClient: git, gitCLI: GitWorktreeCLI())

    let (events, error) = await fx.collect(client.createGroupStream(plan(setup), UUID()))

    #expect(error != nil)
    guard case .rolledBack(let failures) = events.last else {
      Issue.record("expected rolledBack last, got \(String(describing: events.last))")
      return
    }
    #expect(failures.contains { $0.contains(appCheckout) && $0.contains("locked by test") })
    // The group directory holds the checkout git still lists, so it stays
    // and is reported instead of being deleted out from under git.
    let groupDirectory = "\(setup.root)/fix"
    #expect(fx.isDirectory(appCheckout))
    #expect(failures.contains { $0.hasPrefix("\(groupDirectory):") && $0.contains(appCheckout) })
    #expect(try worktreeCount(fx, setup.app) == 2)
  }

  // MARK: Setup

  @Test
  func setupRunsAfterEveryCheckoutAndAFailureKeepsTheGroup() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let setup = try await makeWorkspace(fx)
    var groupPlan = plan(setup)
    // `app` is set up first; it can see `lib` only when every checkout
    // exists before any setup starts.
    groupPlan.members[0].setupCommand = "test -e ../lib/.git && touch saw-lib"
    groupPlan.members[1].setupCommand = "exit 3"

    let (events, error) = await fx.collect(fx.client.createGroupStream(groupPlan, UUID()))

    #expect(error == nil)
    #expect(fx.exists("\(setup.root)/fix/app/saw-lib"))
    let registered = try #require(
      events.firstIndex { if case .groupRegistered = $0 { true } else { false } })
    let firstSetup = try #require(events.firstIndex(of: .setupStarted(name: "app")))
    #expect(registered < firstSetup)
    #expect(events.contains(.setupFailed(name: "lib", reason: "setup script exited with code 3")))
    guard case .groupCreated(let result) = events.last else {
      Issue.record("expected groupCreated last")
      return
    }
    #expect(result.setupFailures == [.init(name: "lib", reason: "setup script exited with code 3")])
    let manifest = try WorkspaceManifestStore.loadGroups(rootPath: setup.root)
    #expect(manifest.groups.contains { $0.name == "fix" })
    #expect(fx.isDirectory("\(setup.root)/fix/lib"))
  }

  /// Live git whose checkout of `repo` fails after reporting progress.
  private func failingCheckout(of repo: String) -> GitWorktreeClient {
    var git = GitWorktreeClient.makeLive()
    let live = git.createWorktreeStream
    git.createWorktreeStream = { spec in
      guard HierarchyManager.canonicalPath(spec.repoRoot.path(percentEncoded: false)) == repo else {
        return live(spec)
      }
      return AsyncThrowingStream {
        $0.yield(.progressLine("checking out"))
        $0.finish(throwing: GitWorktreeError.commandFailed(command: "wt sw", stderr: "injected failure"))
      }
    }
    return git
  }
}
