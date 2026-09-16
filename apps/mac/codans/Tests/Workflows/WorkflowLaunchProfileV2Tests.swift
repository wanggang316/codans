import CodansCore
import Testing

@testable import Codans

struct WorkflowLaunchProfileV2Tests {
  @Test func claudeIsolationChangesOnlyEffectiveEnvironment() {
    let selected = AgentProfile(
      kind: .claudeCode, name: "Reviewer", modelID: "sonnet", reasoningEffortID: "high",
      executionModeID: "plan", target: .split, direction: .down,
      extraArguments: "--verbose", envVars: ["CUSTOM_SETTING": "retained", "CLAUDE_CODE_DISABLE_AGENT_VIEW": "0"],
      usesDedicatedHome: true)
    let effective = WorkflowLaunchProfileV2.isolated(selected)
    var expected = selected
    expected.envVars["CLAUDE_CODE_DISABLE_AGENT_VIEW"] = "1"
    #expect(effective == expected)
    #expect(selected.envVars["CLAUDE_CODE_DISABLE_AGENT_VIEW"] == "0")
    #expect(effective.envVars["HOME"] == nil)
    #expect(AgentLaunchCommand.render(profile: effective).contains("CLAUDE_CODE_DISABLE_AGENT_VIEW='1'"))
  }

  @Test func otherAgentProfilesAreUnchanged() {
    for kind in AgentKind.allCases where kind != .claudeCode {
      let selected = AgentProfile(
        kind: kind, name: "Worker", extraArguments: "--custom-option",
        envVars: ["CUSTOM_SETTING": "retained"], usesDedicatedHome: false)
      #expect(WorkflowLaunchProfileV2.isolated(selected) == selected)
    }
  }
}
