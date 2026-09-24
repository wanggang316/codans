import CodansCore
import CodansIPC
import CodansRemote
import ComposableArchitecture
import Foundation

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
}

nonisolated extension RemoteClient: DependencyKey {
  static let liveValue: RemoteClient = {
    let sessions = LiveRemoteSessions()
    return RemoteClient(
      connect: { try await sessions.connect($0, credential: $1) },
      disconnect: { await sessions.disconnect() },
      readPane: { try await sessions.readPane($0, tail: $1) },
      sendInput: { try await sessions.sendInput($0, text: $1) },
      sendKey: { try await sessions.sendKey($0, key: $1) }
    )
  }()

  static let testValue = RemoteClient(
    connect: unimplemented("RemoteClient.connect"),
    disconnect: unimplemented("RemoteClient.disconnect"),
    readPane: unimplemented("RemoteClient.readPane"),
    sendInput: unimplemented("RemoteClient.sendInput"),
    sendKey: unimplemented("RemoteClient.sendKey")
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
    let endpoint = try await GatewayDiscovery.resolve(gateway)
    let hello = HelloRequest(clientVersion: Self.clientVersion, clientBinary: "codans-mobile")
    let control = try await RemoteRPCClient.connect(to: endpoint, credential: credential, hello: hello)
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
    let response = try await requireControl().call(.paneRead, params: request, as: IPC.PaneReadResponse.self)
    return response.content
  }

  func sendInput(_ paneID: String, text: String) async throws {
    _ = try await requireControl().callRaw(
      .terminalSendInput, params: SendInputParams(paneID: try Self.paneID(paneID), text: text))
  }

  func sendKey(_ paneID: String, key: IPC.TerminalNamedKey) async throws {
    _ = try await requireControl().callRaw(
      .terminalSendKey, params: SendKeyParams(paneID: try Self.paneID(paneID), key: key))
  }

  // MARK: - Internals

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

  private func requireControl() throws -> RemoteRPCClient {
    guard let control else { throw RemoteRPCClient.ClientError.connectionClosed }
    return control
  }

  private static func paneID(_ string: String) throws -> PaneID {
    guard let uuid = UUID(uuidString: string) else {
      throw RemoteFailure(.other, "Invalid pane id \(string).")
    }
    return PaneID(raw: uuid)
  }

  /// Sent in `system.hello`; the Mac refuses a different major version.
  private static let clientVersion =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
}
