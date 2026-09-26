import CodansIPC
import CodansRemote
import ComposableArchitecture
import Foundation
import Network
import Testing

@testable import CodansMobile

/// The connection phase machine: discovering → handshaking → syncing →
/// live, per-phase timeouts and the attempt deadline, backoff, the failure
/// taxonomy (refusals becoming `rejected`, Local Network denial), network
/// path changes, the background grace, and pairing.
@MainActor
struct ConnectionFeatureTests {
  // MARK: - Backoff

  @Test
  func backoffStartsAtHalfASecondDoublesAndCapsAtThirtySeconds() {
    #expect(ConnectionFeature.backoff(afterFailures: 1) == .milliseconds(500))
    #expect(ConnectionFeature.backoff(afterFailures: 2) == .seconds(1))
    #expect(ConnectionFeature.backoff(afterFailures: 3) == .seconds(2))
    #expect(ConnectionFeature.backoff(afterFailures: 7) == .seconds(30))
    #expect(ConnectionFeature.backoff(afterFailures: 50) == .seconds(30))
  }

  @Test
  func jitterOnlyShortensTheDelayAndNeverPassesTheCap() {
    #expect(ConnectionFeature.backoff(afterFailures: 2, jitter: 1) == .milliseconds(750))
    #expect(ConnectionFeature.backoff(afterFailures: 50, jitter: 0.5) < .seconds(30))
    #expect(ConnectionFeature.backoff(afterFailures: 50, jitter: 7) >= .milliseconds(22_500))
  }

  // MARK: - Phases

  @Test
  func startWithoutPairingStaysIdle() async {
    let store = TestStore(initialState: ConnectionFeature.State()) {
      ConnectionFeature()
    } withDependencies: {
      $0.pairingStore = .inMemory()
      $0.networkPath.changes = { .finished }
    }

    await store.send(.task) {
      $0.hasStarted = true
    }
    // A second scene appearing does not restart anything.
    await store.send(.task)
    #expect(store.state.health.title == "Not paired")
    #expect(store.state.health.recovery == nil)
  }

  @Test
  func attemptRunsThroughEveryPhaseAndIsLiveOnlyAfterTheSnapshot() async {
    let clock = TestClock()
    let now = LockIsolated(Fixtures.pairedAt)
    let (events, feed) = AsyncThrowingStream<IPC.EventFrame, Error>.makeStream()
    let store = Self.store(clock: clock, now: now) {
      $0.remoteClient.discover = { _ in [] }
      $0.remoteClient.connect = { gateway, _, credential in
        #expect(gateway == Fixtures.gateway)
        #expect(credential == Fixtures.payload.credential)
        return RemoteSession(info: Fixtures.liveInfo, events: events)
      }
    }

    await store.send(.connectTapped) {
      $0.phase = .discovering
    }
    await store.receive(\.gatewayResolved) {
      $0.phase = .handshaking
    }
    await store.receive(\.sessionOpened) {
      $0.phase = .syncing
      $0.session = Fixtures.liveInfo
      $0.supportsLiveTerminal = true
      $0.lastSessionPermission = .interactive
      $0.lastContact = Fixtures.pairedAt
    }
    #expect(store.state.health.title == "Syncing with Studio…")

    // A heartbeat proves the Mac is there, but is not data: still syncing.
    now.setValue(Fixtures.pairedAt.addingTimeInterval(1))
    feed.yield(IPC.EventFrame(seq: 0, payload: .heartbeat))
    await store.receive(\.eventReceived) {
      $0.lastContact = Fixtures.pairedAt.addingTimeInterval(1)
    }
    await store.receive(\.delegate.eventReceived)
    #expect(!store.state.isLive)

    now.setValue(Fixtures.pairedAt.addingTimeInterval(2))
    feed.yield(Fixtures.snapshot(agents: []))
    await store.receive(\.eventReceived) {
      $0.phase = .live
      $0.lastContact = Fixtures.pairedAt.addingTimeInterval(2)
      $0.lastSyncedAt = Fixtures.pairedAt.addingTimeInterval(2)
    }
    await store.receive(\.delegate.eventReceived)
    #expect(store.state.health.title == "Connected to Studio")
    #expect(store.state.health.failure == nil)
    #expect(!store.state.health.isStale)

    // Past every phase timeout and the deadline: live has none.
    await clock.advance(by: .seconds(14))
    feed.yield(IPC.EventFrame(seq: 1, payload: .heartbeat))
    await store.receive(\.eventReceived)
    await store.receive(\.delegate.eventReceived)
    await clock.advance(by: .seconds(14))
    #expect(store.state.phase == .live)

    feed.finish()
    await store.receive(\.sessionEnded) {
      $0.phase = .reconnecting(attempt: 1, nextAttemptAt: Fixtures.pairedAt.addingTimeInterval(2.5))
      $0.failedAttempts = 1
      $0.session = nil
      $0.lastFailure = .streamEnded
    }
    #expect(store.state.health.isStale)
    #expect(store.state.health.canRetryNow)
    #expect(store.state.health.attempt == 1)
    await Self.endSession(store)
  }

