import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The reducer selects the Git Platform implementation per fetch unit (ADR 0004 items 13, 16;
/// ADR 0005). These tests run the real `GitPlatformClient.live` dispatch and resolver over one
/// fake implementation per kind, so they observe which implementation answered.
@MainActor
struct GitPlatformSelectionFeatureTests {
  /// A Git Platform alias for a host neither CLI knows: the unit gets its Merge Requests from
  /// the GitLab implementation at the alias's API host.
  @Test
  func anAliasSelectsTheImplementationForAHostNeitherCLIKnows() async {
    let unit = Self.unit(root: "/repos/app", branch: "feat-open")
    let github = FakeGitPlatform(kind: .github, hosts: ["github.com"])
    let gitlab = FakeGitPlatform(kind: .gitlab, hosts: ["192.168.2.158:8929"])
    let store = Self.makeStore(
      github: github, gitlab: gitlab,
      remotes: ["/repos/app": RemoteInfo(host: "gl", path: "codans-e2e/app")],
      aliases: LockIsolated([Self.glAlias]))

    await store.send(.projectActivated(unit.projectID, gitRoot: unit.gitRoot, worktreeBranches: unit.pairs))
    await store.receive(\.projectBatchLoaded)

    let repository = GitPlatformRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/app")
    #expect(store.state.snapshotsByProject[unit.projectID]?.repository == repository)
    #expect(store.state.snapshots[unit.pairs[0].worktreeID] == FakeGitPlatform.snapshot(kind: .gitlab, branch: "feat-open"))
    #expect(gitlab.requests.value == [repository])
    #expect(github.requests.value.isEmpty)
    #expect(store.state.unitsWithoutGitPlatform.isEmpty)
  }

  /// No alias and a host neither CLI knows: no fetch, no badge, no error.
  @Test
  func autoWithNoMatchStartsNoFetch() async {
    let unit = Self.unit(root: "/repos/app", branch: "feat-open")
    let github = FakeGitPlatform(kind: .github, hosts: ["github.com"])
    let gitlab = FakeGitPlatform(kind: .gitlab, hosts: ["192.168.2.158:8929"])
    let store = Self.makeStore(
      github: github, gitlab: gitlab,
      remotes: ["/repos/app": RemoteInfo(host: "gl", path: "codans-e2e/app")])

    await store.send(.projectActivated(unit.projectID, gitRoot: unit.gitRoot, worktreeBranches: unit.pairs))
    await store.receive(.gitPlatformUnresolved(unit.projectID, worktreeBranches: unit.pairs))

    #expect(github.requests.value.isEmpty)
    #expect(gitlab.requests.value.isEmpty)
    #expect(store.state.unitsWithoutGitPlatform == [unit.projectID])
    #expect(store.state.snapshots.isEmpty)
    #expect(store.state.lastError.isEmpty)
    #expect(store.state.lastErrorByProject.isEmpty)
  }

  /// A Workspace with a GitHub member and a GitLab member, both on a branch of the same
  /// name: each member's row shows the Pull Request of its own Git Platform.
  @Test
  func aMixedWorkspaceGetsEachUnitsSnapshotsFromItsOwnImplementation() async {
    let workspace = ProjectID()
    let githubUnit = Self.unit(
      id: RootFeature.workspaceFetchGroupID(workspace: workspace, gitRoot: "/repos/gh"),
      root: "/repos/gh", branch: "feature/shared")
    let gitlabUnit = Self.unit(
      id: RootFeature.workspaceFetchGroupID(workspace: workspace, gitRoot: "/repos/gl"),
      root: "/repos/gl", branch: "feature/shared")
    let github = FakeGitPlatform(kind: .github, hosts: ["github.com"])
    let gitlab = FakeGitPlatform(kind: .gitlab, hosts: ["192.168.2.158:8929"])
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
        == FakeGitPlatform.snapshot(kind: .github, branch: "feature/shared"))
    #expect(
      store.state.snapshots[gitlabUnit.pairs[0].worktreeID]
        == FakeGitPlatform.snapshot(kind: .gitlab, branch: "feature/shared"))
    #expect(github.requests.value == [GitPlatformRepository(kind: .github, host: "github.com", path: "wanggang316/codans")])
    #expect(
      gitlab.requests.value
        == [GitPlatformRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/nested/deep-app")])
    #expect(store.state.repository(for: githubUnit.pairs[0].worktreeID)?.kind == .github)
    #expect(store.state.repository(for: gitlabUnit.pairs[0].worktreeID)?.kind == .gitlab)
  }

  /// A changed alias resolves the unit to another repository. When the new
  /// read fails with a non-CLI error, the rows must not keep the old Git Platform's Pull
  /// Request: its badge would stay, and write actions would target the old repository.
  @Test
  func aNewRepositoryDropsTheOldSnapshotsEvenWhenItsReadFails() async {
    let unit = Self.unit(root: "/repos/app", branch: "feat-open")
    let worktreeID = unit.pairs[0].worktreeID
    let old = GitPlatformRepository(kind: .github, host: "gl", path: "codans-e2e/app")
    var seed = GitPlatformFeature.State()
    seed.snapshotsByProject[unit.projectID] = BatchedPullRequests(
      repository: old, byBranch: ["feat-open": FakeGitPlatform.snapshot(kind: .github, branch: "feat-open")],
      seenBranches: ["feat-open"], fetchedAt: .distantPast)
    seed.snapshots[worktreeID] = FakeGitPlatform.snapshot(kind: .github, branch: "feat-open")
    seed.projectByWorktree[worktreeID] = unit.projectID
    let gitlab = FakeGitPlatform(kind: .gitlab, hosts: [], failure: .network("dial tcp: lookup gl"))
    let store = Self.makeStore(
      initialState: seed,
      github: FakeGitPlatform(kind: .github, hosts: ["github.com"]), gitlab: gitlab,
      remotes: ["/repos/app": RemoteInfo(host: "gl", path: "codans-e2e/app")],
      aliases: LockIsolated([Self.glAlias]))

    await store.send(.projectRefreshRequested(unit.projectID, gitRoot: unit.gitRoot, worktreeBranches: unit.pairs))
    await store.receive(\.gitPlatformRepositoryChanged)
    await store.receive(\.projectBatchLoaded)

    #expect(
      gitlab.requests.value == [GitPlatformRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/app")])
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
    let repository = GitPlatformRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/app")
    let snapshot = FakeGitPlatform.snapshot(kind: .gitlab, branch: "feat-open")
    var seed = GitPlatformFeature.State()
    seed.snapshotsByProject[unit.projectID] = BatchedPullRequests(
      repository: repository, byBranch: ["feat-open": snapshot], seenBranches: ["feat-open"], fetchedAt: .distantPast)
    seed.snapshots[worktreeID] = snapshot
    let store = Self.makeStore(
      initialState: seed,
      github: FakeGitPlatform(kind: .github, hosts: ["github.com"]),
      gitlab: FakeGitPlatform(kind: .gitlab, hosts: ["192.168.2.158:8929"], failure: .timeout),
      remotes: ["/repos/app": RemoteInfo(host: "192.168.2.158:8929", path: "codans-e2e/app")])

    await store.send(.projectRefreshRequested(unit.projectID, gitRoot: unit.gitRoot, worktreeBranches: unit.pairs))
    await store.receive(\.projectBatchLoaded)

    #expect(store.state.snapshots[worktreeID] == snapshot)
    #expect(store.state.snapshotsByProject[unit.projectID]?.repository == repository)
  }

  /// A unit with no Git Platform is skipped by the poll. A change to the alias list sends
  /// `refreshAllRequested` (`CodansApp.observeGitPlatformAliases`), and the unit resolves
  /// again at once with the new alias.
  @Test
  func anAliasListChangeReResolvesAUnitThatHadNoGitPlatform() async {
    let unit = Self.unit(root: "/repos/app", branch: "feat-open")
    let gitlab = FakeGitPlatform(kind: .gitlab, hosts: [])
    let aliases = LockIsolated<[GitPlatformAlias]>([])
    let store = Self.makeStore(
      github: FakeGitPlatform(kind: .github, hosts: ["github.com"]), gitlab: gitlab,
      remotes: ["/repos/app": RemoteInfo(host: "127.0.0.1:2224", path: "codans-e2e/app", isSSH: true)],
      aliases: aliases)

    await store.send(.pollUnitsChanged([unit], selected: [unit.projectID]))
    await store.send(.projectActivated(unit.projectID, gitRoot: unit.gitRoot, worktreeBranches: unit.pairs))
    await store.receive(.gitPlatformUnresolved(unit.projectID, worktreeBranches: unit.pairs))
    #expect(store.state.unitsWithoutGitPlatform == [unit.projectID])
    #expect(gitlab.requests.value.isEmpty)

    aliases.setValue([GitPlatformAlias(remoteHost: "127.0.0.1", kind: .gitlab, apiHost: "192.168.2.158:8929")])
    await store.send(.refreshAllRequested)
    await store.receive(\.projectBatchLoaded)

    let repository = GitPlatformRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/app")
    #expect(gitlab.requests.value == [repository])
    #expect(store.state.unitsWithoutGitPlatform.isEmpty)
    #expect(
      store.state.snapshots[unit.pairs[0].worktreeID] == FakeGitPlatform.snapshot(kind: .gitlab, branch: "feat-open"))
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
    let github = GitHubGitPlatform(
      runner: runner, resolver: CLIExecutableResolver(prober: { URL(fileURLWithPath: "/opt/homebrew/bin/gh") }))
    let store = Self.makeStore(
      github: github, gitlab: FakeGitPlatform(kind: .gitlab, hosts: []),
      remotes: ["/repos/app": RemoteInfo(host: "ssh.ghe.example.com", path: "platform/app", isSSH: true)],
      aliases: LockIsolated([
        GitPlatformAlias(remoteHost: "ssh.ghe.example.com", kind: .github, apiHost: "ghe.example.com")
      ]))

    await store.send(.projectActivated(unit.projectID, gitRoot: unit.gitRoot, worktreeBranches: unit.pairs))
    await store.receive(\.projectBatchLoaded)

    let error = GitPlatformError.notAuthenticated(.github, host: "ghe.example.com")
    #expect(store.state.lastError[unit.pairs[0].worktreeID] == error)
    #expect(store.state.lastErrorByProject[unit.projectID] == error)
    #expect(error.userFacingMessage.contains("gh auth login"))
  }

  // MARK: - Fixtures

  nonisolated private static let glAlias = GitPlatformAlias(
    remoteHost: "gl", kind: .gitlab, apiHost: "192.168.2.158:8929")

  private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

  private static func unit(id: ProjectID = ProjectID(), root: String, branch: String) -> GitPlatformFeature.FetchUnit {
    GitPlatformFeature.FetchUnit(
      projectID: id, gitRoot: URL(fileURLWithPath: root),
      pairs: [.init(worktreeID: WorktreeID(), branch: branch)])
  }

  private static func makeStore(
    initialState: GitPlatformFeature.State = .init(),
    github: any GitPlatform, gitlab: any GitPlatform, remotes: [String: RemoteInfo],
    aliases: LockIsolated<[GitPlatformAlias]> = LockIsolated([])
  ) -> TestStoreOf<GitPlatformFeature> {
    let store = TestStore(initialState: initialState) {
      GitPlatformFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
      $0.continuousClock = ImmediateClock()
      $0[GitPlatformClient.self] = .live(github: github, gitlab: gitlab, sshHostName: { $0 })
      $0[GitPlatformAliasesClient.self] = GitPlatformAliasesClient { aliases.value }
      var git = GitServiceClient.testValue
      git.remoteInfo = { root in
        guard let remote = remotes[root.path] else { throw GitPlatformError.remoteInfoUnavailable }
        return remote
      }
      $0[GitServiceClient.self] = git
    }
    store.exhaustivity = .off
    return store
  }
}

