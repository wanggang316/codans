import ComposableArchitecture
import Foundation
import Testing

@testable import Codans
@testable import CodansIPC

/// `pane.attachStream` on the server: snapshot then live output, coalesced
/// and ordered, with drop-and-reset when the consumer falls behind. Every
/// test carries a time limit, because a hung pull would otherwise still let
/// the run report success.
struct PaneStreamSessionTests {
  @Test(.timeLimit(.minutes(1)))
  func snapshotComesFirstThenLiveOutput() async throws {
    let fixture = Fixture()
    fixture.connection.emit(.output, "before the snapshot")
    fixture.connection.emitObserveState(cols: 120, rows: 40, "SNAP")
    fixture.connection.emit(.output, "live")

    let reset = try #require(await fixture.nextFrame())
    #expect(reset.payload == .reset(cols: 120, rows: 40, fidelity: .exact))
    #expect(reset.seq == 1)
    #expect(reset.epoch == 1)
    #expect(try #require(await fixture.nextFrame()).payload == .output(Data("SNAP".utf8)))
    #expect(try #require(await fixture.nextFrame()).payload == .output(Data("live".utf8)))
    #expect(fixture.connection.commands == ["observe:1000"])
  }

  @Test(.timeLimit(.minutes(1)))
  func outputInsideTheWindowIsCoalesced() async throws {
    let fixture = Fixture()
    fixture.connection.emitObserveState(cols: 80, rows: 24, "")
    _ = await fixture.nextFrame()

    fixture.connection.emit(.output, "a")
    fixture.connection.emit(.output, "b")
    fixture.connection.emit(.output, "c")
    await fixture.waitForLiveBytes(3)
    let frame = try #require(await fixture.nextFrame())
    #expect(frame.payload == .output(Data("abc".utf8)))
    #expect(frame.seq == 2)
  }

  @Test(.timeLimit(.minutes(1)))
  func outputPastTheByteThresholdGoesOutWithoutWaiting() async throws {
    var config = PaneStreamSession.Configuration()
    config.coalesceBytes = 4
    let fixture = Fixture(configuration: config)
    fixture.connection.emitObserveState(cols: 80, rows: 24, "")
    _ = await fixture.nextFrame()

    fixture.connection.emit(.output, "abcdefghij")
    await fixture.waitForLiveBytes(10)
    // No clock movement: full frames are released immediately.
    #expect(try #require(await fixture.nextFrame(step: .zero)).payload == .output(Data("abcd".utf8)))
    #expect(try #require(await fixture.nextFrame(step: .zero)).payload == .output(Data("efgh".utf8)))
    // The tail waits for the window.
    #expect(try #require(await fixture.nextFrame()).payload == .output(Data("ij".utf8)))
  }

  @Test(.timeLimit(.minutes(1)))
  func resizedIsNeverMergedAcross() async throws {
    let fixture = Fixture()
    fixture.connection.emitObserveState(cols: 80, rows: 24, "")
    _ = await fixture.nextFrame()

    fixture.connection.emit(.output, "a")
    fixture.connection.emitObserveResize(cols: 100, rows: 30)
    fixture.connection.emit(.output, "b")
    #expect(try #require(await fixture.nextFrame()).payload == .output(Data("a".utf8)))
    #expect(try #require(await fixture.nextFrame()).payload == .resized(cols: 100, rows: 30))
    #expect(try #require(await fixture.nextFrame()).payload == .output(Data("b".utf8)))
  }

