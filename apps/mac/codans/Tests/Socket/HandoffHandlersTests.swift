import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import Codans

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
    let source: HandoffSource
    let registry: HandoffRequestRegistry
    let recorder: Recorder
  }

  private final class Recorder {
    struct Call {
      let request: IPC.HandoffRequest
      let source: HandoffSource
      let profile: AgentProfile?
      let placement: HandoffPlacement
    }
    var calls: [Call] = []
    var failure: Error?
    let runID = UUID()
    let directory = "/tmp/handoff-workflow-run"
  }

  private static func makeHarness(
    isRemote: Bool = false, profiles: [AgentProfile]? = nil
  ) throws -> Harness {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("HandoffHandlersTests-\(UUID().uuidString)")
    let settings = SettingsStore(fileURL: root.appendingPathComponent("settings.json"))
    if let profiles { settings.mutateAgents { $0.profiles = profiles } }
    let source = HandoffSource(
      paneID: PaneID(), projectID: ProjectID(raw: UUID()), worktreeID: WorktreeID(raw: UUID()),
      tabID: TabID(), worktreePath: root.path, isRemote: isRemote,
      agentKind: .claudeCode, sessionID: "source-session", paneTitle: "source")
    let registry = HandoffRequestRegistry()
    let recorder = Recorder()
    let handlers = HandoffHandlers(
      settings: settings, registry: registry,
      resolveSource: { $0 == source.paneID ? source : nil },
      cli: "codans",
      startWorkflow: { request, source, profile, placement in
        recorder.calls.append(
          .init(request: request, source: source, profile: profile, placement: placement))
        if let failure = recorder.failure { throw failure }
        return (recorder.runID, recorder.directory)
      })
    return Harness(handlers: handlers, source: source, registry: registry, recorder: recorder)
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
    paneID: PaneID? = nil,
    target: ScriptTarget? = nil,
    direction: ScriptSplitDirection? = nil
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
      requestID: requestID,
      target: target,
      direction: direction
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

  @Test
  func briefingValidationPrecedesWorkflowCreation() async throws {
    let harness = try Self.makeHarness()
    let missing = await Self.ipcError {
      try await harness.handlers.to(Self.request(.to, harness, receiver: "codex"))
    }
    guard case .invalidParams(let message, let path) = missing else {
      Issue.record("Expected missing briefing error")
      return
    }
    #expect(path == ["brief"])
    #expect(message.contains("codans handoff to codex --brief -"))
    let malformed = await Self.ipcError {
      try await harness.handlers.save(Self.request(.save, harness, brief: "just prose"))
    }
    guard case .invalidParams = malformed else {
      Issue.record("Expected invalid briefing error")
      return
    }
    let conflicting = await Self.ipcError {
      try await harness.handlers.save(
        Self.request(.save, harness, brief: Self.briefing, contextOnly: true))
    }
    guard case .invalidParams = conflicting else {
      Issue.record("Expected conflicting briefing options error")
      return
    }
    #expect(harness.recorder.calls.isEmpty)
  }

  @Test
  func saveReturnsQueuedRunWithoutClaimingCompletion() async throws {
    let harness = try Self.makeHarness()
    let response = try await harness.handlers.save(
      Self.request(.save, harness, brief: Self.briefing))
    let call = try #require(harness.recorder.calls.first)
    #expect(call.request.action == .save)
    #expect(call.request.brief == Self.briefing)
    #expect(call.source == harness.source)
    #expect(call.profile == nil)
    #expect(response.runID == harness.recorder.runID)
    #expect(response.artifactPath == harness.recorder.directory)
    #expect(response.action == .save)
    #expect(response.hasBriefing)
    #expect(response.launchedPane == nil)
    #expect(response.archivedPath == nil)
    #expect(response.sessionExcerptPath == nil)
    #expect(
      !FileManager.default.fileExists(atPath: harness.source.worktreePath + "/.codans/handoff"))
    let roundTrip = try JSONDecoder().decode(
      IPC.HandoffResponse.self, from: JSONEncoder().encode(response))
    #expect(roundTrip == response)
  }

  @Test
  func receiverProfileAndSourceAnchoredPlacementReachWorkflow() async throws {
    let profile = AgentProfile(kind: .codex, name: "Build", modelID: "gpt-5.1")
    let harness = try Self.makeHarness(profiles: [profile])
    let response = try await harness.handlers.to(
      Self.request(
        .to, harness, receiver: "codex", profile: profile.id.uuidString,
        brief: Self.briefing, target: .split, direction: .down))
    let call = try #require(harness.recorder.calls.first)
    #expect(call.profile == profile)
    #expect(call.source.paneID == harness.source.paneID)
    #expect(call.source.projectID == harness.source.projectID)
    #expect(call.source.worktreeID == harness.source.worktreeID)
    #expect(call.source.sessionID == "source-session")
    #expect(call.placement.target == .split)
    #expect(call.placement.direction == .down)
    #expect(response.receiver == "codex")
    #expect(response.runID == harness.recorder.runID)
    #expect(response.launchedPane == nil)
  }

  @Test
  func explicitContextOnlyAndNoLaunchAreForwarded() async throws {
    let harness = try Self.makeHarness()
    let response = try await harness.handlers.to(
      Self.request(.to, harness, receiver: "codex", contextOnly: true, launch: false))
    let call = try #require(harness.recorder.calls.first)
    #expect(call.request.contextOnly)
    #expect(!call.request.launch)
    #expect(call.request.brief == nil)
    #expect(call.placement.target == .newTab)
    #expect(!response.hasBriefing)
    #expect(response.runID != nil)
    _ = try await harness.handlers.save(Self.request(.save, harness, contextOnly: true))
    #expect(harness.recorder.calls.last?.request.action == .save)
    #expect(harness.recorder.calls.last?.profile == nil)
  }

  @Test
  func invalidSourceReceiverProfileAndPlacementNeverStartWorkflow() async throws {
    let profile = AgentProfile(kind: .codex, name: "Build")
    let harness = try Self.makeHarness(profiles: [profile])
    let unknown = await Self.ipcError {
      try await harness.handlers.save(
        Self.request(.save, harness, contextOnly: true, paneID: PaneID()))
    }
    guard case .notFound = unknown else {
      Issue.record("Expected unknown source error")
      return
    }
    let receiver = await Self.ipcError {
      try await harness.handlers.to(
        Self.request(.to, harness, receiver: "unknown-agent", contextOnly: true))
    }
    guard case .invalidParams = receiver else {
      Issue.record("Expected unknown receiver error")
      return
    }
    let mismatch = await Self.ipcError {
      try await harness.handlers.to(
        Self.request(
          .to, harness, receiver: "claude", profile: profile.id.uuidString, contextOnly: true))
    }
    guard case .conflict = mismatch else {
      Issue.record("Expected mismatched profile error")
      return
    }
    let placement = await Self.ipcError {
      try await harness.handlers.to(
        Self.request(.to, harness, receiver: "codex", contextOnly: true, target: .focused))
    }
    guard case .invalidParams = placement else {
      Issue.record("Expected focused placement rejection")
      return
    }
    #expect(harness.recorder.calls.isEmpty)
    let remote = try Self.makeHarness(isRemote: true)
    let remoteError = await Self.ipcError {
      try await remote.handlers.save(Self.request(.save, remote, contextOnly: true))
    }
    guard case .unsupported = remoteError else {
      Issue.record("Expected remote source rejection")
      return
    }
    #expect(remote.recorder.calls.isEmpty)
  }

  @Test
  func workflowCreationFailureIsReturnedWithoutFallback() async throws {
    let harness = try Self.makeHarness()
    harness.recorder.failure = IPCError.internal("Run store unavailable")
    let error = await Self.ipcError {
      try await harness.handlers.save(Self.request(.save, harness, brief: Self.briefing))
    }
    guard case .internal(let message) = error else {
      Issue.record("Expected workflow failure")
      return
    }
    #expect(message == "Run store unavailable")
    #expect(harness.recorder.calls.count == 1)
    #expect(
      !FileManager.default.fileExists(atPath: harness.source.worktreePath + "/.codans/handoff"))
  }

  @Test
  func authorizedRequestStartsOnceAndSupersededRequestNeverStarts() async throws {
    let harness = try Self.makeHarness()
    let requestID = UUID()
    harness.registry.register(requestID)
    _ = try await harness.handlers.save(
      Self.request(.save, harness, brief: Self.briefing, requestID: requestID))
    let repeated = await Self.ipcError {
      try await harness.handlers.save(
        Self.request(.save, harness, brief: Self.briefing, requestID: requestID))
    }
    guard case .conflict = repeated else {
      Issue.record("Expected duplicate request rejection")
      return
    }
    let superseded = UUID()
    harness.registry.register(superseded)
    #expect(harness.registry.supersede(superseded))
    let retired = await Self.ipcError {
      try await harness.handlers.save(
        Self.request(.save, harness, brief: Self.briefing, requestID: superseded))
    }
    guard case .conflict = retired else {
      Issue.record("Expected superseded request rejection")
      return
    }
    #expect(harness.recorder.calls.count == 1)
    #expect(harness.recorder.calls.first?.request.requestID == requestID)
  }
}
