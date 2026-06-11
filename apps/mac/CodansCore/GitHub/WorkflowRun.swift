import Foundation

/// One GitHub Actions workflow run on the head branch of a pull request. Decoded from
/// `gh run list --branch <branch> --json ...`. Only the latest run per branch is surfaced
/// to the UI; the feature reducer uses `databaseID` to target `gh run rerun <id> --failed`.
public struct WorkflowRun: Equatable, Codable, Sendable, Identifiable {
  public var id: Int64 { databaseID }

  public var databaseID: Int64
  public var name: String
  public var status: CheckStatus
  public var conclusion: CheckConclusion?
  public var headBranch: String
  public var headSHA: String
  public var runNumber: Int
  public var updatedAt: Date
  public var url: URL

  public init(
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
