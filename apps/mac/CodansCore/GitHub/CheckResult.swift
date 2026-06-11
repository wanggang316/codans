import Foundation

/// One check run or status context associated with a pull request's head commit.
/// Decoded from `gh pr checks --json ...` by the app-tier parsers. A PR may surface
/// zero or many of these; rollup to a single pass/fail/pending view happens in the
/// feature reducer.
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

/// Check-run lifecycle state. Raw values match GitHub's GraphQL `CheckStatusState`.
public enum CheckStatus: String, Codable, Sendable, CaseIterable {
  case queued = "QUEUED"
  case inProgress = "IN_PROGRESS"
  case completed = "COMPLETED"
  case waiting = "WAITING"
  case pending = "PENDING"
}

/// Check-run conclusion once completed. Raw values match GitHub's `CheckConclusionState`.
public enum CheckConclusion: String, Codable, Sendable, CaseIterable {
  case success = "SUCCESS"
  case failure = "FAILURE"
  case cancelled = "CANCELLED"
  case skipped = "SKIPPED"
  case neutral = "NEUTRAL"
  case timedOut = "TIMED_OUT"
  case actionRequired = "ACTION_REQUIRED"
  case stale = "STALE"
  case startupFailure = "STARTUP_FAILURE"
}
