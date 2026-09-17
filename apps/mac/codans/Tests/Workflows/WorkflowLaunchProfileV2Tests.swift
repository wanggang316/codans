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

  @MainActor @Test func roleDefaultsUseOnlyMatchingCurrentContext() throws {
    let paneID = PaneID()
    let worktreeID = WorktreeID()
    let panes = [WorkflowPaneChoice(id: paneID, title: "Agent", worktreeID: worktreeID)]
    let workspaces = [WorkflowWorkspaceChoice(id: worktreeID, projectID: ProjectID(), title: "Location")]
    let current = WorkflowRoleV2(label: "Author", source: "current")
    let selected = try WorkflowRoleDefaultsV2.selection(
      for: current, profiles: [], panes: panes, workspaces: workspaces,
      currentPaneID: paneID, currentWorktreeID: worktreeID)
    #expect(selected.paneID == paneID)
    let missing = try WorkflowRoleDefaultsV2.selection(
      for: current, profiles: [], panes: panes, workspaces: workspaces,
      currentPaneID: PaneID(), currentWorktreeID: worktreeID)
    #expect(missing.paneID == nil)
    let pick = try WorkflowRoleDefaultsV2.selection(
      for: WorkflowRoleV2(label: "Reviewer", source: "pick"), profiles: [], panes: panes,
      workspaces: workspaces, currentPaneID: paneID, currentWorktreeID: worktreeID)
    #expect(pick.paneID == nil)
    let launch = try WorkflowRoleDefaultsV2.selection(
      for: WorkflowRoleV2(label: "Receiver", source: "launch"), profiles: [], panes: panes,
      workspaces: workspaces, currentPaneID: paneID, currentWorktreeID: worktreeID)
    #expect(launch.worktreeID == worktreeID)
    #expect(launch.profileID == nil)
  }

  @MainActor @Test func configuredProfileResolvesExactNameOrIDAndRejectsInvalidReferences() throws {
    let profile = AgentProfile(kind: .claudeCode, name: "Receiver")
    var role = WorkflowRoleV2(label: "Receiver", source: "launch", profile: "Receiver")
    #expect(try WorkflowRoleDefaultsV2.profile(for: role, profiles: [profile]) == profile)
    role.profile = profile.id.uuidString
    #expect(try WorkflowRoleDefaultsV2.profile(for: role, profiles: [profile]) == profile)
    var disabled = profile
    disabled.isEnabled = false
    #expect(throws: WorkflowDefinitionErrorV2.self) {
      try WorkflowRoleDefaultsV2.profile(for: role, profiles: [disabled])
    }
    #expect(throws: WorkflowDefinitionErrorV2.self) {
      try WorkflowRoleDefaultsV2.profile(for: role, profiles: [])
    }
    role.profile = "Receiver"
    let duplicate = AgentProfile(kind: .claudeCode, name: "Receiver")
    #expect(throws: WorkflowDefinitionErrorV2.self) {
      try WorkflowRoleDefaultsV2.profile(for: role, profiles: [profile, duplicate])
    }
  }

  @MainActor @Test func restoredContextUsesOnlyUnambiguousPane() {
    let first = Pane(workingDirectory: "/tmp", initialCommand: nil)
    let second = Pane(workingDirectory: "/tmp", initialCommand: nil)
    #expect(WorkflowRoleDefaultsV2.currentPane(in: Tab(panes: [first]), remembered: nil) == first.id)
    let split = Tab(panes: [first, second])
    #expect(WorkflowRoleDefaultsV2.currentPane(in: split, remembered: nil) == nil)
    #expect(WorkflowRoleDefaultsV2.currentPane(in: split, remembered: second.id) == second.id)
    #expect(WorkflowRoleDefaultsV2.currentPane(in: split, remembered: PaneID()) == nil)
  }

}
