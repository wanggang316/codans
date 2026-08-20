import CodansCore
import Foundation
import Testing

@testable import Codans

struct AgentSummaryCardFormatTests {
  @Test
  func durationTextFormatsAcrossUnits() {
    let start = Date(timeIntervalSince1970: 0)
    func at(_ seconds: TimeInterval) -> String {
      AgentSummaryCardFormat.durationText(from: start, to: start.addingTimeInterval(seconds))
    }
    #expect(at(0) == "0s")
    #expect(at(42) == "42s")
    #expect(at(60) == "1m")
    #expect(at(12 * 60 + 30) == "12m")
    #expect(at(3600) == "1h")
    #expect(at(3600 + 3 * 60) == "1h 3m")
    #expect(at(26 * 3600) == "1d")
    #expect(at(3 * 86_400) == "3d")
  }

  @Test
  func durationTextClampsNegativeElapsedToZero() {
    let start = Date(timeIntervalSince1970: 100)
    let earlier = Date(timeIntervalSince1970: 40)
    #expect(AgentSummaryCardFormat.durationText(from: start, to: earlier) == "0s")
  }

  // MARK: - isRedundantActivityTitle

  @Test
  func redundantTitlesAreDetectedThroughDecorationAndCase() {
    let name = "Claude Code"
    #expect(AgentSummaryCardFormat.isRedundantActivityTitle("Claude Code", agentDisplayName: name))
    #expect(AgentSummaryCardFormat.isRedundantActivityTitle("✳ Claude Code", agentDisplayName: name))
    #expect(
      AgentSummaryCardFormat.isRedundantActivityTitle("· claude code  ", agentDisplayName: name))
  }

  @Test
  func informativeTitlesAreNotRedundant() {
    let name = "Claude Code"
    #expect(
      !AgentSummaryCardFormat.isRedundantActivityTitle("✳ Running tests…", agentDisplayName: name))
    #expect(
      !AgentSummaryCardFormat.isRedundantActivityTitle(
        "Claude Code · fixing tests", agentDisplayName: name))
  }

  // MARK: - latestSession

  private func session(
    _ agent: AgentKind, id: String, at seconds: TimeInterval
  ) -> AgentSessionSummary {
    AgentSessionSummary(
      agent: agent, sessionID: id, title: "task \(id)",
      updatedAt: Date(timeIntervalSince1970: seconds)
    )
  }

  @Test
  func latestSessionPicksNewestOfMatchingKind() {
    let groups = [
      AgentSessionGroup(
        agent: .claudeCode,
        sessions: [session(.claudeCode, id: "old", at: 10), session(.claudeCode, id: "new", at: 99)]
      ),
      AgentSessionGroup(agent: .codex, sessions: [session(.codex, id: "cdx", at: 500)]),
    ]
    let picked = AgentSummaryCardFormat.latestSession(
      in: groups, kind: .claudeCode, preferredID: nil
    )
    #expect(picked?.sessionID == "new")
  }

  @Test
  func latestSessionPrefersExactIDMatch() {
    let groups = [
      AgentSessionGroup(
        agent: .claudeCode,
        sessions: [session(.claudeCode, id: "old", at: 10), session(.claudeCode, id: "new", at: 99)]
      )
    ]
    let picked = AgentSummaryCardFormat.latestSession(
      in: groups, kind: .claudeCode, preferredID: "old"
    )
    #expect(picked?.sessionID == "old")
  }

  @Test
  func latestSessionReturnsNilWhenKindAbsent() {
    let groups = [
      AgentSessionGroup(agent: .codex, sessions: [session(.codex, id: "cdx", at: 500)])
    ]
    #expect(
      AgentSummaryCardFormat.latestSession(in: groups, kind: .claudeCode, preferredID: nil) == nil)
  }
}
