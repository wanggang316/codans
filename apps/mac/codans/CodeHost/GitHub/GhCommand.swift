import Foundation
import CodansCore

/// Argv builder for every `gh` invocation the GitHub Code Host issues. Each static
/// function returns the complete argument vector (without the `gh` executable path)
/// together with the exit codes that are treated as *success* by the calling service.
///
/// `gh` exits non-zero for a wide range of conditions — "no PR found", "not authenticated",
/// network failure, etc. The caller decides which of those to treat as a fatal error and
/// which to translate into a richer domain result (`.notAPullRequest`, `.notAuthenticated`,
/// etc.). `expectedExitCodes` names the codes that reach the happy-path parsing; anything
/// else triggers `GitHubCodeHost`'s stderr-sniffing error-translation branch.
///
/// Tests lock every argv list — these are the exact strings sent to a long-lived external
/// tool, and a silent drift (flag position, missing `--json` field) can mask real bugs
/// (e.g. a misplaced flag that becomes a pathspec).
nonisolated enum GhCommand {
  /// `gh auth status --json hosts`. Exit 0 → logged in (parse hosts); exit 1 → not logged in.
  static func authStatus() -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["auth", "status", "--json", "hosts"], [0, 1])
  }

  /// `gh pr view <number> --repo <repo> --json statusCheckRollup`. The checks of the pull
  /// request's head commit; `rerunFailedChecks` reads the failed Actions runs from them.
  static func pullRequestCheckRollup(
    number: Int, repo: String
  ) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["pr", "view", String(number), "--repo", repo, "--json", "statusCheckRollup"], [0])
  }

  /// `gh pr merge <number> <flag> --repo <repo>`.
  static func pullRequestMerge(
    number: Int,
    strategy: MergeStrategy,
    repo: String
  ) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["pr", "merge", String(number), mergeFlag(strategy), "--repo", repo], [0])
  }

  /// `gh pr close <number> --repo <repo>`.
  static func pullRequestClose(
    number: Int, repo: String
  ) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["pr", "close", String(number), "--repo", repo], [0])
  }

  /// `gh pr ready <number> --repo <repo>`. Promotes a draft PR to ready-for-review.
  static func pullRequestReady(
    number: Int, repo: String
  ) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["pr", "ready", String(number), "--repo", repo], [0])
  }

  /// `gh run rerun <runID> --failed --repo <repo>`. One-shot: re-runs every failed job in
  /// the run. There is no per-job selection.
  static func runRerunFailed(
    runID: Int64, repo: String
  ) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["run", "rerun", String(runID), "--failed", "--repo", repo], [0])
  }

  /// Flag `gh pr merge` takes for a strategy.
  static func mergeFlag(_ strategy: MergeStrategy) -> String {
    switch strategy {
    case .mergeCommit: return "--merge"
    case .squash: return "--squash"
    case .rebase: return "--rebase"
    }
  }

  /// `gh api graphql --hostname <host> -f query=<body> -f <var1>=<val1> ...`. Used by the
  /// v2 batched PR fetcher to run one custom GraphQL query for many branches at once. The
  /// `variables` dictionary is sorted before serialisation so argv diffs stay deterministic
  /// in tests — a mis-ordered flag list can silently mask field-omission bugs.
  ///
  /// Exit 0 → GraphQL response (may still carry `"errors": [...]` inside stdout; the
  /// caller inspects the payload). Exit 1 → gh-level failure (network, auth, etc.),
  /// stderr-translated by the caller.
  static func apiGraphQL(
    query: String,
    hostname: String,
    variables: [String: String]
  ) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    var args = ["api", "graphql", "--hostname", hostname, "-f", "query=\(query)"]
    for key in variables.keys.sorted() {
      args.append("-f")
      args.append("\(key)=\(variables[key] ?? "")")
    }
    return (args, [0])
  }
}
