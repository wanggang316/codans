import CodansCore
import Foundation
import Testing

@testable import Codans

struct AgentSessionHistoryScannerTests {
  @Test
  func claudeProjectDirNameMungesEveryNonAlphanumeric() {
    #expect(
      AgentSessionHistoryScanner.claudeProjectDirName(
        for: "/Users/g/.codans/repos/codans/feat/agent-history")
        == "-Users-g--codans-repos-codans-feat-agent-history")
  }

  @Test
  func claudeTitleSkipsMetaSidechainAndWrapperLines() {
    let lines = [
      #"{"type":"mode","mode":"normal","sessionId":"s"}"#,
      #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: replayed"}}"#,
      #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
      #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"sidechain prompt"}}"#,
      #"{"type":"user","message":{"role":"user","content":"fix the login bug"}}"#,
    ].joined(separator: "\n")
    #expect(
      AgentSessionHistoryScanner.claudeTitle(fromPrefix: Data(lines.utf8))
        == "fix the login bug")
  }

  @Test
  func claudeTitleReadsBlockContentAndCollapsesNewlines() {
    let line =
      #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"block\nprompt"}]}}"#
    #expect(
      AgentSessionHistoryScanner.claudeTitle(fromPrefix: Data(line.utf8)) == "block prompt")
  }

  @Test
  func claudeTitleReturnsNilWhenNoUserMessage() {
    let line = #"{"type":"assistant","message":{"role":"assistant","content":"hi"}}"#
    #expect(AgentSessionHistoryScanner.claudeTitle(fromPrefix: Data(line.utf8)) == nil)
  }

  @Test
  func codexSessionMetaParsesFirstLineOnly() {
    let file =
      #"{"timestamp":"t","type":"session_meta","payload":{"id":"01AB","cwd":"/tmp/wt"}}"#
      + "\n"
      + #"{"type":"event_msg","payload":{}}"#
    let meta = AgentSessionHistoryScanner.codexSessionMeta(fromFirstLine: Data(file.utf8))
    #expect(meta == AgentSessionHistoryScanner.CodexSessionMeta(id: "01AB", cwd: "/tmp/wt"))
  }

  @Test
  func codexSessionMetaRejectsNonMetaFirstLine() {
    let file = #"{"type":"event_msg","payload":{}}"# + "\n"
    #expect(AgentSessionHistoryScanner.codexSessionMeta(fromFirstLine: Data(file.utf8)) == nil)
  }

  @Test
  func codexThreadNamesLastWriteWins() {
    let index = [
      #"{"id":"a","thread_name":"old name","updated_at":"t1"}"#,
      #"{"id":"b","thread_name":"other","updated_at":"t1"}"#,
      #"{"id":"a","thread_name":"new name","updated_at":"t2"}"#,
    ].joined(separator: "\n")
    let names = AgentSessionHistoryScanner.codexThreadNames(from: Data(index.utf8))
    #expect(names == ["a": "new name", "b": "other"])
  }

  @Test
  func groupedOrdersSectionsByNewestSessionAndRowsNewestFirst() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    func summary(
      _ agent: AgentKind, _ id: String, _ offset: TimeInterval
    ) -> AgentSessionSummary {
      AgentSessionSummary(
        agent: agent, sessionID: id, title: id, updatedAt: base.addingTimeInterval(offset))
    }
    let groups = AgentSessionHistoryScanner.grouped([
      summary(.claudeCode, "c1", 10),
      summary(.codex, "x1", 30),
      summary(.claudeCode, "c2", 20),
    ])
    #expect(groups.map(\.agent) == [.codex, .claudeCode])
    #expect(groups[1].sessions.map(\.sessionID) == ["c2", "c1"])
  }

  @Test
  func scanReadsFixtureStoresScopedToTheWorktree() throws {
    let fileManager = FileManager.default
    let home = fileManager.temporaryDirectory
      .appendingPathComponent("agent-history-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: home) }
    let worktree = "/tmp/wt/feature-x"

    // Claude Code: one session under the munged project directory.
    let claudeDir = home.appendingPathComponent(
      ".claude/projects/"
        + AgentSessionHistoryScanner.claudeProjectDirName(for: worktree),
      isDirectory: true)
    try fileManager.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    let claudeID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeffff"
    let claudeLine = #"{"type":"user","message":{"role":"user","content":"claude prompt"}}"#
    try Data(claudeLine.utf8).write(to: claudeDir.appendingPathComponent("\(claudeID).jsonl"))

    // Codex: one rollout for this worktree, one for another cwd that must
    // be filtered out, plus the global thread-name index.
    let codexDay = home.appendingPathComponent(".codex/sessions/2026/07/22", isDirectory: true)
    try fileManager.createDirectory(at: codexDay, withIntermediateDirectories: true)
    let matching =
      #"{"timestamp":"t","type":"session_meta","payload":{"id":"01ULID","cwd":"/tmp/wt/feature-x"}}"#
      + "\n"
    try Data(matching.utf8).write(to: codexDay.appendingPathComponent("rollout-a.jsonl"))
    let foreign =
      #"{"timestamp":"t","type":"session_meta","payload":{"id":"01OTHER","cwd":"/tmp/other"}}"#
      + "\n"
    try Data(foreign.utf8).write(to: codexDay.appendingPathComponent("rollout-b.jsonl"))
    let index = #"{"id":"01ULID","thread_name":"codex thread","updated_at":"t"}"#
    try Data(index.utf8).write(to: home.appendingPathComponent(".codex/session_index.jsonl"))

    let groups = AgentSessionHistoryScanner.scan(worktreePath: worktree, home: home)
    let all = groups.flatMap(\.sessions)
    #expect(all.count == 2)
    #expect(
      all.contains {
        $0.agent == .claudeCode && $0.sessionID == claudeID && $0.title == "claude prompt"
      })
    #expect(
      all.contains {
        $0.agent == .codex && $0.sessionID == "01ULID" && $0.title == "codex thread"
      })
  }
}
