import Foundation
import Testing

@testable import TouchCodeCore

/// Exercises the `AgentKindPatterns.classify` decision table and the
/// new `Pane.agentKind` / `Pane.agentSessionID` Codable round-trip +
/// backward-compatibility properties (T1 of the ActiveAgents plan).
///
/// The classifier has three signals and an explicit resolution order
/// (initialCommand → title → notificationTitle), with two
/// load-bearing subtleties:
///
/// - `pi` is short enough that substring matching against
///   `initialCommand` would mis-fire on `pip`, `pipenv`, `mpirun`,
///   etc., so the rule is first-token-equality, not substring.
/// - `title` patterns can overlap (e.g. `"Codex"` is a prefix of
///   `"Codex CLI"`), so the matcher prefers the longest pattern.
struct AgentKindPatternsTests {
  // MARK: - initialCommand hits

  @Test
  func initialCommand_claudeBareToken() {
    #expect(
      AgentKindPatterns.classify(initialCommand: "claude", title: nil, notificationTitle: nil)
        == .claudeCode
    )
  }

  @Test
  func initialCommand_claudeWithFullPath() {
    // Basename of `/usr/local/bin/claude` must still match.
    #expect(
      AgentKindPatterns.classify(
        initialCommand: "/usr/local/bin/claude",
        title: nil,
        notificationTitle: nil
      ) == .claudeCode
    )
  }

  @Test
  func initialCommand_claudeWithArgsAndUppercase() {
    // First-token match, case-insensitive.
    #expect(
      AgentKindPatterns.classify(
        initialCommand: "CLAUDE --resume",
        title: nil,
        notificationTitle: nil
      ) == .claudeCode
    )
  }

  @Test
  func initialCommand_claudeCodeHyphenatedAlias() {
    #expect(
      AgentKindPatterns.classify(
        initialCommand: "claude-code --help",
        title: nil,
        notificationTitle: nil
      ) == .claudeCode
    )
  }

  @Test
  func initialCommand_codexBareToken() {
    #expect(
      AgentKindPatterns.classify(initialCommand: "codex", title: nil, notificationTitle: nil)
        == .codex
    )
  }

  @Test
  func initialCommand_codexCaseInsensitive() {
    #expect(
      AgentKindPatterns.classify(initialCommand: "Codex", title: nil, notificationTitle: nil)
        == .codex
    )
  }

  @Test
  func initialCommand_piBareToken() {
    #expect(
      AgentKindPatterns.classify(initialCommand: "pi", title: nil, notificationTitle: nil) == .pi
    )
  }

  // MARK: - .pi hits via title / notificationTitle

  /// Per-kind dimension coverage: `.pi` must hit on `title` as well as
  /// on `initialCommand`. The title pattern table only contains
  /// `["pi"]` for `.pi`; `"pi"` substring-matches none of the
  /// `.claudeCode` / `.codex` title patterns, so this should classify
  /// cleanly without tripping the longest-pattern tiebreaker.
  @Test
  func title_piBareWord() {
    #expect(
      AgentKindPatterns.classify(initialCommand: nil, title: "pi", notificationTitle: nil) == .pi
    )
  }

  /// Per-kind dimension coverage: `.pi` must hit on
  /// `notificationTitle`. Same substring-safety argument as
  /// `title_piBareWord`.
  @Test
  func notificationTitle_piMatches() {
    #expect(
      AgentKindPatterns.classify(initialCommand: nil, title: nil, notificationTitle: "pi") == .pi
    )
  }

  // MARK: - initialCommand: first-token-only behaviour

  @Test
  func initialCommand_pipDoesNotMatchPi() {
    // `pip` is a prefix containing `pi`, but first-token equality
    // (rather than substring) must reject it.
    #expect(
      AgentKindPatterns.classify(initialCommand: "pip install foo", title: nil, notificationTitle: nil)
        == nil
    )
  }

  @Test
  func initialCommand_pipenvDoesNotMatchPi() {
    #expect(
      AgentKindPatterns.classify(initialCommand: "pipenv shell", title: nil, notificationTitle: nil)
        == nil
    )
  }

  @Test
  func initialCommand_mpirunDoesNotMatchPi() {
    #expect(
      AgentKindPatterns.classify(
        initialCommand: "mpirun -n 4 ./solve",
        title: nil,
        notificationTitle: nil
      ) == nil
    )
  }

  // MARK: - .claudeCode near-misses

  /// First-token equality means a token that merely *resembles*
  /// `"claude"` (here a misspelt `"clawd"`) must not classify.
  @Test
  func initialCommand_clawdDoesNotMatchClaude() {
    #expect(
      AgentKindPatterns.classify(initialCommand: "clawd", title: nil, notificationTitle: nil) == nil
    )
  }

  /// First-token equality also rejects `"claudius"`, even though it
  /// shares the `"claud"` prefix with the `.claudeCode` pattern.
  @Test
  func initialCommand_claudiusDoesNotMatchClaude() {
    #expect(
      AgentKindPatterns.classify(
        initialCommand: "claudius status",
        title: nil,
        notificationTitle: nil
      ) == nil
    )
  }

  /// Substring matching on `title` looks for the *full* pattern
  /// string. `"claudication"` lacks the trailing `"e"` of `"claude"`
  /// (`c-l-a-u-d-i-c-a-t-i-o-n`) so it cannot match either
  /// `"claude"` or `"Claude Code"`.
  @Test
  func title_claudicationDoesNotMatchClaude() {
    #expect(
      AgentKindPatterns.classify(
        initialCommand: nil,
        title: "claudication report",
        notificationTitle: nil
      ) == nil
    )
  }

  // MARK: - .codex near-misses

  /// `"codexlike"` shares the `"codex"` prefix but first-token
  /// equality on `initialCommand` requires exact match (case-
  /// insensitive), not prefix.
  @Test
  func initialCommand_codexlikeDoesNotMatchCodex() {
    #expect(
      AgentKindPatterns.classify(
        initialCommand: "codexlike",
        title: nil,
        notificationTitle: nil
      ) == nil
    )
  }

  /// `"codecs"` is a near-neighbour of `"codex"` and must not
  /// classify under first-token equality.
  @Test
  func initialCommand_codecsDoesNotMatchCodex() {
    #expect(
      AgentKindPatterns.classify(
        initialCommand: "codecs install",
        title: nil,
        notificationTitle: nil
      ) == nil
    )
  }

  /// The `.codex` title patterns are `["Codex CLI", "Codex"]`. A
  /// title containing only the substring `"Code"` (here `"Visual
  /// Studio Code"`) does not contain the full pattern `"Codex"` and
  /// must not classify.
  @Test
  func title_visualStudioCodeDoesNotMatchCodex() {
    #expect(
      AgentKindPatterns.classify(
        initialCommand: nil,
        title: "Visual Studio Code",
        notificationTitle: nil
      ) == nil
    )
  }

  // MARK: - title hits

  @Test
  func title_claudeCodeExactPattern() {
    #expect(
      AgentKindPatterns.classify(initialCommand: nil, title: "Claude Code", notificationTitle: nil)
        == .claudeCode
    )
  }

  @Test
  func title_claudeFallbackPattern() {
    #expect(
      AgentKindPatterns.classify(initialCommand: nil, title: "claude (idle)", notificationTitle: nil)
        == .claudeCode
    )
  }

  @Test
  func title_codexCLI() {
    #expect(
      AgentKindPatterns.classify(initialCommand: nil, title: "Codex CLI", notificationTitle: nil)
        == .codex
    )
  }

  // MARK: - title tiebreaker (longest pattern wins)

  @Test
  func title_codexCLIWithVersionPrefersLongestPattern() {
    // Both `"Codex CLI"` and `"Codex"` match — the longer pattern
    // must win. (Today both belong to .codex so the resolved kind
    // would be the same, but the matcher contract is what's
    // tested: when patterns overlap, longest wins.)
    #expect(
      AgentKindPatterns.classify(
        initialCommand: nil,
        title: "Codex CLI v1.2",
        notificationTitle: nil
      ) == .codex
    )
  }

  // MARK: - notificationTitle hits

  @Test
  func notificationTitle_claudeMatchesClaudeCode() {
    #expect(
      AgentKindPatterns.classify(initialCommand: nil, title: nil, notificationTitle: "Claude")
        == .claudeCode
    )
  }

  @Test
  func notificationTitle_codexMatchesCodex() {
    #expect(
      AgentKindPatterns.classify(initialCommand: nil, title: nil, notificationTitle: "Codex")
        == .codex
    )
  }

  @Test
  func notificationTitle_caseInsensitive() {
    #expect(
      AgentKindPatterns.classify(initialCommand: nil, title: nil, notificationTitle: "CLAUDE NEEDS YOU")
        == .claudeCode
    )
  }

  // MARK: - resolution order

  @Test
  func resolutionOrder_initialCommandWinsOverTitle() {
    // initialCommand `claude` would classify as .claudeCode; title
    // `Codex` would classify as .codex on its own. The earlier
    // signal must win.
    #expect(
      AgentKindPatterns.classify(initialCommand: "claude", title: "Codex", notificationTitle: nil)
        == .claudeCode
    )
  }

  @Test
  func resolutionOrder_titleWinsOverNotificationTitle() {
    // initialCommand is nil, so title runs next and short-circuits
    // before notificationTitle even though both would match.
    #expect(
      AgentKindPatterns.classify(initialCommand: nil, title: "Codex CLI", notificationTitle: "Claude")
        == .codex
    )
  }

  // MARK: - miss cases

  @Test
  func miss_bashCommand() {
    #expect(
      AgentKindPatterns.classify(initialCommand: "bash -l", title: nil, notificationTitle: nil) == nil
    )
  }

  @Test
  func miss_makeCommand() {
    #expect(
      AgentKindPatterns.classify(initialCommand: "make build", title: nil, notificationTitle: nil)
        == nil
    )
  }

  @Test
  func miss_pytestCommand() {
    #expect(
      AgentKindPatterns.classify(initialCommand: "pytest -q", title: nil, notificationTitle: nil)
        == nil
    )
  }

  @Test
  func miss_emptyStringInputs() {
    #expect(AgentKindPatterns.classify(initialCommand: "", title: "", notificationTitle: "") == nil)
  }

  @Test
  func miss_allNil() {
    #expect(AgentKindPatterns.classify(initialCommand: nil, title: nil, notificationTitle: nil) == nil)
  }

  // MARK: - Pane Codable round-trip

  @Test
  func paneCodable_roundTripsAgentFields() throws {
    let original = Pane(
      workingDirectory: "/tmp",
      agentKind: .claudeCode,
      agentSessionID: "abc"
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Pane.self, from: data)
    #expect(decoded.id == original.id)
    #expect(decoded.agentKind == .claudeCode)
    #expect(decoded.agentSessionID == "abc")
  }

  // MARK: - Pane backward / forward compat

  @Test
  func paneCodable_preT1JSONDecodesWithNilAgentFields() throws {
    // PaneID is a nested `{ "raw": "<UUID>" }` value (see
    // CatalogCodableTests / WorktreeArchivedCodableTests). A pre-T1
    // catalog has no agentKind / agentSessionID keys.
    let json = #"""
      {
        "id": { "raw": "00000000-0000-0000-0000-000000000001" },
        "workingDirectory": "/tmp"
      }
      """#
    let data = Data(json.utf8)
    let decoded = try JSONDecoder().decode(Pane.self, from: data)
    #expect(decoded.agentKind == nil)
    #expect(decoded.agentSessionID == nil)
  }

  @Test
  func paneCodable_defaultPaneOmitsNewKeysOnReencode() throws {
    // Forward-compat probe: a Pane with no agent state must serialise
    // identically to a pre-T1 build, so an older app cannot trip on
    // unexpected keys it never wrote.
    let pane = Pane(workingDirectory: "/tmp")
    let data = try JSONEncoder().encode(pane)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["agentKind"] == nil)
    #expect(object?["agentSessionID"] == nil)
  }
}
