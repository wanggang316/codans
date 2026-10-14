import CodansIPC
import ComposableArchitecture
import Foundation

/// Process-wide state: the connection to the paired Mac and the models the
/// event stream feeds. Every scene renders from the same store; only
/// navigation (selected tab, project, pane) is per scene.
///
/// The models are also cached per Mac (`WorkspaceCacheClient`): a cold
/// start shows the last hierarchy and agents, marked stale, until the
/// first snapshot replaces them.
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
    case cacheLoaded(gatewayID: UUID, CachedWorkspace?)
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case cacheLoad
    case cacheSave
  }

  /// Event bursts (an agent flipping state, a tab opening) settle before
  /// the cache is written once.
  nonisolated static let cacheSaveDelay: Duration = .seconds(2)

  @Dependency(\.workspaceCache) var workspaceCache
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now

  var body: some Reducer<State, Action> {
    Scope(state: \.connection, action: \.connection) { ConnectionFeature() }
    Scope(state: \.agents, action: \.agents) { AgentsFeature() }
    Scope(state: \.browser, action: \.browser) { BrowserFeature() }
    Scope(state: \.composer, action: \.composer) { ComposerFeature() }
    Reduce { state, action in
      switch action {
      case .connection(let connectionAction):
        state.composer.isConnectionLive = state.connection.isLive
        return reduce(connectionAction, &state)

      case .agents(.eventReceived(let frame)), .browser(.eventReceived(let frame)):
        return saveCache(after: frame, state)

      case .cacheLoaded(let id, let workspace):
        // A snapshot that beat the disk is newer than anything cached.
        guard let workspace, state.connection.activeID == id, !state.connection.isLive,
          state.browser.hierarchy == nil
        else { return .none }
        return .merge(
          .send(.browser(.restored(workspace.hierarchy))),
          .send(.agents(.restored(workspace.agents))),
          .send(.connection(.cacheRestored(workspace)))
        )

      case .agents, .browser, .composer:
        return .none
      }
    }
  }

  private func reduce(_ action: ConnectionFeature.Action, _ state: inout State) -> Effect<Action> {
    switch action {
    case .delegate(.eventReceived(let frame)):
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

    case .delegate(.activeGatewayChanged(let id)):
      var effects: [Effect<Action>] = [
        .cancel(id: CancelID.cacheSave),
        .send(.agents(.reset)),
        .send(.browser(.reset)),
        .send(.composer(.reset)),
      ]
      if let id {
        let load = workspaceCache.load
        effects.append(
          .run { send in await send(.cacheLoaded(gatewayID: id, await load(id))) }
            .cancellable(id: CancelID.cacheLoad, cancelInFlight: true))
      }
      return .concatenate(effects)

    default:
      return .none
    }
  }

  /// Writes the models to the cache shortly after a frame that changed
  /// them, but only while live: data shown during a reconnect is already
  /// stale and must not be saved as fresh.
  private func saveCache(after frame: IPC.EventFrame, _ state: State) -> Effect<Action> {
    switch frame.payload {
    case .snapshot, .hierarchyChanged, .agentStatesChanged: break
    case .heartbeat, .unknown: return .none
    }
    guard state.connection.isLive, let id = state.connection.activeID else { return .none }
    let workspace = CachedWorkspace(
      savedAt: now,
      protocolMinor: state.connection.session?.protocolMinor,
      hierarchy: state.browser.hierarchy,
      agents: state.agents.entries.values.sorted { $0.paneID < $1.paneID }
    )
    let save = workspaceCache.save
    return .run { [clock] _ in
      try await clock.sleep(for: Self.cacheSaveDelay)
      await save(id, workspace)
    }
    .cancellable(id: CancelID.cacheSave, cancelInFlight: true)
  }
}
