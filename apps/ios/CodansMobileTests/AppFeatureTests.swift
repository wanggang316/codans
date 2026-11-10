import CodansIPC
import ComposableArchitecture
import Foundation
import Testing

@testable import CodansMobile

/// Event frames from the connection feed the agents and browser models, and
/// a snapshot refreshes the composer's profiles; changing the active Mac
/// clears them all and shows its cached workspace; live data is cached.
@MainActor
struct AppFeatureTests {
  @Test
  func eventFramesFanOutToAgentsAndBrowser() async {
    let profile = Fixtures.profile("Claude")
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Fixtures.pairedAt
      $0.remoteClient.listProfiles = { [profile] }
    }
    let agent = Fixtures.agent("A", state: "blocked")
    let frame = Fixtures.snapshot(agents: [agent])

    await store.send(.connection(.eventReceived(frame))) {
      $0.connection.lastContact = Fixtures.pairedAt
    }
    await store.receive(\.connection.delegate.eventReceived)
    await store.receive(\.agents.eventReceived) {
      $0.agents.entries = ["A": agent]
      $0.agents.hasSnapshot = true
    }
    await store.receive(\.browser.eventReceived) {
      $0.browser.hierarchy = Fixtures.hierarchy
    }
    // A snapshot (every connect starts with one) refreshes the profiles.
    await store.receive(\.composer.loadProfiles)
    await store.receive(\.composer.profilesLoaded) {
      $0.composer.profiles = [profile]
    }
    #expect(store.state.browser.location(ofPane: "A")?.paneTitle == "claude")

    await store.send(.connection(.delegate(.activeGatewayChanged(nil))))
    await store.receive(\.agents.reset) {
      $0.agents = AgentsFeature.State()
    }
    await store.receive(\.browser.reset) {
      $0.browser = BrowserFeature.State()
    }
    await store.receive(\.composer.reset) {
      $0.composer = ComposerFeature.State()
    }
  }

  @Test
  func switchingMacsShowsItsCachedWorkspaceMarkedStale() async {
    let agent = Fixtures.agent("A", state: "working")
    let cached = CachedWorkspace(
      savedAt: Fixtures.pairedAt.addingTimeInterval(-600), protocolMinor: 2, hierarchy: Fixtures.hierarchy,
      agents: [agent])
    var initial = AppFeature.State()
    initial.connection.gateways = [Fixtures.gateway]
    initial.connection.activeID = Fixtures.deviceID
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.workspaceCache.load = { id in id == Fixtures.deviceID ? cached : nil }
    }

    await store.send(.connection(.delegate(.activeGatewayChanged(Fixtures.deviceID))))
    await store.receive(\.agents.reset)
    await store.receive(\.browser.reset)
    await store.receive(\.composer.reset)
    await store.receive(\.cacheLoaded)
    await store.receive(\.browser.restored) {
      $0.browser.hierarchy = Fixtures.hierarchy
    }
    await store.receive(\.agents.restored) {
      $0.agents.entries = ["A": agent]
      $0.agents.hasSnapshot = true
    }
    await store.receive(\.connection.cacheRestored) {
      $0.connection.lastSyncedAt = Fixtures.pairedAt.addingTimeInterval(-600)
      $0.connection.supportsLiveTerminal = true
    }
    #expect(store.state.connection.health.isStale)
  }

  @Test
  func aCacheThatLosesTheRaceToTheSnapshotIsDropped() async {
    var initial = AppFeature.State()
    initial.connection.activeID = Fixtures.deviceID
    initial.connection.phase = .live
    initial.browser.hierarchy = Fixtures.hierarchy
    let store = TestStore(initialState: initial) { AppFeature() }
    let stale = CachedWorkspace(savedAt: .distantPast, protocolMinor: 1, hierarchy: nil, agents: [])
    await store.send(.cacheLoaded(gatewayID: Fixtures.deviceID, stale))
  }

  @Test
  func liveChangesAreCachedOnceTheBurstSettles() async {
    let clock = TestClock()
    let saved = LockIsolated<[CachedWorkspace]>([])
    var initial = AppFeature.State()
    initial.connection.gateways = [Fixtures.gateway]
    initial.connection.activeID = Fixtures.deviceID
    initial.connection.phase = .live
    initial.connection.session = Fixtures.liveInfo
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = Fixtures.pairedAt
      $0.workspaceCache.save = { id, workspace in
        #expect(id == Fixtures.deviceID)
        saved.withValue { $0.append(workspace) }
      }
    }
    store.exhaustivity = .off

    let agent = Fixtures.agent("A", state: "blocked")
    await store.send(
      .connection(.eventReceived(IPC.EventFrame(seq: 1, payload: .hierarchyChanged(Fixtures.hierarchy)))))
    await store.send(
      .connection(
        .eventReceived(
          IPC.EventFrame(
            seq: 2, payload: .agentStatesChanged(IPC.AgentStatesDelta(upserted: [agent], removedPaneIDs: []))))))
    await store.skipReceivedActions()
    await clock.advance(by: AppFeature.cacheSaveDelay)
    #expect(
      saved.value == [
        CachedWorkspace(
          savedAt: Fixtures.pairedAt, protocolMinor: 2, hierarchy: Fixtures.hierarchy, agents: [agent])
      ])
  }
}
