/// Agent-specific, stateless interpretation of a rendered active region.
/// Binding, observation time, hysteresis, and recovery policy belong to callers.
public nonisolated protocol AgentObservationParser: Sendable {
  var supportsErrorRecovery: Bool { get }
  func parse(_ text: String) -> AgentObservation
}

extension AgentObservationParser {
  public var supportsErrorRecovery: Bool { false }
}
