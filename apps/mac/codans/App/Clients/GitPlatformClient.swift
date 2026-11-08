import CodansCore
import ComposableArchitecture
import Foundation

/// TCA dependency over the `GitPlatform` implementations in `codans/GitPlatform/`. It is the
/// one place that selects an implementation by `GitPlatformKind`; features call it with a
/// repository or a Pull Request reference and never branch on the kind themselves.
///
/// Not `@MainActor`: `GitPlatform` is nonisolated and Sendable. Every closure is
/// `@Sendable` — safe to call from any reducer effect.
nonisolated struct GitPlatformClient: Sendable {
  var availability: @Sendable (_ kind: GitPlatformKind) async -> GitPlatformAvailability
  /// The Git Platform repository behind a remote, or `nil` when no Git Platform serves its host.
  /// Order: an alias from `aliases`; `github.com` or a host `gh` is logged in to → GitHub;
  /// `gitlab.com` or a host `glab` is logged in to → GitLab; for an SSH remote, its
  /// `ssh -G` HostName matched to one of those hosts; a host name that contains `github` or
  /// `gitlab`; otherwise none (ADR 0004 item 2, ADR 0005).
  var resolveRepository: @Sendable (_ remote: RemoteInfo, _ aliases: [GitPlatformAlias]) async -> GitPlatformRepository?
  /// Hosts the CLI of `kind` is logged in to. The Git Platforms pane uses it for the status
  /// of each alias.
  var authenticatedHosts: @Sendable (_ kind: GitPlatformKind) async -> Set<String>
  /// Drops cached resolver input (the CLI paths, the hosts each CLI is logged in to, and
  /// the `ssh -G` results), so the next resolution and fetch see a fresh install,
  /// `auth login`, or `~/.ssh/config`.
  var invalidateResolution: @Sendable () async -> Void
  /// Batched Pull Request lookup for one repository, keyed by source branch name.
  var batchPullRequests:
    @Sendable (_ repository: GitPlatformRepository, _ branches: [String]) async throws -> [String: PullRequestSnapshot]
  var merge: @Sendable (_ pullRequest: PullRequestReference, _ strategy: MergeStrategy) async throws -> Void
  var close: @Sendable (_ pullRequest: PullRequestReference) async throws -> Void
  var markReady: @Sendable (_ pullRequest: PullRequestReference) async throws -> Void
  var rerunFailedChecks: @Sendable (_ pullRequest: PullRequestReference) async throws -> Void
  var repositoryWebURL: @Sendable (_ repository: GitPlatformRepository) -> URL?
  var pullRequestWebURL: @Sendable (_ pullRequest: PullRequestReference) -> URL?
}

extension GitPlatformClient {
  /// Constructs a client that dispatches each call to the implementation of its kind.
  static func live(
    github: any GitPlatform = GitHubGitPlatform(), gitlab: any GitPlatform = GitLabGitPlatform(),
    sshHostName: @escaping GitPlatformResolver.SSHHostNameProvider = { await SSHHostName().resolve($0) }
  ) -> GitPlatformClient {
    let implementation: @Sendable (GitPlatformKind) -> any GitPlatform = { kind in
      switch kind {
      case .github: return github
      case .gitlab: return gitlab
      }
    }
    let resolver = GitPlatformResolver(
      hostsProvider: { kind in await implementation(kind).authenticatedHosts() },
      sshHostName: sshHostName)
    return GitPlatformClient(
      availability: { kind in await implementation(kind).availability() },
      resolveRepository: { remote, aliases in await resolver.resolve(remote, aliases: aliases) },
      authenticatedHosts: { kind in await implementation(kind).authenticatedHosts() },
      invalidateResolution: {
        await resolver.invalidate()
        for kind in GitPlatformKind.allCases {
          await implementation(kind).invalidateExecutable()
        }
      },
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

extension GitPlatformClient: DependencyKey {
  static let liveValue: GitPlatformClient = .live()

  static let testValue: GitPlatformClient = GitPlatformClient(
    // Idempotent query — returning `.unknown` is a safe default that doesn't affect
    // behaviour assertions. The host app probes availability eagerly
    // (GitPlatformFeature.onAppear).
    availability: { _ in .unknown },
    resolveRepository: unimplemented("GitPlatformClient.resolveRepository", placeholder: nil),
    authenticatedHosts: { _ in [] },
    invalidateResolution: {},
    batchPullRequests: unimplemented("GitPlatformClient.batchPullRequests", placeholder: [:]),
    merge: unimplemented("GitPlatformClient.merge"),
    close: unimplemented("GitPlatformClient.close"),
    markReady: unimplemented("GitPlatformClient.markReady"),
    rerunFailedChecks: unimplemented("GitPlatformClient.rerunFailedChecks"),
    repositoryWebURL: unimplemented("GitPlatformClient.repositoryWebURL", placeholder: nil),
    pullRequestWebURL: unimplemented("GitPlatformClient.pullRequestWebURL", placeholder: nil)
  )
}

extension DependencyValues {
  var gitPlatform: GitPlatformClient {
    get { self[GitPlatformClient.self] }
    set { self[GitPlatformClient.self] = newValue }
  }
}