  @Test(.timeLimit(.minutes(1)))
  func snapshotIsSplitIntoBoundedChunks() async throws {
    var config = PaneStreamSession.Configuration()
    config.snapshotChunkBytes = 4
    let fixture = Fixture(configuration: config)
    fixture.connection.emitObserveState(cols: 80, rows: 24, "abcdefghij")

    #expect(try #require(await fixture.nextFrame()).payload == .reset(cols: 80, rows: 24, fidelity: .exact))
    for chunk in ["abcd", "efgh", "ij"] {
      #expect(try #require(await fixture.nextFrame(step: .zero)).payload == .output(Data(chunk.utf8)))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func fallingTooFarBehindResetsIntoANewEpoch() async throws {
    var config = PaneStreamSession.Configuration()
    config.queueLimit = 10
    let fixture = Fixture(configuration: config)
    fixture.connection.emitObserveState(cols: 80, rows: 24, "")
    let first = try #require(await fixture.nextFrame())
    #expect(first.epoch == 1)

    // Nobody pulls while 12 bytes arrive: over the limit.
    fixture.connection.emit(.output, "aaaaaa")
    fixture.connection.emit(.output, "bbbbbb")
    #expect(await fixture.wait { fixture.connection.commands.count == 2 })
    #expect(fixture.connection.commands == ["observe:1000", "observe:1000"])
    fixture.connection.emit(.output, "dropped until the snapshot")
    fixture.connection.emitObserveState(cols: 100, rows: 30, "X")

    let reset = try #require(await fixture.nextFrame())
    #expect(reset.payload == .reset(cols: 100, rows: 30, fidelity: .exact))
    #expect(reset.epoch == 2)
    #expect(reset.seq == 2)
    let repaint = try #require(await fixture.nextFrame())
    #expect(repaint.payload == .output(Data("X".utf8)))
    #expect(repaint.epoch == 2)
  }

  @Test(.timeLimit(.minutes(1)))
  func daemonEOFBecomesExitedAndEndsTheStream() async throws {
    let fixture = Fixture()
    fixture.connection.emitObserveState(cols: 80, rows: 24, "")
    _ = await fixture.nextFrame()

    fixture.connection.emit(.output, "last words")
    fixture.connection.finish(error: nil)
    #expect(try #require(await fixture.nextFrame()).payload == .output(Data("last words".utf8)))
    #expect(try #require(await fixture.nextFrame()).payload == .exited(reason: "sessionEnded", exitCode: nil))
    #expect(await fixture.session.next() == nil)
    #expect(fixture.connection.closeCount >= 1)
    #expect(fixture.ended.value)
  }

  @Test(.timeLimit(.minutes(1)))
  func framesBufferedAfterAProtocolErrorCannotDropTheExit() async throws {
    var config = PaneStreamSession.Configuration()
    config.queueLimit = 4
    let fixture = Fixture(configuration: config)
    fixture.connection.emitObserveState(cols: 80, rows: 24, "")
    _ = await fixture.nextFrame()

    // A resize payload too short to decode, then output the connection
    // had already buffered: enough to overflow the queue if it were taken.
    fixture.connection.emit(.observeResize, "x")
    fixture.connection.emit(.output, "buffered")
    fixture.connection.emit(.output, "behind it")
    #expect(try #require(await fixture.nextFrame()).payload == .exited(reason: "protocolError", exitCode: nil))
    #expect(await fixture.session.next() == nil)
    #expect(fixture.connection.commands == ["observe:1000"])
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellingTheConsumerClosesTheConnection() async throws {
    let fixture = Fixture()
    fixture.connection.emitObserveState(cols: 80, rows: 24, "")
    _ = await fixture.nextFrame()

    let pending = Task { await fixture.session.next() }
    await Task.megaYield()
    pending.cancel()
    #expect(await pending.value == nil)
    #expect(await fixture.wait { fixture.connection.closeCount >= 1 })
    #expect(await fixture.wait { fixture.ended.value })
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellingTheJSONStreamClosesTheConnection() async throws {
    let fixture = Fixture()
    fixture.connection.emitObserveState(cols: 80, rows: 24, "")
    let consumer = Task {
      var count = 0
      for await _ in fixture.session.jsonFrames() { count += 1 }
      return count
    }
    #expect(await fixture.wait { fixture.connection.commands.count == 1 })
    consumer.cancel()
    _ = await consumer.value
    #expect(await fixture.wait { fixture.connection.closeCount >= 1 })
    #expect(await fixture.wait { fixture.ended.value })
  }

  @Test(.timeLimit(.minutes(1)))
  func quietStreamSendsHeartbeats() async throws {
    let fixture = Fixture()
    fixture.connection.emitObserveState(cols: 80, rows: 24, "")
    _ = await fixture.nextFrame()
    let frame = try #require(await fixture.nextFrame(step: .seconds(30)))
    #expect(frame.payload == .heartbeat)
  }

  @Test(.timeLimit(.minutes(1)))
  func oldDaemonFallsBackToAnApproximateHistorySnapshot() async throws {
    let fixture = Fixture(gridSize: .init(cols: 90, rows: 20))
    let pull = fixture.pull()
    // The daemon ignores `.observe`; after 300 ms the session asks for history.
    for _ in 0..<40 where fixture.connection.commands.count < 2 {
      await Task.megaYield()
      await fixture.clock.advance(by: .milliseconds(50))
    }
    #expect(fixture.connection.commands == ["observe:1000", "history"])
    fixture.connection.emit(.output, "dropped")
    fixture.connection.emit(.history, "HIST")

    #expect(await fixture.finish(pull)?.payload == .reset(cols: 90, rows: 20, fidelity: .approximate))
    #expect(
      try #require(await fixture.nextFrame()).payload
        == .output(Data("HIST".utf8) + PaneStreamSession.historySnapshotSuffix))

    // A resize on the Mac cannot be observed through `.history`, so the
    // session takes a new snapshot once the grid settles.
    await fixture.session.geometryChanged()
    await fixture.session.geometryChanged()
    for _ in 0..<20 where fixture.connection.commands.count < 3 {
      await Task.megaYield()
      await fixture.clock.advance(by: .milliseconds(50))
    }
    #expect(fixture.connection.commands == ["observe:1000", "history", "history"])
  }

  @Test(.timeLimit(.minutes(1)))
  func observerDaemonIgnoresGeometryChanges() async throws {
    let fixture = Fixture()
    fixture.connection.emitObserveState(cols: 80, rows: 24, "")
    _ = await fixture.nextFrame()
    await fixture.session.geometryChanged()
    await fixture.clock.advance(by: .seconds(1))
    await Task.megaYield()
    #expect(fixture.connection.commands == ["observe:1000"])
  }

  @Test
  func requestedSettingsAreClamped() {
    let low = PaneStreamSession.Configuration.clamped(scrollbackRows: -5, coalesceMillis: 1)
    #expect(low.scrollbackRows == 0)
    #expect(low.coalesceWindow == .milliseconds(8))
    let high = PaneStreamSession.Configuration.clamped(scrollbackRows: 1_000_000, coalesceMillis: 5000)
    #expect(high.scrollbackRows == 5000)
    #expect(high.coalesceWindow == .milliseconds(100))
    let defaults = PaneStreamSession.Configuration.clamped(scrollbackRows: nil, coalesceMillis: nil)
    #expect(defaults.scrollbackRows == 1000)
    #expect(defaults.coalesceWindow == .milliseconds(16))
  }

  // MARK: - Against a daemon socket

  @Test(.timeLimit(.minutes(1)))
  func realClientObservesAndHangsUpOnEnd() async throws {
    let daemon = try FakeZmxDaemon()
    defer { daemon.shutdown() }
    let client = try ZmxStreamClient(socketPath: daemon.socketPath)
    let session = PaneStreamSession(connection: client)
    #expect(await daemon.waitForClient())

    let first = Task { await session.next() }
    #expect(await daemon.waitForFrame(.observe) != nil)
    let state = ZmxObserveStatePayload(rows: 24, cols: 80, state: Data("hello".utf8))
    try daemon.send(ZmxFrame(tag: .observeState, payload: state.encode()))
    #expect(await first.value?.payload == .reset(cols: 80, rows: 24, fidelity: .exact))
    #expect(await session.next()?.payload == .output(Data("hello".utf8)))

    await session.end()
    #expect(await daemon.wait { daemon.sawClientClose })
    #expect(Set(daemon.receivedTags).isSubset(of: [.observe, .history]))
  }

  // MARK: - Fixture

  private struct Fixture {
    let connection = FakeObserverConnection()
    let clock = TestClock<Duration>()
    let ended = LockIsolated(false)
    let session: PaneStreamSession

    init(
      configuration: PaneStreamSession.Configuration = .init(),
      gridSize: PaneStreamSession.GridSize? = nil
    ) {
      let ended = self.ended
      session = PaneStreamSession(
        connection: connection,
        configuration: configuration,
        clock: clock,
        gridSize: { gridSize },
        onEnd: { ended.setValue(true) }
      )
    }

    struct Pull {
      let task: Task<IPC.TerminalStreamFrame?, Never>
      let delivered: LockIsolated<Bool>
    }

    func pull() -> Pull {
      let delivered = LockIsolated(false)
      let task = Task { [session] in
        let frame = await session.next()
        delivered.setValue(true)
        return frame
      }
      return Pull(task: task, delivered: delivered)
    }

    /// Steps the test clock until `pull` delivers. Timers are armed
    /// asynchronously, so a single `advance` could land before a sleep is
    /// registered; stepping until delivery removes that race.
    func finish(_ pull: Pull, step: Duration = .milliseconds(16)) async -> IPC.TerminalStreamFrame? {
      for _ in 0..<200 where !pull.delivered.value {
        await Task.megaYield()
        await clock.advance(by: step)
      }
      return await pull.task.value
    }

    func nextFrame(step: Duration = .milliseconds(16)) async -> IPC.TerminalStreamFrame? {
      await finish(pull(), step: step)
    }

    func waitForLiveBytes(_ bytes: Int) async {
      for _ in 0..<1000 where await session.queuedLiveBytes != bytes {
        await Task.megaYield()
      }
    }

    func wait(until condition: () -> Bool) async -> Bool {
      for _ in 0..<1000 where !condition() {
        await Task.megaYield()
        try? await Task.sleep(for: .milliseconds(1))
      }
      return condition()
    }
  }
}

/// Scripted observer connection: the test plays the daemon's frames and
/// reads back what the session asked for.
final class FakeObserverConnection: ZmxObserverConnection, @unchecked Sendable {
  let events: AsyncStream<ZmxStreamClient.Event>
  private let continuation: AsyncStream<ZmxStreamClient.Event>.Continuation
  private let state = LockIsolated<(commands: [String], closeCount: Int)>(([], 0))

  init() {
    (events, continuation) = AsyncStream.makeStream(of: ZmxStreamClient.Event.self)
  }

  var commands: [String] { state.value.commands }
  var closeCount: Int { state.value.closeCount }

  func observe(scrollbackRows: UInt32) {
    state.withValue { $0.commands.append("observe:\(scrollbackRows)") }
  }

  func requestHistory() {
    state.withValue { $0.commands.append("history") }
  }

  func close() {
    state.withValue { $0.closeCount += 1 }
    continuation.finish()
  }

  func emit(_ tag: ZmxTag, _ text: String) {
    continuation.yield(.frame(ZmxFrame(tag: tag, payload: Data(text.utf8))))
  }

  func emitObserveState(cols: UInt16, rows: UInt16, _ text: String) {
    let payload = ZmxObserveStatePayload(rows: rows, cols: cols, state: Data(text.utf8))
    continuation.yield(.frame(ZmxFrame(tag: .observeState, payload: payload.encode())))
  }

  func emitObserveResize(cols: UInt16, rows: UInt16) {
    continuation.yield(.frame(ZmxFrame(tag: .observeResize, payload: ZmxResizePayload(cols: cols, rows: rows).encode())))
  }

  func finish(error: (any Error)?) {
    continuation.yield(.closed(error))
    continuation.finish()
  }
}
