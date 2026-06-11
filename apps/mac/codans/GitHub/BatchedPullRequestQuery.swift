import Foundation

/// Pure functions that build the batched GraphQL query sent via `gh api graphql`. Kept
/// separate from `LiveGitHubService` so the query construction is trivially unit-testable
/// (deterministic string output for given branches) and the chunking policy can be tuned
/// without touching the subprocess-runner code.
///
/// The query uses **GraphQL aliases** to fetch multiple branches' PR data in one request:
///
///     repository(owner, name) {
///       branch0: pullRequests(first: 5, headRefName: "<b0>", ...) { ... }
///       branch1: pullRequests(first: 5, headRefName: "<b1>", ...) { ... }
///       ...
///     }
///
/// One alias per branch, up to `chunkSize = 25` per request. The caller keeps the
/// `[alias: originalBranch]` map so the decoder can pair results back to branch names —
/// the alias itself is a monotonic `branch<N>` label (not the branch name itself) so we
/// sidestep GraphQL's alias-name grammar (`/[_a-zA-Z][_a-zA-Z0-9]*/`) which user branch
/// names like `feat/test-005` do not satisfy.
///
/// Branch names carry untrusted user data: they flow into the query body as GraphQL
/// string literals. The validator rejects any branch containing newlines or null bytes
/// (the only characters that cannot be made safe by escaping); every other character is
/// escaped into a double-quoted string per GraphQL's string lexical rules.
nonisolated enum BatchedPullRequestQuery {
  /// Max branches per GraphQL request. 25 keeps each query well under GitHub's query
  /// complexity cap while still fanning out meaningfully. Tunable from one place.
  static let chunkSize: Int = 25

  /// Max concurrent requests when a single fetch needs more than `chunkSize` branches.
  /// The work-stealing TaskGroup in `LiveGitHubService.batchPullRequests` keeps exactly
  /// this many children active at once.
  static let maxConcurrentChunks: Int = 3

  /// Builds one GraphQL query string for the given branch list plus the `[alias: branch]`
  /// map the decoder uses to reattach results to their source branch. Throws
  /// `ValidationError.invalidBranchName(branch)` if any branch contains a character
  /// that cannot appear in a GraphQL string literal (newline / null).
  ///
  /// Call sites passing an empty array get an empty aliasMap and a placeholder query
  /// that is syntactically valid GraphQL but does nothing; tests assert this. In
  /// practice `LiveGitHubService.batchPullRequests` short-circuits at empty input and
  /// never reaches the builder — but the builder stays safe if it is called directly.
  static func buildQuery(
    branches: [String]
  ) throws -> (query: String, aliasMap: [String: String]) {
    guard !branches.isEmpty else {
      // Minimal valid query for the empty case — never issued by the service, but makes
      // the builder total.
      let empty = """
        query($owner: String!, $repo: String!) {
          repository(owner: $owner, name: $repo) { id }
        }
        """
      return (empty, [:])
    }
    var aliasMap: [String: String] = [:]
    var selections: [String] = []
    for (index, branch) in branches.enumerated() {
      let escaped = try escapeGraphQLString(branch)
      let alias = "branch\(index)"
      aliasMap[alias] = branch
      selections.append(Self.selection(alias: alias, escapedBranch: escaped))
    }
    let selectionBlock = selections.joined(separator: "\n")
    let query = """
      query($owner: String!, $repo: String!) {
        repository(owner: $owner, name: $repo) {
      \(selectionBlock)
        }
      }
      """
    return (query, aliasMap)
  }

  /// Slices `branches` into runs of length `chunkSize` (last run may be shorter). Returns
  /// an empty array of chunks for an empty input.
  static func chunk(_ branches: [String], chunkSize: Int = Self.chunkSize) -> [[String]] {
    guard !branches.isEmpty else { return [] }
    var chunks: [[String]] = []
    var index = 0
    while index < branches.count {
      let end = min(index + chunkSize, branches.count)
      chunks.append(Array(branches[index..<end]))
      index = end
    }
    return chunks
  }

  /// Error raised when a branch name cannot appear in the query.
  enum ValidationError: Error, Equatable, Sendable {
    case invalidBranchName(String)
  }

  // MARK: - Private

  /// Emits one `branchN: pullRequests(...)` selection block. Field list matches the
  /// design doc (github-integration-batched.md §GraphQL Query Shape):
  /// - `first: 5` — one branch may have multiple PRs; we take the 5 most recent.
  /// - `states: [OPEN, MERGED]` — closed non-merged PRs are rare dead-ends; skip.
  /// - `orderBy UPDATED_AT DESC` — within the slice, most-recently-active first.
  /// - `statusCheckRollup.contexts(first: 100)` — CI result aggregation in one hop.
  private static func selection(alias: String, escapedBranch: String) -> String {
    """
    \(alias): pullRequests(first: 5, states: [OPEN, MERGED], headRefName: \(escapedBranch), orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number
        title
        state
        isDraft
        additions
        deletions
        mergeable
        mergeStateStatus
        reviewDecision
        url
        updatedAt
        headRefName
        baseRefName
        commits { totalCount }
        author { login }
        headRepository { name owner { login } }
        statusCheckRollup {
          contexts(first: 100) {
            nodes {
              ... on CheckRun {
                name
                status
                conclusion
                startedAt
                completedAt
                detailsUrl
              }
              ... on StatusContext {
                context
                state
                targetUrl
                createdAt
              }
            }
          }
        }
      }
    }
    """
  }

  /// Escapes a branch name into a GraphQL double-quoted string literal. Rules per
  /// graphql.org/learn/queries: backslash-escape `\`, `"`, `/`, and the non-printable
  /// control escapes `\b`, `\f`, `\n`, `\r`, `\t`; any other character under U+0020 is
  /// rejected (there is no portable way to represent it in a double-quoted string).
  /// Branch names in git technically accept `\n` and control bytes; git itself discourages
  /// them, and GitHub rejects them on push, so in practice we never see them.
  private static func escapeGraphQLString(_ input: String) throws -> String {
    var out = "\""
    for scalar in input.unicodeScalars {
      switch scalar {
      case "\\":
        out.append("\\\\")
      case "\"":
        out.append("\\\"")
      case "\u{08}":
        out.append("\\b")
      case "\u{0C}":
        out.append("\\f")
      case "\n":
        throw ValidationError.invalidBranchName(input)
      case "\r":
        throw ValidationError.invalidBranchName(input)
      case "\t":
        out.append("\\t")
      case "\u{00}":
        throw ValidationError.invalidBranchName(input)
      default:
        if scalar.value < 0x20 {
          throw ValidationError.invalidBranchName(input)
        }
        out.unicodeScalars.append(scalar)
      }
    }
    out.append("\"")
    return out
  }
}
