import CodansIPC
import ComposableArchitecture
import Foundation

/// One pane's live terminal: the `pane.attachStream` byte stream rendered
/// into a `TerminalScreenModel`, key input batched into
/// `terminal.sendEvents`, and the tab and pane actions of the pane screen.
///
/// Stream: a `reset` starts a new epoch on a blank grid; `output` and
/// `resized` apply only within the epoch of the last reset, so a resync is
/// idempotent. When the connection drops the last screen stays, dimmed,
/// and the next connection attaches again and resyncs from a fresh reset.
///
/// Input: one ordered queue, flushed about every 8 ms, one call in flight.
/// Nothing is queued while disconnected and a failed batch is dropped, not
/// replayed — keys typed at a shell that has since moved on could run the
/// wrong command.
@Reducer
struct TerminalStreamFeature {
  @ObservableState
  struct State: Equatable {
    let paneID: String
    var permission: IPC.RemotePermission
    var isConnected: Bool
    var phase: Phase = .connecting
    var grid: Grid?
    /// Epoch of the last applied `reset`. Frames of any other epoch are
    /// stale and dropped.
    var epoch: Int?
    var fidelity: IPC.TerminalStreamFidelity = .exact
    /// Stream attempts that ended without a frame, since the last frame.
    var attachFailures = 0
    /// Whether a stream is open or opening, so reappearing does not resync.
    var isAttached = false

    var outbox: [IPC.TerminalInputEvent] = []
    var isFlushScheduled = false
    var isSending = false
    var modifiers = ModifierLatch()
    var composeDraft = ""
    /// Compose text queued or in flight, restored into the draft if its
    /// batch fails.
    var composePending: String?
    var notice: Notice?
    var toast: String?

    /// Where the pane sits, for the tab and pane actions. Nil until the
    /// hierarchy lists the pane.
    var location: PaneLocator?
    var isManaging = false
    /// Where a finished tab or pane action wants the screen to go; the
    /// view performs it and reports back with `navigationHandled`.
    var navigation: Navigation?

    let screen: TerminalScreenModel
    /// Scopes this store's effects: two windows may show the same pane,
    /// and cancel IDs are shared by every store in the process.
    let instance: UUID

    init(
      paneID: String,
      permission: IPC.RemotePermission,
      isConnected: Bool,
      screen: TerminalScreenModel = TerminalScreenModel(),
      instance: UUID = UUID()
    ) {
      self.paneID = paneID
      self.permission = permission
      self.isConnected = isConnected
      self.screen = screen
      self.instance = instance
    }

    var isInteractive: Bool { permission == .interactive }

    /// Keys go out only over a live connection to a pane still running.
    var canSendInput: Bool {
      guard isInteractive, isConnected else { return false }
      if case .exited = phase { return false }
      return true
    }

    /// Why input is off, for an interactive device; nil while it is on.
    var inputDisabledReason: String? {
      guard isInteractive else { return nil }
      if !isConnected { return "Reconnecting — keys aren't sent while offline." }
      if case .exited = phase { return "The process in this pane has exited." }
      return nil
    }

    /// Whether the last screen is shown dimmed under a reconnect overlay.
    var isStale: Bool {
      phase == .reconnecting || (!isConnected && grid != nil)
    }
  }

  struct Grid: Equatable {
    var cols: Int
    var rows: Int
  }

  enum Phase: Equatable {
    /// Waiting for the first `reset`.
    case connecting
    case live
    /// The stream dropped; the last screen stays until the resync.
    case reconnecting
    /// The pane's process ended; no more frames come.
    case exited(reason: String)
    /// Attaching kept failing while the connection itself was fine.
    case failed(String)
  }

  enum Notice: Equatable {
    /// The Mac has no live terminal for the pane, so keys cannot be
    /// encoded until it is opened there.
    case paneNotOpenOnMac
  }

  enum Navigation: Equatable {
    /// Show this tab (its focused pane) once the hierarchy lists it.
    case showTab(String)
    /// Show this pane once the hierarchy lists it.
    case showPane(String)
    /// The pane on screen is gone; pick another.
    case paneClosed
  }

  enum Management: Equatable {
    case tabCreated(tabID: String)
    case paneCreated(paneID: String)
    case tabRenamed
    case paneClosed
    case tabClosed
    case openedOnMac
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    /// Lifetime of the visible view.
    case task
    case connectionChanged(Bool)
    case permissionChanged(IPC.RemotePermission)
    case locationChanged(PaneLocator?)
    case frameReceived(IPC.TerminalStreamFrame)
    case streamEnded(RemoteFailure?)
    case retryAttach

