import CodansIPC
import ComposableArchitecture
import Testing

@testable import CodansMobile

/// Event frames from the connection feed both the agents and the browser
/// models; changing the active Mac clears them.
@MainActor
struct AppFeatureTests {
  @Test
  func eventFramesFanOutToAgentsAndBrowser() async {
    let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
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
    #expect(store.state.browser.location(ofPane: "A")?.paneTitle == "claude")

    await store.send(.connection(.delegate(.activeGatewayChanged)))
    await store.receive(\.agents.reset) {
      $0.agents = AgentsFeature.State()
    }
    await store.receive(\.browser.reset) {
      $0.browser = BrowserFeature.State()
    }
  }
}
