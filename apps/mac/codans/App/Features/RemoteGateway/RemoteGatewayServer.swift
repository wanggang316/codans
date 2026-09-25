import CodansCore
import CodansIPC
import CodansRemote
import Foundation
import Network
import Observation
import os

/// The LAN listener the iOS companion connects to: TLS-PSK over TCP,
/// advertised over Bonjour, off unless the user turns it on.
///
/// Every authenticated connection is served by the same `SocketConnection`
/// / `MethodRouter` pair as the local Unix socket, tagged with a
/// `.remote` caller context so the router enforces the device's permission
/// tier. Network.framework gives the server no per-connection key lookup,
/// so the listener is built with every paired key and rebuilt whenever the
/// paired set changes; `RemoteHandshake` then binds the connection to one
/// device.
@MainActor
@Observable
final class RemoteGatewayServer {
  enum Status: Equatable {
    case off
    /// `CODANS_REMOTE_DISABLED=1` overrides the setting.
    case forcedOff
    /// Enabled, but nothing is paired, so there is nothing to listen for.
    case noDevices
    case starting
    case listening(port: UInt16)
    /// The listener cannot serve right now (no network, bind failure).
    case unavailable(String)
  }

  /// Where the listener binds. Tests use `.loopback` so they never listen
  /// on the LAN or advertise over Bonjour.
  enum Scope {
    case lan
    case loopback
  }

  /// Unauthenticated handshakes in flight at once; more are refused.
  static let maxPendingHandshakes = 8

  private(set) var status: Status = .off
  /// Devices with at least one live connection, for the device list.
  private(set) var connectedDeviceIDs: Set<UUID> = []
  let devices: PairedDeviceStore
  /// Bonjour service name, also written into pairing codes.
  let serviceName: String
  let channel: BuildChannel
  let isForcedOff: Bool

  @ObservationIgnored private let router: MethodRouter
  @ObservationIgnored private let scope: Scope
  @ObservationIgnored private var isEnabled = false
  @ObservationIgnored private var listener: NWListener?
  @ObservationIgnored private var listenerCredentials: Set<RemoteTLS.PSKCredential> = []
  @ObservationIgnored private var connections: [UUID: LiveConnection] = [:]
  @ObservationIgnored private var pendingHandshakes = 0
  @ObservationIgnored private var expiryTask: Task<Void, Never>?
  @ObservationIgnored private let queue = DispatchQueue(label: "com.gumpw.codans.remote.gateway")
  @ObservationIgnored private let logger = Logger(subsystem: "com.gumpw.codans.remote", category: "gateway")

  private struct LiveConnection {
    let deviceID: UUID
    let task: Task<Void, Never>
    let transport: NWFrameTransport
  }

  init(
    router: MethodRouter,
    devices: PairedDeviceStore,
    channel: BuildChannel = .current,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    hostName: String = RemoteGatewayServer.defaultHostName(),
    scope: Scope = .lan
  ) {
    self.router = router
    self.scope = scope
    self.devices = devices
    self.channel = channel
    self.isForcedOff = environment[CodansEnvironment.Key.remoteDisabled.rawValue] == "1"
    self.serviceName = RemoteBonjour.serviceName(
      hostName: hostName, channel: channel.slug, releaseChannel: BuildChannel.release.slug)
    devices.onCredentialsChanged = { [weak self] in self?.reconcileListener() }
    devices.onRevoked = { [weak self] id in self?.dropConnections(of: id) }
  }

  static func defaultHostName() -> String {
    Host.current().localizedName ?? ProcessInfo.processInfo.hostName
  }

