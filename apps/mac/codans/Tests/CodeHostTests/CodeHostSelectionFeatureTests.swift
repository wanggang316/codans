import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The reducer selects the Code Host implementation per fetch unit (ADR 0004 items 2, 13,
/// 16). These tests run the real `CodeHostClient.live` dispatch and resolver over one
/// fake implementation per kind, so they observe which implementation answered.
@MainActor
struct CodeHostSelectionFeatureTests {
  /// A Project set to GitLab whose `origin` is an SSH alias neither CLI knows gets its
  /// Merge Requests from the GitLab implementation.
  @Test
  func aProjectChoiceSelectsTheImplementationForAHostNeitherCLIKnows() async {
    let unit = Self.unit(root: "/repos/app", branch: "feat-open")
    let github = FakeCodeHost(kind: .github, hosts: ["github.com"])
    let gitlab = FakeCodeHost(kind: .gitlab, hosts: ["192.168.2.158:8929"])
    let store = Self.makeStore(
      github: github, gitlab: gitlab,
      remotes: ["/repos/app": RemoteInfo(host: "gl", path: "codans-e2e/app")],
      choices: [unit.projectID: .gitlab])

    await store.send(.projectActivated(unit.projectID, gitRoot: unit.gitRoot, worktreeBranches: unit.pairs))
    await store.receive(\.projectBatchLoaded)

    let repository = CodeHostRepository(kind: .gitlab, host: "gl", path: "codans-e2e/app")
    #expect(store.state.snapshotsByProject[unit.projectID]?.repository == repository)
    #expect(store.state.snapshots[unit.pairs[0].worktreeID] == FakeCodeHost.snapshot(kind: .gitlab, branch: "feat-open"))
    #expect(gitlab.requests.value == [repository])
    #expect(github.requests.value.isEmpty)
    #expect(store.state.unitsWithoutCodeHost.isEmpty)
  }

  /// Auto and a host neither CLI knows: no fetch, no badge, no error.
  @Test
  func autoWithNoMatchStartsNoFetch() async {
    let unit = Self.unit(root: "/repos/app", branch: "feat-open")
    let github = FakeCodeHost(kind: .github, hosts: ["github.com"])
    let gitlab = FakeCodeHost(kind: .gitlab, hosts: ["192.168.2.158:8929"])
    let store = Self.makeStore(
      github: github, gitlab: gitlab,
      remotes: ["/repos/app": RemoteInfo(host: "gl", path: "codans-e2e/app")],
      choices: [:])

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
      ],
      choices: [:])

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

  // MARK: - Fixtures

  private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

  private static func unit(id: ProjectID = ProjectID(), root: String, branch: String) -> CodeHostFeature.FetchUnit {
    CodeHostFeature.FetchUnit(
      projectID: id, gitRoot: URL(fileURLWithPath: root),
      pairs: [.init(worktreeID: WorktreeID(), branch: branch)])
  }

  private static func makeStore(
    github: FakeCodeHost, gitlab: FakeCodeHost, remotes: [String: RemoteInfo], choices: [ProjectID: CodeHostKind]
  ) -> TestStoreOf<CodeHostFeature> {
    let store = TestStore(initialState: CodeHostFeature.State()) {
      CodeHostFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
      $0.continuousClock = ImmediateClock()
      $0[CodeHostClient.self] = .live(github: github, gitlab: gitlab)
      $0[ProjectCodeHostChoiceClient.self] = ProjectCodeHostChoiceClient { unitID, _ in choices[unitID] }
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
  let requests = LockIsolated<[CodeHostRepository]>([])

  init(kind: CodeHostKind, hosts: Set<String>) {
    self.kind = kind
    self.hosts = hosts
  }

  static func snapshot(kind: CodeHostKind, branch: String) -> PullRequestSnapshot {
    PullRequestSnapshot(
      number: kind == .github ? 1 : 2, title: "\(kind.displayName) \(branch)", state: .open, isDraft: false,
      headRefName: branch, author: "codans-dev", additions: 0, deletions: 0, commitCount: 1,
      url: URL(string: "https://\(kind.publicHost)/\(branch)")!, updatedAt: Date(timeIntervalSince1970: 0),
      mergeState: PullRequestMergeState(status: .clean))
  }

  func availability() async -> CodeHostAvailability { .unknown }
  func authenticatedHosts() async -> Set<String> { hosts }

  func batchPullRequests(repository: CodeHostRepository, branches: [String]) async throws -> [String: PullRequestSnapshot] {
    requests.withValue { $0.append(repository) }
    return Dictionary(uniqueKeysWithValues: branches.map { ($0, Self.snapshot(kind: kind, branch: $0)) })
  }

  func merge(_ pullRequest: PullRequestReference, strategy: MergeStrategy) async throws {}
  func close(_ pullRequest: PullRequestReference) async throws {}
  func markReady(_ pullRequest: PullRequestReference) async throws {}
  func rerunFailedChecks(_ pullRequest: PullRequestReference) async throws {}
  func repositoryWebURL(_ repository: CodeHostRepository) -> URL? { nil }
  func pullRequestWebURL(_ pullRequest: PullRequestReference) -> URL? { nil }
}