    /// Text from the keyboard or the key bar's symbol keys.
    case textTyped(String)
    /// A named key from the key bar or a hardware keyboard; latched
    /// modifiers are added.
    case keyPressed(code: String, mods: IPC.TerminalKeyModifiers)
    /// Events sent exactly as given (shortcut panel, paste).
    case eventsRequested([IPC.TerminalInputEvent])
    case modifierTapped(ModifierLatch.Modifier)
    case composeSubmitted(pressEnter: Bool)
    case flush
    case sendFinished(Result<IPC.TerminalSendEventsResult, RemoteFailure>)
    case toastExpired

    case openOnMacTapped
    case newTabTapped
    case splitTapped(SplitDirection)
    case renameTabSubmitted(String)
    case closePaneConfirmed
    case closeTabConfirmed
    case managementFinished(Result<Management, RemoteFailure>)
    case navigationHandled
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case stream(UUID)
    case retry(UUID)
    case flush(UUID)
    case send(UUID)
    case toast(UUID)
  }

  /// How long typed keys wait to share one `terminal.sendEvents` call.
  nonisolated static let flushDelay: Duration = .milliseconds(8)
  nonisolated static let toastDuration: Duration = .milliseconds(2500)
  /// Stream attempts retried before the pane shows as failed.
  nonisolated static let maxAttachRetries = 3
  /// Lets a TUI take a pasted block before its Enter.
  nonisolated static let pasteSettleMillis = 30

  nonisolated static func retryDelay(afterFailures failures: Int) -> Duration {
    .milliseconds(500) * (1 << min(max(failures - 1, 0), 4))
  }

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
        guard !state.isAttached else { return .none }
        return attach(&state)

      case .connectionChanged(let isConnected):
        guard isConnected != state.isConnected else { return .none }
        state.isConnected = isConnected
        if isConnected {
          state.attachFailures = 0
          return attach(&state)
        }
        state.isAttached = false
        // Never replay keys typed before the drop.
        state.outbox.removeAll()
        state.isFlushScheduled = false
        state.isSending = false
        state.modifiers.clear()
        if let pending = state.composePending, state.composeDraft.isEmpty { state.composeDraft = pending }
        state.composePending = nil
        if state.phase == .live || state.phase == .connecting, state.grid != nil { state.phase = .reconnecting }
        return .merge(
          .cancel(id: CancelID.stream(state.instance)),
          .cancel(id: CancelID.retry(state.instance)),
          .cancel(id: CancelID.flush(state.instance)),
          .cancel(id: CancelID.send(state.instance))
        )

      case .permissionChanged(let permission):
        state.permission = permission
        if permission != .interactive { state.outbox.removeAll() }
        return .none

      case .locationChanged(let location):
        state.location = location
        return .none

      case .frameReceived(let frame):
        return apply(frame, to: &state)

      case .streamEnded(let failure):
        state.isAttached = false
        if case .exited = state.phase { return .none }
        guard state.isConnected else { return .none }
        state.attachFailures += 1
        if state.attachFailures > Self.maxAttachRetries {
          state.phase = .failed(failure?.message ?? "The terminal stream keeps ending.")
          return .none
        }
        if state.grid != nil { state.phase = .reconnecting }
        let delay = Self.retryDelay(afterFailures: state.attachFailures)
        return .run { [clock] send in
          try await clock.sleep(for: delay)
          await send(.retryAttach)
        }
        .cancellable(id: CancelID.retry(state.instance), cancelInFlight: true)

      case .retryAttach:
        if case .failed = state.phase { state.attachFailures = 0 }
        return attach(&state)

      case .textTyped(let text):
        guard state.canSendInput, !text.isEmpty else { return .none }
        if state.modifiers.isActive, text.count == 1, let character = text.first,
          let event = TerminalKeyMap.event(for: character, mods: state.modifiers.modifiers)
        {
          state.modifiers.consume()
          return enqueue([event], &state)
        }
        return enqueue(Self.events(forTyped: text), &state)

      case .keyPressed(let code, var mods):
        guard state.canSendInput else { return .none }
        let latched = state.modifiers.modifiers
        mods.ctrl = mods.ctrl || latched.ctrl
        mods.alt = mods.alt || latched.alt
        state.modifiers.consume()
        return enqueue([.key(code: code, text: nil, mods: mods)], &state)

      case .eventsRequested(let events):
        guard state.canSendInput, !events.isEmpty else { return .none }
        return enqueue(events, &state)

      case .modifierTapped(let modifier):
        guard state.canSendInput else { return .none }
        state.modifiers.tap(modifier, at: now)
        return .none

