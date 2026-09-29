import Foundation

nonisolated struct PiObservationParser: AgentTerminalParser {
  func parse(_ text: String) -> TerminalParseResult {
    let screen = AgentObservationText.interactionLines(text, promptPrefixes: ["pi>"]).joined(separator: "\n")
    let activity = Self.detectPi(screen)
    if activity == .unknown, Self.hasEmptyEditor(text) {
      return .idle(inputAvailability: .unknown)
    }
    return AgentObservationText.result(activity: activity, text: screen, promptPrefixes: ["pi>"])
  }

  private static func hasEmptyEditor(_ content: String) -> Bool {
    // Inspect raw rows: stripping quoted/code text would turn occupied editors
    // into empty ones. Borders prove execution idle, not permission to paste.
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    let nonBlank = lines.indices.filter { !lines[$0].isEmpty }
    guard nonBlank.count >= 2 else { return false }
    let bottom = nonBlank[nonBlank.count - 1]
    let top = nonBlank[nonBlank.count - 2]
    guard bottom > top + 1,
      lines[top].count >= 3, lines[top].allSatisfy({ $0 == "─" }),
      lines[bottom].count >= 3, lines[bottom].allSatisfy({ $0 == "─" })
    else { return false }
    let unquoted = AgentObservationText.unquotedLines(content)
    return unquoted[top] == lines[top] && unquoted[bottom] == lines[bottom]
  }

  private static func detectPi(_ content: String) -> AgentObservedActivity {
    if content.contains("Working...") { return .working }
    // Pi embeds its live loader in the editor's top border. The message
    // is customizable and can disappear at narrow widths; the border and
    // spinner remain, unlike ordinary transcript text or startup help.
    let hasBorderLoader = content.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("─") else { return false }
      let status = trimmed.drop(while: { $0 == "─" || $0.isWhitespace })
      guard let first = status.unicodeScalars.first else { return false }
      return (0x2801...0x28FF).contains(first.value) && status.hasSuffix("─")
    }
    return hasBorderLoader ? .working : .unknown
  }

}
