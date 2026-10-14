import CodansIPC
import CodansRemote
import ComposableArchitecture
import Foundation
import SwiftUI
import os

/// The connection to the paired Mac as an explicit phase machine. One
/// instance per process (in `AppFeature`), shared by every scene.
///
/// ```
/// discovering ─▶ handshaking ─▶ syncing ─▶ live
///      ▲               │            │        │
///      └── reconnecting(attempt, nextAttemptAt) ◀─┘
///
/// offline (background)      failed(rejected | localNetworkDenied | incompatible | missingKey)
/// ```
///
/// - Live means data: `syncing` lasts until the first `events.subscribe`
///   snapshot, and only `live` reports the Mac as connected.
/// - Each connecting phase has its own timeout and a whole attempt has
///   `attemptDeadline`; failures back off with jitter up to 30 s.
/// - While in the foreground, any network path change reconnects at once.
/// - Going to the background keeps the connection for `backgroundGrace`
///   under a background task, so a quick app switch resumes instantly.
/// - `refusalLimit` TLS refusals without a successful handshake in between
///   end in `failed(rejected)`: the Mac no longer knows this device, and
///   retrying forever would never tell the user to pair again.
@Reducer
struct ConnectionFeature {
  @ObservableState
  struct State: Equatable {
    var gateways: [PairedGateway] = []
    var activeID: UUID?
    var phase: Phase = .idle
    /// Consecutive failed attempts since the last time the Mac was live;
    /// drives backoff and the attempt number shown.
    var failedAttempts = 0
    /// TLS handshake refusals since the last successful handshake.
    var refusals = 0
    var session: RemoteSessionInfo?
    /// Whether the active Mac streams live terminals, remembered across
    /// reconnects (and restored from the workspace cache on a cold start)
    /// so a dropped connection keeps the terminal on screen, dimmed,
    /// instead of falling back to the text view.
    var supportsLiveTerminal = false
    /// The permission of the last session with the active Mac, kept while
    /// reconnecting so the terminal keeps its (disabled) keyboard instead
    /// of flickering to read-only.
    var lastSessionPermission: IPC.RemotePermission?
    var lastFailure: RemoteFailure?
    /// The last frame of any kind from the Mac, heartbeats included.
    var lastContact: Date?
    /// When the shown hierarchy and agents last matched the Mac: the last
    /// frame while live, else the cached workspace's save time.
    var lastSyncedAt: Date?
    var pairingError: String?
    /// A `codans-pair:` link opened from outside the app (Camera, Safari,
    /// Messages). It is never paired silently: any web page can carry such
    /// a link, and pairing with a stranger's Mac would send it everything
    /// typed into its panes.
    var linkPairing: LinkPairing?
    /// False while every scene is in the background.
    var isAppActive = true
    var hasStarted = false

    var activeGateway: PairedGateway? {
      gateways.first { $0.deviceID == activeID }
    }

    var isLive: Bool { phase == .live }

    /// The permission to render with. Read-only until the Mac says
    /// otherwise, so input controls never flash for a read-only device.
    var permission: IPC.RemotePermission {
      session?.permission ?? .readOnly
    }

    /// The permission a live terminal renders with: the last session's
    /// while reconnecting. Input stays off until the connection is back.
    var terminalPermission: IPC.RemotePermission {
      session?.permission ?? lastSessionPermission ?? .readOnly
    }

    /// Everything the UI shows about the connection, in one value.
    var health: ConnectionHealth {
      var attempt: Int?
      var nextAttemptAt: Date?
      if case .reconnecting(let number, let at) = phase {
        attempt = number
        nextAttemptAt = at
      }
      let canRetryNow: Bool
      switch phase {
      case .reconnecting, .failed: canRetryNow = true
      case .idle: canRetryNow = activeGateway != nil
      case .discovering, .handshaking, .syncing, .live, .offline: canRetryNow = false
      }
      return ConnectionHealth(
        phase: phase,
        macName: activeGateway?.displayName,
        lastContact: lastContact,
        lastSyncedAt: lastSyncedAt,
        failure: phase == .live ? nil : lastFailure,
        attempt: attempt,
        nextAttemptAt: nextAttemptAt,
        canRetryNow: canRetryNow,
        // Kept while reconnecting to an old Mac, so the notice does not
        // flicker away with every dropped connection.
        needsMacUpdate: session.map { !$0.supportsLiveTerminal }
          ?? (lastSessionPermission != nil && !supportsLiveTerminal),
        isRelayed: session?.route == .relay,
        hasRelay: activeGateway?.relay != nil
      )
    }
  }

