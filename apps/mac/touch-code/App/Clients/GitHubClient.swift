import ComposableArchitecture
import Foundation
import TouchCodeCore

/// TCA dependency-injection bridge over the `GitHubService` protocol from
/// `touch-code/GitHub/`. Mirrors `GitServiceClient` in shape so features use a consistent
/// client pattern across the codebase.
///
/// Not `@MainActor`: `GitHubService` is nonisolated and Sendable. Every closure is
/// `@Sendable async` — safe to call from any reducer effect.
nonisolated struct GitHubClient: Sendable {
  var availability: @Sendable () async -> GitHubAvailability
  var latestWorkflowRun: @Sendable (_ branch: String, _ worktreePath: URL) async throws -> WorkflowRun?
  var merge: @Sendable (_ number: Int, _ strategy: MergeStrategy, _ worktreePath: URL) async throws -> Void
  var close: @Sendable (_ number: Int, _ worktreePath: URL) async throws -> Void
  var markReady: @Sendable (_ number: Int, _ worktreePath: URL) async throws -> Void
  var rerunFailedJobs: @Sendable (_ runID: Int64, _ worktreePath: URL) async throws -> Void
  /// Batched PR lookup for one repository, keyed by head branch name (0013 M3). One
  /// `gh api graphql` subprocess per chunk of up to 25 branches, up to 3 chunks concurrent.
  var batchPullRequests:
    @Sendable (
      _ host: String, _ owner: String, _ repo: String, _ branches: [String]
    ) async throws -> [String: PullRequestSnapshot]
}

extension GitHubClient {
  /// Constructs a client that forwards every closure to the given concrete service.
  static func live(service: any GitHubService = GitHub.makeService()) -> GitHubClient {
    GitHubClient(
      availability: { await service.availability() },
      latestWorkflowRun: { branch, path in try await service.latestWorkflowRun(branch: branch, worktreePath: path) },
      merge: { number, strategy, path in
        try await service.merge(number: number, strategy: strategy, worktreePath: path)
      },
      close: { number, path in try await service.close(number: number, worktreePath: path) },
      markReady: { number, path in try await service.markReady(number: number, worktreePath: path) },
      rerunFailedJobs: { runID, path in
        try await service.rerunFailedJobs(runID: runID, worktreePath: path)
      },
      batchPullRequests: { host, owner, repo, branches in
        try await service.batchPullRequests(host: host, owner: owner, repo: repo, branches: branches)
      }
    )
  }
}

extension GitHubClient: DependencyKey {
  static let liveValue: GitHubClient = .live()

  static let testValue: GitHubClient = GitHubClient(
    // Idempotent query — returning `.unknown` is a safe default that doesn't
    // affect behaviour assertions. The host app probes availability eagerly
    // (GitHubFeature.onAppear), so leaving this as `unimplemented` is enough
    // to fail any XCTest case that doesn't manually override per-test, even
    // when the test itself is skipped.
    availability: { .unknown },
    latestWorkflowRun: unimplemented("GitHubClient.latestWorkflowRun", placeholder: nil),
    merge: unimplemented("GitHubClient.merge"),
    close: unimplemented("GitHubClient.close"),
    markReady: unimplemented("GitHubClient.markReady"),
    rerunFailedJobs: unimplemented("GitHubClient.rerunFailedJobs"),
    batchPullRequests: unimplemented("GitHubClient.batchPullRequests", placeholder: [:])
  )
}

extension DependencyValues {
  var gitHub: GitHubClient {
    get { self[GitHubClient.self] }
    set { self[GitHubClient.self] = newValue }
  }
}
