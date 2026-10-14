import Foundation
import Testing

@testable import Codans

struct ZmxStreamDecoderTests {
  private static func output(_ text: String) -> ZmxFrame {
    ZmxFrame(tag: .output, payload: Data(text.utf8))
  }

  private static func observeState(cols: UInt16, rows: UInt16, _ text: String) -> ZmxFrame {
    ZmxFrame(
      tag: .observeState,
      payload: ZmxObserveStatePayload(rows: rows, cols: cols, state: Data(text.utf8)).encode())
  }

  private static func observeResize(cols: UInt16, rows: UInt16) -> ZmxFrame {
    ZmxFrame(tag: .observeResize, payload: ZmxResizePayload(cols: cols, rows: rows).encode())
  }

  @Test
  func startAsksForAnObserverSnapshot() {
    var decoder = ZmxStreamDecoder()
    #expect(decoder.start() == .sendObserve)
    #expect(decoder.phase == .syncing(.observe))
  }

  @Test
  func outputBeforeTheSnapshotIsDroppedAndAfterItFlows() throws {
    var decoder = ZmxStreamDecoder()
    _ = decoder.start()
    #expect(try decoder.receive(Self.output("already in the snapshot")) == nil)
    #expect(
      try decoder.receive(Self.observeState(cols: 120, rows: 40, "SNAP"))
        == .snapshot(cols: 120, rows: 40, state: Data("SNAP".utf8)))
    #expect(decoder.phase == .live(.observe))
    #expect(try decoder.receive(Self.output("new")) == .output(Data("new".utf8)))
  }

  @Test
  func resizeIsReportedOnlyOnceLive() throws {
    var decoder = ZmxStreamDecoder()
    _ = decoder.start()
    // While syncing, the snapshot on its way carries the new size.
    #expect(try decoder.receive(Self.observeResize(cols: 90, rows: 20)) == nil)
    _ = try decoder.receive(Self.observeState(cols: 90, rows: 20, ""))
    #expect(try decoder.receive(Self.observeResize(cols: 100, rows: 30)) == .resized(cols: 100, rows: 30))
  }

  @Test
  func framesThatAreNotForAnObserverAreIgnored() throws {
    var decoder = ZmxStreamDecoder()
    _ = decoder.start()
    _ = try decoder.receive(Self.observeState(cols: 80, rows: 24, ""))
    #expect(try decoder.receive(ZmxFrame(tag: .ack)) == nil)
    #expect(try decoder.receive(ZmxFrame(tag: .resize, payload: ZmxResizePayload(cols: 1, rows: 1).encode())) == nil)
    // A `.history` reply nobody asked for (observe mode) is not a snapshot.
    #expect(try decoder.receive(ZmxFrame(tag: .history, payload: Data("H".utf8))) == nil)
    #expect(decoder.phase == .live(.observe))
  }

  @Test
  func fallbackSwitchesToHistoryWhenTheDaemonStaysSilent() throws {
    var decoder = ZmxStreamDecoder()
    _ = decoder.start()
    #expect(decoder.fallbackDeadlinePassed() == .sendHistory)
    #expect(decoder.phase == .syncing(.history))
    #expect(try decoder.receive(Self.output("dropped")) == nil)
    #expect(
      try decoder.receive(ZmxFrame(tag: .history, payload: Data("HIST".utf8)))
        == .historySnapshot(Data("HIST".utf8)))
    #expect(decoder.phase == .live(.history))
    #expect(try decoder.receive(Self.output("live")) == .output(Data("live".utf8)))
    // Resync stays in history mode.
    #expect(decoder.resync() == .sendHistory)
  }

  @Test
  func fallbackDoesNothingOnceTheSnapshotLanded() throws {
    var decoder = ZmxStreamDecoder()
    #expect(decoder.fallbackDeadlinePassed() == nil)
    _ = decoder.start()
    _ = try decoder.receive(Self.observeState(cols: 80, rows: 24, ""))
    #expect(decoder.fallbackDeadlinePassed() == nil)
    #expect(decoder.phase == .live(.observe))
  }

  @Test
  func lateObserverSnapshotWinsOverTheFallback() throws {
    var decoder = ZmxStreamDecoder()
    _ = decoder.start()
    _ = decoder.fallbackDeadlinePassed()
    #expect(try decoder.receive(Self.observeState(cols: 80, rows: 24, "S")) != nil)
    #expect(decoder.phase == .live(.observe))
    // The history reply still in flight is now stale.
    #expect(try decoder.receive(ZmxFrame(tag: .history, payload: Data("H".utf8))) == nil)
  }

  @Test
  func resyncDropsOutputUntilTheNextSnapshot() throws {
    var decoder = ZmxStreamDecoder()
    _ = decoder.start()
    _ = try decoder.receive(Self.observeState(cols: 80, rows: 24, ""))
    #expect(decoder.resync() == .sendObserve)
    #expect(try decoder.receive(Self.output("gap")) == nil)
    #expect(try decoder.receive(Self.observeState(cols: 80, rows: 24, "S2")) != nil)
    #expect(try decoder.receive(Self.output("after")) == .output(Data("after".utf8)))
  }

  @Test
  func nothingIsDeliveredBeforeStart() throws {
    var decoder = ZmxStreamDecoder()
    #expect(try decoder.receive(Self.output("x")) == nil)
    #expect(try decoder.receive(Self.observeState(cols: 1, rows: 1, "")) == nil)
    #expect(decoder.phase == .idle)
  }

  @Test
  func truncatedObserveStateThrows() {
    var decoder = ZmxStreamDecoder()
    _ = decoder.start()
    #expect(throws: ZmxIPCError.self) {
      try decoder.receive(ZmxFrame(tag: .observeState, payload: Data([1, 2, 3])))
    }
  }

  // MARK: - Wire helpers

  @Test
  func observeStatePayloadLayoutIsRowsColsFlags() throws {
    let payload = ZmxObserveStatePayload(rows: 0x0102, cols: 0x0304, flags: 0b11, state: Data([9]))
    let bytes = [UInt8](payload.encode())
    #expect(bytes == [0x02, 0x01, 0x04, 0x03, 0x03, 0x00, 0x00, 0x00, 9])
    let decoded = try ZmxObserveStatePayload.decode(payload.encode())
    #expect(decoded == payload)
    #expect(decoded.isAlternateScreen)
    #expect(decoded.isScrollbackTruncated)
  }

  @Test
  func observePayloadIsLittleEndianRows() {
    #expect([UInt8](ZmxObservePayload(scrollbackRows: 0x0102_0304).encode()) == [4, 3, 2, 1])
  }

  @Test
  func decodeSkippingUnknownDropsNewTagsAndKeepsOrder() throws {
    var buffer = Data()
    buffer.append(ZmxFraming.encode(Self.output("a")))
    // Tag 99 with a 3-byte payload, from a hypothetical newer daemon.
    buffer.append(contentsOf: [99, 3, 0, 0, 0, 0, 0, 0, 7, 7, 7])
    buffer.append(ZmxFraming.encode(Self.output("b")))
    var frames: [ZmxFrame] = []
    while let frame = try ZmxFraming.decodeSkippingUnknown(buffer: &buffer) {
      frames.append(frame)
    }
    #expect(frames == [Self.output("a"), Self.output("b")])
    #expect(buffer.isEmpty)
  }

  @Test
  func decodeSkippingUnknownWaitsForAPartialUnknownFrame() throws {
    var buffer = Data([99, 4, 0, 0, 0, 0, 0, 0, 1])
    #expect(try ZmxFraming.decodeSkippingUnknown(buffer: &buffer) == nil)
    #expect(buffer.count == 9)
    buffer.append(contentsOf: [2, 3, 4])
    buffer.append(ZmxFraming.encode(Self.output("z")))
    #expect(try ZmxFraming.decodeSkippingUnknown(buffer: &buffer) == Self.output("z"))
  }
}