      case .composeSubmitted(let pressEnter):
        let text = state.composeDraft
        guard state.canSendInput, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          return .none
        }
        state.composeDraft = ""
        state.composePending = text
        return enqueue(Self.composeEvents(text, pressEnter: pressEnter), &state)

      case .flush:
        state.isFlushScheduled = false
        guard !state.isSending, !state.outbox.isEmpty, state.canSendInput else { return .none }
        let batch = Self.takeBatch(from: &state.outbox)
        state.isSending = true
        let sendEvents = remoteClient.sendEvents
        let paneID = state.paneID
        return .run { send in
          let result = try await sendEvents(paneID, batch)
          await send(.sendFinished(.success(result)))
        } catch: { error, send in
          await send(.sendFinished(.failure(RemoteFailure(error))))
        }
        .cancellable(id: CancelID.send(state.instance))

      case .sendFinished(.success(let result)):
        state.isSending = false
        if state.outbox.isEmpty { state.composePending = nil }
        if result.delivered > 0, state.notice == .paneNotOpenOnMac { state.notice = nil }
        var effects: [Effect<Action>] = []
        if let message = Self.message(forRejections: result.rejected) {
          effects.append(showToast(message, &state))
        }
        if !state.outbox.isEmpty { effects.append(.send(.flush)) }
        return .merge(effects)

      case .sendFinished(.failure(let failure)):
        state.isSending = false
        state.outbox.removeAll()
        if let pending = state.composePending, state.composeDraft.isEmpty { state.composeDraft = pending }
        state.composePending = nil
        switch failure.kind {
        case .unsupported:
          state.notice = .paneNotOpenOnMac
          return .none
        case .forbidden:
          // The Mac downgraded this device since the handshake.
          state.permission = .readOnly
          return showToast("This device is read-only now.", &state)
        default:
          return showToast("Couldn't send: \(failure.message)", &state)
        }

      case .toastExpired:
        state.toast = nil
        return .none

      case .openOnMacTapped:
        guard let tabID = state.location?.tabID else { return .none }
        let activate = remoteClient.activateTab
        return manage(&state) {
          try await activate(tabID)
          return .openedOnMac
        }

      case .newTabTapped:
        guard let location = state.location else { return .none }
        let createTab = remoteClient.createTab
        return manage(&state) { .tabCreated(tabID: try await createTab(location)) }

      case .splitTapped(let direction):
        guard let location = state.location else { return .none }
        let splitPane = remoteClient.splitPane
        return manage(&state) { .paneCreated(paneID: try await splitPane(location, direction)) }

      case .renameTabSubmitted(let name):
        guard let location = state.location else { return .none }
        let renameTab = remoteClient.renameTab
        return manage(&state) {
          try await renameTab(location, name)
          return .tabRenamed
        }

      case .closePaneConfirmed:
        guard let location = state.location else { return .none }
        let closePane = remoteClient.closePane
        return manage(&state) {
          try await closePane(location)
          return .paneClosed
        }

      case .closeTabConfirmed:
        guard let location = state.location else { return .none }
        let closeTab = remoteClient.closeTab
        return manage(&state) {
          try await closeTab(location)
          return .tabClosed
        }

      case .managementFinished(.success(let outcome)):
        state.isManaging = false
        switch outcome {
        case .tabCreated(let tabID):
          state.navigation = .showTab(tabID)
          return .none
        case .paneCreated(let paneID):
          state.navigation = .showPane(paneID)
          return .none
        case .paneClosed, .tabClosed:
          state.navigation = .paneClosed
          return .none
        case .openedOnMac:
          // The surface appears once the Mac lays the tab out; the next
          // key will tell. Clearing now lets the user try at once.
          state.notice = nil
          return .none
        case .tabRenamed:
          return .none
        }

      case .managementFinished(.failure(let failure)):
        state.isManaging = false
        return showToast(failure.message, &state)

      case .navigationHandled:
        state.navigation = nil
        return .none
      }
    }
  }

  // MARK: - Stream

  private func attach(_ state: inout State) -> Effect<Action> {
    guard state.isConnected else { return .none }
    if case .exited = state.phase { return .none }
    state.isAttached = true
    if state.grid == nil {
      state.phase = .connecting
    } else if state.phase != .live {
      state.phase = .reconnecting
    }
    let attachStream = remoteClient.attachStream
    let paneID = state.paneID
    return .run { send in
      let frames = try await attachStream(paneID)
      for try await frame in frames {
        await send(.frameReceived(frame))
      }
      await send(.streamEnded(nil))
    } catch: { error, send in
      await send(.streamEnded(RemoteFailure(error)))
    }
    .cancellable(id: CancelID.stream(state.instance), cancelInFlight: true)
  }

  private func apply(_ frame: IPC.TerminalStreamFrame, to state: inout State) -> Effect<Action> {
    switch frame.payload {
    case .reset(let cols, let rows, let fidelity):
      state.epoch = frame.epoch
      state.grid = Grid(cols: cols, rows: rows)
      state.fidelity = fidelity
      state.attachFailures = 0
      if case .exited = state.phase {} else { state.phase = .live }
      state.screen.reset(cols: cols, rows: rows)
    case .output(let data):
      guard frame.epoch == state.epoch else { return .none }
      state.screen.feed(data)
    case .resized(let cols, let rows):
      guard frame.epoch == state.epoch else { return .none }
      state.grid = Grid(cols: cols, rows: rows)
      state.screen.resize(cols: cols, rows: rows)
    case .exited(let reason, _):
      state.phase = .exited(reason: reason)
      state.outbox.removeAll()
      state.modifiers.clear()
      return .merge(.cancel(id: CancelID.flush(state.instance)), .cancel(id: CancelID.retry(state.instance)))
    case .heartbeat, .unknown:
      break
    }
    return .none
  }

  // MARK: - Input

  private func enqueue(_ events: [IPC.TerminalInputEvent], _ state: inout State) -> Effect<Action> {
    state.outbox.append(contentsOf: events)
    guard !state.isFlushScheduled, !state.isSending else { return .none }
    state.isFlushScheduled = true
    return .run { [clock] send in
      try await clock.sleep(for: Self.flushDelay)
      await send(.flush)
    }
    .cancellable(id: CancelID.flush(state.instance), cancelInFlight: true)
  }

  /// Typed text as events: a lone line break or tab is its key, so the
  /// pane's key modes shape it; anything else is committed text.
  nonisolated static func events(forTyped text: String) -> [IPC.TerminalInputEvent] {
    switch text {
    case "\n", "\r", "\r\n": return [.press("Enter")]
    case "\t": return [.press("Tab")]
    default: return [.text(text)]
    }
  }

  /// The compose card's send: pasted as one block (bracketed paste keeps a
  /// multi-line prompt from submitting line by line), a short settle, then
  /// Enter — or just the paste, to insert without submitting.
  nonisolated static func composeEvents(_ text: String, pressEnter: Bool) -> [IPC.TerminalInputEvent] {
    guard pressEnter else { return [.paste(text)] }
    return [.paste(text), .delay(millis: pasteSettleMillis), .press("Enter")]
  }

  /// The next batch within the per-call limits of `terminal.sendEvents`.
  nonisolated static func takeBatch(from outbox: inout [IPC.TerminalInputEvent]) -> [IPC.TerminalInputEvent] {
    var count = 0
    var delay = 0
    for event in outbox {
      if count == IPC.TerminalSendEventsRequest.maxEvents { break }
      if case .delay(let millis) = event {
        if delay + millis > IPC.TerminalSendEventsRequest.maxTotalDelayMillis, count > 0 { break }
        delay += millis
      }
      count += 1
    }
    let batch = Array(outbox.prefix(count))
    outbox.removeFirst(count)
    return batch
  }

  nonisolated static func message(forRejections rejections: [IPC.TerminalInputRejection]) -> String? {
    guard let first = rejections.first else { return nil }
    typealias Reason = IPC.TerminalInputRejection.Reason
    switch first.reason {
    case Reason.binding: return "That key is a shortcut on your Mac, so it wasn't sent."
    case Reason.paneGone: return "The pane closed on your Mac."
    case Reason.tooLarge: return "That text is too long to send at once."
    case Reason.unknownKey, Reason.unknownEvent: return "Your Mac doesn't know that key."
    default: return "Some keys weren't sent."
    }
  }

  private func showToast(_ message: String, _ state: inout State) -> Effect<Action> {
    state.toast = message
    return .run { [clock] send in
      try await clock.sleep(for: Self.toastDuration)
      await send(.toastExpired)
    }
    .cancellable(id: CancelID.toast(state.instance), cancelInFlight: true)
  }

  private func manage(
    _ state: inout State, _ operation: @escaping @Sendable () async throws -> Management
  ) -> Effect<Action> {
    guard state.isInteractive, state.isConnected, !state.isManaging else { return .none }
    state.isManaging = true
    return .run { send in
      await send(.managementFinished(.success(try await operation())))
    } catch: { error, send in
      await send(.managementFinished(.failure(RemoteFailure(error))))
    }
  }
}
