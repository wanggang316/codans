import CodansCore
import CodansIPC
import CodansRemote
import ComposableArchitecture
import Foundation
import Network

/// What a successful connect learned from the Mac.
nonisolated struct RemoteSessionInfo: Equatable, Sendable {
  var serverVersion: String
  /// The permission the Mac reported at handshake. Nil from a Mac that
  /// predates the field; the UI then treats the device as read-only.
  var permission: IPC.RemotePermission?
  /// `system.hello`'s protocol minor. Minor 2 brings the live terminal
  /// (`pane.attachStream`, `terminal.sendEvents`) and tab/pane management.
  var protocolMinor: Int = 1

  /// Whether the Mac serves the live terminal and typed key events.
  var supportsLiveTerminal: Bool { protocolMinor >= 2 }
}

/// An open session: handshake facts plus the `events.subscribe` stream,
/// whose first element is always a snapshot.
nonisolated struct RemoteSession: Sendable {
  var info: RemoteSessionInfo
  var events: AsyncThrowingStream<IPC.EventFrame, Error>
}

/// The network seam of the app. Reducers talk to the Mac only through this
/// dependency, so connection, agents and pane-detail logic are testable
/// without a gateway. The live value keeps one session (a control and an
/// events connection) per process, shared by every scene.
nonisolated struct RemoteClient: Sendable {
  /// Discovers the gateway, opens both connections and subscribes to
  /// events. Replaces any previous session.
  var connect: @Sendable (_ gateway: PairedGateway, _ credential: RemoteTLS.PSKCredential) async throws -> RemoteSession
  /// Closes both connections. Idempotent.
  var disconnect: @Sendable () async -> Void
  /// `pane.read` with `tail` lines of plain text.
  var readPane: @Sendable (_ paneID: String, _ tail: Int) async throws -> String
  var sendInput: @Sendable (_ paneID: String, _ text: String) async throws -> Void
  var sendKey: @Sendable (_ paneID: String, _ key: IPC.TerminalNamedKey) async throws -> Void
  /// `agent.listProfiles`: every profile the Mac knows, enabled or not.
  var listProfiles: @Sendable () async throws -> [IPC.AgentProfileSummary]
  /// `hierarchy.createWorktree` with only a branch name (the Mac picks the
  /// path); returns the new worktree's ID.
  var createWorktree: @Sendable (_ projectID: String, _ branch: String) async throws -> String
  /// `agent.launch` in the background with `prompt` as the agent's first
  /// message; returns the new pane's ID when the Mac created one.
  var launchAgent:
    @Sendable (_ projectID: String, _ worktreeID: String, _ profile: String, _ prompt: String?) async throws -> String?
  /// `pane.attachStream` on a connection of its own, closed when the
  /// stream ends or its consumer stops iterating.
  var attachStream: @Sendable (_ paneID: String) async throws -> AsyncThrowingStream<IPC.TerminalStreamFrame, Error>
  /// `terminal.sendEvents`: one ordered batch.
  var sendEvents:
    @Sendable (_ paneID: String, _ events: [IPC.TerminalInputEvent]) async throws -> IPC.TerminalSendEventsResult
  /// `hierarchy.createTab`; returns the new tab's ID.
  var createTab: @Sendable (_ location: PaneLocator) async throws -> String
  /// `hierarchy.splitPane` beside `location.paneID`; returns the new pane's ID.
  var splitPane: @Sendable (_ location: PaneLocator, _ direction: SplitDirection) async throws -> String
  /// `hierarchy.renameTab`; an empty name clears the user's name.
  var renameTab: @Sendable (_ location: PaneLocator, _ name: String) async throws -> Void
  /// `hierarchy.closeTab`: ends every pane's process in the tab.
  var closeTab: @Sendable (_ location: PaneLocator) async throws -> Void
  /// `hierarchy.closePane`: ends the pane's process.
  var closePane: @Sendable (_ location: PaneLocator) async throws -> Void
  /// `hierarchy.activateTab`: shows the tab on the Mac, which opens its
  /// panes' terminals there.
  var activateTab: @Sendable (_ tabID: String) async throws -> Void
}

