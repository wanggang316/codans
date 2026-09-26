import Foundation

nonisolated struct CodexObservationParser: AgentObservationParser {
  let supportsErrorRecovery = true

  func parse(_ text: String) -> AgentObservation {
    let screen = AgentObservationText.recentAgentLines(
      text, limit: AgentObservationText.recentLineLimit)
    let activity = Self.detectCodex(screen)
    let fingerprint = Self.errorFingerprint(screen)
    let visible = Set(text.split(separator: "\n").compactMap { Self.errorFingerprint(String($0)) })
    return AgentObservation(
      activity: activity == .idle && fingerprint != nil ? .error : activity,
      errorFingerprint: fingerprint,
      visibleErrorFingerprints: visible)
  }

  private static func errorFingerprint(_ text: String) -> String? {
    guard let line = AgentObservationText.trailingErrorLine(text) else { return nil }
    guard line.hasPrefix("■ ") else { return nil }
    let message = String(line.dropFirst(2))
    let prefixes = [
      "stream disconnected before completion:", "unexpected status ",
      "exceeded retry limit", "You've hit your usage limit",
    ]
    guard prefixes.contains(where: message.hasPrefix) else { return nil }
    return message
  }

  private static func detectCodex(_ content: String) -> AgentObservation.Activity {
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
    if hasTrailingIdlePrompt(content, prefixes: ["codex>"]) {
      return .idle
    }
    if AgentObservationText.hasInterruptPattern(lower) || hasCodexWorkingHeader(content) {
      return .working
    }
    return .idle
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
