import Foundation
import CodansCore

/// Argv builder for every `gh` invocation the GitHub integration issues. Each static
/// function returns the complete argument vector (without the `gh` executable path)
/// together with the exit codes that are treated as *success* by the calling service.
///
/// `gh` exits non-zero for a wide range of conditions — "no PR found", "not authenticated",
/// network failure, etc. The caller decides which of those to treat as a fatal error and
/// which to translate into a richer domain result (`.notAPullRequest`, `.notAuthenticated`,
/// etc.). `expectedExitCodes` names the codes that reach the happy-path parsing; anything
/// else triggers `LiveGitHubService`'s stderr-sniffing error-translation branch.
///
/// Tests lock every argv list — these are the exact strings sent to a long-lived external
/// tool, and a silent drift (flag position, missing `--json` field) can mask real bugs.
/// Precedent: exec-plan 0005 DEC-19 — a `-w` placement test that didn't reach argv masked
/// a flag-vs-pathspec bug.
nonisolated enum GhCommand {
  /// `gh auth status --json hosts`. Exit 0 → logged in (parse hosts); exit 1 → not logged in.
  static func authStatus() -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["auth", "status", "--json", "hosts"], [0, 1])
  }

  /// `gh run list --branch <branch> --limit 1 --json <fields>`. Returns the latest
  /// workflow run for the branch. Empty array → no runs yet (caller returns nil).
  static func runListLatest(branch: String) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    let fields = [
      "databaseId", "name", "status", "conclusion",
      "headBranch", "headSha", "number", "updatedAt", "url",
    ].joined(separator: ",")
    return (
      ["run", "list", "--branch", branch, "--limit", "1", "--json", fields],
      [0]
    )
  }

  /// `gh pr merge <number> <flag>`. `flag` is `MergeStrategy.cliFlag`.
  static func pullRequestMerge(
    number: Int,
    strategy: MergeStrategy
  ) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["pr", "merge", String(number), strategy.cliFlag], [0])
  }

  /// `gh pr close <number>`.
  static func pullRequestClose(number: Int) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["pr", "close", String(number)], [0])
  }

  /// `gh pr ready <number>`. Promotes a draft PR to ready-for-review.
  static func pullRequestReady(number: Int) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["pr", "ready", String(number)], [0])
  }

  /// `gh run rerun <runID> --failed`. One-shot: re-runs every failed job in the run.
  /// Per exec-plan 0012 DEC-3 there is no per-job selection in v1.
  static func runRerunFailed(runID: Int64) -> (arguments: [String], expectedExitCodes: Set<Int32>) {
    (["run", "rerun", String(runID), "--failed"], [0])
  }

  /// `gh api graphql --hostname <host> -f query=<body> -f <var1>=<val1> ...`. Used by the
  /// v2 batched PR fetcher (0013 M3) to run one custom GraphQL query for many branches at
  /// once. The `variables` dictionary is sorted before serialisation so argv diffs stay
  /// deterministic in tests — a mis-ordered flag list can silently mask field-omission
  /// bugs the way 0005 DEC-19's `-w` placement did.
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
