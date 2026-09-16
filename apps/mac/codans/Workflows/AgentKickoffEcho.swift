import CodansCore
import Foundation

/// Recognizes a submitted paste in an Agent composer before sending Return.
nonisolated enum AgentKickoffEcho {
  static func containsPaste(kind: AgentKind, prompt: String, before: String, after: String) -> Bool {
    let marker = String(prompt.prefix(19))
    guard !marker.isEmpty else { return false }
    if kind == .pi { return containsPiPaste(prompt: prompt, before: before, after: after) }
    guard kind == .omp else { return after.contains(marker) || after.contains("Pasted") }
    if attachmentIDs(in: after).isEmpty { return after.contains(marker) }
    // OMP collapses multiline input into a numbered attachment card. Require
    // a new card plus its truncated prompt preview, rather than any old chip.
    let newAttachments = attachmentIDs(in: after).subtracting(attachmentIDs(in: before))
    guard !newAttachments.isEmpty else { return false }
    let lines = after.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    for (index, line) in lines.enumerated() where line.hasPrefix("╭") {
      guard !attachmentIDs(in: line).isDisjoint(with: newAttachments), index + 1 < lines.count
      else { continue }
      let firstPreviewLine = lines[index + 1]
      guard firstPreviewLine.hasPrefix("│"), firstPreviewLine.hasSuffix("│") else { continue }
      let preview = firstPreviewLine.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
      guard preview.hasSuffix("…") else { continue }
      let prefix = String(preview.dropLast())
      if prefix.count >= 8 && prompt.hasPrefix(prefix) { return true }
    }
    return false
  }

  static func composerReady(kind: AgentKind, screen: String) -> Bool {
    if kind == .claudeCode {
      return PaneAttentionInterpreter.hasEmptyClaudePrompt(viewportText: screen)
    }
    return canAcceptPaste(kind: kind, screen: screen)
  }

  static func hasPendingInput(kind: AgentKind, screen: String) -> Bool {
    if kind == .pi { return piComposer(screen).map { !$0.isEmpty } ?? false }
    return kind == .omp && hasPendingOmpAttachment(screen)
  }

  static func canAcceptPaste(kind: AgentKind, screen: String) -> Bool {
    if kind == .pi { return piComposer(screen) == "" }
    return kind != .omp || !hasPendingOmpAttachment(screen)
  }

  private static func containsPiPaste(prompt: String, before: String, after: String) -> Bool {
    guard piComposer(before) == "", let composer = piComposer(after) else { return false }
    let expanded = prompt.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\t", with: "    ")
    let normalized = String(
      String.UnicodeScalarView(expanded.unicodeScalars.filter { $0.value >= 32 || $0.value == 10 }))
    let lines = normalized.components(separatedBy: "\n").count
    if lines > 10 || normalized.utf16.count > 1000 {
      let size = lines > 10 ? "+\(lines) lines" : "\(normalized.utf16.count) chars"
      let escapedSize = NSRegularExpression.escapedPattern(for: size)
      return composer.range(of: "^\\[paste #[1-9][0-9]* \(escapedSize)\\]$", options: .regularExpression) != nil
    }
    return composer == normalized.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Pi renders its editor between horizontal rules. Scope evidence to that
  /// editor because submitted history can contain identical paste markers.
  private static func piComposer(_ screen: String) -> String? {
    let lines = screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    let borders = lines.indices.filter { index in
      lines[index].count >= 3 && lines[index].allSatisfy { $0 == "─" }
    }
    guard borders.count >= 2, let bottom = borders.last, bottom >= lines.count - 6 else {
      return nil
    }
    let top = borders[borders.count - 2]
    return lines[(top + 1)..<bottom].joined(separator: "\n").trimmingCharacters(
      in: .whitespacesAndNewlines)
  }

  static func hasPendingOmpAttachment(_ screen: String) -> Bool {
    screen.split(separator: "\n").suffix(6).contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      return trimmed.hasPrefix("╰─") && !attachmentIDs(in: trimmed).isEmpty
    }
  }

  private static func attachmentIDs(in text: String) -> Set<String> {
    guard let pattern = try? NSRegularExpression(pattern: "📄 #[0-9]+") else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return Set(
      pattern.matches(in: text, range: range).compactMap { match in
        Range(match.range, in: text).map { String(text[$0]) }
      })
  }
}
