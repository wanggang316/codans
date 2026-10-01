/// Compatibility lookup. AgentRegistry owns the only exhaustive registration.
public nonisolated enum AgentObservationParsers {
  public static func parser(for kind: AgentKind) -> any AgentTerminalParser {
    AgentRegistry.definition(for: kind).terminalParser
  }
}
