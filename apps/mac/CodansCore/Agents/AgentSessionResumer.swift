import Foundation

/// Renders a resume invocation without overriding the stored session's settings.
public nonisolated protocol AgentSessionResumer: Sendable {
  func resumeCommand(sessionID: String) -> String
}

nonisolated struct ClaudeCodeSessionResumer: AgentSessionResumer {
  func resumeCommand(sessionID: String) -> String {
    "claude --resume \(ShellQuoting.quoted(sessionID))"
  }
}

nonisolated struct CodexSessionResumer: AgentSessionResumer {
  func resumeCommand(sessionID: String) -> String {
    "codex resume \(ShellQuoting.quoted(sessionID))"
  }
}

nonisolated struct OmpSessionResumer: AgentSessionResumer {
  func resumeCommand(sessionID: String) -> String {
    "omp --resume \(ShellQuoting.quoted(sessionID))"
  }
}