/// Where a pane sits, as the hierarchy methods address it.
nonisolated struct PaneLocator: Equatable, Sendable {
  var projectID: String
  var worktreeID: String
  var tabID: String
  var paneID: String
}

/// A split direction as `hierarchy.splitPane` names it.
nonisolated enum SplitDirection: String, Equatable, Sendable {
  case right
  case down
}

nonisolated extension RemoteClient: DependencyKey {
  static let liveValue: RemoteClient = {
    let sessions = LiveRemoteSessions()
    return RemoteClient(
      connect: { try await sessions.connect($0, credential: $1) },
      disconnect: { await sessions.disconnect() },
      readPane: { try await sessions.readPane($0, tail: $1) },
      sendInput: { try await sessions.sendInput($0, text: $1) },
      sendKey: { try await sessions.sendKey($0, key: $1) },
      listProfiles: { try await sessions.listProfiles() },
      createWorktree: { try await sessions.createWorktree(projectID: $0, branch: $1) },
      launchAgent: { try await sessions.launchAgent(projectID: $0, worktreeID: $1, profile: $2, prompt: $3) },
      attachStream: { try await sessions.attachStream($0) },
      sendEvents: { try await sessions.sendEvents($0, events: $1) },
      createTab: { try await sessions.createTab($0) },
      splitPane: { try await sessions.splitPane($0, direction: $1) },
      renameTab: { try await sessions.renameTab($0, name: $1) },
      closeTab: { try await sessions.closeTab($0) },
      closePane: { try await sessions.closePane($0) },
      activateTab: { try await sessions.activateTab($0) }
    )
  }()

  static let testValue = RemoteClient(
    connect: unimplemented("RemoteClient.connect"),
    disconnect: unimplemented("RemoteClient.disconnect"),
    readPane: unimplemented("RemoteClient.readPane"),
    sendInput: unimplemented("RemoteClient.sendInput"),
    sendKey: unimplemented("RemoteClient.sendKey"),
    listProfiles: unimplemented("RemoteClient.listProfiles"),
    createWorktree: unimplemented("RemoteClient.createWorktree"),
    launchAgent: unimplemented("RemoteClient.launchAgent"),
    attachStream: unimplemented("RemoteClient.attachStream"),
    sendEvents: unimplemented("RemoteClient.sendEvents"),
    createTab: unimplemented("RemoteClient.createTab"),
    splitPane: unimplemented("RemoteClient.splitPane"),
    renameTab: unimplemented("RemoteClient.renameTab"),
    closeTab: unimplemented("RemoteClient.closeTab"),
    closePane: unimplemented("RemoteClient.closePane"),
    activateTab: unimplemented("RemoteClient.activateTab")
  )
}

nonisolated extension DependencyValues {
  var remoteClient: RemoteClient {
    get { self[RemoteClient.self] }
    set { self[RemoteClient.self] = newValue }
  }
}

