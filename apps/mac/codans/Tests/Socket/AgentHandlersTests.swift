import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import Codans

/// `agent.listProfiles` / `agent.launch` against a live `SettingsStore` and a
/// recording `HierarchyClient.launchAgent`.
@MainActor
struct AgentHandlersTests {
  private final class Recorder {
    var specs: [AgentLaunchSpec] = []
  }

  private func makeStore(profiles: [AgentProfile]) -> SettingsStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AgentHandlersTests-\(UUID().uuidString).json")
    let store = SettingsStore(fileURL: url)
    store.mutateAgents { $0.profiles = profiles }
    return store
  }

  private func makeHandlers(
    profiles: [AgentProfile],
    projectID: ProjectID,
    recorder: Recorder
  ) -> AgentHandlers {
    var hierarchy = HierarchyClient.testValue
    hierarchy.kind = { pid in pid == projectID ? .gitRepo : nil }
    hierarchy.launchAgent = { spec in
      recorder.specs.append(spec)
      return AgentLaunchOutcome(profile: spec.profile, command: "cmd", tabID: TabID(), paneID: PaneID())
    }
    return AgentHandlers(settings: makeStore(profiles: profiles), hierarchy: hierarchy, installation: nil)
  }

  @Test
  func listProfilesReportsEveryProfileInOrder() {
    let build = AgentProfile(kind: .codex, name: "Build", modelID: "gpt-5.1")
    let plan = AgentProfile(kind: .claudeCode, isEnabled: false, executionModeID: "plan")
    let handlers = makeHandlers(profiles: [build, plan], projectID: ProjectID(raw: UUID()), recorder: Recorder())

    let rows = handlers.listProfiles().profiles
    #expect(rows.map(\.name) == ["Build", "Claude Code"])
    #expect(rows.map(\.agent) == ["codex", "claude-code"])
    #expect(rows.map(\.isEnabled) == [true, false])
    #expect(rows.map(\.command) == ["codex --model 'gpt-5.1'", "claude --permission-mode plan"])
    // `allSatisfy` is `rethrows`; hoist it so the `#expect` expansion stays
    // non-throwing.
    let noneProbed = rows.allSatisfy { $0.isInstalled == nil }
    let allPromptable = rows.allSatisfy(\.supportsPrompt)
    #expect(noneProbed)
    #expect(allPromptable)
  }

  @Test
  func launchResolvesByNameIdOrAgentAndForwardsOverrides() async throws {
    let build = AgentProfile(kind: .codex, name: "Build")
    let claude = AgentProfile(kind: .claudeCode)
    let projectID = ProjectID(raw: UUID())
    let worktreeID = WorktreeID(raw: UUID())
    let recorder = Recorder()
    let handlers = makeHandlers(profiles: [build, claude], projectID: projectID, recorder: recorder)

    let byName = try await handlers.launch(
      IPC.AgentLaunchRequest(projectID: projectID, worktreeID: worktreeID, profile: "build"))
    #expect(byName.profileID == build.id)
    #expect(byName.paneID != nil)

    _ = try await handlers.launch(
      IPC.AgentLaunchRequest(
        projectID: projectID, worktreeID: worktreeID, profile: claude.id.uuidString,
        prompt: "go", target: .split, direction: .down, focus: false))
    let spec = try #require(recorder.specs.last)
    #expect(spec.profile.id == claude.id)
    #expect(spec.prompt == "go")
    #expect(spec.target == .split)
    #expect(spec.direction == .down)
    #expect(spec.focus == false)

    let byAgent = try await handlers.launch(
      IPC.AgentLaunchRequest(projectID: projectID, worktreeID: worktreeID, agent: "codex"))
    #expect(byAgent.profileID == build.id)

    // No profile for the agent at all → a transient bare preset still launches.
    let bare = try await handlers.launch(
      IPC.AgentLaunchRequest(projectID: projectID, worktreeID: worktreeID, agent: "gemini"))
    #expect(bare.agent == "gemini")
    #expect(recorder.specs.last?.profile.kind == .gemini)
  }

  @Test
  func launchRefusesDisabledUnknownAndPromptlessCases() async throws {
    let disabled = AgentProfile(kind: .codex, name: "Off", isEnabled: false)
    let amp = AgentProfile(kind: .amp)
    let projectID = ProjectID(raw: UUID())
    let worktreeID = WorktreeID(raw: UUID())
    let handlers = makeHandlers(profiles: [disabled, amp], projectID: projectID, recorder: Recorder())

    await #expect(throws: IPCError.conflict(reason: "profile \"Off\" is disabled; enable it in Settings > Agents")) {
      try await handlers.launch(
        IPC.AgentLaunchRequest(projectID: projectID, worktreeID: worktreeID, profile: "Off"))
    }
    await #expect(throws: IPCError.notFound(kind: "profile", id: "nope")) {
      try await handlers.launch(
        IPC.AgentLaunchRequest(projectID: projectID, worktreeID: worktreeID, profile: "nope"))
    }
    let unknownProject = ProjectID(raw: UUID())
    await #expect(throws: IPCError.notFound(kind: "project", id: unknownProject.description)) {
      try await handlers.launch(
        IPC.AgentLaunchRequest(projectID: unknownProject, worktreeID: worktreeID, profile: "Off"))
    }
    let promptless = await Self.ipcError {
      try await handlers.launch(
        IPC.AgentLaunchRequest(projectID: projectID, worktreeID: worktreeID, agent: "amp", prompt: "x"))
    }
    guard case .unsupported = promptless else {
      Issue.record("expected unsupported, got \(String(describing: promptless))")
      return
    }
  }

  private static func ipcError(_ body: () async throws -> some Any) async -> IPCError? {
    do {
      _ = try await body()
      return nil
    } catch let error as IPCError {
      return error
    } catch {
      Issue.record("unexpected error \(error)")
      return nil
    }
  }
}
