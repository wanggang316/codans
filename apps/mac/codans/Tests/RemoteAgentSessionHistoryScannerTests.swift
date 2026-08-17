import CodansCore
import Foundation
import Testing

@testable import Codans

struct RemoteAgentSessionHistoryScannerTests {
  private static let host = RemoteHost(alias: "example.com", username: "alice")

  @Test
  func parsesMarkerDelimitedChunksAndIgnoresBanners() {
    let stream = """
      Welcome to the server!
      motd noise
      ===CODANS-SESSION 1755000000 ABC.jsonl===
      line one
      line two
      ===CODANS-SESSION 1755000100 /deep/path/rollout-x.jsonl===
      only line
      """
    let chunks = RemoteAgentSessionHistoryScanner.parseSessionChunks(Data(stream.utf8))
    #expect(chunks.count == 2)
    #expect(chunks[0].name == "ABC.jsonl")
    #expect(chunks[0].mtime == Date(timeIntervalSince1970: 1_755_000_000))
    #expect(String(data: chunks[0].body, encoding: .utf8) == "line one\nline two")
    // Codex markers carry full paths; the chunk name is the basename.
    #expect(chunks[1].name == "rollout-x.jsonl")
    #expect(String(data: chunks[1].body, encoding: .utf8) == "only line")
  }

  @Test
  func extractsIndexSectionBetweenMarkers() {
    let stream = """
      login banner
      ===CODANS-INDEX===
      {"id":"01X","thread_name":"fix the bug"}
      ===CODANS-END-INDEX===
      ===CODANS-SESSION 1 f.jsonl===
      """
    let index = RemoteAgentSessionHistoryScanner.indexSection(of: Data(stream.utf8))
    let names = AgentSessionHistoryScanner.codexThreadNames(from: index)
    #expect(names["01X"] == "fix the bug")
  }

  @Test
  func claudeScriptListsNewestSessionsPortably() {
    let script = RemoteAgentSessionHistoryScanner.claudeScript(
      worktreePath: "/srv/my app")
    // Munged project dir (non-alphanumerics → dashes) is interpolated directly.
    #expect(script.contains(".claude/projects/-srv-my-app"))
    // GNU then BSD stat so Linux and macOS hosts both answer.
    #expect(script.contains("stat -c '%Y %n'"))
    #expect(script.contains("stat -f '%m %N'"))
    #expect(script.contains("sort -rn"))
    #expect(script.contains("===CODANS-SESSION"))
  }

  @Test
  func scanParsesClaudeAndCodexOverSSH() async {
    let sessionID = "11111111-2222-3333-4444-555555555555"
    let claudeLine =
      #"{"type":"user","message":{"role":"user","content":"fix the login flow"}}"#
    let claudeStream = """
      ===CODANS-SESSION 1755000000 \(sessionID).jsonl===
      \(claudeLine)
      """
    let codexMeta =
      #"{"type":"session_meta","payload":{"id":"01JCODEX","cwd":"/srv/app"}}"#
    let codexStream = """
      ===CODANS-INDEX===
      {"id":"01JCODEX","thread_name":"ship it"}
      ===CODANS-END-INDEX===
      ===CODANS-SESSION 1755000100 /x/rollout-a.jsonl===
      \(codexMeta)
      """
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data(claudeStream.utf8), stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: Data(codexStream.utf8), stderr: Data(), stdoutOverflow: false),
    ])
    let groups = await RemoteAgentSessionHistoryScanner.scan(
      host: Self.host, worktreePath: "/srv/app", runner: runner
    )
    let all = groups.flatMap(\.sessions)
    #expect(all.count == 2)
    let claude = all.first { $0.agent == .claudeCode }
    #expect(claude?.sessionID == sessionID)
    #expect(claude?.title == "fix the login flow")
    let codex = all.first { $0.agent == .codex }
    #expect(codex?.sessionID == "01JCODEX")
    #expect(codex?.title == "ship it")
    // Newest-first group ordering: codex (1755000100) leads claude.
    #expect(groups.first?.agent == .codex)

    // Both invocations rode ssh with the cwd needle as a codex positional.
    let calls = await runner.calls
    #expect(calls.count == 2)
    #expect(calls.allSatisfy { $0.executable.path == "/usr/bin/ssh" })
    #expect(calls[1].arguments.last?.contains(#""cwd":"/srv/app""#) == true)
  }

  @Test
  func codexSessionOutsideWorktreeIsFilteredLocally() async {
    // The host-side grep is a substring prefilter; a cwd that merely
    // CONTAINS the worktree path must still be dropped by the exact match.
    let codexStream = """
      ===CODANS-INDEX===
      ===CODANS-END-INDEX===
      ===CODANS-SESSION 1755000100 /x/rollout-b.jsonl===
      {"type":"session_meta","payload":{"id":"01JOTHER","cwd":"/srv/app-other"}}
      """
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false),
      .exited(code: 0, stdout: Data(codexStream.utf8), stderr: Data(), stdoutOverflow: false),
    ])
    let groups = await RemoteAgentSessionHistoryScanner.scan(
      host: Self.host, worktreePath: "/srv/app", runner: runner
    )
    #expect(groups.isEmpty)
  }
}