  @Test
  func discoveryThatFindsNothingReportsTheMacNotFoundAndBacksOff() async {
    let clock = TestClock()
    let store = Self.store(clock: clock) {
      $0.remoteClient.discover = { _ in try await Task<[NWEndpoint], Never>.never() }
    }

    await store.send(.connectTapped) {
      $0.phase = .discovering
    }
    await clock.advance(by: ConnectionFeature.discoveryTimeout)
    await store.receive(\.phaseTimedOut) {
      $0.phase = .reconnecting(attempt: 1, nextAttemptAt: Fixtures.pairedAt.addingTimeInterval(0.5))
      $0.failedAttempts = 1
      $0.lastFailure = .macNotFound("Studio")
    }
    #expect(store.state.health.checklist.count == 3)
    #expect(store.state.health.title == "Can't find Studio")

    await clock.advance(by: .milliseconds(500))
    await store.receive(\.retryTimerFired) {
      $0.phase = .discovering
    }
    // Looking again keeps the cause on screen instead of flickering.
    #expect(store.state.health.title == "Can't find Studio")
    #expect(store.state.health.explanation == "Couldn't find Studio on this network. Trying again…")
    await store.send(.scenePhaseChanged(.background)) {
      $0.isAppActive = false
    }
    await Self.endSession(store)
  }

  /// Each phase stays within its own timeout, but together they pass the
  /// attempt deadline.
  @Test
  func attemptDeadlineEndsASlowAttempt() async {
    let clock = TestClock()
    let (events, feed) = AsyncThrowingStream<IPC.EventFrame, Error>.makeStream()
    let store = Self.store(clock: clock) {
      $0.remoteClient.discover = { _ in
        try await clock.sleep(for: .seconds(8))
        return []
      }
      $0.remoteClient.connect = { _, _, _ in
        try await clock.sleep(for: .seconds(10))
        return RemoteSession(info: Fixtures.liveInfo, events: events)
      }
    }

    await store.send(.connectTapped) {
      $0.phase = .discovering
    }
    await clock.advance(by: .seconds(8))
    await store.receive(\.gatewayResolved) {
      $0.phase = .handshaking
    }
    await clock.advance(by: .seconds(10))
    await store.receive(\.sessionOpened) {
      $0.phase = .syncing
      $0.session = Fixtures.liveInfo
      $0.supportsLiveTerminal = true
      $0.lastSessionPermission = .interactive
      $0.lastContact = Fixtures.pairedAt
    }
    // 20 s after the start; the sync timeout alone would wait until 26 s.
    await clock.advance(by: .seconds(2))
    await store.receive(\.attemptDeadlinePassed) {
      $0.phase = .reconnecting(attempt: 1, nextAttemptAt: Fixtures.pairedAt.addingTimeInterval(0.5))
      $0.failedAttempts = 1
      $0.session = nil
      $0.lastFailure = .deadlinePassed
    }
    await Self.endSession(store)
  }

  // MARK: - Failure taxonomy

