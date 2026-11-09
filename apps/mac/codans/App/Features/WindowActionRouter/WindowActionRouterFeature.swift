import ComposableArchitecture
import Foundation
import CodansCore

/// Pure router reducer for `TerminalEvent.windowActionRequested`. Keeps the
/// dispatch table in one place so every window/app-level ghostty action
/// maps onto exactly one client call — no silent branches, no scattered
/// AppKit usage in other reducers.
///
/// State is intentionally empty: there is nothing to observe, undo, or
/// collapse across requests. The reducer is a fan-out with well-typed
/// arms, not a state machine. Composing it into `RootFeature` lands in
/// the integration task (plan §Milestone 7); this milestone only wires
/// the type contract and its dependencies.
@Reducer
struct WindowActionRouterFeature {
  @ObservableState
  struct State: Equatable {}

  enum Action: Equatable {
    case requested(WindowActionRequest)
  }

  @Dependency(WindowService.self) private var windowService
  @Dependency(AppLifecycleClient.self) private var appLifecycleClient
  @Dependency(UpdatesClient.self) private var updatesClient
  @Dependency(GhosttyConfigOpenerClient.self) private var ghosttyConfigOpener

  var body: some Reducer<State, Action> {
    Reduce { _, action in
      switch action {
      case .requested(let request):
        return dispatch(request)
      }
    }
  }

  private func dispatch(_ request: WindowActionRequest) -> Effect<Action> {
    switch request {
    case .new(let from):
      windowService.openNewWindow(from)
      return .none
    case .close(let from):
      windowService.closeWindow(from)
      return .none
    case .closeAll:
      appLifecycleClient.terminate()
      return .none
    case .goto(let target):
      windowService.activateWindow(target)
      return .none
    case .toggleFullscreen(let from):
      windowService.toggleFullscreen(from)
      return .none
    case .toggleMaximize(let from):
      windowService.toggleMaximize(from)
      return .none
    case .toggleTabOverview(let from):
      windowService.toggleTabOverview(from)
      return .none
    case .toggleAppVisibility:
      windowService.toggleAppVisibility()
      return .none
    case .quit:
      appLifecycleClient.requestQuit()
      return .none
    case .checkForUpdates:
      updatesClient.checkNow()
      return .none
    case .openConfig:
      ghosttyConfigOpener.open(ghosttyConfigOpener.configURL())
      return .none
    }
  }
}
