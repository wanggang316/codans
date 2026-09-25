import ComposableArchitecture
import Foundation

/// Process-wide state: the connection to the paired Mac and the models the
/// event stream feeds. Every scene renders from the same store; only
/// navigation (selected tab, project, pane) is per scene.
@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    var connection = ConnectionFeature.State()
    var agents = AgentsFeature.State()
    var browser = BrowserFeature.State()
    var composer = ComposerFeature.State()
  }

  enum Action: Equatable {
    case connection(ConnectionFeature.Action)
    case agents(AgentsFeature.Action)
    case browser(BrowserFeature.Action)
    case composer(ComposerFeature.Action)
  }

  var body: some Reducer<State, Action> {
    Scope(state: \.connection, action: \.connection) { ConnectionFeature() }
    Scope(state: \.agents, action: \.agents) { AgentsFeature() }
    Scope(state: \.browser, action: \.browser) { BrowserFeature() }
    Scope(state: \.composer, action: \.composer) { ComposerFeature() }
    Reduce { _, action in
      switch action {
      case .connection(.delegate(.eventReceived(let frame))):
        var effects: [Effect<Action>] = [
          .send(.agents(.eventReceived(frame))),
          .send(.browser(.eventReceived(frame))),
        ]
        // Each (re)connect opens with a snapshot; refresh the profiles then,
        // since they may have changed on the Mac while disconnected.
        if case .snapshot = frame.payload {
          effects.append(.send(.composer(.loadProfiles)))
        }
        return .merge(effects)
      case .connection(.delegate(.activeGatewayChanged)):
        return .merge(.send(.agents(.reset)), .send(.browser(.reset)), .send(.composer(.reset)))
      case .connection, .agents, .browser, .composer:
        return .none
      }
    }
  }
}