  @Test
  func threeRefusalsEndInRejectedAndStopRetrying() async {
    let clock = TestClock()
    let connects = LockIsolated(0)
    let store = Self.store(clock: clock) {
      $0.remoteClient.discover = { _ in [] }
      $0.remoteClient.connect = { _, _, _ in
        connects.withValue { $0 += 1 }
        throw RemoteFailure.refused
      }
    }

    await store.send(.connectTapped) {
      $0.phase = .discovering
    }
    await store.receive(\.gatewayResolved) {
      $0.phase = .handshaking
    }
    await store.receive(\.sessionEnded) {
      $0.phase = .reconnecting(attempt: 1, nextAttemptAt: Fixtures.pairedAt.addingTimeInterval(0.5))
      $0.failedAttempts = 1
      $0.refusals = 1
      $0.lastFailure = .refused
    }
    await clock.advance(by: .milliseconds(500))
    await store.receive(\.retryTimerFired) {
      $0.phase = .discovering
    }
    await store.receive(\.gatewayResolved) {
      $0.phase = .handshaking
    }
    await store.receive(\.sessionEnded) {
      $0.phase = .reconnecting(attempt: 2, nextAttemptAt: Fixtures.pairedAt.addingTimeInterval(1))
      $0.failedAttempts = 2
      $0.refusals = 2
    }
    await clock.advance(by: .seconds(1))
    await store.receive(\.retryTimerFired) {
      $0.phase = .discovering
    }
    await store.receive(\.gatewayResolved) {
      $0.phase = .handshaking
    }
    await store.receive(\.sessionEnded) {
      $0.phase = .failed(.rejected)
      $0.refusals = 3
      $0.lastFailure = .rejected
    }
    #expect(store.state.health.recovery == .pairAgain)
    #expect(store.state.health.title == "This device was removed")

    // Neither time nor a trip through the background retries it. A phase
    // timer that started just before the refusal may still fire; the
    // reducer ignores it once the phase has moved on.
    await clock.run()
    await Self.dropStaleTimers(store)
    await store.send(.scenePhaseChanged(.background)) {
      $0.isAppActive = false
    }
    await store.send(.scenePhaseChanged(.active)) {
      $0.isAppActive = true
    }
    #expect(connects.value == 3)
  }

  @Test
  func aSuccessfulHandshakeClearsTheRefusalCount() async {
    let (events, feed) = AsyncThrowingStream<IPC.EventFrame, Error>.makeStream()
    var initial = Self.pairedState()
    initial.phase = .reconnecting(attempt: 2, nextAttemptAt: Fixtures.pairedAt)
    initial.failedAttempts = 2
    initial.refusals = 2
    initial.lastFailure = .refused
    let store = Self.store(initial) {
      $0.remoteClient.discover = { _ in [] }
      $0.remoteClient.connect = { _, _, _ in RemoteSession(info: Fixtures.liveInfo, events: events) }
    }

    await store.send(.retryTimerFired) {
      $0.phase = .discovering
    }
    await store.receive(\.gatewayResolved) { $0.phase = .handshaking }
    await store.receive(\.sessionOpened) {
      $0.phase = .syncing
      $0.session = Fixtures.liveInfo
      $0.supportsLiveTerminal = true
      $0.lastSessionPermission = .interactive
      $0.lastContact = Fixtures.pairedAt
      $0.refusals = 0
    }
    // Ending before the snapshot is still a failed attempt.
    feed.finish()
    await store.receive(\.sessionEnded) {
      $0.phase = .reconnecting(attempt: 3, nextAttemptAt: Fixtures.pairedAt.addingTimeInterval(2))
      $0.failedAttempts = 3
      $0.session = nil
      $0.lastFailure = .streamEnded
    }
    await Self.endSession(store)
  }

