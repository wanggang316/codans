import CodansCore
import Foundation

/// One GitHub Actions workflow run on the source branch of a pull request. Decoded from
/// `gh run list --branch <branch> --json ...`. `GitHubCodeHost.rerunFailedChecks` uses
/// the latest run's `databaseID` to target `gh run rerun <id> --failed`.
nonisolated struct WorkflowRun: Equatable, Codable, Sendable, Identifiable {
  var id: Int64 { databaseID }

  var databaseID: Int64
  var name: String
  var status: CheckStatus
  var conclusion: CheckConclusion?
  var headBranch: String
  var headSHA: String
  var runNumber: Int
  var updatedAt: Date
  var url: URL

  init(
    databaseID: Int64,
    name: String,
    status: CheckStatus,
    conclusion: CheckConclusion? = nil,
    headBranch: String,
    headSHA: String,
    runNumber: Int,
    updatedAt: Date,
    url: URL
  ) {
    self.databaseID = databaseID
    self.name = name
    self.status = status
    self.conclusion = conclusion
    self.headBranch = headBranch
    self.headSHA = headSHA
    self.runNumber = runNumber
    self.updatedAt = updatedAt
    self.url = url
  }
}
