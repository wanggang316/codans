import Foundation
import Testing

@testable import CodansCore

struct AgentRuntimeAdapterTests {
  // MARK: - registry

  @Test
  func registryCoversEveryAgentKind() {
    for kind in AgentKind.allCases {
      let adapter = AgentRuntimeAdapters.adapter(for: kind)
      #expect(adapter.kind == kind)
      #expect(!adapter.displayName.isEmpty)
      #expect(!adapter.processNames.isEmpty)
    }
  }

  @Test
  func allReturnsAdaptersInAgentKindOrder() {
    #expect(AgentRuntimeAdapters.all.map(\.kind) == AgentKind.allCases)
  }

  // MARK: - resume invocation

  @Test
  func resumeCommandsCoverResumableAgentsOnly() {
    #expect(
      AgentRuntimeAdapters.adapter(for: .claudeCode).resumeCommand(sessionID: "abc")
        == "claude --resume 'abc'")
    #expect(
      AgentRuntimeAdapters.adapter(for: .codex).resumeCommand(sessionID: "01X")
        == "codex resume '01X'")
    #expect(
      AgentRuntimeAdapters.adapter(for: .omp).resumeCommand(sessionID: "01abc")
        == "omp --resume '01abc'")
    for kind in AgentKind.allCases
    where kind != .claudeCode && kind != .codex && kind != .omp {
      #expect(AgentRuntimeAdapters.adapter(for: kind).resumeCommand(sessionID: "x") == nil)
    }
  }

  /// The side-effect-free contract from the protocol doc: a resume command
  /// only reattaches, so the sole flag it may render is the resume entry
  /// point itself — never permission-mode, sandbox, model, or prompt
  /// overrides.
  @Test
  func resumeCommandsRenderNoExecutionModeFlags() {
    for adapter in AgentRuntimeAdapters.all {
      guard let command = adapter.resumeCommand(sessionID: "session-id") else { continue }
      let flags = command.split(separator: " ").filter { $0.hasPrefix("-") }.map(String.init)
      #expect(
        flags.isEmpty || flags == ["--resume"],
        "\(adapter.kind.rawValue) resume renders unexpected flags: \(flags)")
    }
  }

  @Test
  func resumeCommandsShellQuoteSessionIDs() {
    #expect(
      AgentRuntimeAdapters.adapter(for: .claudeCode).resumeCommand(sessionID: "a'b")
        == #"claude --resume 'a'\''b'"#)
  }

  @Test
  func shellQuotedEscapesEmbeddedSingleQuotes() {
    #expect(AgentRuntimeAdapters.shellQuoted("a'b") == #"'a'\''b'"#)
  }

  // MARK: - session-id display

  @Test
  func shortSessionIDTakesCodexTailAndPrefixElsewhere() {
    #expect(
      AgentRuntimeAdapters.adapter(for: .codex).shortSessionID("0123456789ABCDEF") == "89ABCDEF")
    #expect(
      AgentRuntimeAdapters.adapter(for: .claudeCode).shortSessionID("0123456789ABCDEF")
        == "01234567")
  }
}
