import CodansIPC
import CodansRemote
import ComposableArchitecture
import Foundation
import SwiftUI
import os

/// The connection state machine to the paired Mac: pairing, connecting,
/// streaming events, backing off after a failure, and suspending while the
/// app is in the background. One instance per process (in `AppFeature`),
/// shared by every scene.
///
/// ```
/// idle ──connect──▶ connecting ──opened──▶ connected
///   ▲                  │  ▲                    │
///   │            failed│  │timer / network     │stream ended
///   │                  ▼  │                    ▼
///   └── background ── retrying(after:) ◀───────┘
/// ```
@Reducer
struct ConnectionFeature {
  @ObservableState
  struct State: Equatable {
    var gateways: [PairedGateway] = []
    var activeID: UUID?
    var status: Status = .idle
    /// Consecutive failed attempts since the last success; drives backoff.
    var failedAttempts = 0
    var session: RemoteSessionInfo?
    var lastFailure: RemoteFailure?
    var pairingError: String?
    /// False while every scene is in the background.
    var isAppActive = true
    var hasStarted = false

    var activeGateway: PairedGateway? {
      gateways.first { $0.deviceID == activeID }
    }

    /// The permission to render with. Read-only until the Mac says
    /// otherwise, so input controls never flash for a read-only device.
    var permission: IPC.RemotePermission {
      session?.permission ?? .readOnly
    }
  }

  enum Status: Equatable {
    /// Not connected and not trying: no pairing, or a failure that retrying
    /// cannot fix.
    case idle
    case connecting
    case connected
    /// Waiting out a backoff delay before the next attempt.
    case retrying(after: Duration)
    /// Every scene is in the background; iOS would suspend the sockets.
    case suspended
  }

