import Foundation
import Testing

@testable import TouchCodeCore

struct AgentKindPatternsTests {
  // MARK: - foreground job hits

  @Test
  func foregroundJob_matchesEverySupportedAgentProcess() {
    let samples: [(argv0: String, kind: AgentKind)] = [
      ("claude", .claudeCode),
      ("claude-code", .claudeCode),
      ("codex", .codex),
      ("pi", .pi),
      ("opencode", .opencode),
      ("open-code", .opencode),
      ("gemini", .gemini),
      ("cursor-agent", .cursorAgent),
      ("cline", .cline),
      ("copilot", .copilot),
      ("github-copilot", .copilot),
      ("ghcs", .copilot),
      ("kimi", .kimi),
      ("kimi-code", .kimi),
      ("droid", .droid),
      ("amp", .amp),
      ("amp-local", .amp),
    ]

    for sample in samples {
      #expect(
        AgentKindPatterns.classify(
          foregroundJob: Self.job(argv0: sample.argv0, commandLine: "\(sample.argv0) --resume")
        ) == sample.kind
      )
    }
  }

  @Test
  func foregroundJob_matchesFullPathBasename() {
    #expect(
      AgentKindPatterns.classify(
        foregroundJob: Self.job(
          argv0: "/opt/homebrew/bin/codex",
          commandLine: "/opt/homebrew/bin/codex --resume"
        )
      ) == .codex
    )
  }

  @Test
  func foregroundJob_matchesAgentInsideNodeWrapper() {
    #expect(
      AgentKindPatterns.classify(
        foregroundJob: Self.job(
          argv0: "node",
          commandLine: "node /Users/me/.npm/bin/codex --dangerously-bypass"
        )
      ) == .codex
    )
  }

  @Test
  func foregroundJob_matchesAgentInsideNpxWrapper() {
    #expect(
      AgentKindPatterns.classify(
        foregroundJob: Self.job(
          argv0: "npx",
          commandLine: "npx github-copilot status"
        )
      ) == .copilot
    )
  }

  @Test
  func foregroundJob_matchesJavaScriptEntrypointInWrapper() {
    #expect(
      AgentKindPatterns.classify(
        foregroundJob: Self.job(
          argv0: "node",
          commandLine: "node /Users/me/.npm/_npx/bin/codex.js --resume"
        )
      ) == .codex
    )
  }

  @Test
  func foregroundJob_matchesCursorAgentAliasInGenericAgentProcess() {
    #expect(
      AgentKindPatterns.classify(
        foregroundJob: Self.job(
          argv0: "agent",
          commandLine: "agent --client /Applications/Cursor.app --cursor-agent"
        )
      ) == .cursorAgent
    )
  }

  @Test
  func foregroundJob_directAgentOutranksWrapperToken() {
    let job = ForegroundJob(
      processGroupID: 40,
      processes: [
        ForegroundProcess(
          pid: 40,
          parentPID: 39,
          processGroupID: 40,
          argv0: "node",
          commandLine: "node /tmp/codex"
        ),
        ForegroundProcess(
          pid: 41,
          parentPID: 40,
          processGroupID: 40,
          argv0: "claude",
          commandLine: "claude --resume"
        ),
      ]
    )

    #expect(AgentKindPatterns.classify(foregroundJob: job) == .claudeCode)
  }

  // MARK: - misses

  @Test
  func foregroundJob_nonWrapperDoesNotMatchCommandLineSubstring() {
    #expect(
      AgentKindPatterns.classify(
        foregroundJob: Self.job(
          argv0: "vim",
          commandLine: "vim /tmp/codex-notes.md"
        )
      ) == nil
    )
  }

  @Test
  func foregroundJob_nearMissesDoNotMatchShortAgentNames() {
    for argv0 in ["pip", "pipenv", "mpirun", "lamp", "ramp", "sample"] {
      #expect(
        AgentKindPatterns.classify(
          foregroundJob: Self.job(argv0: argv0, commandLine: "\(argv0) run")
        ) == nil
      )
    }
  }

  @Test
  func foregroundJob_cursorEditorDoesNotMatchCursorAgent() {
    #expect(
      AgentKindPatterns.classify(
        foregroundJob: Self.job(argv0: "cursor", commandLine: "cursor .")
      ) == nil
    )
  }

  @Test
  func foregroundJob_cursorProcessWithAgentHintMatchesCursorAgent() {
    #expect(
      AgentKindPatterns.classify(
        foregroundJob: Self.job(argv0: "cursor", commandLine: "cursor --cursor-agent")
      ) == .cursorAgent
    )
  }

  @Test
  func foregroundJob_emptyJobDoesNotMatch() {
    #expect(
      AgentKindPatterns.classify(
        foregroundJob: ForegroundJob(processGroupID: 123, processes: [])
      ) == nil
    )
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
  func paneCodable_preAgentJSONDecodesWithNilAgentFields() throws {
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
  func paneCodable_defaultPaneOmitsAgentKeysOnReencode() throws {
    let pane = Pane(workingDirectory: "/tmp")
    let data = try JSONEncoder().encode(pane)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?.keys.contains("agentKind") == false)
    #expect(object?.keys.contains("agentSessionID") == false)
  }

  private static func job(argv0: String, commandLine: String) -> ForegroundJob {
    ForegroundJob(
      processGroupID: 123,
      processes: [
        ForegroundProcess(
          pid: 123,
          parentPID: 122,
          processGroupID: 123,
          argv0: argv0,
          commandLine: commandLine
        )
      ]
    )
  }
}
