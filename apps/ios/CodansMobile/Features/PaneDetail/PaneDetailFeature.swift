import CodansIPC
import ComposableArchitecture
import Foundation

/// One pane's recent output as a text snapshot (`pane.read`), refreshed
/// while visible — on a fallback timer and whenever the event stream
/// touches the pane — plus text and named-key input for interactive
/// devices. This is the fallback for a Mac too old to stream terminals
/// (protocol minor 1); newer Macs get `TerminalStreamFeature`.
///
/// One read is in flight at a time. A refresh asked for meanwhile is
/// remembered and runs when it finishes, instead of cancelling it: under a
/// steady stream of change signals a cancelled read would never complete.
@Reducer
struct PaneDetailFeature {
  @ObservableState
  struct State: Equatable {
    let paneID: String
    var permission: IPC.RemotePermission
    var content = ""
    var hasLoaded = false
    var isLoading = false
    /// A refresh arrived while a read was in flight.
    var needsRefresh = false
    /// When `content` was read.
    var loadedAt: Date?
    /// The last read failed; `content` is from an earlier one.
    var readFailed = false
    var draft = ""
    var isSending = false
    var errorMessage: String?

    init(paneID: String, permission: IPC.RemotePermission) {
      self.paneID = paneID
      self.permission = permission
    }

    /// Input bar and key row exist only for interactive devices; the Mac
    /// refuses input from read-only ones anyway.
    var showsInput: Bool { permission == .interactive }

    var canSend: Bool {
      showsInput && !isSending && !draft.isEmpty
    }

    /// The text on screen is older than the last attempt to read it.
    var isStale: Bool { hasLoaded && readFailed }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    /// Lifetime of the visible view: loads once, then polls.
    case task
    case refresh
    case contentLoaded(String)
    case loadFailed(RemoteFailure)
    /// The event stream reported a change on this pane.
    case paneChanged
    case permissionChanged(IPC.RemotePermission)
    case sendTapped
    case keyTapped(IPC.TerminalNamedKey)
    case inputDelivered
    case inputFailed(RemoteFailure)
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case send
  }

  /// Lines of scrollback fetched per read. Enough to follow an agent;
  /// bounded so a huge scrollback costs the Mac and the radio little.
  nonisolated static let tailLines = 400
  /// Fallback refresh while visible, for output with no agent-state change
  /// behind it (a plain shell running a build).
  nonisolated static let pollInterval: Duration = .seconds(3)
  /// Give the pane a moment to echo input before re-reading it.
  nonisolated static let echoDelay: Duration = .milliseconds(300)

  @Dependency(\.remoteClient) var remoteClient
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        let interval = Self.pollInterval
        return .run { [clock] send in
          await send(.refresh)
          for await _ in clock.timer(interval: interval) {
            await send(.refresh)
          }
        }

      case .refresh, .paneChanged:
        guard !state.isLoading else {
          state.needsRefresh = true
          return .none
        }
        return read(&state)

      case .contentLoaded(let content):
        state.isLoading = false
        state.hasLoaded = true
        state.content = content
        state.loadedAt = now
        state.readFailed = false
        state.errorMessage = nil
        return readAgainIfAsked(&state)

      case .loadFailed(let failure):
        state.isLoading = false
        // The last text stays on screen, marked stale.
        state.readFailed = true
        state.errorMessage = failure.message
        return readAgainIfAsked(&state)

      case .permissionChanged(let permission):
        state.permission = permission
        return .none

      case .sendTapped:
        guard state.canSend else { return .none }
        let text = state.draft
        state.draft = ""
        state.isSending = true
        let remote = remoteClient
        let paneID = state.paneID
        // The Mac's text path drops control bytes, so the line is typed as
        // text and submitted with a named Enter key.
        return deliver {
          try await remote.sendInput(paneID, text)
          try await remote.sendKey(paneID, .enter)
        }

      case .keyTapped(let key):
        guard state.showsInput, !state.isSending else { return .none }
        state.isSending = true
        let sendKey = remoteClient.sendKey
        let paneID = state.paneID
        return deliver { try await sendKey(paneID, key) }

      case .inputDelivered:
        state.isSending = false
        state.errorMessage = nil
        return .run { [clock] send in
          try await clock.sleep(for: Self.echoDelay)
          await send(.refresh)
        }

      case .inputFailed(let failure):
        state.isSending = false
        state.errorMessage = failure.message
        // The permission may have been downgraded on the Mac since the
        // handshake; stop offering input the router will refuse.
        if failure.kind == .forbidden { state.permission = .readOnly }
        return .none
      }
    }
  }

  private func read(_ state: inout State) -> Effect<Action> {
    state.isLoading = true
    state.needsRefresh = false
    let read = remoteClient.readPane
    let paneID = state.paneID
    return .run { send in
      await send(.contentLoaded(try await read(paneID, Self.tailLines)))
    } catch: { error, send in
      await send(.loadFailed(RemoteFailure(error)))
    }
  }

  private func readAgainIfAsked(_ state: inout State) -> Effect<Action> {
    guard state.needsRefresh else { return .none }
    return read(&state)
  }

  private func deliver(_ operation: @escaping @Sendable () async throws -> Void) -> Effect<Action> {
    .run { send in
      try await operation()
      await send(.inputDelivered)
    } catch: { error, send in
      await send(.inputFailed(RemoteFailure(error)))
    }
    .cancellable(id: CancelID.send)
  }
}