  @Test
  func localNetworkDenialWaitsForSettingsThenRetriesOnReturn() async {
    let denied = RemoteFailure(.localNetworkDenied, "Local Network access is off.")
    let discovers = LockIsolated(0)
    let store = Self.store {
      $0.remoteClient.discover = { _ in
        discovers.withValue { $0 += 1 }
        throw denied
      }
    }

    await store.send(.connectTapped) {
      $0.phase = .discovering
    }
    await store.receive(\.sessionEnded) {
      $0.phase = .failed(denied)
      $0.lastFailure = denied
    }
    #expect(store.state.health.recovery == .openSettings)
    #expect(discovers.value == 1)

    // Coming back from Settings (the scene turns active again) retries.
    await store.send(.scenePhaseChanged(.active)) {
      $0.phase = .discovering
    }
    await store.receive(\.sessionEnded) {
      $0.phase = .failed(denied)
    }
    #expect(discovers.value == 2)
  }

  @Test
  func incompatibleMacIsNotRetried() async {
    let clock = TestClock()
    let failure = RemoteFailure(.incompatible, "update")
    let store = Self.store(clock: clock) {
      $0.remoteClient.discover = { _ in [] }
      $0.remoteClient.connect = { _, _, _ in throw failure }
    }

    await store.send(.connectTapped) {
      $0.phase = .discovering
    }
    await store.receive(\.gatewayResolved) { $0.phase = .handshaking }
    await store.receive(\.sessionEnded) {
      $0.phase = .failed(failure)
      $0.lastFailure = failure
    }
    await clock.run()
    await Self.dropStaleTimers(store)
    #expect(store.state.phase == .failed(failure))
    #expect(store.state.health.title == "Update needed")
  }

  /// A minor-1 Mac is not a failure: browsing works, only the live
  /// terminal asks for an update, and keeps asking while reconnecting.
  @Test
  func olderMacConnectsButAsksForAnUpdateForTheTerminal() async {
    let (events, feed) = AsyncThrowingStream<IPC.EventFrame, Error>.makeStream()
    let store = Self.store {
      $0.remoteClient.discover = { _ in [] }
      $0.remoteClient.connect = { _, _, _ in RemoteSession(info: Fixtures.info, events: events) }
    }

    await store.send(.connectTapped) { $0.phase = .discovering }
    await store.receive(\.gatewayResolved) { $0.phase = .handshaking }
    await store.receive(\.sessionOpened) {
      $0.phase = .syncing
      $0.session = Fixtures.info
      $0.lastSessionPermission = .interactive
      $0.lastContact = Fixtures.pairedAt
    }
    feed.yield(Fixtures.snapshot(agents: []))
    await store.receive(\.eventReceived) {
      $0.phase = .live
      $0.lastSyncedAt = Fixtures.pairedAt
    }
    await store.receive(\.delegate.eventReceived)
    #expect(store.state.health.needsMacUpdate)

    feed.finish()
    await store.receive(\.sessionEnded) {
      $0.phase = .reconnecting(attempt: 1, nextAttemptAt: Fixtures.pairedAt.addingTimeInterval(0.5))
      $0.failedAttempts = 1
      $0.session = nil
      $0.lastFailure = .streamEnded
    }
    #expect(store.state.health.needsMacUpdate)
    await Self.endSession(store)
  }

  @Test
  func missingKeyAsksForRepairingWithoutConnecting() async {
    let store = Self.store {
      $0.pairingStore.credential = { _ in nil }
    }

    await store.send(.connectTapped) {
      $0.phase = .discovering
    }
    await store.receive(\.sessionEnded) {
      $0.phase = .failed(.missingKey)
      $0.lastFailure = .missingKey
    }
    #expect(store.state.health.recovery == .pairAgain)
  }

  // MARK: - Network path and liveness

