import Foundation

nonisolated struct CodexObservationParser: AgentTerminalParser {
  func parse(_ text: String) -> TerminalParseResult {
    AgentTerminalErrorParsing.parse(
      text, promptPrefixes: ["codex>", "›"], activity: Self.detectCodex, banner: Self.errorFingerprint)
  }

  private static func errorFingerprint(_ text: String) -> String? {
    let line = text.trimmingCharacters(in: .whitespaces)
    guard line.hasPrefix("■ ") else { return nil }
    let message = String(line.dropFirst(2))
    let prefixes = [
      "stream disconnected before completion:", "unexpected status ",
      "exceeded retry limit", "You've hit your usage limit",
    ]
    guard prefixes.contains(where: message.hasPrefix) else { return nil }
    return message
  }

  private static func detectCodex(_ content: String) -> AgentObservedActivity {
    let lower = content.lowercased()
    if lower.contains("press enter to confirm or esc to cancel")
      || lower.contains("enter to submit answer")
      || lower.contains("allow command?")
      || lower.contains("[y/n]")
      || lower.contains("yes (y)")
      || AgentObservationText.hasConfirmationPrompt(lower)
    {
      return .blocked
    }
    if hasTrailingIdlePrompt(content, prefixes: ["codex>"]) { return .idle }
    if AgentObservationText.hasInterruptPattern(lower) || hasCodexWorkingHeader(content) {
      return .working
    }
    return .unknown
  }

  private static func hasTrailingIdlePrompt(_ content: String, prefixes: [String]) -> Bool {
    guard
      let line = content.split(separator: "\n").last(where: {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
      })
    else {
      return false
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
    return prefixes.contains { trimmed.hasPrefix($0) }
  }

  private static func hasCodexWorkingHeader(_ content: String) -> Bool {
    content.split(separator: "\n").contains { line in
      line.trimmingCharacters(in: .whitespaces).hasPrefix("• Working (")
    }
  }

}
