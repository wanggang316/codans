import Foundation

nonisolated struct GrokObservationParser: AgentTerminalParser {
  func parse(_ text: String) -> TerminalParseResult {
    let screen = AgentObservationText.interactionLines(text, promptPrefixes: ["grok>"]).joined(separator: "\n")
    return AgentObservationText.result(
      activity: Self.detectGenericInterruptCue(screen), text: screen, promptPrefixes: ["grok>"])
  }

  /// Fallback classifier for agents whose TUI we have not profiled yet: the
  /// two cues almost every CLI agent renders — a yes/no confirmation prompt
  /// (blocked) and an "esc to interrupt / cancel" hint (working). Less
  /// precise than a hand-tuned detector, but it keeps the badge honest
  /// instead of pinning a live agent on idle.
  private static func detectGenericInterruptCue(_ content: String) -> AgentObservedActivity {
    let lower = content.lowercased()
    if AgentObservationText.hasConfirmationPrompt(lower) || lower.contains("[y/n]") || lower.contains("(y/n)") {
      return .blocked
    }
    if AgentObservationText.hasInterruptPattern(lower) || lower.contains("esc to cancel")
      || lower.contains("esc to stop")
    {
      return .working
    }
    return .unknown
  }

}
