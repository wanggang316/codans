import Foundation

/// The batched GraphQL read sent through `glab api graphql`: one request per chunk of
/// source branches, `project(fullPath:) { mergeRequests(sourceBranches: [...]) }`.
///
/// Branch names travel as a JSON array variable (`-F branches=[...]`), never inside the
/// query text, so no escaping rule applies to them. `JSONEncoder` builds the array.
///
/// Field notes, all checked against GitLab CE 19.5:
/// - CE has no `approvalsLeft` / `approvalsRequired` (EE). The query uses only fields CE
///   has; `detailedMergeStatus == NOT_APPROVED` carries "approvals still required".
/// - `diffStats` (per file), not `diffStatsSummary`: selecting `diffStatsSummary` in a
///   list makes GitLab report `CONFLICT` as the `detailedMergeStatus` of mergeable
///   merge requests.
/// - `jobs(retried: false)`: a retried job stays in the pipeline's job list; only the
///   latest run of each job counts.
/// - `currentUser` is `null` when `glab` has no token for the host. GitLab answers an
///   anonymous query without an error, so this is how the read detects "not logged in".
nonisolated enum GitLabMergeRequestQuery {
  /// Branches per request. Each request reads at most `pageSize` merge requests, newest
  /// first; 20 branches leave room for several merge requests per branch.
  static let chunkSize = 20

  /// Merge requests per request (GitLab's maximum page size).
  static let pageSize = 100

  /// Concurrent requests when a fetch needs more than one chunk.
  static let maxConcurrentChunks = 3

  static let query = """
    query($fullPath: ID!, $branches: [String!]) {
      currentUser { username }
      project(fullPath: $fullPath) {
        mergeRequests(sourceBranches: $branches, first: \(pageSize), sort: UPDATED_DESC) {
          nodes {
            iid
            title
            state
            draft
            sourceBranch
            targetBranch
            webUrl
            updatedAt
            detailedMergeStatus
            squashReadOnly
            squashOnMerge
            approved
            approvedBy { nodes { username } }
            reviewers { nodes { mergeRequestInteraction { reviewState } } }
            diffStats { additions deletions }
            commitCount
            author { username }
            sourceProject { fullPath }
            targetProject { fullPath webUrl }
            headPipeline {
              status
              jobs(first: 100, retried: false) {
                nodes { name status allowFailure manualJob startedAt finishedAt webPath }
              }
            }
          }
        }
      }
    }
    """

  /// The `branches` variable: a JSON array of the branch names.
  static func branchesVariable(_ branches: [String]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = (try? encoder.encode(branches)) ?? Data("[]".utf8)
    return String(data: data, encoding: .utf8) ?? "[]"
  }

  /// Slices `branches` into runs of `chunkSize`; the last run may be shorter.
  static func chunk(_ branches: [String], chunkSize: Int = Self.chunkSize) -> [[String]] {
    stride(from: 0, to: branches.count, by: chunkSize).map {
      Array(branches[$0..<min($0 + chunkSize, branches.count)])
    }
  }
}
