import CodansCore
import Testing

@testable import Codans

struct AgentActivityFormatTests {
  // MARK: - isRedundantActivityTitle

  @Test
  func redundantTitlesAreDetectedThroughDecorationAndCase() {
    let name = "Claude Code"
    #expect(AgentActivityFormat.isRedundantActivityTitle("Claude Code", agentDisplayName: name))
    #expect(AgentActivityFormat.isRedundantActivityTitle("✳ Claude Code", agentDisplayName: name))
    #expect(AgentActivityFormat.isRedundantActivityTitle("· claude code  ", agentDisplayName: name))
  }

  @Test
  func informativeTitlesAreNotRedundant() {
    let name = "Claude Code"
    #expect(!AgentActivityFormat.isRedundantActivityTitle("✳ Running tests…", agentDisplayName: name))
    #expect(
      !AgentActivityFormat.isRedundantActivityTitle("Claude Code · fixing tests", agentDisplayName: name))
  }

  // MARK: - activityLine

  @Test
  func activityLineTrimsInformativeText() {
    #expect(AgentActivityFormat.activityLine(from: "  Running tests \n", kind: .codex) == "Running tests")
  }

  @Test(arguments: [nil, "", "   ", "Codex", "✳ codex"] as [String?])
  func activityLineIsNilForEmptyOrAgentNameOnlyText(_ text: String?) {
    #expect(AgentActivityFormat.activityLine(from: text, kind: .codex) == nil)
  }

  // MARK: - rowText

  @Test(arguments: [nil, "", "  ", "✳ Claude Code"] as [String?])
  func rowTextFallsBackToAgentDisplayName(_ text: String?) {
    #expect(AgentActivityFormat.rowText(from: text, kind: .claudeCode) == AgentKind.claudeCode.displayName)
  }

  @Test
  func rowTextShowsActivityWhenPresent() {
    #expect(AgentActivityFormat.rowText(from: "✳ Committing…", kind: .claudeCode) == "✳ Committing…")
  }
}
