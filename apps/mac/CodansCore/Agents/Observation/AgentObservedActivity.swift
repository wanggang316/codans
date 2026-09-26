/// Raw activity inferred from one rendered agent observation.
public nonisolated enum AgentObservedActivity: Equatable, Sendable {
  case unknown
  case working
  case blocked
  case error
  case idle

  public var isActive: Bool {
    self == .working || self == .blocked
  }
}
