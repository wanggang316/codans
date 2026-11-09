import CodansCore
import Foundation
import Observation

/// Agent Skill completion for a composer text editor: finds the skill call
/// the caret is in, filters the skills by it, and builds the text with the
/// picked skill's call token. Owned by the view that owns the editor and
/// independent of any one feature, so every prompt input can use it.
///
/// Positions are UTF-16 offsets, as in `ComposerPathInsertion`.
@MainActor
@Observable
final class ComposerSkillCompletion {
  /// The skill call being typed: the prefix character and the query after
  /// it, up to the caret.
  struct Query: Equatable {
    /// From the prefix character to the caret.
    var range: Range<Int>
    var text: String
  }

  /// What a key press did. `ignored` lets the owner run its own handling
  /// (Return sends, Escape closes the dialog).
  enum KeyOutcome: Equatable {
    case ignored
    case handled
    /// Replace the text and put the caret at the offset.
    case insert(text: String, caret: Int)
  }

  enum Key: Equatable {
    case up, down, accept, dismiss
  }

  /// Skills the agent can call. Setting them refilters the open list.
  var skills: [AgentSkillEntry] = [] {
    didSet { refilter() }
  }
  /// The agent's Skill Location. `none` style turns completion off.
  var location: SkillLocation = .none {
    didSet {
      if location != oldValue { close() }
    }
  }

  private(set) var query: Query?
  private(set) var matches: [AgentSkillEntry] = []
  private(set) var highlightedIndex = 0
  /// Start of the call the user closed with Escape. The list stays closed
  /// for that call until the caret leaves it.
  private var dismissedStart: Int?

  var isOpen: Bool { query != nil && !matches.isEmpty }

  var highlighted: AgentSkillEntry? {
    matches.indices.contains(highlightedIndex) ? matches[highlightedIndex] : nil
  }

  /// Recomputes the list after the text or the caret changed. `caret` is
  /// `nil` when the editor reports none; the end of the text is used.
  func update(text: String, caret: Int?) {
    let found = location.invocationStyle.prefix.flatMap { prefix in
      Self.query(
        in: text, caret: caret ?? text.utf16.count, prefix: prefix,
        position: location.invocationPosition)
    }
    if let dismissedStart, found?.range.lowerBound != dismissedStart {
      self.dismissedStart = nil
    }
    guard let found, found.range.lowerBound != dismissedStart else {
      close()
      return
    }
    if found.range.lowerBound != query?.range.lowerBound || found.text != query?.text {
      highlightedIndex = 0
    }
    query = found
    refilter()
  }

  /// Handles a key while the editor has focus. Does nothing when the list
  /// is closed.
  func handle(_ key: Key, text: String) -> KeyOutcome {
    guard isOpen else { return .ignored }
    switch key {
    case .up:
      highlightedIndex = (highlightedIndex - 1 + matches.count) % matches.count
      return .handled
    case .down:
      highlightedIndex = (highlightedIndex + 1) % matches.count
      return .handled
    case .dismiss:
      dismissedStart = query?.range.lowerBound
      close()
      return .handled
    case .accept:
      guard let highlighted else { return .handled }
      return select(highlighted, text: text)
    }
  }

  /// Replaces the typed call with the skill's call token and a space. When
  /// whitespace already follows, the caret goes after it instead.
  func select(_ skill: AgentSkillEntry, text: String) -> KeyOutcome {
    guard let query, let token = location.invocationStyle.token(for: skill.name) else {
      return .ignored
    }
    let rest = text.utf16.dropFirst(query.range.upperBound)
    let followedBySpace = rest.first.flatMap(Unicode.Scalar.init).map {
      Character($0).isWhitespace
    } ?? false
    let result = Self.replacing(query.range, in: text, with: followedBySpace ? token : token + " ")
    close()
    return .insert(text: result.text, caret: result.caret + (followedBySpace ? 1 : 0))
  }

  /// Closes the list without blocking it from opening again.
  func close() {
    query = nil
    matches = []
    highlightedIndex = 0
  }

  private func refilter() {
    guard let query else { return }
    matches = Self.filter(skills, query: query.text)
    if matches.isEmpty {
      close()
    } else if highlightedIndex >= matches.count {
      highlightedIndex = 0
    }
  }

  // MARK: - Rules

  /// The skill call that ends at `caret`: a token that starts with
  /// `prefix` at the prompt start or after whitespace and has no
  /// whitespace up to the caret. `leading` allows only the first token of
  /// the prompt.
  nonisolated static func query(
    in text: String, caret: Int, prefix: Character, position: SkillInvocationPosition
  ) -> Query? {
    let utf16 = text.utf16
    guard caret >= 0, caret <= utf16.count else { return nil }
    let caretIndex = utf16.index(utf16.startIndex, offsetBy: caret)
    // `String.Index` from UTF-16 can sit inside a character; a caret the
    // editor reports never does, so an odd one means no call.
    guard caretIndex.samePosition(in: text) != nil else { return nil }
    let head = text[..<caretIndex]
    let tokenStart =
      head.lastIndex(where: { $0.isWhitespace }).map { head.index(after: $0) } ?? head.startIndex
    guard tokenStart < caretIndex, head[tokenStart] == prefix else { return nil }
    if position == .leading, !head[..<tokenStart].allSatisfy(\.isWhitespace) { return nil }
    let lower = utf16.distance(from: utf16.startIndex, to: tokenStart)
    let queryText = String(head[head.index(after: tokenStart)...])
    return Query(range: lower..<caret, text: queryText)
  }

  /// Fuzzy match on name and description. Order: name prefix, name
  /// substring, name subsequence, then description match; ties keep the
  /// input order. An empty query keeps every skill.
  nonisolated static func filter(_ skills: [AgentSkillEntry], query: String) -> [AgentSkillEntry] {
    let needle = query.lowercased()
    guard !needle.isEmpty else { return skills }
    let ranked = skills.enumerated().compactMap { offset, skill -> (rank: Int, offset: Int, skill: AgentSkillEntry)? in
      let name = skill.name.lowercased()
      let rank: Int
      if name.hasPrefix(needle) {
        rank = 0
      } else if name.contains(needle) {
        rank = 1
      } else if isSubsequence(needle, of: name) {
        rank = 2
      } else if let summary = skill.summary?.lowercased(),
        summary.contains(needle) || isSubsequence(needle, of: summary)
      {
        rank = 3
      } else {
        return nil
      }
      return (rank, offset, skill)
    }
    return ranked.sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }.map(\.skill)
  }

  nonisolated static func replacing(
    _ range: Range<Int>, in text: String, with replacement: String
  ) -> (text: String, caret: Int) {
    let utf16 = text.utf16
    let lower = utf16.index(utf16.startIndex, offsetBy: min(range.lowerBound, utf16.count))
    let upper = utf16.index(utf16.startIndex, offsetBy: min(range.upperBound, utf16.count))
    var result = text
    result.replaceSubrange(lower..<upper, with: replacement)
    return (result, range.lowerBound + replacement.utf16.count)
  }

  private nonisolated static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
    var remaining = needle[...]
    for character in haystack where character == remaining.first {
      remaining = remaining.dropFirst()
      if remaining.isEmpty { return true }
    }
    return remaining.isEmpty
  }
}
