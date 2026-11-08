import CodansCore
import Testing

@testable import Codans

struct AgentTitleFormatTests {
  // MARK: - isRedundantTitle

  @Test
  func redundantTitlesAreDetectedThroughDecorationAndCase() {
    let name = "Claude Code"
    #expect(AgentTitleFormat.isRedundantTitle("Claude Code", agentDisplayName: name))
    #expect(AgentTitleFormat.isRedundantTitle("✳ Claude Code", agentDisplayName: name))
    #expect(AgentTitleFormat.isRedundantTitle("· claude code  ", agentDisplayName: name))
  }

  @Test
  func informativeTitlesAreNotRedundant() {
    let name = "Claude Code"
    #expect(!AgentTitleFormat.isRedundantTitle("✳ Running tests…", agentDisplayName: name))
    #expect(
      !AgentTitleFormat.isRedundantTitle("Claude Code · fixing tests", agentDisplayName: name))
  }

  // MARK: - titleLine

  @Test
  func titleLineTrimsInformativeText() {
    #expect(AgentTitleFormat.titleLine(from: "  Running tests \n", kind: .codex) == "Running tests")
  }

  @Test(arguments: [nil, "", "   ", "Codex", "✳ codex"] as [String?])
  func titleLineIsNilForEmptyOrAgentNameOnlyText(_ text: String?) {
    #expect(AgentTitleFormat.titleLine(from: text, kind: .codex) == nil)
  }

  // MARK: - rowText

  @Test(arguments: [nil, "", "  ", "✳ Claude Code"] as [String?])
  func rowTextFallsBackToAgentDisplayName(_ text: String?) {
    #expect(AgentTitleFormat.rowText(from: text, kind: .claudeCode) == AgentKind.claudeCode.displayName)
  }

  @Test
  func rowTextShowsActivityWhenPresent() {
    #expect(AgentTitleFormat.rowText(from: "✳ Committing…", kind: .claudeCode) == "✳ Committing…")
  }
}
