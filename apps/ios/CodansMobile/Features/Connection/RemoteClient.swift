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
      launchAgent: { try await sessions.launchAgent(projectID: $0, worktreeID: $1, profile: $2, prompt: $3) }
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
    launchAgent: unimplemented("RemoteClient.launchAgent")
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
        control = try await RemoteRPCClient.connect(to: candidate, credential: credential, hello: hello, timeout: budget)
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

    let stream = try await events.subscribe(
      .eventsSubscribe, params: IPC.EventsSubscribeRequest(), as: IPC.EventFrame.self)
    let serverHello = await control.serverHello
    return RemoteSession(
      info: RemoteSessionInfo(
        serverVersion: serverHello?.serverVersion ?? "",
        permission: serverHello?.remotePermission
      ),
      events: stream
    )
  }

  func disconnect() async {
    let control = self.control
    let events = self.events
    self.control = nil
    self.events = nil
    await control?.close()
    await events?.close()
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
