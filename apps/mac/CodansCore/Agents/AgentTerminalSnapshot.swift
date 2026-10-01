import Foundation

/// Text whose owning process and surface were checked before and after capture.
public nonisolated struct AgentTerminalSnapshot: Equatable, Sendable {
  public let binding: AgentBinding
  public let sequence: UInt64
  public let observedAt: Date
  public let text: String

  public init(binding: AgentBinding, sequence: UInt64, observedAt: Date, text: String) {
    self.binding = binding
    self.sequence = sequence
    self.observedAt = observedAt
    self.text = text
  }
}
