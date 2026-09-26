import Foundation
import Testing

@testable import CodansCore

struct AgentObservationParserTests {
  private struct Fixture {
    let kind: AgentKind
    let working: String
    let blocked: String?
    let idle: String
  }

  private static let fixtures: [Fixture] = [
    .init(kind: .pi, working: "Working...", blocked: nil, idle: "pi> "),
    .init(
      kind: .claudeCode, working: "✢ Editing…",
      blocked: "Do you want to proceed?\n❯ 1. Yes\n  2. No", idle: "❯ "),
    .init(
      kind: .codex, working: "• Working (12s)",
      blocked: "Allow command?\n[y/n]", idle: "codex> "),
    .init(
      kind: .gemini, working: "Esc to cancel",
      blocked: "│ Do you want to proceed", idle: "gemini> "),
    .init(
      kind: .cursorAgent, working: "Ctrl+C to stop",
      blocked: "Run this command?\nRun (y) (enter)", idle: "cursor> "),
    .init(
      kind: .cline, working: "Esc to interrupt",
      blocked: "Let Cline use this tool?", idle: "cline> "),
    .init(
      kind: .opencode, working: "Esc to interrupt",
      blocked: "△ Permission required", idle: "opencode> "),
    .init(
      kind: .copilot, working: "Esc to cancel",
      blocked: "│ do you want to continue", idle: "copilot> "),
    .init(kind: .kimi, working: "thinking", blocked: "approve?", idle: "kimi> "),
    .init(
      kind: .droid, working: "⠋ Esc to stop",
      blocked: "EXECUTE\nenter to select\n> yes, allow", idle: "droid> "),
    .init(
      kind: .amp, working: "Esc to cancel",
      blocked: "Waiting for approval\nInvoke tool\nApprove\nAllow all for this session", idle: "amp> "),
    .init(kind: .grok, working: "Esc to interrupt", blocked: "[y/n]", idle: "grok> "),
    .init(
      kind: .omp, working: "⠋ Working… ⟦esc⟧",
      blocked: "Allow tool: bash\nReason: destructive\n❯ Approve\n  Deny", idle: "❯ fix the login bug"),
  ]

  @Test
  func registryCoversEveryAgentAndRestrictsRecoverySupport() {
    #expect(Set(Self.fixtures.map(\.kind)) == Set(AgentKind.allCases))
    for kind in AgentKind.allCases {
      let parser = AgentObservationParsers.parser(for: kind)
      #expect(parser.supportsErrorRecovery == (kind == .claudeCode || kind == .codex))
      let empty = parser.parse("")
      #expect(empty.activity == .idle)
      #expect(empty.errorFingerprint == nil)
      #expect(empty.visibleErrorFingerprints.isEmpty)
    }
  }

  @Test
  func existingActivityFixturesRetainExpectedStatesAndFacadeCompatibility() {
    for fixture in Self.fixtures {
      check(fixture.kind, fixture.working, expected: .working)
      if let blocked = fixture.blocked {
        check(fixture.kind, blocked, expected: .blocked)
      }
      check(fixture.kind, fixture.idle, expected: .idle)
    }
  }

  @Test
  func terminalErrorFixturesRemainNarrowAndCompatible() {
    check(.codex, "■ stream disconnected before completion: timeout", expected: .error)
    check(.codex, "■ unexpected status 503: unavailable", expected: .error)
    check(.claudeCode, "⎿ API Error: 503 unavailable\n❯", expected: .error)
    check(.claudeCode, "API Error: 401 unauthorized", expected: .error)
    check(.codex, "Tool failed with exit code 1", expected: .idle)
    check(.claudeCode, "Example: API Error: 503", expected: .idle)
    check(.claudeCode, "```\nAPI Error: 503", expected: .idle)
    check(.codex, "■ stream disconnected before completion: timeout\nCompleted successfully", expected: .idle)
    check(.claudeCode, "API Error: 503\nesc to interrupt", expected: .working)
    check(.claudeCode, "API Error: 503\nDo you want to proceed? yes", expected: .blocked)
  }