  @Test
  func pathChangeWhileLiveReconnectsAtOnce() async {
    let clock = TestClock()
    let (paths, pathFeed) = AsyncStream<NetworkPathClient.Path>.makeStream()
    let streams = LockIsolated<[AsyncThrowingStream<IPC.EventFrame, Error>.Continuation]>([])
    let connects = LockIsolated(0)
    var initial = Self.pairedState()
    initial.hasStarted = false
    let store = Self.store(initial, clock: clock) {
      $0.pairingStore = .inMemory(.init(gateways: [Fixtures.gateway], activeID: Fixtures.deviceID))
      $0.pairingStore.credential = { _ in Fixtures.payload.credential }
      $0.networkPath.changes = { paths }
      $0.remoteClient.discover = { _ in [] }
      $0.remoteClient.connect = { _, _, _ in
        connects.withValue { $0 += 1 }
        let (events, feed) = AsyncThrowingStream<IPC.EventFrame, Error>.makeStream()
        streams.withValue { $0.append(feed) }
        return RemoteSession(info: Fixtures.liveInfo, events: events)
      }
    }

    await store.send(.task) {
      $0.hasStarted = true
      $0.phase = .discovering
    }
    await store.receive(\.delegate.activeGatewayChanged)
    await store.receive(\.gatewayResolved) { $0.phase = .handshaking }
    await store.receive(\.sessionOpened) {
      $0.phase = .syncing
      $0.session = Fixtures.liveInfo
      $0.supportsLiveTerminal = true
      $0.lastSessionPermission = .interactive
      $0.lastContact = Fixtures.pairedAt
    }
    streams.value[0].yield(Fixtures.snapshot(agents: []))
    await store.receive(\.eventReceived) {
      $0.phase = .live
      $0.lastSyncedAt = Fixtures.pairedAt
    }
    await store.receive(\.delegate.eventReceived)

    // Wi-Fi → cellular: still satisfied, but the old socket is bound to an
    // interface that is gone.
    pathFeed.yield(.init(isSatisfied: true, interfaces: ["cellular:pdp_ip0"]))
    await store.receive(\.networkPathChanged) {
      $0.phase = .discovering
      $0.session = nil
    }
    await store.receive(\.gatewayResolved) { $0.phase = .handshaking }
    await store.receive(\.sessionOpened) {
      $0.phase = .syncing
      $0.session = Fixtures.liveInfo
    }
    streams.value[1].yield(Fixtures.snapshot(agents: []))
    await store.receive(\.eventReceived) { $0.phase = .live }
    await store.receive(\.delegate.eventReceived)
    #expect(connects.value == 2)

    // An unusable path is not worth an attempt.
    pathFeed.yield(.init(isSatisfied: false, interfaces: []))
    await store.receive(\.networkPathChanged)
    #expect(connects.value == 2)

    await Self.endSession(store)
  }

  @Test
  func pathChangeCutsABackoffShort() async {
    let clock = TestClock()
    let (paths, pathFeed) = AsyncStream<NetworkPathClient.Path>.makeStream()
    let attempts = LockIsolated(0)
    var initial = Self.pairedState()
    initial.hasStarted = false
    let store = Self.store(initial, clock: clock) {
      $0.pairingStore = .inMemory(.init(gateways: [Fixtures.gateway], activeID: Fixtures.deviceID))
      $0.pairingStore.credential = { _ in Fixtures.payload.credential }
      $0.networkPath.changes = { paths }
      $0.remoteClient.discover = { _ in
        let attempt = attempts.withValue { value -> Int in
          value += 1
          return value
        }
        guard attempt > 1 else { throw RemoteFailure.macNotFound("Studio") }
        return try await Task<[NWEndpoint], Never>.never()
      }
    }
    await store.send(.task) {
      $0.hasStarted = true
      $0.phase = .discovering
    }
    await store.receive(\.delegate.activeGatewayChanged)
    await store.receive(\.sessionEnded) {
      $0.phase = .reconnecting(attempt: 1, nextAttemptAt: Fixtures.pairedAt.addingTimeInterval(0.5))
      $0.failedAttempts = 1
      $0.lastFailure = .macNotFound("Studio")
    }

    pathFeed.yield(.init(isSatisfied: true, interfaces: ["wifi:en0"]))
    await store.receive(\.networkPathChanged) {
      $0.phase = .discovering
      $0.failedAttempts = 0
    }
    // The cancelled backoff timer never fires.
    await clock.advance(by: .seconds(1))
    #expect(attempts.value == 2)
    await Self.endSession(store)
  }

