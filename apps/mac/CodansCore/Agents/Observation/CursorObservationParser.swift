import Foundation

nonisolated struct CursorObservationParser: AgentTerminalParser {
  func parse(_ text: String) -> TerminalParseResult {
    let screen = AgentObservationText.interactionLines(text, promptPrefixes: ["cursor>"]).joined(separator: "\n")
    return AgentObservationText.result(activity: Self.detectCursor(screen), text: screen, promptPrefixes: ["cursor>"])
  }

  private static func detectCursor(_ content: String) -> AgentObservedActivity {
    let lower = content.lowercased()
    if lower.contains("workspace trust required")
      || lower.contains("trust this workspace")
      || hasCursorPermissionPrompt(content: content, lower: lower)
    {
      return .blocked
    }
    if lower.contains("trusting workspace") || lower.contains("ctrl+c to stop")
      || hasCursorSpinner(content)
    {
      return .working
    }
    return .unknown
  }

  private static func hasCursorPermissionPrompt(content: String, lower: String) -> Bool {
    if lower.contains("(y) (enter)") {
      return true
    }

    let hasPermissionHeader =
      lower.contains("run this command?")
      || lower.contains("run command?")
      || lower.contains("not in allowlist")
      || lower.contains("to allowlist?")
      || lower.contains("allow execution")
    guard hasPermissionHeader else { return false }

    let hasConfirmAction = content.split(separator: "\n", omittingEmptySubsequences: false)
      .contains { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.contains("(y)") else { return false }
        return trimmed.contains("run") || trimmed.contains("allow")
      }
    let hasCancelAction =
      lower.contains("skip (esc or n)")
      || lower.contains("keep (n)")

    return hasConfirmAction || hasCancelAction
  }

  private static func hasCursorSpinner(_ content: String) -> Bool {
    content.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
      return (trimmed.hasPrefix("⬡") || trimmed.hasPrefix("⬢")) && trimmed.contains("ing")
    }
  }

}
