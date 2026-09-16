import CodansCore
import Foundation

/// Recognizes a submitted paste in an Agent composer before sending Return.
nonisolated enum AgentKickoffEcho {
  static func containsPaste(kind: AgentKind, prompt: String, before: String, after: String) -> Bool {
    let marker = String(prompt.prefix(19))
    guard !marker.isEmpty else { return false }
    guard kind == .omp else { return after.contains(marker) || after.contains("Pasted") }
    if attachmentIDs(in: after).isEmpty { return after.contains(marker) }
    // OMP collapses multiline input into a numbered attachment card. Require
    // a new card plus its truncated prompt preview, rather than any old chip.
    let newAttachments = attachmentIDs(in: after).subtracting(attachmentIDs(in: before))
    guard !newAttachments.isEmpty else { return false }
    let lines = after.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    for (index, line) in lines.enumerated() where line.hasPrefix("╭") {
      guard !attachmentIDs(in: line).isDisjoint(with: newAttachments), index + 1 < lines.count else { continue }
      let firstPreviewLine = lines[index + 1]
      guard firstPreviewLine.hasPrefix("│"), firstPreviewLine.hasSuffix("│") else { continue }
      let preview = firstPreviewLine.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
      guard preview.hasSuffix("…") else { continue }
      let prefix = String(preview.dropLast())
      if prefix.count >= 8 && prompt.hasPrefix(prefix) { return true }
    }
    return false
  }

  static func canAcceptPaste(kind: AgentKind, screen: String) -> Bool {
    kind != .omp || !hasPendingOmpAttachment(screen)
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
