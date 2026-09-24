import CodansIPC
import CodansRemote
import ComposableArchitecture
import Foundation
import Testing

@testable import CodansMobile

/// The connection state machine: pairing, connect, event delivery, backoff
/// after failures, immediate retry on network recovery, and suspension in
/// the background.
@MainActor
struct ConnectionFeatureTests {
  @Test
  func backoffStartsAtHalfASecondDoublesAndCapsAtThirtySeconds() {
    #expect(ConnectionFeature.backoff(afterFailures: 1) == .milliseconds(500))
    #expect(ConnectionFeature.backoff(afterFailures: 2) == .seconds(1))
    #expect(ConnectionFeature.backoff(afterFailures: 3) == .seconds(2))
    #expect(ConnectionFeature.backoff(afterFailures: 7) == .seconds(30))
    #expect(ConnectionFeature.backoff(afterFailures: 50) == .seconds(30))
  }

  @Test
  func startWithoutPairingStaysIdle() async {
    let store = TestStore(initialState: ConnectionFeature.State()) {
      ConnectionFeature()
    } withDependencies: {
      $0.pairingStore = .inMemory()
      $0.networkPath.becameAvailable = { .finished }
    }

    await store.send(.task) {
      $0.hasStarted = true
    }
    // A second scene appearing does not restart anything.
    await store.send(.task)
  }

  @Test
  func pairingConnectsStreamsEventsAndRetriesWhenTheStreamEnds() async {
    let clock = TestClock()
    let (events, feed) = AsyncThrowingStream<IPC.EventFrame, Error>.makeStream()
    let connects = LockIsolated(0)
    let disconnects = LockIsolated(0)
    let store = TestStore(initialState: ConnectionFeature.State()) {
      ConnectionFeature()
    } withDependencies: {
      $0.pairingStore = .inMemory()
      $0.continuousClock = clock
      $0.date.now = Fixtures.pairedAt
      $0.remoteClient.disconnect = { disconnects.withValue { $0 += 1 } }
      $0.remoteClient.connect = { gateway, credential in
        #expect(gateway == Fixtures.gateway)
        #expect(credential == Fixtures.payload.credential)
        let attempt = connects.withValue { value -> Int in
          value += 1
          return value
        }
        guard attempt == 1 else { throw RemoteFailure(.notFound, "gone") }
        return RemoteSession(info: Fixtures.info, events: events)
      }
    }

    await store.send(.pairingCodeSubmitted(Fixtures.pairingCode)) {
      $0.gateways = [Fixtures.gateway]
      $0.activeID = Fixtures.deviceID
      $0.status = .connecting
    }
    await store.receive(\.delegate.activeGatewayChanged)
    await store.receive(\.sessionOpened) {
      $0.status = .connected
      $0.session = Fixtures.info
    }
    #expect(store.state.permission == .interactive)

    let frame = Fixtures.snapshot(agents: [])
    feed.yield(frame)
    await store.receive(\.eventReceived)
    await store.receive(\.delegate.eventReceived)

    feed.finish()
    await store.receive(\.sessionEnded) {
      $0.status = .retrying(after: .milliseconds(500))
      $0.failedAttempts = 1
      $0.session = nil
      $0.lastFailure = .streamEnded
    }

    await clock.advance(by: .milliseconds(500))
    await store.receive(\.retryTimerFired) {
      $0.status = .connecting
    }
    await store.receive(\.sessionEnded) {
      $0.status = .retrying(after: .seconds(1))
      $0.failedAttempts = 2
      $0.lastFailure = RemoteFailure(.notFound, "gone")
    }
    #expect(connects.value == 2)

    await store.send(.scenePhaseChanged(.background)) {
      $0.isAppActive = false
      $0.status = .suspended
    }
    // Nothing fires once suspended, however long the backoff was.
    await clock.advance(by: .seconds(60))
    #expect(connects.value == 2)
    #expect(disconnects.value >= 3)
  }

  @Test
  func returningToTheForegroundReconnectsImmediately() async {
    let (events, feed) = AsyncThrowingStream<IPC.EventFrame, Error>.makeStream()
    let store = TestStore(initialState: Self.pairedState(status: .suspended, isAppActive: false)) {
      ConnectionFeature()
    } withDependencies: {
      $0.pairingStore = .inMemory(.init(gateways: [Fixtures.gateway], activeID: Fixtures.deviceID))
      $0.pairingStore.credential = { _ in Fixtures.payload.credential }
      $0.remoteClient.disconnect = {}
      $0.remoteClient.connect = { _, _ in RemoteSession(info: Fixtures.info, events: events) }
    }

    await store.send(.scenePhaseChanged(.inactive))
    await store.send(.scenePhaseChanged(.active)) {
      $0.isAppActive = true
      $0.status = .connecting
    }
    await store.receive(\.sessionOpened) {
      $0.status = .connected
      $0.session = Fixtures.info
    }

    await store.send(.scenePhaseChanged(.background)) {
      $0.isAppActive = false
      $0.status = .suspended
    }
    feed.finish()
  }