  @Test
  func providerRetriesSuppressActionableErrorsButRetainVisibleEvidence() {
    for (kind, banner, retry, fingerprint) in [
      (
        AgentKind.codex, "■ stream disconnected before completion: timeout", "Reconnecting... 1/5",
        "stream disconnected before completion: timeout"
      ),
      (.claudeCode, "API Error: 503", "Retrying in 3 seconds", "API Error: 503"),
    ] {
      let text = banner + "\n" + retry
      let observation = AgentObservationParsers.parser(for: kind).parse(text)
      #expect(observation.activity != .error)
      #expect(observation.errorFingerprint == nil)
      #expect(observation.visibleErrorFingerprints == [fingerprint])
      check(kind, text, expected: observation.activity)
    }
  }

  @Test
  func workingAndBlockedStatesDoNotDiscardErrorEvidence() {
    for (kind, cue, banner, fingerprint, expected) in [
      (
        AgentKind.codex, "• Working (12s)", "■ stream disconnected before completion: timeout",
        "stream disconnected before completion: timeout", PaneAttentionInterpreter.AgentActivityState.working
      ),
      (.claudeCode, "✢ Editing…", "⎿ API Error: 503 unavailable", "API Error: 503 unavailable", .working),
      (
        .codex, "Allow command?\n[y/n]", "■ unexpected status 503: unavailable",
        "unexpected status 503: unavailable", .blocked
      ),
      (
        .claudeCode, "Do you want to proceed? yes", "API Error: 401 unauthorized",
        "API Error: 401 unauthorized", .blocked
      ),
    ] {
      let text = cue + "\n" + banner
      let observation = AgentObservationParsers.parser(for: kind).parse(text)
      #expect(observation.activity == expected)
      #expect(observation.errorFingerprint == fingerprint)
      #expect(observation.visibleErrorFingerprints == [fingerprint])
      check(kind, text, expected: expected)
    }
  }

  @Test
  func visibleEvidenceIncludesMultipleBannersOutsideTheActivityWindow() {
    for (kind, first, second, firstFingerprint, secondFingerprint) in [
      (
        AgentKind.codex, "■ stream disconnected before completion: timeout", "■ unexpected status 503: unavailable",
        "stream disconnected before completion: timeout", "unexpected status 503: unavailable"
      ),
      (
        .claudeCode, "⎿ API Error: 503 unavailable", "API Error: 401 unauthorized",
        "API Error: 503 unavailable", "API Error: 401 unauthorized"
      ),
    ] {
      let filler = Array(repeating: "Older transcript content", count: 30).joined(separator: "\n")
      let text = first + "\n" + filler + "\n" + second + "\n" + second
      let observation = AgentObservationParsers.parser(for: kind).parse(text)
      #expect(observation.activity == .error)
      #expect(observation.errorFingerprint == secondFingerprint)
      #expect(observation.visibleErrorFingerprints == [firstFingerprint, secondFingerprint])
      check(kind, text, expected: .error)
    }
  }

  @Test
  func unsupportedAgentsDoNotAcquireErrorEvidenceFromAnotherAgentsBanner() {
    for kind in AgentKind.allCases where kind != .codex && kind != .claudeCode {
      let observation = AgentObservationParsers.parser(for: kind).parse(
        "API Error: 503 unavailable\n■ stream disconnected before completion: timeout")
      #expect(observation.activity == .idle)
      #expect(observation.errorFingerprint == nil)
      #expect(observation.visibleErrorFingerprints.isEmpty)
    }
  }

  private func check(
    _ kind: AgentKind, _ text: String, expected: PaneAttentionInterpreter.AgentActivityState
  ) {
    let observation = AgentObservationParsers.parser(for: kind).parse(text)
    #expect(observation.activity == expected)
    #expect(PaneAttentionInterpreter.classifyAgentActivity(kind: kind, viewportText: text) == expected)
    #expect(
      observation.errorFingerprint
        == PaneAttentionInterpreter.agentErrorFingerprint(kind: kind, viewportText: text))
  }
}
