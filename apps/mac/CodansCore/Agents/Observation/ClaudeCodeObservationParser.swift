import Foundation

nonisolated struct ClaudeCodeObservationParser: AgentObservationParser {
  let supportsErrorRecovery = true

  func parse(_ text: String) -> AgentObservation {
    let screen = AgentObservationText.recentAgentLines(
      text, limit: AgentObservationText.recentLineLimit)
    let activity = Self.detectClaude(screen)
    let fingerprint = Self.errorFingerprint(screen)
    let visible = Set(text.split(separator: "\n").compactMap { Self.errorFingerprint(String($0)) })
    return AgentObservation(
      activity: activity == .idle && fingerprint != nil ? .error : activity,
      errorFingerprint: fingerprint,
      visibleErrorFingerprints: visible)
  }

  private static func errorFingerprint(_ text: String) -> String? {
    guard let line = AgentObservationText.trailingErrorLine(text) else { return nil }
    let banner =
      line.hasPrefix("⎿ ") ? String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) : line
    guard banner.hasPrefix("API Error: ") else { return nil }
    return banner
  }

  private static func detectClaude(_ content: String) -> AgentObservation.Activity {
    let lower = content.lowercased()
    if content.contains("⌕ Search…") || lower.contains("ctrl+r to toggle") {
      return .idle
    }
    let currentInteraction = claudeCurrentInteractionRegion(content)
    if hasClaudeBlockedPrompt(content: currentInteraction, lower: currentInteraction.lowercased()) {
      return .blocked
    }

    let above = contentAbovePromptBox(content)
    let aboveLower = above.lowercased()
    if aboveLower.contains("esc to interrupt") || aboveLower.contains("ctrl+c to interrupt") {
      return .working
    }
    if hasSpinnerActivity(above) {
      return .working
    }
    return .idle
  }

  private static func contentAbovePromptBox(_ content: String) -> String {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let promptIndex = lines.lastIndex(where: { $0.contains("❯") }) else {
      return content
    }
    let borderIndex = lines[..<promptIndex].lastIndex(where: isBoxBorderLine)
    let endIndex = borderIndex ?? promptIndex
    return lines[..<endIndex].joined(separator: "\n")
  }

  private static func isBoxBorderLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 3 else { return false }
    return trimmed.allSatisfy { $0 == "─" || $0 == "-" }
  }

  private static func claudeCurrentInteractionRegion(_ content: String) -> String {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let promptIndex = lines.lastIndex(where: { $0.contains("❯") }) else {
      return lines.suffix(AgentObservationText.recentLineLimit).joined(separator: "\n")
    }
    let lowerBound = max(lines.startIndex, promptIndex - 10)
    return lines[lowerBound..<lines.endIndex].joined(separator: "\n")
  }

  private static func hasClaudeBlockedPrompt(content: String, lower: String) -> Bool {
    if lower.contains("do you want to proceed?")
      || lower.contains("would you like to proceed?")
      || lower.contains("waiting for permission")
      || lower.contains("do you want to allow this connection?")
      || lower.contains("tab to amend")
      || lower.contains("ctrl+e to explain")
      || lower.contains("chat about this")
      || lower.contains("review your answers")
      || lower.contains("skip interview and plan immediately")
    {
      return true
    }
    return AgentObservationText.hasConfirmationPrompt(lower)
      || (hasClaudeSelectionPrompt(content) && hasClaudeYesNoChoice(content))
  }

  private static func hasClaudeSelectionPrompt(_ content: String) -> Bool {
    content.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      return trimmed.hasPrefix("❯")
        && trimmed.contains(".")
        && trimmed.contains(where: \.isNumber)
    }
  }

  private static func hasClaudeYesNoChoice(_ content: String) -> Bool {
    content.split(separator: "\n").contains { line in
      let line = line.trimmingCharacters(in: .whitespaces)
      let option =
        line.hasPrefix("❯")
        ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        : line
      let trimmed = option.lowercased()
      return trimmed == "yes"
        || trimmed == "no"
        || trimmed.hasPrefix("1. yes")
        || trimmed.hasPrefix("2. no")
        || trimmed.hasPrefix("yes, and ")
        || trimmed.hasPrefix("no, and tell claude")
    }
  }

  private static func hasSpinnerActivity(_ content: String) -> Bool {
    // `※` is deliberately absent: Claude Code prefixes its post-completion
    // recap line with it (`※ recap: …`), and a recap truncated to the
    // terminal width ends in `…` — which would otherwise satisfy the
    // spinner-line shape below and pin a *finished* agent on `working`
    // (observed as a done→working flip while the recap re-rendered). The
    // live working spinner uses the sparkle/asterisk frames kept here; the
    // `✻ Crunched for …s` completion summary carries no `…`, so it is
    // already excluded by the `…` requirement.
    let spinnerScalars: Set<UnicodeScalar> = [
      "·", "✱", "✲", "✳", "✴", "✵", "✶", "✷", "✸", "✹", "✺", "✻", "✼", "✽", "✾",
      "✿", "❀", "❁", "❂", "❃", "❇", "❈", "❉", "❊", "❋", "✢", "✣", "✤", "✥",
      "✦", "✧", "✨", "⊛", "⊕", "⊙", "◉", "◎", "◍", "⁂", "⁕", "⍟", "☼",
      "★", "☆",
    ]
    return content.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let first = trimmed.unicodeScalars.first else { return false }
      let rest = String(trimmed.unicodeScalars.dropFirst())
      return spinnerScalars.contains(first)
        && rest.hasPrefix(" ")
        && rest.contains("…")
        && rest.contains(where: \.isLetter)
    }
  }

}
