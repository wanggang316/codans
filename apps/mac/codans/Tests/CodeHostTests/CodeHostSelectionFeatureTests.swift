import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The reducer selects the Code Host implementation per fetch unit (ADR 0004 items 13, 16;
/// ADR 0005). These tests run the real `CodeHostClient.live` dispatch and resolver over one
/// fake implementation per kind, so they observe which implementation answered.
@MainActor
struct CodeHostSelectionFeatureTests {
  /// A Code Host alias for a host neither CLI knows: the unit gets its Merge Requests from
  /// the GitLab implementation at the alias's API host.
  @Test
  func anAliasSelectsTheImplementationForAHostNeitherCLIKnows() async {
    let unit = Self.unit(root: "/repos/app", branch: "feat-open")
    let github = FakeCodeHost(kind: .github, hosts: ["github.com"])
    let gitlab = FakeCodeHost(kind: .gitlab, hosts: ["192.168.2.158:8929"])
    let store = Self.makeStore(
      github: github, gitlab: gitlab,
      remotes: ["/repos/app": RemoteInfo(host: "gl", path: "codans-e2e/app")],
      aliases: LockIsolated([Self.glAlias]))

    await store.send(.projectActivated(unit.projectID, gitRoot: unit.gitRoot, worktreeBranches: unit.pairs))
    await store.receive(\.projectBatchLoaded)

    let repository = CodeHostRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/app")
    #expect(store.state.snapshotsByProject[unit.projectID]?.repository == repository)
    #expect(store.state.snapshots[unit.pairs[0].worktreeID] == FakeCodeHost.snapshot(kind: .gitlab, branch: "feat-open"))
    #expect(gitlab.requests.value == [repository])
    #expect(github.requests.value.isEmpty)
    #expect(store.state.unitsWithoutCodeHost.isEmpty)
  }

  /// No alias and a host neither CLI knows: no fetch, no badge, no error.
  @Test
  func autoWithNoMatchStartsNoFetch() async {
    let unit = Self.unit(root: "/repos/app", branch: "feat-open")
    let github = FakeCodeHost(kind: .github, hosts: ["github.com"])
    let gitlab = FakeCodeHost(kind: .gitlab, hosts: ["192.168.2.158:8929"])
    let store = Self.makeStore(
      github: github, gitlab: gitlab,
      remotes: ["/repos/app": RemoteInfo(host: "gl", path: "codans-e2e/app")])

    await store.send(.projectActivated(unit.projectID, gitRoot: unit.gitRoot, worktreeBranches: unit.pairs))
    await store.receive(.codeHostUnresolved(unit.projectID, worktreeBranches: unit.pairs))

    #expect(github.requests.value.isEmpty)
    #expect(gitlab.requests.value.isEmpty)
    #expect(store.state.unitsWithoutCodeHost == [unit.projectID])
    #expect(store.state.snapshots.isEmpty)
    #expect(store.state.lastError.isEmpty)
    #expect(store.state.lastErrorByProject.isEmpty)
  }

  /// A Workspace with a GitHub member and a GitLab member, both on a branch of the same
  /// name: each member's row shows the Pull Request of its own Code Host.
  @Test
  func aMixedWorkspaceGetsEachUnitsSnapshotsFromItsOwnImplementation() async {
    let workspace = ProjectID()
    let githubUnit = Self.unit(
      id: RootFeature.workspaceFetchGroupID(workspace: workspace, gitRoot: "/repos/gh"),
      root: "/repos/gh", branch: "feature/shared")
    let gitlabUnit = Self.unit(
      id: RootFeature.workspaceFetchGroupID(workspace: workspace, gitRoot: "/repos/gl"),
      root: "/repos/gl", branch: "feature/shared")
    let github = FakeCodeHost(kind: .github, hosts: ["github.com"])
    let gitlab = FakeCodeHost(kind: .gitlab, hosts: ["192.168.2.158:8929"])
    let store = Self.makeStore(
      github: github, gitlab: gitlab,
      remotes: [
        "/repos/gh": RemoteInfo(host: "github.com", path: "wanggang316/codans"),
        "/repos/gl": RemoteInfo(host: "192.168.2.158:8929", path: "codans-e2e/nested/deep-app"),
      ])

    for unit in [githubUnit, gitlabUnit] {
      await store.send(.projectActivated(unit.projectID, gitRoot: unit.gitRoot, worktreeBranches: unit.pairs))
      await store.receive(\.projectBatchLoaded)
    }

    #expect(
      store.state.snapshots[githubUnit.pairs[0].worktreeID]
        == FakeCodeHost.snapshot(kind: .github, branch: "feature/shared"))
    #expect(
      store.state.snapshots[gitlabUnit.pairs[0].worktreeID]
        == FakeCodeHost.snapshot(kind: .gitlab, branch: "feature/shared"))
    #expect(github.requests.value == [CodeHostRepository(kind: .github, host: "github.com", path: "wanggang316/codans")])
    #expect(
      gitlab.requests.value
        == [CodeHostRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/nested/deep-app")])
    #expect(store.state.repository(for: githubUnit.pairs[0].worktreeID)?.kind == .github)
    #expect(store.state.repository(for: gitlabUnit.pairs[0].worktreeID)?.kind == .gitlab)
  }

  /// A changed alias resolves the unit to another repository. When the new
  /// read fails with a non-CLI error, the rows must not keep the old Code Host's Pull
  /// Request: its badge would stay, and write actions would target the old repository.
  @Test
  func aNewRepositoryDropsTheOldSnapshotsEvenWhenItsReadFails() async {
    let unit = Self.unit(root: "/repos/app", branch: "feat-open")
    let worktreeID = unit.pairs[0].worktreeID
    let old = CodeHostRepository(kind: .github, host: "gl", path: "codans-e2e/app")
    var seed = CodeHostFeature.State()
    seed.snapshotsByProject[unit.projectID] = BatchedPullRequests(
      repository: old, byBranch: ["feat-open": FakeCodeHost.snapshot(kind: .github, branch: "feat-open")],
      seenBranches: ["feat-open"], fetchedAt: .distantPast)
    seed.snapshots[worktreeID] = FakeCodeHost.snapshot(kind: .github, branch: "feat-open")
    seed.projectByWorktree[worktreeID] = unit.projectID
    let gitlab = FakeCodeHost(kind: .gitlab, hosts: [], failure: .network("dial tcp: lookup gl"))
    let store = Self.makeStore(
      initialState: seed,
      github: FakeCodeHost(kind: .github, hosts: ["github.com"]), gitlab: gitlab,
      remotes: ["/repos/app": RemoteInfo(host: "gl", path: "codans-e2e/app")],
      aliases: LockIsolated([Self.glAlias]))

    await store.send(.projectRefreshRequested(unit.projectID, gitRoot: unit.gitRoot, worktreeBranches: unit.pairs))
    await store.receive(\.codeHostRepositoryChanged)
    await store.receive(\.projectBatchLoaded)

    #expect(
      gitlab.requests.value == [CodeHostRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/app")])
    #expect(store.state.snapshots[worktreeID] == nil)
    #expect(store.state.snapshotsByProject[unit.projectID] == nil)
    #expect(store.state.pullRequestReference(for: worktreeID) == nil)
    #expect(store.state.lastErrorByProject[unit.projectID] == .network("dial tcp: lookup gl"))
  }

  /// The same repository and a transient failure: the rows keep what they show.
  @Test
  func theSameRepositoryKeepsItsSnapshotsWhenAReadFails() async {
    let unit = Self.unit(root: "/repos/app", branch: "feat-open")
    let worktreeID = unit.pairs[0].worktreeID
    let repository = CodeHostRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/app")
    let snapshot = FakeCodeHost.snapshot(kind: .gitlab, branch: "feat-open")
    var seed = CodeHostFeature.State()
    seed.snapshotsByProject[unit.projectID] = BatchedPullRequests(
      repository: repository, byBranch: ["feat-open": snapshot], seenBranches: ["feat-open"], fetchedAt: .distantPast)
    seed.snapshots[worktreeID] = snapshot
    let store = Self.makeStore(
      initialState: seed,
      github: FakeCodeHost(kind: .github, hosts: ["github.com"]),
      gitlab: FakeCodeHost(kind: .gitlab, hosts: ["192.168.2.158:8929"], failure: .timeout),
      remotes: ["/repos/app": RemoteInfo(host: "192.168.2.158:8929", path: "codans-e2e/app")])

    await store.send(.projectRefreshRequested(unit.projectID, gitRoot: unit.gitRoot, worktreeBranches: unit.pairs))
    await store.receive(\.projectBatchLoaded)

    #expect(store.state.snapshots[worktreeID] == snapshot)
    #expect(store.state.snapshotsByProject[unit.projectID]?.repository == repository)
  }

  /// A unit with no Code Host is skipped by the poll. A change to the alias list sends
  /// `refreshAllRequested` (`CodansApp.observeCodeHostAliases`), and the unit resolves
  /// again at once with the new alias.
  @Test
  func anAliasListChangeReResolvesAUnitThatHadNoCodeHost() async {
    let unit = Self.unit(root: "/repos/app", branch: "feat-open")
    let gitlab = FakeCodeHost(kind: .gitlab, hosts: [])
    let aliases = LockIsolated<[CodeHostAlias]>([])
    let store = Self.makeStore(
      github: FakeCodeHost(kind: .github, hosts: ["github.com"]), gitlab: gitlab,
      remotes: ["/repos/app": RemoteInfo(host: "127.0.0.1:2224", path: "codans-e2e/app", isSSH: true)],
      aliases: aliases)

    await store.send(.pollUnitsChanged([unit], selected: [unit.projectID]))
    await store.send(.projectActivated(unit.projectID, gitRoot: unit.gitRoot, worktreeBranches: unit.pairs))
    await store.receive(.codeHostUnresolved(unit.projectID, worktreeBranches: unit.pairs))
    #expect(store.state.unitsWithoutCodeHost == [unit.projectID])
    #expect(gitlab.requests.value.isEmpty)

    aliases.setValue([CodeHostAlias(remoteHost: "127.0.0.1", kind: .gitlab, apiHost: "192.168.2.158:8929")])
    await store.send(.refreshAllRequested)
    await store.receive(\.projectBatchLoaded)

    let repository = CodeHostRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/app")
    #expect(gitlab.requests.value == [repository])
    #expect(store.state.unitsWithoutCodeHost.isEmpty)
    #expect(
      store.state.snapshots[unit.pairs[0].worktreeID] == FakeCodeHost.snapshot(kind: .gitlab, branch: "feat-open"))
  }

  /// An alias to a GitHub API host that `gh` is not logged in to still resolves; the
  /// real `gh` read then fails with its login prompt, and each row shows the login
  /// message for that host at its badge position (ADR 0005 item 4).
  @Test
  func anAliasToANotLoggedInGitHubHostShowsTheLoginMessageAtEachRow() async {
    let unit = Self.unit(root: "/repos/app", branch: "feat-open")
    let runner = RecordingCommandRunner(outcomes: [
      .exited(
        code: 4, stdout: Data(),
        stderr: Data("To get started with GitHub CLI, please run:  gh auth login\n".utf8),
        stdoutOverflow: false)
    ])
    let github = GitHubCodeHost(
      runner: runner, resolver: CLIExecutableResolver(prober: { URL(fileURLWithPath: "/opt/homebrew/bin/gh") }))
    let store = Self.makeStore(
      github: github, gitlab: FakeCodeHost(kind: .gitlab, hosts: []),
      remotes: ["/repos/app": RemoteInfo(host: "ssh.ghe.example.com", path: "platform/app", isSSH: true)],
      aliases: LockIsolated([
        CodeHostAlias(remoteHost: "ssh.ghe.example.com", kind: .github, apiHost: "ghe.example.com")
      ]))

    await store.send(.projectActivated(unit.projectID, gitRoot: unit.gitRoot, worktreeBranches: unit.pairs))
    await store.receive(\.projectBatchLoaded)

    let error = CodeHostError.notAuthenticated(.github, host: "ghe.example.com")
    #expect(store.state.lastError[unit.pairs[0].worktreeID] == error)
    #expect(store.state.lastErrorByProject[unit.projectID] == error)
    #expect(error.userFacingMessage.contains("gh auth login"))
  }

  // MARK: - Fixtures

  nonisolated private static let glAlias = CodeHostAlias(
    remoteHost: "gl", kind: .gitlab, apiHost: "192.168.2.158:8929")

  private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

  private static func unit(id: ProjectID = ProjectID(), root: String, branch: String) -> CodeHostFeature.FetchUnit {
    CodeHostFeature.FetchUnit(
      projectID: id, gitRoot: URL(fileURLWithPath: root),
      pairs: [.init(worktreeID: WorktreeID(), branch: branch)])
  }

  private static func makeStore(
    initialState: CodeHostFeature.State = .init(),
    github: any CodeHost, gitlab: any CodeHost, remotes: [String: RemoteInfo],
    aliases: LockIsolated<[CodeHostAlias]> = LockIsolated([])
  ) -> TestStoreOf<CodeHostFeature> {
    let store = TestStore(initialState: initialState) {
      CodeHostFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
      $0.continuousClock = ImmediateClock()
      $0[CodeHostClient.self] = .live(github: github, gitlab: gitlab, sshHostName: { $0 })
      $0[CodeHostAliasesClient.self] = CodeHostAliasesClient { aliases.value }
      var git = GitServiceClient.testValue
      git.remoteInfo = { root in
        guard let remote = remotes[root.path] else { throw CodeHostError.remoteInfoUnavailable }
        return remote
      }
      $0[GitServiceClient.self] = git
    }
    store.exhaustivity = .off
    return store
  }
}

