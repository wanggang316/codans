import CodansCore
import ComposableArchitecture
import Foundation

/// TCA dependency over the `CodeHost` implementations in `codans/CodeHost/`. It is the
/// one place that selects an implementation by `CodeHostKind`; features call it with a
/// repository or a Pull Request reference and never branch on the kind themselves.
///
/// Not `@MainActor`: `CodeHost` is nonisolated and Sendable. Every closure is
/// `@Sendable` — safe to call from any reducer effect.
nonisolated struct CodeHostClient: Sendable {
  var availability: @Sendable (_ kind: CodeHostKind) async -> CodeHostAvailability
  /// The Code Host repository behind a remote, or `nil` when no Code Host serves its host
  /// (`github.com` or a host `gh` is logged in to → GitHub; `gitlab.com` or a host `glab`
  /// is logged in to → GitLab; then `choice`, the Project's Code Host setting, `nil` for
  /// Auto; otherwise none).
  var resolveRepository: @Sendable (_ remote: RemoteInfo, _ choice: CodeHostKind?) async -> CodeHostRepository?
  /// Drops cached resolver input (the hosts each CLI is logged in to), so the next
  /// resolution sees a fresh `auth login`.
  var invalidateResolution: @Sendable () async -> Void
  /// Batched Pull Request lookup for one repository, keyed by source branch name.
  var batchPullRequests:
    @Sendable (_ repository: CodeHostRepository, _ branches: [String]) async throws -> [String: PullRequestSnapshot]
  var merge: @Sendable (_ pullRequest: PullRequestReference, _ strategy: MergeStrategy) async throws -> Void
  var close: @Sendable (_ pullRequest: PullRequestReference) async throws -> Void
  var markReady: @Sendable (_ pullRequest: PullRequestReference) async throws -> Void
  var rerunFailedChecks: @Sendable (_ pullRequest: PullRequestReference) async throws -> Void
  var repositoryWebURL: @Sendable (_ repository: CodeHostRepository) -> URL?
  var pullRequestWebURL: @Sendable (_ pullRequest: PullRequestReference) -> URL?
}

extension CodeHostClient {
  /// Constructs a client that dispatches each call to the implementation of its kind.
  static func live(
    github: any CodeHost = GitHubCodeHost(), gitlab: any CodeHost = GitLabCodeHost()
  ) -> CodeHostClient {
    let implementation: @Sendable (CodeHostKind) -> any CodeHost = { kind in
      switch kind {
      case .github: return github
      case .gitlab: return gitlab
      }
    }
    let sshHostName = SSHHostName()
    let resolver = CodeHostResolver(
      hostsProvider: { kind in await implementation(kind).authenticatedHosts() },
      sshHostName: { host in await sshHostName.resolve(host) })
    return CodeHostClient(
      availability: { kind in await implementation(kind).availability() },
      resolveRepository: { remote, choice in await resolver.resolve(remote, choice: choice) },
      invalidateResolution: { await resolver.invalidate() },
      batchPullRequests: { repository, branches in
        try await implementation(repository.kind).batchPullRequests(repository: repository, branches: branches)
      },
      merge: { pullRequest, strategy in
        try await implementation(pullRequest.repository.kind).merge(pullRequest, strategy: strategy)
      },
      close: { pullRequest in try await implementation(pullRequest.repository.kind).close(pullRequest) },
      markReady: { pullRequest in try await implementation(pullRequest.repository.kind).markReady(pullRequest) },
      rerunFailedChecks: { pullRequest in
        try await implementation(pullRequest.repository.kind).rerunFailedChecks(pullRequest)
      },
      repositoryWebURL: { repository in implementation(repository.kind).repositoryWebURL(repository) },
      pullRequestWebURL: { pullRequest in
        implementation(pullRequest.repository.kind).pullRequestWebURL(pullRequest)
      }
    )
  }
}

extension CodeHostClient: DependencyKey {
  static let liveValue: CodeHostClient = .live()

  static let testValue: CodeHostClient = CodeHostClient(
    // Idempotent query — returning `.unknown` is a safe default that doesn't affect
    // behaviour assertions. The host app probes availability eagerly
    // (CodeHostFeature.onAppear).
    availability: { _ in .unknown },
    resolveRepository: unimplemented("CodeHostClient.resolveRepository", placeholder: nil),
    invalidateResolution: {},
    batchPullRequests: unimplemented("CodeHostClient.batchPullRequests", placeholder: [:]),
    merge: unimplemented("CodeHostClient.merge"),
    close: unimplemented("CodeHostClient.close"),
    markReady: unimplemented("CodeHostClient.markReady"),
    rerunFailedChecks: unimplemented("CodeHostClient.rerunFailedChecks"),
    repositoryWebURL: unimplemented("CodeHostClient.repositoryWebURL", placeholder: nil),
    pullRequestWebURL: unimplemented("CodeHostClient.pullRequestWebURL", placeholder: nil)
  )
}

extension DependencyValues {
  var codeHost: CodeHostClient {
    get { self[CodeHostClient.self] }
    set { self[CodeHostClient.self] = newValue }
  }
}
