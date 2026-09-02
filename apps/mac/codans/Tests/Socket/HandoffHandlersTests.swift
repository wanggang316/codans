import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import Codans

/// `handoff.save` / `handoff.to` against a temporary worktree and stubbed
/// runtime closures. Pins the contract the CLI and the in-app panel rely on:
/// briefing is mandatory-or-explicit with zero side effects on rejection,
/// the archive-first transition, receiver launch through the shared agent
/// pipeline, and one-shot request authorization.
@MainActor
struct HandoffHandlersTests {
  private static let briefing = """
    # Handoff
    ## Objective
    Finish.
    ## Current State
    Mid-way.
    ## Next Steps
    1. Ship.
    """

  private struct Harness {
    let handlers: HandoffHandlers
    let store: HandoffStore
    let source: HandoffSource
    let registry: HandoffRequestRegistry
    let launches: LaunchRecorder
  }

  /// Records launch specs and answers with a fixed pane, or throws.
  final class LaunchRecorder {
    var specs: [AgentLaunchSpec] = []
    var failure: Error?
    let tabID = TabID()
    let paneID = PaneID()
  }

  private static func makeHarness(
    agent: AgentKind? = .claudeCode,
    isRemote: Bool = false,
    profiles: [AgentProfile]? = nil,
    screen: String? = "last screen"
  ) throws -> Harness {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "HandoffHandlersTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let settingsURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("HandoffHandlersTests-\(UUID().uuidString).json")
    let settings = SettingsStore(fileURL: settingsURL)
    if let profiles {
      settings.mutateAgents { $0.profiles = profiles }
    }
    let source = HandoffSource(
      paneID: PaneID(),
      projectID: ProjectID(raw: UUID()),
      worktreeID: WorktreeID(raw: UUID()),
      tabID: TabID(),
      worktreePath: root.path(percentEncoded: false),
      isRemote: isRemote,
      agentKind: agent,
      sessionID: agent == nil ? nil : "sess-1",
      paneTitle: "source"
    )
    let registry = HandoffRequestRegistry()
    let launches = LaunchRecorder()
    let handlers = HandoffHandlers(
      settings: settings,
      registry: registry,
      resolveSource: { paneID in paneID == source.paneID ? source : nil },
      readScreen: { _ in screen },
      collectRepoState: { _ in
        HandoffRepoState(branch: "feat/x", isGit: true, changedFiles: ["a.swift"], additions: 2, deletions: 1)
      },
      launch: { spec in
        launches.specs.append(spec)
        if let failure = launches.failure { throw failure }
        return AgentLaunchOutcome(
          profile: spec.profile, command: "cmd", tabID: launches.tabID, paneID: launches.paneID)
      },
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    return Harness(
      handlers: handlers, store: HandoffStore(rootURL: root), source: source,
      registry: registry, launches: launches)
  }

  private static func request(
    _ action: IPC.HandoffAction,
    _ harness: Harness,
    receiver: String? = nil,
    profile: String? = nil,
    brief: String? = nil,
    contextOnly: Bool = false,
    launch: Bool = true,
    requestID: UUID? = nil,
    paneID: PaneID? = nil
  ) -> IPC.HandoffRequest {
    IPC.HandoffRequest(
      action: action,
      paneID: paneID ?? harness.source.paneID,
      receiver: receiver,
      profile: profile,
      brief: brief,
      contextOnly: contextOnly,
      note: nil,
      launch: launch,
      requestID: requestID
    )
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

  // MARK: - Briefing gate

  @Test
  func missingBriefingChoiceIsRejectedWithGuidanceAndNoSideEffects() async throws {
    let harness = try Self.makeHarness()
    let error = await Self.ipcError {
      try await harness.handlers.to(Self.request(.to, harness, receiver: "codex"))
    }
    guard case .invalidParams(let message, let path) = error else {
      Issue.record("expected invalidParams, got \(String(describing: error))")
      return
    }
    #expect(path == ["brief"])
    #expect(message.contains("codans handoff to codex --brief - <<'EOF'"))
    #expect(!FileManager.default.fileExists(atPath: harness.store.handoffDirectory.path(percentEncoded: false)))
    #expect(harness.launches.specs.isEmpty)
  }

  @Test
  func invalidBriefingIsRejectedBeforeAnyWrite() async throws {
    let harness = try Self.makeHarness()
    let error = await Self.ipcError {
      try await harness.handlers.save(Self.request(.save, harness, brief: "just prose"))
    }
    guard case .invalidParams(let message, _) = error else {
      Issue.record("expected invalidParams, got \(String(describing: error))")
      return
    }
    #expect(message.contains("missing required sections"))
    #expect(!FileManager.default.fileExists(atPath: harness.store.handoffDirectory.path(percentEncoded: false)))
  }

  @Test
  func briefAndNoBriefTogetherAreRejected() async throws {
    let harness = try Self.makeHarness()
    let error = await Self.ipcError {
      try await harness.handlers.save(Self.request(.save, harness, brief: Self.briefing, contextOnly: true))
    }
    guard case .invalidParams = error else {
      Issue.record("expected invalidParams, got \(String(describing: error))")
      return
    }
  }

  // MARK: - save

  @Test
  func saveInstallsTheBriefingAndRefreshesContext() async throws {
    let harness = try Self.makeHarness()
    let response = try await harness.handlers.save(Self.request(.save, harness, brief: Self.briefing))

    #expect(response.action == .save)
    #expect(response.hasBriefing)
    #expect(response.outgoingAgent == "claude-code")
    #expect(response.branch == "feat/x")
    #expect(response.changedFileCount == 1)
    // The session file is named after the pane id; the slug lowercases the
    // UUID and keeps its dashes.
    let paneSlug = harness.source.paneID.description.lowercased()
    #expect(response.sessionExcerptPath == "handoff/sessions/20231114-221320-\(paneSlug).md")
    #expect(try String(contentsOf: harness.store.currentURL, encoding: .utf8) == Self.briefing + "\n")
    let context = try String(contentsOf: harness.store.contextURL, encoding: .utf8)
    #expect(context.contains("- Agent: Claude Code"))
    #expect(context.contains("- Reattach to the outgoing session: `claude --resume 'sess-1'`"))
    let excerpt = try String(
      contentsOf: harness.store.stateDirectory.appending(path: response.sessionExcerptPath!), encoding: .utf8)
    #expect(excerpt.contains("last screen"))
    #expect(try String(contentsOf: harness.store.logURL, encoding: .utf8).contains("save  agent=claude-code"))
    #expect(harness.launches.specs.isEmpty)
  }

  // MARK: - to

  @Test
  func handoffToLaunchesTheReceiverInABackgroundTabWithTheKickoffPrompt() async throws {
    let harness = try Self.makeHarness()
    try harness.store.writeBriefing("# previous\n", archivingPrevious: false, now: Date())

    let response = try await harness.handlers.to(
      Self.request(.to, harness, receiver: "codex", brief: Self.briefing))

    #expect(response.receiver == "codex")
    #expect(response.hasBriefing)
    #expect(response.archivedPath == "handoff/archive/20231114-221320-claude-code-to-codex.md")
    #expect(response.launchedPane?.paneID == harness.launches.paneID)
    #expect(response.launchedPane?.tabID == harness.launches.tabID)
    #expect(response.launchedPane?.profileName == "Codex")

    let spec = try #require(harness.launches.specs.first)
    #expect(spec.profile.kind == .codex)
    #expect(spec.prompt == HandoffKickoff.receiverPrompt(hasBriefing: true))
    #expect(spec.target == .newTab)
    #expect(spec.focus == false)
    #expect(spec.tabName == "Hand off → Codex")
    #expect(spec.projectID == harness.source.projectID)

    let log = try String(contentsOf: harness.store.logURL, encoding: .utf8)
    #expect(log.contains("claude-code -> codex  pane=\(harness.launches.paneID)  briefing=inline  source=cli"))
  }

  @Test
  func handoffToUsesTheReceiversEnabledProfileOrAnExplicitOne() async throws {
    let build = AgentProfile(kind: .codex, name: "Build", modelID: "gpt-5.1")
    let plan = AgentProfile(kind: .codex, name: "Plan", isEnabled: false)
    let harness = try Self.makeHarness(profiles: [plan, build])

    _ = try await harness.handlers.to(
      Self.request(.to, harness, receiver: "codex", contextOnly: true))
    #expect(harness.launches.specs.last?.profile.id == build.id)

    _ = try await harness.handlers.to(
      Self.request(.to, harness, receiver: "codex", profile: "plan", contextOnly: true))
    #expect(harness.launches.specs.last?.profile.id == plan.id)

    let mismatch = await Self.ipcError {
      try await harness.handlers.to(
        Self.request(.to, harness, receiver: "claude", profile: build.id.uuidString, contextOnly: true))
    }
    guard case .conflict = mismatch else {
      Issue.record("expected conflict, got \(String(describing: mismatch))")
      return
    }
  }

  @Test
  func contextOnlyHandoffRemovesTheStaleBriefingAndTellsTheReceiver() async throws {
    let harness = try Self.makeHarness()
    try harness.store.writeBriefing("# previous\n", archivingPrevious: false, now: Date())

    let response = try await harness.handlers.to(
      Self.request(.to, harness, receiver: "claude", contextOnly: true))
    #expect(!response.hasBriefing)
    #expect(!harness.store.hasCurrentBriefing)
    #expect(harness.launches.specs.first?.prompt == HandoffKickoff.receiverPrompt(hasBriefing: false))
  }

  @Test
  func noLaunchArchivesAndSavesWithoutStartingAnything() async throws {
    let harness = try Self.makeHarness()
    let response = try await harness.handlers.to(
      Self.request(.to, harness, receiver: "amp", brief: Self.briefing, launch: false))
    #expect(response.launchedPane == nil)
    #expect(harness.launches.specs.isEmpty)
    #expect(try String(contentsOf: harness.store.logURL, encoding: .utf8).contains("claude-code -> amp  (no launch)"))
  }

  @Test
  func launchingAnAgentWithoutAPromptStyleIsUnsupported() async throws {
    let harness = try Self.makeHarness()
    let error = await Self.ipcError {
      try await harness.handlers.to(Self.request(.to, harness, receiver: "amp", brief: Self.briefing))
    }
    guard case .unsupported(let reason) = error else {
      Issue.record("expected unsupported, got \(String(describing: error))")
      return
    }
    #expect(reason.contains("--no-launch"))
    #expect(!FileManager.default.fileExists(atPath: harness.store.handoffDirectory.path(percentEncoded: false)))
  }

  @Test
  func failedReceiverLaunchIsLoggedAndReported() async throws {
    let harness = try Self.makeHarness()
    harness.launches.failure = RunScriptError.missingWorktree(harness.source.worktreeID)
    let error = await Self.ipcError {
      try await harness.handlers.to(Self.request(.to, harness, receiver: "codex", brief: Self.briefing))
    }
    guard case .internal(let message) = error else {
      Issue.record("expected internal, got \(String(describing: error))")
      return
    }
    #expect(message.contains("failed to launch Codex"))
    // The artifact work already happened and is kept: the receiver can
    // still be started by hand from the briefing.
    #expect(harness.store.hasCurrentBriefing)
    #expect(try String(contentsOf: harness.store.logURL, encoding: .utf8).contains("launch=failed"))
  }

  // MARK: - Source resolution

  @Test
  func unknownPaneAndRemoteWorktreeAreRejected() async throws {
    let harness = try Self.makeHarness()
    let unknown = await Self.ipcError {
      try await harness.handlers.save(Self.request(.save, harness, contextOnly: true, paneID: PaneID()))
    }
    guard case .notFound(let kind, _) = unknown, kind == "pane" else {
      Issue.record("expected notFound(pane), got \(String(describing: unknown))")
      return
    }

    let remote = try Self.makeHarness(isRemote: true)
    let error = await Self.ipcError {
      try await remote.handlers.save(Self.request(.save, remote, contextOnly: true))
    }
    guard case .unsupported = error else {
      Issue.record("expected unsupported, got \(String(describing: error))")
      return
    }
  }

  @Test
  func unknownReceiverIsRejected() async throws {
    let harness = try Self.makeHarness()
    let error = await Self.ipcError {
      try await harness.handlers.to(Self.request(.to, harness, receiver: "aider", brief: Self.briefing))
    }
    guard case .invalidParams(_, let path) = error else {
      Issue.record("expected invalidParams, got \(String(describing: error))")
      return
    }
    #expect(path == ["receiver"])
  }

  // MARK: - Request authorization

  @Test
  func panelRequestRunsOnceAndNotAfterBeingSuperseded() async throws {
    let harness = try Self.makeHarness()
    let requestID = UUID()
    harness.registry.register(requestID)

    var received: [HandoffCompletion] = []
    let stream = harness.registry.completions()
    let collector = Task { for await completion in stream { received.append(completion) } }

    _ = try await harness.handlers.save(
      Self.request(.save, harness, brief: Self.briefing, requestID: requestID))
    await Task.yield()
    #expect(received.count == 1)
    #expect(received.first?.requestID == requestID)
    #expect(received.first?.sourcePaneID == harness.source.paneID)

    // Second run of the same request: refused, nothing rewritten.
    let repeated = await Self.ipcError {
      try await harness.handlers.save(
        Self.request(.save, harness, brief: Self.briefing, requestID: requestID))
    }
    guard case .conflict = repeated else {
      Issue.record("expected conflict, got \(String(describing: repeated))")
      return
    }

    let superseded = UUID()
    harness.registry.register(superseded)
    #expect(harness.registry.supersede(superseded))
    let afterFallback = await Self.ipcError {
      try await harness.handlers.save(
        Self.request(.save, harness, brief: Self.briefing, requestID: superseded))
    }
    guard case .conflict = afterFallback else {
      Issue.record("expected conflict, got \(String(describing: afterFallback))")
      return
    }
    // Only one completion was ever published.
    #expect(received.count == 1)
    collector.cancel()
  }
}
