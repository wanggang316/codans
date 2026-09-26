/// Total registry of pure parsers. Every supported AgentKind declares its
/// parser explicitly; adding an agent cannot silently adopt another grammar.
public nonisolated enum AgentObservationParsers {
  public static func parser(for kind: AgentKind) -> any AgentObservationParser {
    switch kind {
    case .pi: return PiObservationParser()
    case .claudeCode: return ClaudeCodeObservationParser()
    case .codex: return CodexObservationParser()
    case .gemini: return GeminiObservationParser()
    case .cursorAgent: return CursorObservationParser()
    case .cline: return ClineObservationParser()
    case .opencode: return OpenCodeObservationParser()
    case .copilot: return CopilotObservationParser()
    case .kimi: return KimiObservationParser()
    case .droid: return DroidObservationParser()
    case .amp: return AmpObservationParser()
    case .grok: return GrokObservationParser()
    case .omp: return OmpObservationParser()
    }
  }
}
