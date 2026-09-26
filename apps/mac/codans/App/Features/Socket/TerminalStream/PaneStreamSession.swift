import CodansIPC
import Foundation
import os

/// One `pane.attachStream` stream: turns a zmx observer connection into
/// ordered `TerminalStreamFrame`s.
///
/// Frames are produced when the consumer pulls (`next()`), like
/// `EventSubscription`, so the writer's pace sets the frame rate. Meanwhile
/// the connection is always drained into an ordered queue: live output is
/// merged as it arrives and released after a short coalescing window (or
/// once enough bytes have built up), and a `resized` or `reset` is never
/// merged across, so a client always applies bytes at the size they were
/// written for.
///
/// A consumer that falls more than `queueLimit` bytes behind is not
/// allowed to hold the Mac's memory hostage: the queue is dropped, the
/// epoch goes up, and a fresh snapshot restarts the stream at the new
/// epoch. The client sees a `reset` instead of a hole.
actor PaneStreamSession {
  nonisolated struct Configuration: Equatable, Sendable {
    var scrollbackRows: UInt32 = 1000
    var coalesceWindow: Duration = .milliseconds(16)
    /// Output released without waiting for the window, and the most one
    /// live `output` frame carries.
    var coalesceBytes = 64 * 1024
    /// Undelivered live output that triggers a drop and a new epoch.
    var queueLimit = 1024 * 1024
    var snapshotChunkBytes = 256 * 1024
    var heartbeatInterval: Duration = .seconds(30)
    /// How long a daemon gets to answer `.observe` before the session
    /// assumes it predates the observer protocol.
    var fallbackDelay: Duration = .milliseconds(300)
    /// History mode only: how long the grid must stay still after a
    /// resize before it is snapshotted again.
    var resnapshotSettle: Duration = .milliseconds(150)

    static let defaultScrollbackRows = 1000
    static let maxScrollbackRows = 5000
    static let defaultCoalesceMillis = 16
    static let coalesceMillisRange = 8...100

    /// The configuration a request asks for, clamped to what the server
    /// allows.
    static func clamped(scrollbackRows: Int?, coalesceMillis: Int?) -> Configuration {
      var config = Configuration()
      let rows = scrollbackRows ?? defaultScrollbackRows
      config.scrollbackRows = UInt32(min(max(rows, 0), maxScrollbackRows))
      let millis = coalesceMillis ?? defaultCoalesceMillis
      config.coalesceWindow = .milliseconds(
        min(max(millis, coalesceMillisRange.lowerBound), coalesceMillisRange.upperBound))
      return config
    }
  }

  /// A grid size in cells.
  nonisolated struct GridSize: Equatable, Sendable {
    var cols: UInt16
    var rows: UInt16
  }

  private enum Item {
    case reset(GridSize, IPC.TerminalStreamFidelity)
    /// `snapshot` chunks repaint after a reset and go out without waiting;
    /// live output is coalesced.
    case output(Data, snapshot: Bool)
    case resized(GridSize)
    case exited(reason: String)
  }

  /// A history snapshot does not carry a size, and a `.history` dump may
  /// leave synchronized output switched on; closing it keeps a client from
  /// freezing its screen.
  static let historySnapshotSuffix = Data("\u{1B}[?2026l".utf8)
  /// Used for a history snapshot when the pane has no surface to ask.
  static let fallbackGridSize = GridSize(cols: 80, rows: 24)

  nonisolated let configuration: Configuration
  private let connection: any ZmxObserverConnection
  private let clock: any Clock<Duration>
  private let gridSize: @Sendable () async -> GridSize?
  private let onEnd: @Sendable () -> Void
  private let logger = Logger(subsystem: "com.gumpw.codans.remote", category: "terminal-stream")

  private var decoder = ZmxStreamDecoder()
  private var started = false
  private var finished = false
  /// Set once `exited` is queued. The connection may still hand over
  /// frames it had buffered (after a protocol error, say); taking them
  /// could overflow the queue, which would drop the `exited` and leave the
  /// stream waiting for a snapshot from a closed connection.
  private var exitQueued = false
  private var seq = 0
  private(set) var epoch = 1
  private var lastSize: GridSize?

  private var queue: [Item] = []
  /// Live output bytes in `queue`; snapshot chunks do not count, so a
  /// large snapshot cannot trigger the drop it is recovering from.
  private var liveBytes = 0
  /// Undelivered live output, for tests.
  var queuedLiveBytes: Int { liveBytes }
  private var coalesceDue = false

  private var pumpTask: Task<Void, Never>?
  private var fallbackTimer: Task<Void, Never>?
  private var coalesceTimer: Task<Void, Never>?
  private var settleTimer: Task<Void, Never>?
  private var heartbeatTimer: Task<Void, Never>?
  private var waiter: CheckedContinuation<Void, Never>?
  /// Distinguishes waits, so a timer that fires late cannot wake a later
  /// wait it was not armed for.
  private var waitGeneration = 0
  private var wokeForChange = true

  init(
    connection: any ZmxObserverConnection,
    configuration: Configuration = Configuration(),
    clock: any Clock<Duration> = ContinuousClock(),
    gridSize: @escaping @Sendable () async -> GridSize? = { nil },
    onEnd: @escaping @Sendable () -> Void = {}
  ) {
    self.connection = connection
    self.configuration = configuration
    self.clock = clock
    self.gridSize = gridSize
    self.onEnd = onEnd
  }

  /// The next frame, or nil once the stream is over (the pane exited and
  /// that was reported, or the consumer went away).
  func next() async -> IPC.TerminalStreamFrame? {
    startIfNeeded()
    while !finished, !Task.isCancelled {
      if let payload = takeReadyPayload() {
        if case .exited = payload { end() }
        return makeFrame(payload)
      }
      if await !waitForChange() {
        return makeFrame(.heartbeat)
      }
    }
    end()
    return nil
  }

  /// The frames as the router's streaming outcome wants them.
  nonisolated func jsonFrames() -> AsyncStream<JSONValue> {
    AsyncStream(
      unfolding: { [self] in
        guard let frame = await self.next() else { return nil }
        do {
          return try JSONValue.encoded(frame)
        } catch {
          await self.end()
          return nil
        }
      },
      onCancel: { [self] in
        Task { await self.end() }
      })
  }

  /// The Mac's grid for this pane changed. Only a history-mode stream
  /// acts on it: an observer daemon reports resizes in the byte stream
  /// itself, but `.history` has no such signal, so the session takes a new
  /// snapshot once the size settles.
  func geometryChanged() {
    guard started, !finished, decoder.mode == .history else { return }
    settleTimer?.cancel()
    settleTimer = Task { [weak self, clock, configuration] in
      do {
        try await clock.sleep(for: configuration.resnapshotSettle)
      } catch {
        return
      }
      await self?.resnapshotAfterSettle()
    }
  }

  /// Ends the stream and closes the daemon connection. Idempotent.
  func end() {
    guard !finished else { return }
    finished = true
    connection.close()
    pumpTask?.cancel()
    for timer in [fallbackTimer, coalesceTimer, settleTimer] { timer?.cancel() }
    queue.removeAll()
    liveBytes = 0
    wake(changed: true)
    onEnd()
  }

  // MARK: - Connection side

  private func startIfNeeded() {
    guard !started, !finished else { return }
    started = true
    let events = connection.events
    pumpTask = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        await self.handle(event)
      }
    }
    send(decoder.start())
    fallbackTimer = Task { [weak self, clock, configuration] in
      do {
        try await clock.sleep(for: configuration.fallbackDelay)
      } catch {
        return
      }
      await self?.fallbackDeadlinePassed()
    }
  }

  private func fallbackDeadlinePassed() {
    guard !finished, let command = decoder.fallbackDeadlinePassed() else { return }
    logger.info("daemon did not answer .observe; falling back to .history")
    send(command)
  }

  private func resnapshotAfterSettle() {
    guard !finished, decoder.mode == .history else { return }
    send(decoder.resync())
  }

  private func send(_ command: ZmxStreamDecoder.Command) {
    switch command {
    case .sendObserve: connection.observe(scrollbackRows: configuration.scrollbackRows)
    case .sendHistory: connection.requestHistory()
    }
  }

  private func handle(_ event: ZmxStreamClient.Event) async {
    guard !finished, !exitQueued else { return }
    switch event {
    case .frame(let frame):
      let decoded: ZmxStreamDecoder.Event?
      do {
        decoded = try decoder.receive(frame)
      } catch {
        logger.error("undecodable zmx frame: \(String(describing: error), privacy: .public)")
        enqueue(.exited(reason: "protocolError"))
        connection.close()
        return
      }
      if let decoded { await apply(decoded) }
    case .closed(let error):
      enqueue(.exited(reason: error == nil ? "sessionEnded" : "connectionLost"))
    }
  }

  private func apply(_ event: ZmxStreamDecoder.Event) async {
    switch event {
    case .snapshot(let cols, let rows, let state):
      fallbackTimer?.cancel()
      enqueueSnapshot(size: GridSize(cols: cols, rows: rows), fidelity: .exact, state: state)
    case .historySnapshot(let state):
      let size = await gridSize() ?? lastSize ?? Self.fallbackGridSize
      // Awaiting the grid size let other work run; a newer snapshot
      // request or an end may have superseded this one.
      guard !finished, decoder.isLive, decoder.mode == .history else { return }
      enqueueSnapshot(size: size, fidelity: .approximate, state: state + Self.historySnapshotSuffix)
    case .output(let data):
      enqueue(.output(data, snapshot: false))
    case .resized(let cols, let rows):
      let size = GridSize(cols: cols, rows: rows)
      lastSize = size
      enqueue(.resized(size))
    }
  }

  private func enqueueSnapshot(size: GridSize, fidelity: IPC.TerminalStreamFidelity, state: Data) {
    lastSize = size
    enqueue(.reset(size, fidelity))
    var offset = state.startIndex
    while offset < state.endIndex {
      let end = state.index(offset, offsetBy: configuration.snapshotChunkBytes, limitedBy: state.endIndex)
        ?? state.endIndex
      enqueue(.output(Data(state[offset..<end]), snapshot: true))
      offset = end
    }
  }

  private func enqueue(_ item: Item) {
    guard !finished, !exitQueued else { return }
    if case .exited = item { exitQueued = true }
    if case .output(let data, snapshot: false) = item {
      guard !data.isEmpty else { return }
      liveBytes += data.count
      if liveBytes > configuration.queueLimit {
        overflow()
        return
      }
      // Merge into the live output already waiting, so the queue stays
      // short however finely the daemon splits its writes.
      if case .output(var pending, snapshot: false)? = queue.last {
        queue.removeLast()
        pending.append(data)
        queue.append(.output(pending, snapshot: false))
      } else {
        queue.append(item)
      }
      armCoalesceTimer()
    } else {
      queue.append(item)
    }
    wake(changed: true)
  }

  /// The consumer fell too far behind: drop what it has not read and start
  /// a new epoch from a fresh snapshot. Output until that snapshot is
  /// dropped by the decoder, and the snapshot covers it.
  private func overflow() {
    logger.notice("terminal stream fell \(self.liveBytes, privacy: .public) bytes behind; resetting")
    queue.removeAll()
    liveBytes = 0
    resetCoalescing()
    epoch += 1
    send(decoder.resync())
  }

  private func armCoalesceTimer() {
    guard coalesceTimer == nil, !coalesceDue else { return }
    coalesceTimer = Task { [weak self, clock, configuration] in
      do {
        try await clock.sleep(for: configuration.coalesceWindow)
      } catch {
        return
      }
      await self?.coalesceWindowClosed()
    }
  }

  private func coalesceWindowClosed() {
    coalesceTimer = nil
    guard !finished else { return }
    coalesceDue = true
    wake(changed: true)
  }

  private func resetCoalescing() {
    coalesceTimer?.cancel()
    coalesceTimer = nil
    coalesceDue = false
  }

  // MARK: - Consumer side

  /// The next payload that may go out now, if any.
  private func takeReadyPayload() -> IPC.TerminalStreamPayload? {
    guard let head = queue.first else { return nil }
    switch head {
    case .reset(let size, let fidelity):
      queue.removeFirst()
      return .reset(cols: Int(size.cols), rows: Int(size.rows), fidelity: fidelity)
    case .resized(let size):
      queue.removeFirst()
      return .resized(cols: Int(size.cols), rows: Int(size.rows))
    case .exited(let reason):
      queue.removeFirst()
      return .exited(reason: reason, exitCode: nil)
    case .output(let data, snapshot: true):
      queue.removeFirst()
      return .output(data)
    case .output(let data, snapshot: false):
      let limit = configuration.coalesceBytes
      // Something queued behind this output means no more can merge into
      // it, so waiting would only add latency.
      let ready = coalesceDue || data.count >= limit || queue.count > 1
      guard ready else {
        // This run may have queued behind an item that reset the window.
        armCoalesceTimer()
        return nil
      }
      queue.removeFirst()
      var sent = data
      if data.count > limit {
        sent = Data(data.prefix(limit))
        queue.insert(.output(Data(data.dropFirst(limit)), snapshot: false), at: 0)
      } else {
        resetCoalescing()
      }
      liveBytes -= sent.count
      return .output(sent)
    }
  }

  private func makeFrame(_ payload: IPC.TerminalStreamPayload) -> IPC.TerminalStreamFrame {
    seq += 1
    return IPC.TerminalStreamFrame(seq: seq, epoch: epoch, payload: payload)
  }

  /// Suspends until the queue changes (true) or the heartbeat interval
  /// passes with nothing to send (false). Cancellation wakes it too.
  private func waitForChange() async -> Bool {
    waitGeneration += 1
    let generation = waitGeneration
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        waiter = continuation
        heartbeatTimer = Task { [weak self, clock, configuration] in
          do {
            try await clock.sleep(for: configuration.heartbeatInterval)
          } catch {
            return
          }
          await self?.heartbeatDue(generation: generation)
        }
      }
    } onCancel: {
      Task { [weak self] in await self?.wake(changed: true) }
    }
    return wokeForChange
  }

  private func heartbeatDue(generation: Int) {
    guard generation == waitGeneration else { return }
    wake(changed: false)
  }

  private func wake(changed: Bool) {
    guard let continuation = waiter else { return }
    waiter = nil
    if changed { heartbeatTimer?.cancel() }
    heartbeatTimer = nil
    wokeForChange = changed
    continuation.resume()
  }
}
