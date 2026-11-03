import Foundation

/// One CI check on the head commit of a Pull Request (a GitHub check run or status
/// context, a GitLab pipeline job). Each Code Host's decoding layer builds it. A Pull
/// Request may carry zero or many; the views roll them up into one pass/fail/pending view.
public struct CheckResult: Equatable, Codable, Sendable, Identifiable {
  /// Composite identity: `"\(name)@\(startedAt?.timeIntervalSince1970 ?? 0)"`. Check names
  /// repeat across runs, so the (name, startedAt) pair is what stays stable row-to-row
  /// when the UI animates updates. Callers that need a raw check name read `.name`.
  public var id: String { "\(name)@\(startedAt?.timeIntervalSince1970 ?? 0)" }

  public var name: String
  public var status: CheckStatus
  public var conclusion: CheckConclusion?
  public var detailsURL: URL?
  public var startedAt: Date?
  public var completedAt: Date?
  public var durationSeconds: Int?

  public init(
    name: String,
    status: CheckStatus,
    conclusion: CheckConclusion? = nil,
    detailsURL: URL? = nil,
    startedAt: Date? = nil,
    completedAt: Date? = nil,
    durationSeconds: Int? = nil
  ) {
    self.name = name
    self.status = status
    self.conclusion = conclusion
    self.detailsURL = detailsURL
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.durationSeconds = durationSeconds
  }
}

/// Check lifecycle state. Provider-neutral: each Code Host's decoding layer maps its
/// wire values into these cases. Raw values are the snapshot-cache form.
public enum CheckStatus: String, Codable, Sendable, CaseIterable {
  case queued
  case inProgress
  case completed
  case waiting
  case pending
}

/// Check conclusion once completed. Provider-neutral, as `CheckStatus`.
public enum CheckConclusion: String, Codable, Sendable, CaseIterable {
  case success
  case failure
  case cancelled
  case skipped
  case neutral
  case timedOut
  case actionRequired
  case stale
  case startupFailure
}