  /// A half-open connection never ends the stream; only the missing
  /// heartbeats reveal it.
  @Test
  func silentStreamIsTreatedAsHalfOpenAndReconnected() async {
    let clock = TestClock()
    let (events, feed) = AsyncThrowingStream<IPC.EventFrame, Error>.makeStream()
    let disconnects = LockIsolated(0)
    let store = Self.store(clock: clock) {
      $0.remoteClient.disconnect = { disconnects.withValue { $0 += 1 } }
      $0.remoteClient.discover = { _ in [] }
      $0.remoteClient.connect = { _, _, _ in RemoteSession(info: Fixtures.liveInfo, events: events) }
    }

    await store.send(.connectTapped) { $0.phase = .discovering }
    await store.receive(\.gatewayResolved) { $0.phase = .handshaking }
    await store.receive(\.sessionOpened) {
      $0.phase = .syncing
      $0.session = Fixtures.liveInfo
      $0.supportsLiveTerminal = true
      $0.lastSessionPermission = .interactive
      $0.lastContact = Fixtures.pairedAt
    }
    feed.yield(Fixtures.snapshot(agents: []))
    await store.receive(\.eventReceived) {
      $0.phase = .live
      $0.lastSyncedAt = Fixtures.pairedAt
    }
    await store.receive(\.delegate.eventReceived)

    // Heartbeats keep the watchdog quiet well past the idle timeout.
    for seq in 0..<4 {
      await clock.advance(by: .seconds(30))
      feed.yield(IPC.EventFrame(seq: seq, payload: .heartbeat))
      await store.receive(\.eventReceived)
      await store.receive(\.delegate.eventReceived)
    }
    #expect(store.state.phase == .live)

    await clock.advance(by: ConnectionFeature.streamIdleTimeout + ConnectionFeature.watchdogTick)
    await store.receive(\.sessionEnded) {
      $0.phase = .reconnecting(attempt: 1, nextAttemptAt: Fixtures.pairedAt.addingTimeInterval(0.5))
      $0.failedAttempts = 1
      $0.session = nil
      $0.lastFailure = .stalled
    }
    #expect(disconnects.value == 1)
    await Self.endSession(store)
  }

  // MARK: - Background

  @Test
  func quickAppSwitchKeepsTheSessionAndALongOneGoesOffline() async {
    let clock = TestClock()
    let streams = LockIsolated<[AsyncThrowingStream<IPC.EventFrame, Error>.Continuation]>([])
    let tasks = LockIsolated<[String]>([])
    let store = Self.store(clock: clock) {
      $0.backgroundTask = BackgroundTaskClient(
        begin: { name, _ in
          tasks.withValue { $0.append("begin \(name)") }
          return 7
        },
        end: { token in tasks.withValue { $0.append("end \(token)") } }
      )
      $0.remoteClient.discover = { _ in [] }
      $0.remoteClient.connect = { _, _, _ in
        let (events, feed) = AsyncThrowingStream<IPC.EventFrame, Error>.makeStream()
        streams.withValue { $0.append(feed) }
        return RemoteSession(info: Fixtures.liveInfo, events: events)
      }
    }

    await store.send(.connectTapped) { $0.phase = .discovering }
    await store.receive(\.gatewayResolved) { $0.phase = .handshaking }
    await store.receive(\.sessionOpened) {
      $0.phase = .syncing
      $0.session = Fixtures.liveInfo
      $0.supportsLiveTerminal = true
      $0.lastSessionPermission = .interactive
      $0.lastContact = Fixtures.pairedAt
    }
    streams.value[0].yield(Fixtures.snapshot(agents: []))
    await store.receive(\.eventReceived) {
      $0.phase = .live
      $0.lastSyncedAt = Fixtures.pairedAt
    }
    await store.receive(\.delegate.eventReceived)

    // A quick switch: back within the grace, still live, no new attempt.
    await store.send(.scenePhaseChanged(.background)) { $0.isAppActive = false }
    await clock.advance(by: .seconds(10))
    await store.send(.scenePhaseChanged(.active)) { $0.isAppActive = true }
    #expect(store.state.phase == .live)
    #expect(streams.value.count == 1)

    // A long one: the grace ends and the session closes.
    await store.send(.scenePhaseChanged(.background)) { $0.isAppActive = false }
    await clock.advance(by: ConnectionFeature.backgroundGrace)
    await store.receive(\.backgroundGraceEnded) {
      $0.phase = .offline
      $0.session = nil
    }
    #expect(tasks.value == ["begin Codans connection", "end 7", "begin Codans connection", "end 7"])

    await store.send(.scenePhaseChanged(.active)) {
      $0.isAppActive = true
      $0.phase = .discovering
    }
    await store.receive(\.gatewayResolved) { $0.phase = .handshaking }
    await store.receive(\.sessionOpened) {
      $0.phase = .syncing
      $0.session = Fixtures.liveInfo
    }
    #expect(streams.value.count == 2)
    await Self.endSession(store)
  }