  enum Action: Equatable {
    /// First appearance of any scene. Idempotent across scenes.
    case task
    case scenePhaseChanged(ScenePhase)
    case connectTapped
    case sessionOpened(RemoteSessionInfo)
    case eventReceived(IPC.EventFrame)
    case sessionEnded(RemoteFailure)
    case retryTimerFired
    case networkBecameAvailable
    case pairingCodeSubmitted(String)
    case gatewaySelected(UUID)
    case forgetTapped(UUID)
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case eventReceived(IPC.EventFrame)
      /// The active Mac changed or was forgotten: drop every model
      /// derived from the previous one.
      case activeGatewayChanged
    }
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case session
    case retry
    case networkPath
  }

  /// First retry waits 0.5 s; each further failure doubles it up to 30 s.
  static func backoff(afterFailures failures: Int) -> Duration {
    let exponent = min(max(failures - 1, 0), 10)
    return min(.milliseconds(500) * (1 << exponent), .seconds(30))
  }

  @Dependency(\.remoteClient) var remoteClient
  @Dependency(\.pairingStore) var pairingStore
  @Dependency(\.networkPath) var networkPath
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now

  private static let logger = Logger(subsystem: "com.gumpw.codans.mobile", category: "connection")

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        guard !state.hasStarted else { return .none }
        state.hasStarted = true
        let snapshot = pairingStore.load()
        state.gateways = snapshot.gateways
        state.activeID = snapshot.activeID
        let paths = networkPath.becameAvailable
        return .merge(
          .run { send in
            for await _ in paths() { await send(.networkBecameAvailable) }
          }
          .cancellable(id: CancelID.networkPath, cancelInFlight: true),
          connect(&state)
        )

      case .scenePhaseChanged(let phase):
        switch phase {
        case .active:
          guard !state.isAppActive else { return .none }
          state.isAppActive = true
          state.failedAttempts = 0
          return connect(&state)
        case .background:
          guard state.isAppActive else { return .none }
          state.isAppActive = false
          state.status = .suspended
          return tearDown()
        default:
          // `.inactive` (app switcher, a sheet over the scene, Control
          // Center) keeps the connection.
          return .none
        }

      case .connectTapped:
        state.failedAttempts = 0
        return .merge(.cancel(id: CancelID.retry), connect(&state))

      case .sessionOpened(let info):
        state.status = .connected
        state.session = info
        state.failedAttempts = 0
        state.lastFailure = nil
        Self.logger.info("connected (server \(info.serverVersion, privacy: .public))")
        return .none

      case .eventReceived(let frame):
        return .send(.delegate(.eventReceived(frame)))

      case .sessionEnded(let failure):
        state.session = nil
        state.lastFailure = failure
        Self.logger.notice("session ended: \(failure.message, privacy: .public)")
        let disconnect = remoteClient.disconnect
        let close = Effect<Action>.run { _ in await disconnect() }
        guard state.isAppActive, state.activeGateway != nil, failure.isRetryable else {
          state.status = state.isAppActive ? .idle : .suspended
          return close
        }
        state.failedAttempts += 1
        let delay = Self.backoff(afterFailures: state.failedAttempts)
        state.status = .retrying(after: delay)
        return .merge(
          close,
          .run { [clock] send in
            try await clock.sleep(for: delay)
            await send(.retryTimerFired)
          }
          .cancellable(id: CancelID.retry, cancelInFlight: true)
        )

      case .retryTimerFired:
        guard case .retrying = state.status else { return .none }
        return connect(&state)

      case .networkBecameAvailable:
        guard case .retrying = state.status else { return .none }
        return .merge(.cancel(id: CancelID.retry), connect(&state))

      case .pairingCodeSubmitted(let code):
        let payload: PairingPayload
        do {
          payload = try PairingPayload.decode(code)
        } catch {
          state.pairingError = Self.message(for: error)
          return .none
        }
        let gateway: PairedGateway
        do {
          gateway = try pairingStore.save(payload, now)
        } catch {
          state.pairingError = "Couldn't store the pairing key: \(error.localizedDescription)"
          return .none
        }
        state.pairingError = nil
        state.gateways.removeAll { $0.deviceID == gateway.deviceID }
        state.gateways.append(gateway)
        return switchActive(to: gateway.deviceID, state: &state)

      case .gatewaySelected(let id):
        guard id != state.activeID, state.gateways.contains(where: { $0.deviceID == id }) else { return .none }
        pairingStore.setActive(id)
        return switchActive(to: id, state: &state)

      case .forgetTapped(let id):
        pairingStore.remove(id)
        state.gateways.removeAll { $0.deviceID == id }
        guard id == state.activeID else { return .none }
        let next = state.gateways.first?.deviceID
        pairingStore.setActive(next)
        return switchActive(to: next, state: &state)

      case .delegate:
        return .none
      }
    }
  }

  // MARK: - Effects

  /// Starts an attempt against the active gateway, or settles in `.idle`
  /// when there is nothing to connect to.
  private func connect(_ state: inout State) -> Effect<Action> {
    guard state.isAppActive else {
      state.status = .suspended
      return .none
    }
    guard let gateway = state.activeGateway else {
      state.status = .idle
      return .none
    }
    state.status = .connecting
    let remote = remoteClient
    let credential = pairingStore.credential
    return .run { send in
      guard let key = credential(gateway) else {
        await send(.sessionEnded(.missingKey))
        return
      }
      let session = try await remote.connect(gateway, key)
      await send(.sessionOpened(session.info))
      for try await frame in session.events {
        await send(.eventReceived(frame))
      }
      await send(.sessionEnded(.streamEnded))
    } catch: { error, send in
      await send(.sessionEnded(RemoteFailure(error)))
    }
    .cancellable(id: CancelID.session, cancelInFlight: true)
  }

  /// Cancels the session and any pending retry, then closes the sockets.
  private func tearDown() -> Effect<Action> {
    let disconnect = remoteClient.disconnect
    return .merge(
      .cancel(id: CancelID.session),
      .cancel(id: CancelID.retry),
      .run { _ in await disconnect() }
    )
  }

  private func switchActive(to id: UUID?, state: inout State) -> Effect<Action> {
    state.activeID = id
    state.session = nil
    state.lastFailure = nil
    state.failedAttempts = 0
    state.status = .idle
    return .concatenate(
      .send(.delegate(.activeGatewayChanged)),
      tearDown(),
      connect(&state)
    )
  }

  static func message(for error: Error) -> String {
    switch error as? PairingPayload.DecodingError {
    case .wrongPrefix?, .malformed?:
      return "That isn't a Codans pairing code. Copy it again from Settings › Remote Access on your Mac."
    case .unsupportedVersion?:
      return "This pairing code comes from a newer Codans. Update this app."
    case .invalidKeyLength?, .emptyIdentity?:
      return "This pairing code is damaged. Generate a new one on your Mac."
    case .channelMismatch?:
      return "This pairing code is for a different Codans build."
    case nil:
      return error.localizedDescription
    }
  }
}
