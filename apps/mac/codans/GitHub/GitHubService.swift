import Foundation
import CodansCore

/// Stateless protocol over the `gh` CLI surface that the GitHub integration needs.
///
/// Every method passes the Worktree's absolute path as the subprocess `cwd` so `gh`
/// resolves the correct repository + remote automatically. User input (branch names,
/// PR numbers, commit SHAs) is always an argv element — never interpolated into a
/// shell. Tests inject `any GitHubService` via `GitHubClient` (TCA DependencyKey,
/// lands in M3).
///
/// Methods that read return either a value, `nil` (for "nothing to report" like "no
/// PR for this branch"), or throw a `GitHubError`. Methods that mutate return Void on
/// success and throw on any non-zero exit.
nonisolated protocol GitHubService: Sendable {
  /// Probes whether gh is installed and logged in. Never throws — the failure is the
  /// `.unavailable` case of the returned enum. Cached for 30 s by the feature reducer.
  func availability() async -> GitHubAvailability

  /// Returns the most-recent workflow run for the branch, or `nil` when no run exists.
  func latestWorkflowRun(branch: String, worktreePath: URL) async throws -> WorkflowRun?

  /// Merges the PR with the given strategy. Throws `.mergeConflict` when the PR is
  /// not cleanly mergeable.
  func merge(number: Int, strategy: MergeStrategy, worktreePath: URL) async throws

  /// Closes the PR without merging.
  func close(number: Int, worktreePath: URL) async throws

  /// Promotes a draft PR to ready-for-review.
  func markReady(number: Int, worktreePath: URL) async throws

  /// Re-runs every failed job in the given workflow run (one `gh run rerun --failed` call).
  func rerunFailedJobs(runID: Int64, worktreePath: URL) async throws

  /// Batched PR lookup via `gh api graphql`. Takes a repository (host + owner + repo) plus
  /// a list of head-branch names and returns `[branch: PullRequestSnapshot]` for every
  /// branch that resolves to a PR after fork-PR filtering. Branches with no PR are absent
  /// from the dictionary (never nil-valued).
  ///
  /// Execution: branches are chunked at `BatchedPullRequestQuery.chunkSize` per query,
  /// with up to `maxConcurrentChunks` GraphQL requests in flight at once. Empty `branches`
  /// returns `[:]` without spawning any subprocess.
  ///
  /// Throws `GitHubError.graphQLError` on an API-level GraphQL error response;
  /// `.malformedBranchName` if any branch name fails the GraphQL-string validator;
  /// `.oversizeResponse` if any chunk's stdout exceeds the 8 MiB cap; and the usual
  /// `.notInstalled` / `.notAuthenticated` / `.network` / `.timeout` / `.other` on the
  /// subprocess layer.
  func batchPullRequests(
    host: String,
    owner: String,
    repo: String,
    branches: [String]
  ) async throws -> [String: PullRequestSnapshot]
}

extension GitHub {
  /// Default factory. Returns a `LiveGitHubService` wired to the shared
  /// `GhExecutableResolver` and a live `FoundationCommandRunner`. Internal (not public)
  /// so the concrete `GitHubService` protocol stays app-local — v2 IPC surface would
  /// either re-export or define its own wire protocol.
  static func makeService() -> any GitHubService {
    LiveGitHubService()
  }
}
