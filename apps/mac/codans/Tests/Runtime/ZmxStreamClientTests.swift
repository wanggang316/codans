import Foundation
import Testing

@testable import Codans

/// `ZmxStreamClient` against a fake daemon socket. The client must never
/// send anything but `.observe` and `.history`: every other client frame
/// could make it the daemon's leader or type into the pane.
@Suite(.serialized)
struct ZmxStreamClientTests {
  private static let allowedTags: Set<ZmxTag> = [.observe, .history]

  /// Frames from `client` until `enough` says stop or the stream ends.
  private func collectFrames(
    _ client: ZmxStreamClient, until enough: ([ZmxFrame]) -> Bool
  ) async -> [ZmxFrame] {
    var frames: [ZmxFrame] = []
    for await event in client.events {
      guard case .frame(let frame) = event else { break }
      frames.append(frame)
      if enough(frames) { break }
    }
    return frames
  }

  @Test(.timeLimit(.minutes(1)))
  func sendsOnlyObserveAndHistoryAndDeliversFramesInOrder() async throws {
    let daemon = try FakeZmxDaemon()
    defer { daemon.shutdown() }
    let client = try ZmxStreamClient(socketPath: daemon.socketPath)
    defer { client.close() }
    #expect(await daemon.waitForClient())

    client.observe(scrollbackRows: 250)
    client.requestHistory()
    let observe = try #require(await daemon.waitForFrame(.observe))
    #expect(observe.payload == ZmxObservePayload(scrollbackRows: 250).encode())
    let history = try #require(await daemon.waitForFrame(.history))
    #expect(history.payload == Data([ZmxHistoryFormat.vt.rawValue]))

    try daemon.send(ZmxFrame(tag: .output, payload: Data("one".utf8)))
    // A tag this build does not know is skipped, not fatal.
    try daemon.sendRaw(Data([99, 2, 0, 0, 0, 0, 0, 0, 0xAA, 0xBB]))
    let state = ZmxObserveStatePayload(rows: 24, cols: 80, state: Data("S".utf8))
    try daemon.send(ZmxFrame(tag: .observeState, payload: state.encode()))

    let frames = await collectFrames(client) { $0.count == 2 }
    #expect(
      frames == [
        ZmxFrame(tag: .output, payload: Data("one".utf8)),
        ZmxFrame(tag: .observeState, payload: state.encode()),
      ])

    #expect(Set(daemon.receivedTags).isSubset(of: Self.allowedTags))
    #expect(!daemon.sawUndecodableFrame)
  }

  @Test(.timeLimit(.minutes(1)))
  func daemonHangUpEndsTheStreamWithClosed() async throws {
    let daemon = try FakeZmxDaemon()
    defer { daemon.shutdown() }
    let client = try ZmxStreamClient(socketPath: daemon.socketPath)
    #expect(await daemon.waitForClient())

    try daemon.send(ZmxFrame(tag: .output, payload: Data("bye".utf8)))
    daemon.disconnectClient()

    var events: [String] = []
    for await event in client.events {
      switch event {
      case .frame(let frame): events.append("frame:\(String(bytes: frame.payload, encoding: .utf8) ?? "?")")
      case .closed(let error): events.append(error == nil ? "closed" : "failed")
      }
    }
    #expect(events == ["frame:bye", "closed"])
  }

  @Test(.timeLimit(.minutes(1)))
  func closeHangsUpOnTheDaemon() async throws {
    let daemon = try FakeZmxDaemon()
    defer { daemon.shutdown() }
    let client = try ZmxStreamClient(socketPath: daemon.socketPath)
    #expect(await daemon.waitForClient())

    client.close()
    #expect(await daemon.wait { daemon.sawClientClose })
    // The event stream finishes without a `.closed`: the owner asked.
    var sawClosed = false
    for await event in client.events {
      if case .closed = event { sawClosed = true }
    }
    #expect(!sawClosed)
  }

  @Test
  func connectingToAMissingSocketThrows() {
    #expect(throws: ZmxSocket.SocketError.self) {
      _ = try ZmxStreamClient(socketPath: "/tmp/zfd-missing-\(UUID().uuidString.prefix(6)).sock")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func largeBurstsArriveIntact() async throws {
    let daemon = try FakeZmxDaemon()
    defer { daemon.shutdown() }
    let client = try ZmxStreamClient(socketPath: daemon.socketPath)
    defer { client.close() }
    #expect(await daemon.waitForClient())

    let chunk = Data(repeating: 0x41, count: 200 * 1024)
    for _ in 0..<5 {
      try daemon.send(ZmxFrame(tag: .output, payload: chunk))
    }
    let frames = await collectFrames(client) { $0.reduce(0) { $0 + $1.payload.count } >= 5 * chunk.count }
    #expect(frames.reduce(0) { $0 + $1.payload.count } == 5 * chunk.count)
    #expect(frames.allSatisfy { $0.payload.allSatisfy { $0 == 0x41 } })
  }
}
