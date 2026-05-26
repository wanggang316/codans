import Foundation

/// Pattern tables and a classifier that maps free-form signals
/// (`initialCommand`, terminal title, OSC-9 notification title) to a
/// known `AgentKind`. The tables stay here — rather than inside
/// `AgentKind` — so the value type stays minimal and the patterns can
/// be exercised in unit tests without spinning up the runtime.
///
/// Matching rules differ per signal because the signals themselves
/// differ in shape:
///
/// - `initialCommand` is a shell command string. We match on its
///   basename (last `/`-separated segment) and on the first
///   whitespace-separated token. A short token like `pi` would
///   misfire as a substring of `pip`, `pipenv`, `mpirun`, etc., so
///   the rule is first-token equality (case-insensitive), not
///   substring search.
/// - `title` is a human-readable terminal title that often embeds
///   version suffixes (`"Codex CLI v1.2.3"`). We match by
///   case-insensitive substring, preferring the longest pattern
///   when several `AgentKind`s would match the same string — so
///   `"Codex CLI"` correctly beats the generic `"Codex"` fallback
///   when both kinds appear in the table.
/// - `notificationTitle` is the OSC-9 notification title. The agents
///   emit short, recognisable strings here (Claude Code emits
///   `"Claude"`); a substring match is sufficient.
///
/// Resolution order is `initialCommand` → `title` →
/// `notificationTitle`. The first signal that yields a match wins;
/// the next signals are only consulted when the earlier signals were
/// nil or did not match.
public nonisolated enum AgentKindPatterns {
  /// Token-level patterns matched against `Pane.initialCommand`. The
  /// classifier compares each pattern (case-insensitive) against the
  /// command's basename and its first whitespace-separated token.
  public static let initialCommand: [AgentKind: [String]] = [
    .claudeCode: ["claude", "claude-code"],
    .codex: ["codex"],
    .pi: ["pi"],
    .opencode: ["opencode", "open-code"],
    .gemini: ["gemini"],
    .cursorAgent: ["cursor-agent"],
    .cline: ["cline"],
    .copilot: ["copilot", "github-copilot", "ghcs"],
    .kimi: ["kimi", "kimi-code"],
    .droid: ["droid"],
    .amp: ["amp", "amp-local"],
  ]

  /// Substring patterns matched against the terminal title (`OSC 0/2`
  /// + libghostty-derived title). Longer patterns are preferred when
  /// multiple kinds match the same input — see `bestTitleMatch`.
  public static let title: [AgentKind: [String]] = [
    .claudeCode: ["Claude Code", "claude"],
    .codex: ["Codex CLI", "Codex"],
    .pi: ["pi"],
    .opencode: ["opencode", "open-code"],
    .gemini: ["Gemini"],
    .cursorAgent: ["Cursor Agent", "cursor-agent"],
    .cline: ["Cline"],
    .copilot: ["GitHub Copilot", "Copilot"],
    .kimi: ["Kimi"],
    .droid: ["Droid"],
    .amp: ["Amp"],
  ]

  /// Substring patterns matched against `OSC 9` notification titles.
  /// These are the strings the agents put in their own desktop-
  /// notification banners and are the most agent-specific of the
  /// three signals.
  public static let notificationTitle: [AgentKind: [String]] = [
    .claudeCode: ["Claude"],
    .codex: ["Codex"],
    .pi: ["pi"],
    .opencode: ["opencode", "open-code"],
    .gemini: ["Gemini"],
    .cursorAgent: ["Cursor Agent", "cursor-agent"],
    .cline: ["Cline"],
    .copilot: ["GitHub Copilot", "Copilot"],
    .kimi: ["Kimi"],
    .droid: ["Droid"],
    .amp: ["Amp"],
  ]

  /// Classify a pane from up to three signals. Returns the first
  /// kind that matches in the documented resolution order, or `nil`
  /// when no signal yields a hit. Each signal is matched
  /// case-insensitively against its own pattern table.
  public static func classify(
    initialCommand: String?,
    title: String?,
    notificationTitle: String?
  ) -> AgentKind? {
    if let command = initialCommand, !command.isEmpty,
      let hit = matchInitialCommand(command)
    {
      return hit
    }
    if let title, !title.isEmpty, let hit = bestTitleMatch(title) {
      return hit
    }
    if let notificationTitle, !notificationTitle.isEmpty,
      let hit = matchNotificationTitle(notificationTitle)
    {
      return hit
    }
    return nil
  }

  // MARK: - Per-signal matchers

  /// Match the command's basename and first token against the
  /// `initialCommand` table. First-token equality (rather than
  /// substring) is load-bearing for `pi`, which would otherwise hit
  /// commands like `pip`, `pipenv`, `mpirun`, etc.
  private static func matchInitialCommand(_ command: String) -> AgentKind? {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let firstToken = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed
    let basename = (firstToken as NSString).lastPathComponent
    let candidates = [firstToken.lowercased(), basename.lowercased()]
    // Walk AgentKind.allCases so the ordering is stable rather than
    // dictionary-iteration order (which is non-deterministic).
    for kind in AgentKind.allCases {
      guard let patterns = initialCommand[kind] else { continue }
      for pattern in patterns where candidates.contains(pattern.lowercased()) {
        return kind
      }
    }
    return nil
  }

  /// Word-boundary match the title against every pattern in the
  /// `title` table and return the kind whose matching pattern is the
  /// longest. Ties (same-length patterns from different kinds)
  /// resolve by `AgentKind.allCases` order — deterministic but not
  /// otherwise meaningful; the table is curated so real-world
  /// inputs don't tie. Word-boundary matching (rather than raw
  /// substring) is load-bearing for short patterns like `"pi"`,
  /// which would otherwise hit `"shipping"`, `"piano"`, `"Spider"`,
  /// etc. Multi-word patterns like `"Claude Code"` still match
  /// because every alphanumeric run inside them is framed by
  /// whitespace or by the haystack's start/end.
  private static func bestTitleMatch(_ title: String) -> AgentKind? {
    var best: (kind: AgentKind, length: Int)?
    for kind in AgentKind.allCases {
      guard let patterns = self.title[kind] else { continue }
      for pattern in patterns where containsAsWord(title, pattern) {
        if best == nil || pattern.count > best!.length {
          best = (kind, pattern.count)
        }
      }
    }
    return best?.kind
  }

  /// Word-boundary match a notification title against the table.
  /// Same rationale as `bestTitleMatch`: notification titles like
  /// `"Helping you"` must not collide with the `.pi` pattern.
  private static func matchNotificationTitle(_ value: String) -> AgentKind? {
    for kind in AgentKind.allCases {
      guard let patterns = notificationTitle[kind] else { continue }
      for pattern in patterns where containsAsWord(value, pattern) {
        return kind
      }
    }
    return nil
  }

  /// Case-insensitive word-boundary containment. Returns `true` iff
  /// `needle` appears in `haystack` framed by either end-of-string
  /// or a non-alphanumeric character on each side. Used by the
  /// title / notificationTitle matchers so a two-letter pattern
  /// like `"pi"` doesn't fire on `"shipping"` / `"piano"` /
  /// `"Spider"`. Returns on the first occurrence — title patterns
  /// are short and rarely repeat, and the matcher only needs a
  /// yes/no answer.
  private static func containsAsWord(_ haystack: String, _ needle: String) -> Bool {
    let pattern = needle.lowercased()
    guard !pattern.isEmpty else { return false }
    let hay = haystack.lowercased()
    var searchStart = hay.startIndex
    while let range = hay.range(of: pattern, range: searchStart..<hay.endIndex) {
      let before: Character? =
        range.lowerBound == hay.startIndex
        ? nil : hay[hay.index(before: range.lowerBound)]
      let after: Character? =
        range.upperBound == hay.endIndex ? nil : hay[range.upperBound]
      if isWordBoundary(before) && isWordBoundary(after) {
        return true
      }
      // Advance past the failed candidate so overlapping matches
      // (e.g. needle `"pipi"` inside haystack `"pipipi"`) still
      // get a chance to find the real word-boundary hit.
      searchStart = hay.index(after: range.lowerBound)
    }
    return false
  }

  /// A nil character (= start / end of string) or any whitespace
  /// character counts as a word boundary. Punctuation, slashes, and
  /// dots do NOT — otherwise a terminal title carrying a path like
  /// `~/.codex/worktrees/...` would false-match `.codex` as "codex"
  /// (the actual bug reported by Gump in the field). The agent's brand
  /// name should be set off from its neighbours by whitespace or
  /// stand alone; anything embedded inside a path component is noise.
  private static func isWordBoundary(_ character: Character?) -> Bool {
    guard let character else { return true }
    return character.isWhitespace
  }
}