/// A `GitPlatform` that answers every batched read with one snapshot per branch, tagged with
/// its kind, and records the repositories it was asked about.
nonisolated private final class FakeGitPlatform: GitPlatform {
  let kind: GitPlatformKind
  let hosts: Set<String>
  let failure: GitPlatformError?
  let requests = LockIsolated<[GitPlatformRepository]>([])

  init(kind: GitPlatformKind, hosts: Set<String>, failure: GitPlatformError? = nil) {
    self.kind = kind
    self.hosts = hosts
    self.failure = failure
  }

  static func snapshot(kind: GitPlatformKind, branch: String) -> PullRequestSnapshot {
    PullRequestSnapshot(
      number: kind == .github ? 1 : 2, title: "\(kind.displayName) \(branch)", state: .open, isDraft: false,
      headRefName: branch, author: "codans-dev", additions: 0, deletions: 0, commitCount: 1,
      url: URL(string: "https://\(kind.publicHost)/\(branch)")!, updatedAt: Date(timeIntervalSince1970: 0),
      mergeState: PullRequestMergeState(status: .clean))
  }

  // The protocol requires `async`; a fake answers at once.
  // swiftlint:disable async_without_await
  func availability() async -> GitPlatformAvailability { .unknown }
  func authenticatedHosts() async -> Set<String> { hosts }

  func batchPullRequests(
    repository: GitPlatformRepository, branches: [String]
  ) async throws -> [String: PullRequestSnapshot] {
    requests.withValue { $0.append(repository) }
    if let failure { throw failure }
    return Dictionary(uniqueKeysWithValues: branches.map { ($0, Self.snapshot(kind: kind, branch: $0)) })
  }

  func merge(_ pullRequest: PullRequestReference, strategy: MergeStrategy) async throws {}
  func close(_ pullRequest: PullRequestReference) async throws {}
  func markReady(_ pullRequest: PullRequestReference) async throws {}
  func rerunFailedChecks(_ pullRequest: PullRequestReference) async throws {}
  // swiftlint:enable async_without_await
  func repositoryWebURL(_ repository: GitPlatformRepository) -> URL? { nil }
  func pullRequestWebURL(_ pullRequest: PullRequestReference) -> URL? { nil }
}