  /// Follows the Settings switch. Turning it off cancels the listener,
  /// withdraws the Bonjour advertisement and closes every remote
  /// connection.
  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    devices.pruneExpiredPending()
    reconcileListener()
    if !enabled || isForcedOff {
      for id in Array(connections.keys) { closeConnection(id) }
    }
  }

  // MARK: - Pairing

  /// Issues a pending device and returns the code the phone scans or
  /// pastes. The code stops working after `PairedDeviceStore.pendingLifetime`
  /// unless the phone connects first.
  func pairNewDevice(permission: IPC.RemotePermission = .readOnly) throws -> PairingPayload {
    let device = try devices.beginPairing(permission: permission)
    guard let payload = payload(for: device.id) else {
      devices.revoke(device.id)
      throw CocoaError(.keyValueValidation)
    }
    return payload
  }

  /// The pairing code for a device still holding a key.
  func payload(for id: UUID) -> PairingPayload? {
    guard let key = devices.key(for: id) else { return nil }
    return PairingPayload(
      serviceName: serviceName, deviceID: id, pskIdentity: id.uuidString, psk: key, channel: channel.slug)
  }

  // MARK: - Listener

  private func reconcileListener() {
    scheduleExpiry()
    guard isEnabled, !isForcedOff else {
      stopListener()
      status = isForcedOff && isEnabled ? .forcedOff : .off
      return
    }
    let credentials = Set(devices.credentials())
    guard !credentials.isEmpty else {
      stopListener()
      status = .noDevices
      return
    }
    if listener != nil, credentials == listenerCredentials { return }
    stopListener()
    startListener(credentials)
  }

  private func startListener(_ credentials: Set<RemoteTLS.PSKCredential>) {
    let parameters = RemoteTLS.serverParameters(credentials: Array(credentials))
    if scope == .loopback {
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    }
    let listener: NWListener
    do {
      listener = try NWListener(using: parameters)
    } catch {
      status = .unavailable(String(describing: error))
      logger.error("listener create failed: \(String(describing: error), privacy: .public)")
      return
    }
    switch scope {
    case .lan:
      listener.service = NWListener.Service(
        name: serviceName,
        type: RemoteBonjour.serviceType,
        domain: nil,
        txtRecord: RemoteBonjour.txtRecord(
          channel: channel.slug, protocolMajor: RemoteRPCClient.supportedProtocolMajor)
      )
    case .loopback:
      break
    }
    let keys = Dictionary(credentials.map { ($0.identity, $0.key) }, uniquingKeysWith: { first, _ in first })
    // Network.framework calls these on `queue`; `@Sendable` keeps them
    // from being inferred MainActor-isolated, which would trap there.
    listener.newConnectionHandler = { @Sendable [weak self] connection in
      Task { @MainActor [weak self] in
        guard let self else {
          connection.cancel()
          return
        }
        self.accept(connection, keys: keys)
      }
    }
    listener.stateUpdateHandler = { @Sendable [weak self, weak listener] state in
      Task { @MainActor [weak self] in
        guard let self, let listener, listener === self.listener else { return }
        self.listenerStateChanged(state, port: listener.port)
      }
    }
    self.listener = listener
    listenerCredentials = credentials
    status = .starting
    listener.start(queue: queue)
    logger.info("listener starting with \(credentials.count, privacy: .public) paired key(s)")
  }

  private func listenerStateChanged(_ state: NWListener.State, port: NWEndpoint.Port?) {
    switch state {
    case .ready:
      status = .listening(port: port?.rawValue ?? 0)
      logger.info("listening on port \(port?.rawValue ?? 0, privacy: .public) as \(self.serviceName, privacy: .public)")
    case .waiting(let error):
      status = .unavailable(error.localizedDescription)
      logger.error("listener waiting: \(String(describing: error), privacy: .public)")
    case .failed(let error):
      status = .unavailable(error.localizedDescription)
      logger.error("listener failed: \(String(describing: error), privacy: .public)")
      stopListener()
    case .setup, .cancelled:
      break
    @unknown default:
      break
    }
  }

  private func stopListener() {
    listener?.stateUpdateHandler = nil
    listener?.newConnectionHandler = nil
    listener?.cancel()
    listener = nil
    listenerCredentials = []
  }

  // MARK: - Connections

  private func accept(_ connection: NWConnection, keys: [String: Data]) {
    guard listener != nil, pendingHandshakes < Self.maxPendingHandshakes else {
      logger.notice("refused connection: gateway stopped or too many pending handshakes")
      connection.cancel()
      return
    }
    pendingHandshakes += 1
    Task { [weak self] in
      let outcome: Result<(identity: String, transport: NWFrameTransport), Error>
      do {
        outcome = .success(try await RemoteHandshake.accept(connection) { keys[$0] })
      } catch {
        outcome = .failure(error)
      }
      self?.handshakeFinished(outcome)
    }
  }

  private func handshakeFinished(_ outcome: Result<(identity: String, transport: NWFrameTransport), Error>) {
    pendingHandshakes -= 1
    let accepted: (identity: String, transport: NWFrameTransport)
    switch outcome {
    case .success(let value):
      accepted = value
    case .failure(let error):
      logger.notice("handshake rejected: \(String(describing: error), privacy: .public)")
      return
    }
    // Re-check against the store: the device may have been revoked, its
    // pairing code may have expired (the listener still holds that key
    // until the next rebuild), or the gateway turned off, while the
    // handshake was in flight.
    guard isEnabled, !isForcedOff, let deviceID = UUID(uuidString: accepted.identity),
      let device = devices.device(deviceID), !devices.isExpired(device)
    else {
      devices.pruneExpiredPending()
      logger.notice("handshake for \(accepted.identity, privacy: .public) no longer authorized")
      accepted.transport.close()
      return
    }
    devices.recordConnection(deviceID)
    serve(accepted.transport, deviceID: deviceID)
  }

  private func serve(_ transport: NWFrameTransport, deviceID: UUID) {
    let connectionID = UUID()
    // A streaming response never reads again, so a phone that vanished is
    // only noticed when a write fails; cancelling the serve task then ends
    // the stream instead of producing into a dead connection.
    let serveTaskBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    let connection = SocketConnection(
      id: connectionID,
      router: router,
      reader: transport.makeReader(),
      write: { data in
        do {
          try await transport.write(data)
        } catch {
          transport.close()
          serveTaskBox.withLock { $0 }?.cancel()
        }
      },
      close: { transport.close() },
      context: { [weak devices] in
        devices?.permission(for: deviceID).map { .remote(deviceID: deviceID, permission: $0) }
      }
    )
    let task = Task.detached { [weak self] in
      await connection.serve()
      await self?.connectionEnded(connectionID)
    }
    serveTaskBox.withLock { $0 = task }
    connections[connectionID] = LiveConnection(deviceID: deviceID, task: task, transport: transport)
    connectedDeviceIDs.insert(deviceID)
    logger.info("device \(deviceID.uuidString, privacy: .public) connected")
  }

  private func connectionEnded(_ connectionID: UUID) {
    guard let ended = connections.removeValue(forKey: connectionID) else { return }
    refreshConnectedDevices()
    logger.info("device \(ended.deviceID.uuidString, privacy: .public) disconnected")
  }

  private func dropConnections(of deviceID: UUID) {
    for (id, live) in connections where live.deviceID == deviceID {
      closeConnection(id)
    }
  }

  /// Cancels the serve task, which ends any event stream with its final
  /// frame and closes the transport; the delayed close is the backstop
  /// for a connection stuck in a write.
  private func closeConnection(_ connectionID: UUID) {
    guard let live = connections.removeValue(forKey: connectionID) else { return }
    live.task.cancel()
    let transport = live.transport
    Task.detached {
      try? await Task.sleep(for: .seconds(1))
      transport.close()
    }
    refreshConnectedDevices()
  }

  private func refreshConnectedDevices() {
    connectedDeviceIDs = Set(connections.values.map(\.deviceID))
  }

  /// Arms one timer for the earliest pending pairing's deadline. Runs on
  /// every reconcile, so pairings loaded at launch and codes issued while
  /// another is still pending each expire on time, not when the newest
  /// code does.
  private func scheduleExpiry() {
    expiryTask?.cancel()
    expiryTask = nil
    guard let deadline = devices.nextPendingExpiry() else { return }
    let delay = max(deadline.timeIntervalSince(devices.currentDate()), 0)
    expiryTask = Task { [weak self] in
      // The slack keeps a wake-up a hair early from re-arming a zero delay.
      try? await Task.sleep(for: .seconds(delay) + .milliseconds(500))
      guard !Task.isCancelled, let self else { return }
      self.devices.pruneExpiredPending()
      self.scheduleExpiry()
    }
  }
}
