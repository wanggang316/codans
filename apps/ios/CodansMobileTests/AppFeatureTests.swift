import CodansIPC
import ComposableArchitecture
import Testing

@testable import CodansMobile

/// Event frames from the connection feed the agents and browser models, and
/// a snapshot refreshes the composer's profiles; changing the active Mac
/// clears them all.
@MainActor
struct AppFeatureTests {
  @Test
  func eventFramesFanOutToAgentsAndBrowser() async {
    let profile = Fixtures.profile("Claude")
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.remoteClient.listProfiles = { [profile] }
    }
    let agent = Fixtures.agent("A", state: "blocked")
    let frame = Fixtures.snapshot(agents: [agent])

    await store.send(.connection(.eventReceived(frame)))
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

    await store.send(.connection(.delegate(.activeGatewayChanged)))
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
}