/// A `CodeHost` that answers every batched read with one snapshot per branch, tagged with
/// its kind, and records the repositories it was asked about.
nonisolated private final class FakeCodeHost: CodeHost {
  let kind: CodeHostKind
  let hosts: Set<String>
  let failure: CodeHostError?
  let requests = LockIsolated<[CodeHostRepository]>([])

  init(kind: CodeHostKind, hosts: Set<String>, failure: CodeHostError? = nil) {
    self.kind = kind
    self.hosts = hosts
    self.failure = failure
  }

  static func snapshot(kind: CodeHostKind, branch: String) -> PullRequestSnapshot {
    PullRequestSnapshot(
      number: kind == .github ? 1 : 2, title: "\(kind.displayName) \(branch)", state: .open, isDraft: false,
      headRefName: branch, author: "codans-dev", additions: 0, deletions: 0, commitCount: 1,
      url: URL(string: "https://\(kind.publicHost)/\(branch)")!, updatedAt: Date(timeIntervalSince1970: 0),
      mergeState: PullRequestMergeState(status: .clean))
  }

  // The protocol requires `async`; a fake answers at once.
  // swiftlint:disable async_without_await
  func availability() async -> CodeHostAvailability { .unknown }
  func authenticatedHosts() async -> Set<String> { hosts }

  func batchPullRequests(repository: CodeHostRepository, branches: [String]) async throws -> [String: PullRequestSnapshot] {
    requests.withValue { $0.append(repository) }
    if let failure { throw failure }
    return Dictionary(uniqueKeysWithValues: branches.map { ($0, Self.snapshot(kind: kind, branch: $0)) })
  }

  func merge(_ pullRequest: PullRequestReference, strategy: MergeStrategy) async throws {}
  func close(_ pullRequest: PullRequestReference) async throws {}
  func markReady(_ pullRequest: PullRequestReference) async throws {}
  func rerunFailedChecks(_ pullRequest: PullRequestReference) async throws {}
  // swiftlint:enable async_without_await
  func repositoryWebURL(_ repository: CodeHostRepository) -> URL? { nil }
  func pullRequestWebURL(_ pullRequest: PullRequestReference) -> URL? { nil }
}