  @Test
  func networkRecoveryCutsTheBackoffShort() async {
    let clock = TestClock()
    let (paths, pathFeed) = AsyncStream<Void>.makeStream()
    let (events, eventFeed) = AsyncThrowingStream<IPC.EventFrame, Error>.makeStream()
    let attempts = LockIsolated(0)
    var initial = Self.pairedState(status: .idle, isAppActive: true)
    initial.hasStarted = false
    let store = TestStore(initialState: initial) {
      ConnectionFeature()
    } withDependencies: {
      $0.pairingStore = .inMemory(.init(gateways: [Fixtures.gateway], activeID: Fixtures.deviceID))
      $0.pairingStore.credential = { _ in Fixtures.payload.credential }
      $0.networkPath.becameAvailable = { paths }
      $0.continuousClock = clock
      $0.remoteClient.disconnect = {}
      $0.remoteClient.connect = { _, _ in
        let attempt = attempts.withValue { value -> Int in
          value += 1
          return value
        }
        guard attempt > 1 else { throw RemoteFailure(.other, "offline") }
        return RemoteSession(info: Fixtures.info, events: events)
      }
    }
    await store.send(.task) {
      $0.hasStarted = true
      $0.status = .connecting
    }
    await store.receive(\.sessionEnded) {
      $0.status = .retrying(after: .milliseconds(500))
      $0.failedAttempts = 1
      $0.lastFailure = RemoteFailure(.other, "offline")
    }

    pathFeed.yield()
    await store.receive(\.networkBecameAvailable) {
      $0.status = .connecting
    }
    await store.receive(\.sessionOpened) {
      $0.status = .connected
      $0.session = Fixtures.info
      $0.failedAttempts = 0
      $0.lastFailure = nil
    }
    // The cancelled backoff timer never fires.
    await clock.advance(by: .seconds(1))

    await store.send(.scenePhaseChanged(.background)) {
      $0.isAppActive = false
      $0.status = .suspended
    }
    pathFeed.finish()
    eventFeed.finish()
    await store.finish()
  }

  @Test
  func incompatibleMacIsNotRetried() async {
    let clock = TestClock()
    let failure = RemoteFailure(.incompatible, "update")
    let store = TestStore(initialState: Self.pairedState(status: .idle, isAppActive: true)) {
      ConnectionFeature()
    } withDependencies: {
      $0.pairingStore = .inMemory(.init(gateways: [Fixtures.gateway], activeID: Fixtures.deviceID))
      $0.pairingStore.credential = { _ in Fixtures.payload.credential }
      $0.continuousClock = clock
      $0.remoteClient.disconnect = {}
      $0.remoteClient.connect = { _, _ in throw failure }
    }

    await store.send(.connectTapped) {
      $0.status = .connecting
    }
    await store.receive(\.sessionEnded) {
      $0.status = .idle
      $0.lastFailure = failure
    }
    await clock.run()
  }

  @Test
  func missingKeyAsksForRepairingWithoutConnecting() async {
    let store = TestStore(initialState: Self.pairedState(status: .idle, isAppActive: true)) {
      ConnectionFeature()
    } withDependencies: {
      $0.pairingStore.credential = { _ in nil }
      $0.remoteClient.disconnect = {}
    }

    await store.send(.connectTapped) {
      $0.status = .connecting
    }
    await store.receive(\.sessionEnded) {
      $0.status = .idle
      $0.lastFailure = .missingKey
    }
  }

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
  func forgettingTheActiveMacDisconnectsAndClearsModels() async {
    var initial = Self.pairedState(status: .connected, isAppActive: true)
    initial.session = Fixtures.info
    let removed = LockIsolated<UUID?>(nil)
    let store = TestStore(initialState: initial) {
      ConnectionFeature()
    } withDependencies: {
      $0.pairingStore.remove = { removed.setValue($0) }
      $0.pairingStore.setActive = { _ in }
      $0.remoteClient.disconnect = {}
    }

    await store.send(.forgetTapped(Fixtures.deviceID)) {
      $0.gateways = []
      $0.activeID = nil
      $0.session = nil
      $0.status = .idle
    }
    await store.receive(\.delegate.activeGatewayChanged)
    #expect(removed.value == Fixtures.deviceID)
  }

  private static func pairedState(status: ConnectionFeature.Status, isAppActive: Bool) -> ConnectionFeature.State {
    var state = ConnectionFeature.State()
    state.gateways = [Fixtures.gateway]
    state.activeID = Fixtures.deviceID
    state.status = status
    state.isAppActive = isAppActive
    state.hasStarted = true
    return state
  }
}