  @Test
  func backoffInTheBackgroundWaitsForTheForeground() async {
    let clock = TestClock()
    var initial = Self.pairedState()
    initial.phase = .reconnecting(attempt: 2, nextAttemptAt: Fixtures.pairedAt)
    let store = Self.store(initial, clock: clock) { _ in }

    await store.send(.scenePhaseChanged(.background)) {
      $0.isAppActive = false
      $0.phase = .offline
    }
    await clock.advance(by: .seconds(60))
    #expect(store.state.health.title == "Offline")
  }

  // MARK: - Cache

  @Test
  func cachedWorkspaceMarksDataStaleAndPicksTheTerminal() async {
    let store = Self.store { _ in }
    let workspace = CachedWorkspace(
      savedAt: Fixtures.pairedAt.addingTimeInterval(-300), protocolMinor: 2, hierarchy: Fixtures.hierarchy,
      agents: [])

    await store.send(.cacheRestored(workspace)) {
      $0.lastSyncedAt = Fixtures.pairedAt.addingTimeInterval(-300)
      $0.supportsLiveTerminal = true
    }
    #expect(store.state.health.isStale)
  }

  // MARK: - Pairing

  @Test
  func invalidPairingCodeReportsAnErrorAndStoresNothing() async {
    let store = TestStore(initialState: ConnectionFeature.State()) {
      ConnectionFeature()
    }

    await store.send(.pairingCodeSubmitted("hello")) {
      $0.pairingError = ConnectionFeature.message(for: PairingPayload.DecodingError.wrongPrefix)
    }
  }

  @Test
  func pairingLinkPairsOnlyAfterConfirmation() async {
    let clock = TestClock()
    let store = Self.store(ConnectionFeature.State(), clock: clock) {
      $0.pairingStore = .inMemory()
      $0.remoteClient.discover = { _ in throw RemoteFailure.macNotFound("Studio") }
    }
    let link = URL(string: Fixtures.pairingCode)!

    await store.send(.pairingLinkOpened(link)) {
      $0.linkPairing = .confirm(Fixtures.payload)
    }
    await store.send(.linkPairingConfirmed) {
      $0.linkPairing = nil
      $0.gateways = [Fixtures.gateway]
      $0.activeID = Fixtures.deviceID
      $0.phase = .discovering
    }
    await store.receive(\.delegate.activeGatewayChanged)
    await store.receive(\.sessionEnded) {
      $0.phase = .reconnecting(attempt: 1, nextAttemptAt: Fixtures.pairedAt.addingTimeInterval(0.5))
      $0.failedAttempts = 1
      $0.lastFailure = .macNotFound("Studio")
    }
    await store.send(.scenePhaseChanged(.background)) {
      $0.isAppActive = false
      $0.phase = .offline
    }
  }

  @Test
  func dismissingAPairingLinkStoresNothing() async {
    let saves = LockIsolated(0)
    let store = TestStore(initialState: ConnectionFeature.State()) {
      ConnectionFeature()
    } withDependencies: {
      $0.pairingStore.save = { payload, date in
        saves.withValue { $0 += 1 }
        return PairedGateway(payload: payload, pairedAt: date)
      }
    }

    await store.send(.pairingLinkOpened(URL(string: Fixtures.pairingCode)!)) {
      $0.linkPairing = .confirm(Fixtures.payload)
    }
    await store.send(.linkPairingDismissed) {
      $0.linkPairing = nil
    }
    // A late confirmation (e.g. from a second window's alert) is a no-op.
    await store.send(.linkPairingConfirmed)
    #expect(saves.value == 0)
  }

