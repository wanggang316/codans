import Foundation

public nonisolated enum AgentState: Equatable, Sendable {
  case unknown
  case idle
  case working
  case blocked
  case error(AgentFailure)
}

public nonisolated struct AgentFailure: Equatable, Codable, Sendable {
  public enum Reason: String, CaseIterable, Codable, Sendable {
    case transient
    case rateLimited
    case authentication
    case quotaExceeded
    case configuration
    case unknown
  }

  public let reason: Reason
  public let message: String
  public let providerCode: String?
  public let retryAfterSeconds: Int?

  public init(reason: Reason, message: String, providerCode: String? = nil, retryAfterSeconds: Int? = nil) {
    self.reason = reason
    self.message = message
    self.providerCode = providerCode
    self.retryAfterSeconds = retryAfterSeconds
  }
}

public nonisolated enum AgentPromptContent: Equatable, Sendable {
  case empty
  case occupied
  case unknown
}

public nonisolated enum AgentInputAvailability: Equatable, Sendable {
  case prompt(AgentPromptContent)
  case choice
  case unavailable
  case unknown
}

public nonisolated struct AgentInstanceID: Hashable, Codable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}
