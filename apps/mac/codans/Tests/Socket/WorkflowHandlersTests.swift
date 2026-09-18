import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import Codans

/// `workflow.*` against a temporary worktree, a user-scope workflow
/// directory and stubbed runtime closures. Pins the admission error codes
/// the CLI branches on and the run → deliver → status round trip.
@MainActor
struct WorkflowHandlersTests {
  final class World {
    var lines: [(PaneID, String)] = []
    var states: [PaneID: AgentStateStore.AgentRuntimeState] = [:]
    var kinds: [PaneID: AgentKind] = [:]
    var notifications: [(String, String, PaneID?)] = []
  }

  struct Harness {
    let handlers: WorkflowHandlers
    let engine: WorkflowEngine
    let registry: WorkflowActivationRegistry
    let settings: SettingsStore
    let world: World
    let root: URL
    let workflows: URL
    let paneID: PaneID
    let otherPaneID: PaneID
    let worktreeID: WorktreeID
  }

  static let ping = """
    name: Ping
    roles:
      author:
        source: current
    steps:
      - id: ask
        message: author
        text: Summarize the diff.
        expect: {delivery: summary, sections: ["## Summary"]}
      - id: done
        notify: Done ${{ deliveries.summary.path }}
    """

  static let launch = """
    name: Launcher
    inputs:
      focus:
        type: string
        required: true
    roles:
      reviewer:
        source: launch
        agents: [claude-code]
    steps:
      - launch: reviewer
        prompt: Review ${{ inputs.focus }}.
        expect: {delivery: review}
    """

