import CodansCore
import CodansIPC
import Foundation

nonisolated struct HandoffSource: Sendable, Equatable {
  let paneID: PaneID
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let tabID: TabID
  let worktreePath: String
  /// Server projects keep their worktree on the remote host; the artifact
  /// cannot be written there from this process.
  let isRemote: Bool
  let agentKind: AgentKind?
  let sessionID: String?
  let paneTitle: String?
}

/// Validates the CLI request and starts the same persisted workflow used by the GUI.
@MainActor
final class HandoffHandlers {
  typealias SourceResolver = @MainActor (PaneID) -> HandoffSource?
  typealias WorkflowStarter =
    @MainActor (
      IPC.HandoffRequest, HandoffSource, AgentProfile?, HandoffPlacement
    ) async throws -> (UUID, String)

  private let settings: SettingsStore
  private let resolveSource: SourceResolver
  private let registry: HandoffRequestRegistry
  private let cli: String
  private let startWorkflow: WorkflowStarter

  init(
    settings: SettingsStore,
    registry: HandoffRequestRegistry,
    resolveSource: @escaping SourceResolver,
    cli: String = CLIInvocation.commandName,
    startWorkflow: @escaping WorkflowStarter = { _, _, _, _ in
      throw IPCError.internal("Handoff workflow is unavailable")
    }
  ) {
    self.settings = settings
    self.registry = registry
    self.resolveSource = resolveSource
    self.cli = cli
    self.startWorkflow = startWorkflow
  }

  static var receiverTokens: String {
    AgentKind.allCases.map(\.rawValue).joined(separator: ", ")
  }

  func save(_ request: IPC.HandoffRequest) async throws -> IPC.HandoffResponse {
    let source = try resolvedSource(request)
    _ = try preparedBriefing(request, command: "\(cli) handoff save --brief -")
    try authorize(request)
    return try await enqueue(request, source: source, profile: nil, placement: .default)
  }

  func to(_ request: IPC.HandoffRequest) async throws -> IPC.HandoffResponse {
    guard let token = request.receiver, let receiver = AgentKind(token: token) else {
      throw IPCError.invalidParams(
        message: "handoff to requires an agent; receivers: \(Self.receiverTokens)",
        path: ["receiver"])
    }
    guard let placement = HandoffPlacement(target: request.target, direction: request.direction)
    else {
      throw IPCError.invalidParams(
        message: "handoff cannot target the focused pane; use a new tab (default) or --split",
        path: ["target"])
    }
    let source = try resolvedSource(request)
    _ = try preparedBriefing(request, command: "\(cli) handoff to \(receiver.rawValue) --brief -")
    let profile = try AgentProfileSelector.resolve(
      selector: request.profile, agent: receiver, in: settings.settings.agents)
    try authorize(request)
    return try await enqueue(request, source: source, profile: profile, placement: placement)
  }

  private func enqueue(
    _ request: IPC.HandoffRequest, source: HandoffSource,
    profile: AgentProfile?, placement: HandoffPlacement
  ) async throws -> IPC.HandoffResponse {
    let (runID, directory) = try await startWorkflow(request, source, profile, placement)
    return IPC.HandoffResponse(
      action: request.action, artifactPath: directory,
      outgoingAgent: source.agentKind?.rawValue, receiver: profile?.kind.rawValue,
      branch: nil, changedFileCount: 0, archivedPath: nil, sessionExcerptPath: nil,
      briefing: request.brief == nil ? "none" : "inline", hasBriefing: request.brief != nil,
      launchedPane: nil, runID: runID)
  }

  private func resolvedSource(_ request: IPC.HandoffRequest) throws -> HandoffSource {
    guard let source = resolveSource(request.paneID) else {
      throw IPCError.notFound(kind: "pane", id: request.paneID.description)
    }
    guard !source.isRemote else {
      throw IPCError.unsupported(reason: "Handoff is not available for Server projects")
    }
    return source
  }

  private func preparedBriefing(
    _ request: IPC.HandoffRequest,
    command: String
  ) throws -> HandoffPreparedBriefing {
    if request.brief != nil, request.contextOnly {
      throw IPCError.invalidParams(
        message: "--brief and --no-brief are mutually exclusive", path: nil)
    }
    if let brief = request.brief {
      do {
        return try HandoffPreparedBriefing(source: .inline(brief))
      } catch {
        throw IPCError.invalidParams(
          message: HandoffKickoff.invalidBriefingMessage(), path: ["brief"])
      }
    }
    if request.contextOnly {
      return .contextOnly
    }
    throw IPCError.invalidParams(
      message: HandoffKickoff.briefRequiredMessage(command: command), path: ["brief"])
  }

  /// A panel-injected request may run at most once, and not after the panel
  /// gave up on it and took the context-only path itself.
  private func authorize(_ request: IPC.HandoffRequest) throws {
    guard let requestID = request.requestID else { return }
    guard registry.claim(requestID) else {
      throw IPCError.conflict(
        reason: "this handoff request was already handled or superseded; nothing was changed")
    }
  }

}