  @Test
  func reopeningAnAlreadyPairedLinkAsksNothing() async {
    let store = TestStore(initialState: Self.pairedState()) {
      ConnectionFeature()
    }
    await store.send(.pairingLinkOpened(URL(string: Fixtures.pairingCode)!))
  }

  @Test
  func unrelatedLinksAreIgnoredAndBrokenPairingLinksReportAnError() async {
    let store = TestStore(initialState: ConnectionFeature.State()) {
      ConnectionFeature()
    }

    await store.send(.pairingLinkOpened(URL(string: "https://example.com/codans-pair")!))
    await store.send(.pairingLinkOpened(URL(string: "codans-pair:AAAA")!)) {
      $0.linkPairing = .invalid(ConnectionFeature.message(for: PairingPayload.DecodingError.malformed))
    }
  }

  @Test
  func forgettingTheActiveMacDisconnectsClearsModelsAndItsCache() async {
    var initial = Self.pairedState()
    initial.phase = .live
    initial.session = Fixtures.liveInfo
    initial.supportsLiveTerminal = true
    initial.lastSyncedAt = Fixtures.pairedAt
    let removed = LockIsolated<UUID?>(nil)
    let uncached = LockIsolated<UUID?>(nil)
    let store = Self.store(initial) {
      $0.pairingStore.remove = { removed.setValue($0) }
      $0.pairingStore.setActive = { _ in }
      $0.workspaceCache.remove = { uncached.setValue($0) }
    }

    await store.send(.forgetTapped(Fixtures.deviceID)) {
      $0.gateways = []
      $0.activeID = nil
      $0.session = nil
      $0.supportsLiveTerminal = false
      $0.lastSyncedAt = nil
      $0.phase = .idle
    }
    await store.receive(\.delegate.activeGatewayChanged)
    await store.finish()
    #expect(removed.value == Fixtures.deviceID)
    #expect(uncached.value == Fixtures.deviceID)
  }

  // MARK: - Helpers

  /// A phase timer armed just before a failure may still fire, since TCA
  /// registers a cancellable only once its task starts; the reducer ignores
  /// it because the phase moved on. Its arrival order is not deterministic.
  private static func dropStaleTimers(_ store: TestStoreOf<ConnectionFeature>) async {
    let exhaustivity = store.exhaustivity
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = exhaustivity
  }

  /// Ends a test whose session, timers or path observer still run: they
  /// are long-lived by design, so they are dropped rather than asserted.
  private static func endSession(_ store: TestStoreOf<ConnectionFeature>) async {
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.skipInFlightEffects()
  }

  private static func pairedState() -> ConnectionFeature.State {
    var state = ConnectionFeature.State()
    state.gateways = [Fixtures.gateway]
    state.activeID = Fixtures.deviceID
    state.isAppActive = true
    state.hasStarted = true
    return state
  }

  /// A store for a paired, foreground connection with deterministic time,
  /// no jitter and a working key; `configure` supplies the remote.
  private static func store(
    _ initial: ConnectionFeature.State = pairedState(),
    clock: TestClock<Duration> = TestClock(),
    now: LockIsolated<Date> = LockIsolated(Fixtures.pairedAt),
    configure: (inout DependencyValues) -> Void
  ) -> TestStoreOf<ConnectionFeature> {
    TestStore(initialState: initial) {
      ConnectionFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date = DateGenerator { now.value }
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(NoJitter())
      $0.pairingStore.credential = { _ in Fixtures.payload.credential }
      $0.remoteClient.disconnect = {}
      configure(&$0)
    }
  }
}

/// Always draws 0, so backoff has no jitter and the next attempt times are
/// exact.
private struct NoJitter: RandomNumberGenerator {
  mutating func next() -> UInt64 { 0 }
}
