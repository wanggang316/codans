import Foundation

/// Unwraps the chat scaffolding an agent tends to put around a markdown
/// document — an opening code fence, chatter before the first heading, the
/// closing fence and anything after it — and answers structural questions
/// about what is left. Used to validate an agent-authored handoff briefing
/// without ever rewriting its prose: only wrapping is removed, the body is
/// kept byte-for-byte.
public nonisolated enum MarkdownDocumentNormalizer {
  /// The document with chat wrapping stripped and outer whitespace trimmed.
  /// Empty when nothing document-like remains.
  public static func normalized(_ text: String) -> String {
    var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).lines
    lines = droppingPreambleBeforeOpeningFence(lines)
    let opening = fence(opening: lines.first.map(trimmed) ?? "")
    if opening != nil {
      lines.removeFirst()
    }
    lines = droppingPreamble(lines)
    lines = droppingClosingFence(lines, opening: opening)
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// ATX headings that sit outside fenced code blocks, trimmed. A heading
  /// quoted inside a fence is content, not structure, and never counts.
  public static func headings(outsideFences text: String) -> [String] {
    var headings: [String] = []
    var open: Fence?
    for rawLine in text.lines {
      let line = trimmed(rawLine)
      if let fence = open {
        if closes(line, fence) { open = nil }
        continue
      }
      if let fence = fence(opening: line) {
        open = fence
        continue
      }
      if let heading = atxHeading(rawLine) {
        headings.append(heading)
      }
    }
    return headings
  }

  /// Whether every section in `sections` appears as a heading outside a
  /// fence. Matching ignores the heading level, letter case, and trailing
  /// text after a space (`## Next Steps (3)` satisfies `## Next Steps`).
  public static func hasSections(_ sections: [String], in text: String) -> Bool {
    missingSections(sections, in: text).isEmpty
  }

  /// The sections no heading satisfies, in declaration order.
  public static func missingSections(_ sections: [String], in text: String) -> [String] {
    let present = headings(outsideFences: text).map(headingKey)
    return sections.filter { section in
      let wanted = headingKey(section)
      return !present.contains { $0 == wanted || $0.hasPrefix(wanted + " ") }
    }
  }

  // MARK: - Headings

  private static func headingKey(_ heading: String) -> String {
    trimmed(heading).drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased()
  }

  /// CommonMark ATX heading: up to three spaces of indentation, one to six
  /// `#`, then a space or end of line. Four spaces of indentation is code.
  static func atxHeading(_ line: String) -> String? {
    let indentation = line.prefix { $0 == " " }.count
    guard indentation <= 3 else { return nil }
    let body = line.dropFirst(indentation)
    let hashes = body.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return nil }
    let rest = body.dropFirst(hashes)
    guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
    return body.trimmingCharacters(in: .whitespaces)
  }

  private static func isHeading(_ line: String) -> Bool {
    atxHeading(line) != nil
  }

  // MARK: - Fences

  /// A fenced-code delimiter: at least three backticks or tildes. The
  /// closer must use the same character, be at least as long, and carry
  /// nothing but whitespace after the run.
  private struct Fence: Equatable {
    let character: Character
    let length: Int
    /// The opener carried an info string (```` ```swift ````).
    let hasInfoString: Bool
  }

  private static func fence(opening line: String) -> Fence? {
    guard let first = line.first, first == "`" || first == "~" else { return nil }
    let length = line.prefix { $0 == first }.count
    guard length >= 3 else { return nil }
    let info = line.dropFirst(length)
    return Fence(character: first, length: length, hasInfoString: !info.allSatisfy(\.isWhitespace))
  }

  private static func closes(_ line: String, _ fence: Fence) -> Bool {
    let run = line.prefix { $0 == fence.character }
    guard run.count >= fence.length else { return false }
    return line.dropFirst(run.count).allSatisfy(\.isWhitespace)
  }

  /// A line that is nothing but a fence run.
  private static func isBareFence(_ line: String) -> Bool {
    guard let fence = fence(opening: line) else { return false }
    return closes(line, fence)
  }

  // MARK: - Unwrapping

  /// "Sure, here it is:" followed by "```markdown" and then the document:
  /// when a fence line precedes the first heading, everything before that
  /// fence is preamble and the fence becomes the opening fence.
  private static func droppingPreambleBeforeOpeningFence(_ lines: [String]) -> [String] {
    guard let first = lines.first, fence(opening: trimmed(first)) == nil, !isHeading(first) else {
      return lines
    }
    guard
      let heading = lines.firstIndex(where: isHeading),
      let fenceIndex = lines.firstIndex(where: { fence(opening: trimmed($0)) != nil }),
      fenceIndex < heading
    else { return lines }
    return Array(lines[fenceIndex...])
  }

  /// Chatter ahead of the first heading is dropped; a document that never
  /// reaches a heading is returned untouched so the caller can reject it.
  private static func droppingPreamble(_ lines: [String]) -> [String] {
    guard let first = lines.first, !isHeading(first) else { return lines }
    guard let start = lines.firstIndex(where: isHeading) else { return lines }
    return Array(lines[start...])
  }

  /// With an opening wrapper fence, the cut is the last bare run matching
  /// it while no inner info-string block is open — unless an info-string
  /// block opens *after* a candidate, which marks a code block in the
  /// trailer; then the last candidate before it closes the wrapper. Without
  /// an opening fence only an exact trailing bare fence line is removed, so
  /// a fence inside the body is never a cut point.
  private static func droppingClosingFence(_ lines: [String], opening: Fence?) -> [String] {
    guard let opening else {
      if let last = lines.last, isBareFence(trimmed(last)) {
        return Array(lines.dropLast())
      }
      return lines
    }
    var depth = 0
    var candidates: [Int] = []
    var trailerStart: Int?
    for (index, rawLine) in lines.enumerated() {
      let line = trimmed(rawLine)
      if closes(line, opening) {
        if depth == 0 {
          candidates.append(index)
        } else {
          depth -= 1
        }
      } else if let inner = fence(opening: line) {
        if inner.hasInfoString {
          if depth == 0, !candidates.isEmpty, trailerStart == nil {
            trailerStart = index
          }
          depth += 1
        } else if depth > 0 {
          depth -= 1
        }
      }
    }
    let cut = trailerStart.map { start in candidates.last { $0 < start } } ?? candidates.last
    guard let cut else { return lines }
    return Array(lines[..<cut])
  }

  private static func trimmed(_ line: String) -> String {
    line.trimmingCharacters(in: .whitespaces)
  }
}

nonisolated extension String {
  /// Newline-split preserving empty lines, so line indices stay stable.
  fileprivate var lines: [String] {
    split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }
}
