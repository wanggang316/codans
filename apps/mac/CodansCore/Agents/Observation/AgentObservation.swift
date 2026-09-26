import Foundation

/// Accepted runtime facts. Terminal-specific evidence stays in the tracker.
public nonisolated struct AgentObservation: Equatable, Sendable {
  public let instanceID: AgentInstanceID
  public let stateRevision: UInt64
  public let sequence: UInt64
  public let observedAt: Date
  public let state: AgentState
  public let inputAvailability: AgentInputAvailability

  public init(
    instanceID: AgentInstanceID, stateRevision: UInt64, sequence: UInt64,
    observedAt: Date, state: AgentState, inputAvailability: AgentInputAvailability
  ) {
    self.instanceID = instanceID
    self.stateRevision = stateRevision
    self.sequence = sequence
    self.observedAt = observedAt
    self.state = state
    self.inputAvailability = inputAvailability
  }
}