  enum Phase: Equatable {
    /// Nothing to connect to: no Mac is paired.
    case idle
    /// Browsing Bonjour for the paired gateway.
    case discovering
    /// TLS-PSK, peer proof and `system.hello` with a resolved endpoint.
    case handshaking
    /// Connected, waiting for the first snapshot.
    case syncing
    case live
    /// Waiting out a backoff delay before attempt `attempt + 1`.
    case reconnecting(attempt: Int, nextAttemptAt: Date)
    /// Every scene is in the background and the grace period is over; the
    /// sockets are closed until the app returns.
    case offline
    /// A failure retrying cannot fix; waits for the user.
    case failed(RemoteFailure)

    var isConnecting: Bool {
      switch self {
      case .discovering, .handshaking, .syncing: return true
      case .idle, .live, .reconnecting, .offline, .failed: return false
      }
    }
  }

  enum LinkPairing: Equatable {
    /// Waiting for the user to confirm pairing with this Mac.
    case confirm(PairingPayload)
    /// The link was a `codans-pair:` link that could not be decoded.
    case invalid(String)
  }

  enum Action: Equatable {
    /// First appearance of any scene. Idempotent across scenes.
    case task
    case scenePhaseChanged(ScenePhase)
    /// Retry / Reconnect Now: a fresh attempt with the counters reset.
    case connectTapped
    case gatewayResolved
    case sessionOpened(RemoteSessionInfo)
    case eventReceived(IPC.EventFrame)
    case sessionEnded(RemoteFailure)
    /// The phase's own timeout passed while still in it.
    case phaseTimedOut(Phase)
    case attemptDeadlinePassed
    case retryTimerFired
    case networkPathChanged(NetworkPathClient.Path)
    case backgroundGraceEnded
    /// The active Mac's cached workspace was shown.
    case cacheRestored(CachedWorkspace)
    case pairingCodeSubmitted(String)
    case pairingLinkOpened(URL)
    case linkPairingConfirmed
    case linkPairingDismissed
    case gatewaySelected(UUID)
    case forgetTapped(UUID)
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case eventReceived(IPC.EventFrame)
      /// The active Mac changed, was forgotten, or was loaded at launch:
      /// drop every model derived from the previous one and show the new
      /// one's cached workspace.
      case activeGatewayChanged(UUID?)
    }
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case session
    case retry
    case networkPath
    case phaseTimer
    case deadline
    case backgroundGrace
  }

  /// A whole attempt, from browsing to the first snapshot.
  nonisolated static let attemptDeadline: Duration = .seconds(20)
  /// Just past `GatewayDiscovery.defaultTimeout`, whose own "not found"
  /// answer carries the better message.
  nonisolated static let discoveryTimeout: Duration = .seconds(9)
  /// Room for two stale candidates at 5 s each before the live one.
  nonisolated static let handshakeTimeout: Duration = .seconds(12)
  /// The snapshot is the Mac's first frame; waiting longer than this means
  /// the events connection is not working.
  nonisolated static let syncTimeout: Duration = .seconds(8)
  nonisolated static let backgroundGrace: Duration = .seconds(25)
  nonisolated static let refusalLimit = 3

  /// The Mac sends a heartbeat on an idle events stream every 30 s. A
  /// stream silent for this long is treated as half-open (a Wi-Fi
  /// hand-off or a sleeping Mac that never sent FIN/RST), which TCP
  /// keepalive alone would take minutes to notice.
  nonisolated static let streamIdleTimeout: Duration = .seconds(60)
  /// How often the watchdog samples the stream; detection lands between
  /// `streamIdleTimeout` and `streamIdleTimeout + watchdogTick` of silence.
  nonisolated static let watchdogTick: Duration = .seconds(15)

  /// First retry waits 0.5 s; each further failure doubles it up to 30 s.
  /// `jitter` in 0...1 takes up to a quarter off, so a phone and its iPad
  /// do not retry in lockstep; the cap is never exceeded.
  static func backoff(afterFailures failures: Int, jitter: Double = 0) -> Duration {
    let exponent = min(max(failures - 1, 0), 10)
    let base = min(.milliseconds(500) * (1 << exponent), Duration.seconds(30))
    return base * (1 - 0.25 * min(max(jitter, 0), 1))
  }

  static func timeout(for phase: Phase) -> Duration? {
    switch phase {
    case .discovering: return discoveryTimeout
    case .handshaking: return handshakeTimeout
    case .syncing: return syncTimeout
    case .idle, .live, .reconnecting, .offline, .failed: return nil
    }
  }

  @Dependency(\.remoteClient) var remoteClient
  @Dependency(\.pairingStore) var pairingStore
  @Dependency(\.networkPath) var networkPath
  @Dependency(\.backgroundTask) var backgroundTask
  @Dependency(\.workspaceCache) var workspaceCache
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now
  @Dependency(\.withRandomNumberGenerator) var withRandomNumberGenerator

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
        let changes = networkPath.changes
        let observePath = Effect<Action>.run { send in
          for await path in changes() { await send(.networkPathChanged(path)) }
        }
        .cancellable(id: CancelID.networkPath, cancelInFlight: true)
        guard let id = state.activeID else { return .merge(observePath, connect(&state)) }
        // The delegate lets the app show this Mac's cached workspace while
        // the first attempt runs.
        return .merge(observePath, .send(.delegate(.activeGatewayChanged(id))), connect(&state))

      case .scenePhaseChanged(let scenePhase):
        switch scenePhase {
        case .active:
          return becameActive(&state)
        case .background:
          guard state.isAppActive else { return .none }
          state.isAppActive = false
          if state.phase.isConnecting || state.phase == .live {
            return .merge(.cancel(id: CancelID.retry), holdInBackground())
          }
          if case .reconnecting = state.phase { state.phase = .offline }
          return tearDown()
        default:
          // `.inactive` (app switcher, a sheet over the scene, Control
          // Center, a system alert) keeps the connection.
          return .none
        }

      case .connectTapped:
        state.failedAttempts = 0
        state.refusals = 0
        return connect(&state)

      case .gatewayResolved:
        guard state.phase == .discovering else { return .none }
        return enter(.handshaking, &state)

      case .sessionOpened(let info):
        guard state.phase == .handshaking else { return .none }
        state.session = info
        state.supportsLiveTerminal = info.supportsLiveTerminal
        state.lastSessionPermission = info.permission
        state.refusals = 0
        state.lastContact = now
        Self.logger.info(
          "handshake done (server \(info.serverVersion, privacy: .public), via \(info.route == .relay ? "relay" : "LAN", privacy: .public))"
        )
        let syncing = enter(.syncing, &state)
        // The Mac tells the phone where its relay is (or that there is none
        // any more) at every handshake; a LAN session is the authority,
        // since a relay session only exists because the phone knew it.
        guard let id = state.activeGateway?.id, info.route == .lan, info.reportsRelay,
          let index = state.gateways.firstIndex(where: { $0.id == id }), state.gateways[index].relay != info.relay
        else { return syncing }
        state.gateways[index].relay = info.relay
        let relay = info.relay
        return .merge(syncing, .run { [pairingStore] _ in pairingStore.setRelay(id, relay) })

      case .eventReceived(let frame):
        state.lastContact = now
        let forward = Effect<Action>.send(.delegate(.eventReceived(frame)))
        switch state.phase {
        case .syncing:
          guard case .snapshot = frame.payload else { return forward }
          state.phase = .live
          state.lastSyncedAt = now
          state.failedAttempts = 0
          state.lastFailure = nil
          Self.logger.info("live")
          return .merge(forward, .cancel(id: CancelID.phaseTimer), .cancel(id: CancelID.deadline))
        case .live:
          state.lastSyncedAt = now
          return forward
        default:
          return forward
        }

      case .sessionEnded(let failure):
        return fail(failure, &state)

      case .phaseTimedOut(let phase):
        guard state.phase == phase else { return .none }
        let failure: RemoteFailure =
          switch phase {
          case .discovering: .macNotFound(state.activeGateway?.displayName ?? "your Mac")
          case .syncing: .syncTimeout
          default: .handshakeTimeout
          }
        return fail(failure, &state)

      case .attemptDeadlinePassed:
        guard state.phase.isConnecting else { return .none }
        return fail(.deadlinePassed, &state)

      case .retryTimerFired:
        guard case .reconnecting = state.phase else { return .none }
        return connect(&state)

      case .networkPathChanged(let path):
        guard path.isSatisfied, state.isAppActive, state.activeGateway != nil else { return .none }
        switch state.phase {
        case .discovering, .handshaking, .syncing, .live, .reconnecting:
          // The old socket may be bound to an interface that is gone; a
          // fresh attempt is cheaper than waiting for it to time out.
          Self.logger.info("network path changed; reconnecting")
          state.failedAttempts = 0
          return connect(&state)
        case .idle, .offline, .failed:
          return .none
        }

      case .backgroundGraceEnded:
        guard !state.isAppActive else { return .none }
        if state.phase.isConnecting || state.phase == .live {
          state.phase = .offline
          state.session = nil
        }
        return tearDown()

      case .cacheRestored(let workspace):
        if state.lastSyncedAt == nil { state.lastSyncedAt = workspace.savedAt }
        if state.session == nil, let minor = workspace.protocolMinor {
          state.supportsLiveTerminal = RemoteSessionInfo.supportsLiveTerminal(protocolMinor: minor)
        }
        return .none

      case .pairingCodeSubmitted(let code):
        let payload: PairingPayload
        do {
          payload = try PairingPayload.decode(code)
        } catch {
          state.pairingError = Self.message(for: error)
          return .none
        }
        return pair(payload, state: &state)

      case .pairingLinkOpened(let url):
        guard url.scheme?.lowercased() == PairingPayload.urlScheme else { return .none }
        do {
          let payload = try PairingPayload.decode(url.absoluteString)
          // The Mac issues a new device ID per code, so a known ID is the
          // same code opened again (a second tap, or iOS delivering the link
          // twice); asking again would only cover the workspace.
          guard !state.gateways.contains(where: { $0.deviceID == payload.deviceID }) else { return .none }
          state.linkPairing = .confirm(payload)
        } catch {
          state.linkPairing = .invalid(Self.message(for: error))
        }
        return .none

      case .linkPairingConfirmed:
        guard case .confirm(let payload) = state.linkPairing else { return .none }
        state.linkPairing = nil
        return pair(payload, state: &state)

      case .linkPairingDismissed:
        state.linkPairing = nil
        return .none

      case .gatewaySelected(let id):
        guard id != state.activeID, state.gateways.contains(where: { $0.deviceID == id }) else { return .none }
        pairingStore.setActive(id)
        return switchActive(to: id, state: &state)

      case .forgetTapped(let id):
        pairingStore.remove(id)
        state.gateways.removeAll { $0.deviceID == id }
        let removeCache = workspaceCache.remove
        let forgetCache = Effect<Action>.run { _ in await removeCache(id) }
        guard id == state.activeID else { return forgetCache }
        let next = state.gateways.first?.deviceID
        pairingStore.setActive(next)
        return .merge(forgetCache, switchActive(to: next, state: &state))

      case .delegate:
        return .none
      }
    }
  }

  // MARK: - Transitions

  /// Starts an attempt against the active gateway: discovery, handshake,
  /// then the events stream until it ends. Settles in `.idle` when there
  /// is nothing to connect to and in `.offline` in the background.
  private func connect(_ state: inout State) -> Effect<Action> {
    guard let gateway = state.activeGateway else {
      state.phase = .idle
      return .none
    }
    guard state.isAppActive else {
      state.phase = .offline
      return .none
    }
    state.session = nil
    let remote = remoteClient
    let credential = pairingStore.credential
    let attempt = Effect<Action>.run { [clock] send in
      guard let key = credential(gateway) else {
        await send(.sessionEnded(.missingKey))
        return
      }
      let session: RemoteSession
      do {
        let endpoints = try await remote.discover(gateway)
        await send(.gatewayResolved)
        session = try await remote.connect(gateway, endpoints, key)
      } catch let failure as RemoteFailure where Self.fallsBackToRelay(failure, gateway: gateway) {
        // Not on the Mac's network (or no Local Network access): go
        // through the relay instead. The TLS-PSK session is the same.
        await send(.gatewayResolved)
        session = try await remote.connectRelay(gateway, key)
      }
      await send(.sessionOpened(session.info))
      try await Self.relay(session.events, clock: clock, send: send)
      await send(.sessionEnded(.streamEnded))
    } catch: { error, send in
      await send(.sessionEnded(RemoteFailure(error)))
    }
    .cancellable(id: CancelID.session, cancelInFlight: true)
    let deadline = Effect<Action>.run { [clock] send in
      try await clock.sleep(for: Self.attemptDeadline)
      await send(.attemptDeadlinePassed)
    }
    .cancellable(id: CancelID.deadline, cancelInFlight: true)
    return .merge(.cancel(id: CancelID.retry), enter(.discovering, &state), deadline, attempt)
  }

  /// Bonjour found nothing (or may not look): the relay can still reach
  /// the Mac when the pairing knows it.
  nonisolated static func fallsBackToRelay(_ failure: RemoteFailure, gateway: PairedGateway) -> Bool {
    gateway.relay != nil && (failure.kind == .macNotFound || failure.kind == .localNetworkDenied)
  }

  /// Moves to a connecting phase and arms its timeout.
  private func enter(_ phase: Phase, _ state: inout State) -> Effect<Action> {
    state.phase = phase
    guard let timeout = Self.timeout(for: phase) else { return .cancel(id: CancelID.phaseTimer) }
    return .run { [clock] send in
      try await clock.sleep(for: timeout)
      await send(.phaseTimedOut(phase))
    }
    .cancellable(id: CancelID.phaseTimer, cancelInFlight: true)
  }

  /// Ends the current attempt or session, then backs off, or settles when
  /// retrying cannot help or the app is in the background.
  private func fail(_ reported: RemoteFailure, _ state: inout State) -> Effect<Action> {
    var failure = reported
    if failure.kind == .refused {
      state.refusals += 1
      if state.refusals >= Self.refusalLimit { failure = .rejected }
    }
    state.session = nil
    state.lastFailure = failure
    Self.logger.notice("attempt failed: \(failure.message, privacy: .public)")
    let disconnect = remoteClient.disconnect
    let close = Effect<Action>.merge(
      .cancel(id: CancelID.session),
      .cancel(id: CancelID.phaseTimer),
      .cancel(id: CancelID.deadline),
      .run { _ in await disconnect() }
    )
    guard state.activeGateway != nil else {
      state.phase = .idle
      return close
    }
    guard failure.isRetryable else {
      state.phase = .failed(failure)
      return close
    }
    guard state.isAppActive else {
      state.phase = .offline
      return .merge(close, .cancel(id: CancelID.backgroundGrace))
    }
    state.failedAttempts += 1
    // One draw mapped to [0, 1): `Double.random(in:using:)` rejection-samples,
    // which never ends with a constant test generator.
    let jitter = withRandomNumberGenerator { Double($0.next() >> 11) * 0x1p-53 }
    let delay = Self.backoff(afterFailures: state.failedAttempts, jitter: jitter)
    state.phase = .reconnecting(
      attempt: state.failedAttempts, nextAttemptAt: now.addingTimeInterval(Self.seconds(delay)))
    return .merge(
      close,
      .run { [clock] send in
        try await clock.sleep(for: delay)
        await send(.retryTimerFired)
      }
      .cancellable(id: CancelID.retry, cancelInFlight: true)
    )
  }

  /// A scene came to the foreground. Within the background grace the
  /// session is still up and nothing happens; otherwise a fresh attempt
  /// starts, except after a failure only the user can fix.
  private func becameActive(_ state: inout State) -> Effect<Action> {
    guard !state.isAppActive else {
      // The Local Network prompt and a trip to Settings both end with the
      // scene active again; the user may have just allowed access.
      if case .failed(let failure) = state.phase, failure.kind == .localNetworkDenied {
        return connect(&state)
      }
      return .none
    }
    state.isAppActive = true
    let endGrace = Effect<Action>.cancel(id: CancelID.backgroundGrace)
    if state.phase.isConnecting || state.phase == .live { return endGrace }
    if case .failed(let failure) = state.phase, failure.kind == .rejected || failure.kind == .missingKey {
      return endGrace
    }
    state.failedAttempts = 0
    return .merge(endGrace, connect(&state))
  }

  /// Keeps the connection for `backgroundGrace` under a UIKit background
  /// task, then reports `backgroundGraceEnded`, earlier if iOS takes the
  /// time back. Cancelled when a scene returns.
  private func holdInBackground() -> Effect<Action> {
    let background = backgroundTask
    return .run { [clock] send in
      let (expired, expire) = AsyncStream<Void>.makeStream()
      let token = await background.begin("Codans connection") { expire.yield() }
      await withTaskGroup(of: Void.self) { group in
        group.addTask { try? await clock.sleep(for: Self.backgroundGrace) }
        group.addTask {
          for await _ in expired { return }
        }
        await group.next()
        group.cancelAll()
      }
      await background.end(token)
      await send(.backgroundGraceEnded)
    }
    .cancellable(id: CancelID.backgroundGrace, cancelInFlight: true)
  }

  /// Forwards event frames until the stream ends, racing it against an
  /// idle watchdog that throws `RemoteFailure.stalled` once nothing
  /// (heartbeats included) has arrived for `streamIdleTimeout`.
  nonisolated private static func relay(
    _ events: AsyncThrowingStream<IPC.EventFrame, Error>,
    clock: any Clock<Duration>,
    send: Send<Action>
  ) async throws {
    let received = LockIsolated(0)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for try await frame in events {
          received.withValue { $0 += 1 }
          await send(.eventReceived(frame))
        }
      }
      group.addTask {
        var lastSeen = received.value
        var quiet: Duration = .zero
        while true {
          try await clock.sleep(for: watchdogTick)
          let seen = received.value
          if seen == lastSeen {
            quiet += watchdogTick
            if quiet >= streamIdleTimeout { throw RemoteFailure.stalled }
          } else {
            lastSeen = seen
            quiet = .zero
          }
        }
      }
      try await group.next()
      group.cancelAll()
    }
  }

  /// Cancels the session, its timers and any pending retry or grace, then
  /// closes the sockets.
  private func tearDown() -> Effect<Action> {
    let disconnect = remoteClient.disconnect
    return .merge(
      .cancel(id: CancelID.session),
      .cancel(id: CancelID.phaseTimer),
      .cancel(id: CancelID.deadline),
      .cancel(id: CancelID.retry),
      .cancel(id: CancelID.backgroundGrace),
      .run { _ in await disconnect() }
    )
  }

  private static func seconds(_ duration: Duration) -> TimeInterval {
    let (seconds, attoseconds) = duration.components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }

  /// Stores a decoded pairing and makes its Mac the active one.
  private func pair(_ payload: PairingPayload, state: inout State) -> Effect<Action> {
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
  }

  private func switchActive(to id: UUID?, state: inout State) -> Effect<Action> {
    state.activeID = id
    state.session = nil
    state.supportsLiveTerminal = false
    state.lastSessionPermission = nil
    state.lastFailure = nil
    state.failedAttempts = 0
    state.refusals = 0
    state.lastContact = nil
    state.lastSyncedAt = nil
    state.phase = .idle
    return .concatenate(
      .send(.delegate(.activeGatewayChanged(id))),
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