  static func makeHarness(
    files: [String: String] = ["ping": ping, "launcher": launch],
    profiles: [AgentProfile] = [],
    agent: AgentKind? = .claudeCode
  ) throws -> Harness {
    let base = FileManager.default.temporaryDirectory
      .appending(path: "WorkflowHandlersTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let root = base.appending(path: "worktree", directoryHint: .isDirectory)
    let workflows = base.appending(path: "workflows", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
    for (id, yaml) in files {
      try yaml.write(to: workflows.appending(path: "\(id).workflow.yaml"), atomically: true, encoding: .utf8)
    }
    let settings = SettingsStore(fileURL: base.appending(path: "settings.json"))
    settings.mutateAgents { $0.profiles = profiles }

    let world = World()
    let pane = Pane(workingDirectory: root.path(percentEncoded: false))
    let other = Pane(workingDirectory: root.path(percentEncoded: false))
    let tab = Tab(name: "dev", panes: [pane, other])
    let worktree = Worktree(name: "wt", path: root.path(percentEncoded: false), branch: "main", tabs: [tab])
    let project = Project(name: "proj", rootPath: root.path(percentEncoded: false), worktrees: [worktree])
    let catalog = Catalog(projects: [project])
    if let agent {
      world.kinds[pane.id] = agent
      world.states[pane.id] = .idle
    }
    let addressOf: @MainActor (PaneID) -> PaneAddress? = { paneID in
      guard tab.panes.contains(where: { $0.id == paneID }) else { return nil }
      return PaneAddress(projectID: project.id, worktreeID: worktree.id, tabID: tab.id, paneID: paneID)
    }

    let registry = WorkflowActivationRegistry()
    var dependencies = WorkflowEngineDependencies(
      sendLine: { paneID, line in
        world.lines.append((paneID, line))
        return true
      },
      launch: { _, _, _ in other.id },
      runCommand: { _, _, _, _ in .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false) },
      closePane: { _ in },
      focusPane: { _ in },
      paneExists: { paneID in tab.panes.contains { $0.id == paneID } },
      agentState: { world.states[$0] },
      notify: { title, body, paneID in world.notifications.append((title, body, paneID)) },
      profile: { id in settings.settings.agents.profile(id: id) },
      rememberBinding: { memory in settings.mutateWorkflows { $0.remember(memory) } }
    )
    dependencies.idleHoldSeconds = 0
    dependencies.pollInterval = .milliseconds(5)
    let engine = WorkflowEngine(registry: registry, dependencies: dependencies)
    let discovery = WorkflowDiscovery(bundleDirectory: nil, userDirectory: workflows)
    let admission = WorkflowAdmission(
      context: WorkflowAdmission.Context(
        discovery: discovery,
        settings: { settings.settings },
        catalog: { catalog },
        addressOf: addressOf,
        resolvePane: { reference in UUID(uuidString: reference).map(PaneID.init(raw:)) },
        agentKind: { world.kinds[$0] },
        runID: { registry.runID(forPane: $0) },
        cliCommand: "codans",
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
      ))
    let handlers = WorkflowHandlers(
      settings: settings,
      engine: engine,
      registry: registry,
      admission: admission,
      discovery: discovery,
      catalog: { catalog },
      addressOf: addressOf
    )
    return Harness(
      handlers: handlers, engine: engine, registry: registry, settings: settings, world: world, root: root,
      workflows: workflows, paneID: pane.id, otherPaneID: other.id, worktreeID: worktree.id)
  }

  static func domainCode(_ body: () async throws -> some Any) async -> String? {
    do {
      _ = try await body()
      return nil
    } catch IPCError.domain(let code, _, _) {
      return code
    } catch let error as IPCError {
      return error.code
    } catch {
      return "\(error)"
    }
  }

  static func settle(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<400 where !condition() {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  // MARK: - Admission errors

  @Test
  func unknownWorkflowIsNotFound() async throws {
    let harness = try Self.makeHarness()
    let code = await Self.domainCode {
      try await harness.handlers.run(
        IPC.WorkflowRunRequest(workflow: "nope", sourcePaneID: harness.paneID), peerPID: nil)
    }
    #expect(code == "WORKFLOW_NOT_FOUND")
  }

  @Test
  func invalidWorkflowReportsDiagnostics() async throws {
    let broken = """
      name: Broken
      roles:
        author: {source: current}
      steps:
        - message: nobody
          text: hi
      """
    let harness = try Self.makeHarness(files: ["broken": broken])
    do {
      _ = try await harness.handlers.run(
        IPC.WorkflowRunRequest(workflow: "broken", sourcePaneID: harness.paneID), peerPID: nil)
      Issue.record("expected WORKFLOW_INVALID")
    } catch IPCError.domain(let code, _, let hint) {
      #expect(code == "WORKFLOW_INVALID")
      #expect(hint?.contains("error") == true)
    }
    let listed = try harness.handlers.list(IPC.WorkflowListRequest(paneID: harness.paneID), peerPID: nil)
    #expect(listed.workflows.map(\.id) == ["broken"])
    #expect(listed.workflows[0].isValid == false)
  }

  @Test
  func disabledWorkflowIsRefused() async throws {
    let harness = try Self.makeHarness()
    harness.settings.mutateWorkflows { $0.disabled = ["ping"] }
    let code = await Self.domainCode {
      try await harness.handlers.run(
        IPC.WorkflowRunRequest(workflow: "ping", sourcePaneID: harness.paneID), peerPID: nil)
    }
    #expect(code == "WORKFLOW_DISABLED")
    let listed = try harness.handlers.list(IPC.WorkflowListRequest(paneID: harness.paneID), peerPID: nil)
    #expect(listed.workflows.first { $0.id == "ping" }?.isEnabled == false)
  }

  @Test
  func masterSwitchOffIsUnsupported() async throws {
    let harness = try Self.makeHarness()
    harness.settings.mutateWorkflows { $0.isEnabled = false }
    let code = await Self.domainCode {
      try harness.handlers.list(IPC.WorkflowListRequest(paneID: harness.paneID), peerPID: nil)
    }
    #expect(code == "unsupported")
  }

  @Test
  func currentRoleWithoutAPaneNeedsASource() async throws {
    let harness = try Self.makeHarness()
    let code = await Self.domainCode {
      try await harness.handlers.run(
        IPC.WorkflowRunRequest(workflow: "ping", worktreeID: harness.worktreeID), peerPID: nil)
    }
    #expect(code == "SOURCE_REQUIRED")
    let noSource = await Self.domainCode {
      try await harness.handlers.run(IPC.WorkflowRunRequest(workflow: "ping"), peerPID: nil)
    }
    #expect(noSource == "SOURCE_REQUIRED")
  }

  @Test
  func currentRoleThatIsMessagedNeedsAnAgent() async throws {
    let harness = try Self.makeHarness(agent: nil)
    let code = await Self.domainCode {
      try await harness.handlers.run(
        IPC.WorkflowRunRequest(workflow: "ping", sourcePaneID: harness.paneID), peerPID: nil)
    }
    #expect(code == "SOURCE_REQUIRED")
  }

  @Test
  func missingRequiredInputIsNamed() async throws {
    let profile = AgentProfile(kind: .claudeCode, name: "Reviewer")
    let harness = try Self.makeHarness(profiles: [profile])
    do {
      _ = try await harness.handlers.run(
        IPC.WorkflowRunRequest(workflow: "launcher", sourcePaneID: harness.paneID), peerPID: nil)
      Issue.record("expected INPUT_REQUIRED")
    } catch IPCError.domain(let code, let message, _) {
      #expect(code == "INPUT_REQUIRED")
      #expect(message.contains("focus"))
    }
  }

  @Test
  func launchRoleWithoutAQualifyingProfileNeedsOne() async throws {
    let harness = try Self.makeHarness(profiles: [AgentProfile(kind: .codex, name: "Codex")])
    let code = await Self.domainCode {
      try await harness.handlers.run(
        IPC.WorkflowRunRequest(workflow: "launcher", sourcePaneID: harness.paneID, inputs: ["focus": "tests"]),
        peerPID: nil)
    }
    #expect(code == "PROFILE_REQUIRED")
  }

  @Test
  func badRoleAndSkipAreInvalidArguments() async throws {
    let harness = try Self.makeHarness()
    let role = await Self.domainCode {
      try await harness.handlers.run(
        IPC.WorkflowRunRequest(workflow: "ping", sourcePaneID: harness.paneID, roles: ["ghost": "auto"]), peerPID: nil)
    }
    #expect(role == "invalidParams")
    let skip = await Self.domainCode {
      try await harness.handlers.run(
        IPC.WorkflowRunRequest(workflow: "ping", sourcePaneID: harness.paneID, skip: ["ask"]), peerPID: nil)
    }
    #expect(skip == "invalidParams", "done needs the delivery ask produces")
  }

  // MARK: - Happy path

  @Test
  func selfInitiatedRunDeliversAndAdvances() async throws {
    let harness = try Self.makeHarness()
    let response = try await harness.handlers.run(
      IPC.WorkflowRunRequest(workflow: "ping", sourcePaneID: harness.paneID), peerPID: nil)
    let task = try #require(response.selfInitiated)
    #expect(task.stepID == "ask")
    #expect(task.line.hasPrefix("Summarize the diff."))
    #expect(task.completionCommand.contains("codans workflow deliver"))
    #expect(harness.world.lines.isEmpty)
    #expect(response.bindings.map(\.role) == ["author"])
    #expect(response.bindings[0].paneID == harness.paneID)
    let activation = try #require(harness.registry.activation(forPane: harness.paneID))
    #expect(task.completionCommand.contains(activation.token))

    // "Who am I": the calling pane's run, with the completion command.
    let status = try harness.handlers.status(
      IPC.WorkflowStatusRequest(callerPaneID: harness.paneID), peerPID: nil)
    #expect(status.run.runID == response.runID)
    #expect(status.participant?.role == "author")
    #expect(status.run.activation?.completionCommands == [task.completionCommand])
    // Another pane asking about the run gets no token-bearing command.
    let outsider = try harness.handlers.status(
      IPC.WorkflowStatusRequest(runID: response.runID, callerPaneID: harness.otherPaneID), peerPID: nil)
    #expect(outsider.run.activation?.completionCommands == [])

    let wrong = await Self.domainCode {
      try await harness.handlers.deliver(
        IPC.WorkflowDeliverRequest(callerPaneID: harness.paneID, token: "nope", body: "## Summary\nfine"),
        peerPID: nil)
    }
    #expect(wrong == "TOKEN_INVALID")

    let delivered = try await harness.handlers.deliver(
      IPC.WorkflowDeliverRequest(callerPaneID: harness.paneID, token: activation.token, body: "## Summary\nfine"),
      peerPID: nil)
    #expect(delivered.state == "delivered")
    #expect(delivered.stepID == "ask")
    #expect(FileManager.default.fileExists(atPath: delivered.path))
    await Self.settle { harness.engine.activeRuns.isEmpty }
    let final = try harness.handlers.status(IPC.WorkflowStatusRequest(runID: response.runID), peerPID: nil)
    #expect(final.run.state == "completed")
    #expect(final.run.deliveries.map(\.name) == ["summary"])
    let runs = try harness.handlers.listRuns(IPC.WorkflowListRunsRequest(paneID: harness.paneID), peerPID: nil)
    #expect(runs.runs.map(\.runID) == [response.runID])
  }

  @Test
  func provisionalDeliveryIsResolvedByAccept() async throws {
    let harness = try Self.makeHarness()
    let response = try await harness.handlers.run(
      IPC.WorkflowRunRequest(workflow: "ping", sourcePaneID: harness.paneID), peerPID: nil)
    let token = try #require(harness.registry.activation(forPane: harness.paneID)?.token)
    let delivered = try await harness.handlers.deliver(
      IPC.WorkflowDeliverRequest(callerPaneID: harness.paneID, token: token, body: "no heading here"), peerPID: nil)
    #expect(delivered.state == "provisional")
    #expect(!delivered.issues.isEmpty)
    let waiting = try harness.handlers.status(IPC.WorkflowStatusRequest(runID: response.runID), peerPID: nil)
    #expect(waiting.run.state == "needs_attention")
    #expect(waiting.run.attention?.actions.contains("accept") == true)
    #expect(harness.world.notifications.contains { $0.0 == "Workflow · Ping" })

    let refused = await Self.domainCode {
      try harness.handlers.resolve(
        IPC.WorkflowResolveRequest(runID: response.runID, action: "relaunch"), peerPID: nil)
    }
    #expect(refused == "conflict")
    _ = try harness.handlers.resolve(IPC.WorkflowResolveRequest(runID: response.runID, action: "accept"), peerPID: nil)
    await Self.settle { harness.engine.activeRuns.isEmpty }
    let final = try harness.handlers.status(IPC.WorkflowStatusRequest(runID: response.runID), peerPID: nil)
    #expect(final.run.state == "completed")
    #expect(final.run.deliveries.first?.isProvisional == false)
  }

  @Test
  func manualDeliveryFromOutsideAPaneNamesTheStep() async throws {
    let harness = try Self.makeHarness()
    let response = try await harness.handlers.run(
      IPC.WorkflowRunRequest(workflow: "ping", sourcePaneID: harness.paneID), peerPID: nil)
    let mismatch = await Self.domainCode {
      try await harness.handlers.deliver(
        IPC.WorkflowDeliverRequest(
          callerPaneID: harness.otherPaneID, runID: response.runID, stepID: "ask", body: "## Summary\nok"),
        peerPID: nil)
    }
    #expect(mismatch == "ROLE_MISMATCH")
    let wrongStep = await Self.domainCode {
      try await harness.handlers.deliver(
        IPC.WorkflowDeliverRequest(runID: response.runID, stepID: "done", body: "## Summary\nok"), peerPID: nil)
    }
    #expect(wrongStep == "STEP_NOT_EXPECTING")
    let delivered = try await harness.handlers.deliver(
      IPC.WorkflowDeliverRequest(runID: response.runID, stepID: "ask", body: "## Summary\nok"), peerPID: nil)
    #expect(delivered.state == "delivered")
  }

  @Test
  func cancelEndsTheRunAndFreesThePane() async throws {
    let harness = try Self.makeHarness()
    let response = try await harness.handlers.run(
      IPC.WorkflowRunRequest(workflow: "ping", sourcePaneID: harness.paneID), peerPID: nil)
    let busy = await Self.domainCode {
      try await harness.handlers.run(
        IPC.WorkflowRunRequest(workflow: "ping", sourcePaneID: harness.paneID), peerPID: nil)
    }
    #expect(busy == "PANE_BUSY")
    let cancelled = try harness.handlers.cancel(IPC.WorkflowCancelRequest(runID: response.runID), peerPID: nil)
    #expect(cancelled.run.state == "cancelled")
    await Self.settle { harness.engine.activeRuns.isEmpty }
    #expect(harness.registry.runID(forPane: harness.paneID) == nil)
    let again = await Self.domainCode {
      try harness.handlers.cancel(IPC.WorkflowCancelRequest(runID: response.runID), peerPID: nil)
    }
    #expect(again == "RUN_NOT_FOUND")
  }
}
