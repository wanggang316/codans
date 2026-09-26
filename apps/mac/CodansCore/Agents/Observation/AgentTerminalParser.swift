/// Stateless parsing only. Runtime supplies identity, time and occurrence
/// bookkeeping; recovery policy is independent of provider implementations.
public nonisolated protocol AgentTerminalParser: Sendable {
  func parse(_ viewport: String) -> TerminalParseResult
}
