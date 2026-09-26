import Foundation

/// The actual Agent process, rather than the wrapper that owns its foreground group.
public nonisolated struct AgentProcessIdentity: Equatable, Sendable {
  public let processID: Int32
  public let processStartedAt: Date
  public let processGroupID: Int32

  public init(processID: Int32, processStartedAt: Date, processGroupID: Int32) {
    self.processID = processID
    self.processStartedAt = processStartedAt
    self.processGroupID = processGroupID
  }
}