/// Owner of the live control + events connections.
private actor LiveRemoteSessions {
  /// Unary calls. Kept apart from the events stream because the Mac serves
  /// one connection's frames serially.
  private var control: RemoteRPCClient?
  private var events: RemoteRPCClient?
  /// Where and how the current session connected, so each terminal stream
  /// can open its own connection to the same gateway.
  private var streamTarget: (endpoint: NWEndpoint, credential: RemoteTLS.PSKCredential)?
  /// One connection per live terminal stream: the Mac serves a
  /// connection's frames serially, so a busy pane would otherwise hold up
  /// every other call.
  private var streams: [UUID: RemoteRPCClient] = [:]
  /// Bumped by every `disconnect`, so a stream connection that finishes
  /// opening after its session was replaced is closed, not kept.
  private var sessionGeneration = 0

  func connect(_ gateway: PairedGateway, credential: RemoteTLS.PSKCredential) async throws -> RemoteSession {
    await disconnect()
    let candidates = try await GatewayDiscovery.resolve(gateway)
    let hello = HelloRequest(clientVersion: Self.clientVersion, clientBinary: "codans-mobile")
    // A stale advertisement never answers, so with several candidates each
    // gets a shorter handshake budget before moving on to the next.
    let budget: Duration = candidates.count > 1 ? .seconds(5) : RemoteHandshake.defaultTimeout
    var control: RemoteRPCClient?
    var endpoint: NWEndpoint?
    var lastError: Error = RemoteFailure(.notFound, "Couldn't reach \(gateway.displayName).")
    for candidate in candidates {
      do {
        control = try await RemoteRPCClient.connect(
          to: candidate, credential: credential, hello: hello, timeout: budget)
        endpoint = candidate
        break
      } catch {
        lastError = error
      }
    }
    guard let control, let endpoint else { throw lastError }
    let events: RemoteRPCClient
    do {
      events = try await RemoteRPCClient.connect(to: endpoint, credential: credential, hello: hello)
    } catch {
      await control.close()
      throw error
    }
    self.control = control
    self.events = events
    self.streamTarget = (endpoint, credential)

    let stream = try await events.subscribe(
      .eventsSubscribe, params: IPC.EventsSubscribeRequest(), as: IPC.EventFrame.self)
    let serverHello = await control.serverHello
    return RemoteSession(
      info: RemoteSessionInfo(
        serverVersion: serverHello?.serverVersion ?? "",
        permission: serverHello?.remotePermission,
        protocolMinor: serverHello?.protocolMinor ?? 1
      ),
      events: stream
    )
  }

  func disconnect() async {
    let control = self.control
    let events = self.events
    let streams = self.streams.values
    self.control = nil
    self.events = nil
    self.streamTarget = nil
    self.streams = [:]
    sessionGeneration += 1
    await control?.close()
    await events?.close()
    for stream in streams { await stream.close() }
  }

  func attachStream(_ paneID: String) async throws -> AsyncThrowingStream<IPC.TerminalStreamFrame, Error> {
    guard let target = streamTarget else { throw RemoteRPCClient.ClientError.connectionClosed }
    let generation = sessionGeneration
    let request = IPC.PaneAttachStreamRequest(paneID: try Self.paneID(paneID))
    let hello = HelloRequest(clientVersion: Self.clientVersion, clientBinary: "codans-mobile")
    let client = try await RemoteRPCClient.connect(to: target.endpoint, credential: target.credential, hello: hello)
    // The session may have been torn down, or replaced by one to another
    // Mac, while this connection opened.
    guard sessionGeneration == generation else {
      await client.close()
      throw RemoteRPCClient.ClientError.connectionClosed
    }
    let id = UUID()
    streams[id] = client
    let frames: AsyncThrowingStream<IPC.TerminalStreamFrame, Error>
    do {
      frames = try await client.subscribe(.paneAttachStream, params: request, as: IPC.TerminalStreamFrame.self)
    } catch {
      await closeStream(id)
      throw error
    }
    // Relay so the connection closes with the stream, whichever side ends it.
    let (relay, continuation) = AsyncThrowingStream<IPC.TerminalStreamFrame, Error>.makeStream()
    let pump = Task {
      do {
        for try await frame in frames { continuation.yield(frame) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
      await self.closeStream(id)
    }
    continuation.onTermination = { _ in
      pump.cancel()
      Task { await self.closeStream(id) }
    }
    return relay
  }

  private func closeStream(_ id: UUID) async {
    guard let client = streams.removeValue(forKey: id) else { return }
    await client.close()
  }

  func sendEvents(_ paneID: String, events: [IPC.TerminalInputEvent]) async throws -> IPC.TerminalSendEventsResult {
    let request = IPC.TerminalSendEventsRequest(paneID: try Self.paneID(paneID), events: events)
    return try await withControl { control in
      try await control.call(.terminalSendEvents, params: request, as: IPC.TerminalSendEventsResult.self)
    }
  }

  func createTab(_ location: PaneLocator) async throws -> String {
    let params = CreateTabParams(
      projectID: ProjectID(raw: try Self.uuid(location.projectID)),
      worktreeID: WorktreeID(raw: try Self.uuid(location.worktreeID)))
    return try await withControl { control in
      try await control.call(.hierarchyCreateTab, params: params, as: IDResult.self)
    }.id
  }

  func splitPane(_ location: PaneLocator, direction: SplitDirection) async throws -> String {
    let params = SplitPaneParams(
      paneID: try Self.uuid(location.paneID), tabID: try Self.uuid(location.tabID),
      worktreeID: try Self.uuid(location.worktreeID), projectID: try Self.uuid(location.projectID),
      direction: direction.rawValue)
    return try await withControl { control in
      try await control.call(.hierarchySplitPane, params: params, as: IDResult.self)
    }.id
  }

  func renameTab(_ location: PaneLocator, name: String) async throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let params = RenameTabParams(
      id: try Self.uuid(location.tabID), worktreeID: try Self.uuid(location.worktreeID),
      projectID: try Self.uuid(location.projectID), name: trimmed.isEmpty ? nil : trimmed)
    _ = try await withControl { try await $0.callRaw(.hierarchyRenameTab, params: params) }
  }

  func closeTab(_ location: PaneLocator) async throws {
    let params = TabLocatorParams(
      id: try Self.uuid(location.tabID), worktreeID: try Self.uuid(location.worktreeID),
      projectID: try Self.uuid(location.projectID))
    _ = try await withControl { try await $0.callRaw(.hierarchyCloseTab, params: params) }
  }

  func closePane(_ location: PaneLocator) async throws {
    let params = PaneLocatorParams(
      id: try Self.uuid(location.paneID), tabID: try Self.uuid(location.tabID),
      worktreeID: try Self.uuid(location.worktreeID), projectID: try Self.uuid(location.projectID))
    _ = try await withControl { try await $0.callRaw(.hierarchyClosePane, params: params) }
  }

  func activateTab(_ tabID: String) async throws {
    let params = IDParams(id: try Self.uuid(tabID))
    _ = try await withControl { try await $0.callRaw(.hierarchyActivateTab, params: params) }
  }

  func readPane(_ paneID: String, tail: Int) async throws -> String {
    let request = IPC.PaneReadRequest(paneID: try Self.paneID(paneID), range: .all, tail: tail, raw: false)
    return try await withControl { control in
      try await control.call(.paneRead, params: request, as: IPC.PaneReadResponse.self).content
    }
  }

  func sendInput(_ paneID: String, text: String) async throws {
    let params = SendInputParams(paneID: try Self.paneID(paneID), text: text)
    _ = try await withControl { try await $0.callRaw(.terminalSendInput, params: params) }
  }

  func sendKey(_ paneID: String, key: IPC.TerminalNamedKey) async throws {
    let params = SendKeyParams(paneID: try Self.paneID(paneID), key: key)
    _ = try await withControl { try await $0.callRaw(.terminalSendKey, params: params) }
  }

  func listProfiles() async throws -> [IPC.AgentProfileSummary] {
    try await withControl { control in
      try await control.call(
        .agentListProfiles, params: [String: String](), as: IPC.AgentProfileListResponse.self
      ).profiles
    }
  }

  func createWorktree(projectID: String, branch: String) async throws -> String {
    let params = CreateWorktreeParams(projectID: ProjectID(raw: try Self.uuid(projectID)), name: branch, branch: branch)
    return try await withControl { control in
      try await control.call(.hierarchyCreateWorktree, params: params, as: CreateWorktreeResult.self)
    }.id.raw.uuidString
  }

  func launchAgent(projectID: String, worktreeID: String, profile: String, prompt: String?) async throws -> String? {
    // `focus: false`: a launch from the phone must not pull the Mac's
    // window to the new tab under someone working there.
    let request = IPC.AgentLaunchRequest(
      projectID: ProjectID(raw: try Self.uuid(projectID)),
      worktreeID: WorktreeID(raw: try Self.uuid(worktreeID)),
      profile: profile,
      prompt: prompt,
      focus: false
    )
    return try await withControl { control in
      try await control.call(.agentLaunch, params: request, as: IPC.AgentLaunchResponse.self)
    }.paneID?.raw.uuidString
  }

  // MARK: - Internals

  /// `hierarchy.createWorktree` params and result, the part a phone may
  /// send: the Mac refuses `path` and `reuseExisting` from paired devices.
  private struct CreateWorktreeParams: Encodable, Sendable {
    let projectID: ProjectID
    let name: String
    let branch: String
  }

  private struct CreateWorktreeResult: Decodable, Sendable {
    let id: WorktreeID
  }

  /// Tab and pane management params, as the Mac's hierarchy handlers
  /// declare them. Like the terminal params below they live next to the
  /// handlers, not in CodansIPC; the shapes are the stable wire contract
  /// the CLI also relies on.
  private struct CreateTabParams: Encodable, Sendable {
    let projectID: ProjectID
    let worktreeID: WorktreeID
  }

  private struct SplitPaneParams: Encodable, Sendable {
    let paneID: UUID
    let tabID: UUID
    let worktreeID: UUID
    let projectID: UUID
    let direction: String
  }

  private struct RenameTabParams: Encodable, Sendable {
    let id: UUID
    let worktreeID: UUID
    let projectID: UUID
    let name: String?
  }

  private struct TabLocatorParams: Encodable, Sendable {
    let id: UUID
    let worktreeID: UUID
    let projectID: UUID
  }

  private struct PaneLocatorParams: Encodable, Sendable {
    let id: UUID
    let tabID: UUID
    let worktreeID: UUID
    let projectID: UUID
  }

  private struct IDParams: Encodable, Sendable {
    let id: UUID
  }

  /// `{"id": "<uuid>"}`, the result of the create and split methods.
  private struct IDResult: Decodable, Sendable {
    let id: String
  }

  /// `terminal.sendInput` / `terminal.sendKey` params. The Mac declares
  /// these next to its handlers rather than in CodansIPC; the shapes are
  /// part of the stable wire contract the CLI also relies on.
  private struct SendInputParams: Encodable, Sendable {
    let paneID: PaneID
    let text: String
  }

  private struct SendKeyParams: Encodable, Sendable {
    let paneID: PaneID
    let key: IPC.TerminalNamedKey
  }

  /// Runs a unary call on the control connection. A control connection
  /// that died takes the session with it: closing the events connection
  /// ends the stream, so `ConnectionFeature` notices and reconnects
  /// instead of leaving every later call to fail against a dead socket.
  private func withControl<T>(_ call: (RemoteRPCClient) async throws -> T) async throws -> T {
    guard let control else { throw RemoteRPCClient.ClientError.connectionClosed }
    do {
      return try await call(control)
    } catch let error as RemoteRPCClient.ClientError {
      switch error {
      case .connectionClosed, .writeFailed:
        // A newer session may have replaced this one while the call ran.
        if self.control === control { await disconnect() }
      default:
        break
      }
      throw error
    }
  }

  private static func paneID(_ string: String) throws -> PaneID {
    PaneID(raw: try uuid(string))
  }

  private static func uuid(_ string: String) throws -> UUID {
    guard let uuid = UUID(uuidString: string) else {
      throw RemoteFailure(.other, "Invalid id \(string).")
    }
    return uuid
  }

  /// Sent in `system.hello`; the Mac refuses a different major version.
  private static let clientVersion =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
}
