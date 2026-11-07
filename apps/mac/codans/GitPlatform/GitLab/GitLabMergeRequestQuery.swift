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
  /// Branches per request chain.
  static let chunkSize = 20

  /// Merge requests, and jobs of one pipeline, per page (GitLab's maximum page size).
  static let pageSize = 100

  /// Most pages one read follows, for the merge request list of a chunk and for the jobs
  /// of one head pipeline. A read that needs more fails with an error instead of showing
  /// a partial list: a dropped merge request would remove a badge, a dropped job could
  /// hide a failure.
  static let maxPages = 20

  /// Concurrent requests when a fetch needs more than one chunk.
  static let maxConcurrentChunks = 3

  /// One page of merge requests. `$after` is the previous page's `endCursor`; it is
  /// absent (null) for the first page.
  static let query = """
    query($fullPath: ID!, $branches: [String!], $after: String) {
      currentUser { username }
      project(fullPath: $fullPath) {
        mergeRequests(sourceBranches: $branches, first: \(pageSize), after: $after, sort: UPDATED_DESC) {
          pageInfo { hasNextPage endCursor }
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
              jobs(first: \(pageSize), retried: false) {
                pageInfo { hasNextPage endCursor }
                nodes { \(jobFields) }
              }
            }
          }
        }
      }
    }
    """

  /// The next page of one merge request's head-pipeline jobs, when the first page in
  /// `query` was not the last.
  static let jobsQuery = """
    query($fullPath: ID!, $iid: String!, $after: String) {
      project(fullPath: $fullPath) {
        mergeRequest(iid: $iid) {
          headPipeline {
            jobs(first: \(pageSize), after: $after, retried: false) {
              pageInfo { hasNextPage endCursor }
              nodes { \(jobFields) }
            }
          }
        }
      }
    }
    """

  private static let jobFields = "name status allowFailure manualJob startedAt finishedAt webPath"

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
