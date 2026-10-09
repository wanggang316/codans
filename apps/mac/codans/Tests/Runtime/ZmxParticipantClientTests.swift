import Foundation
import Testing

@testable import Codans

/// `ZmxParticipantClient` against a fake daemon socket: it introduces the
/// seat with its size, answers the daemon's size request (sent to a new
/// leader) with its current size, and forwards input, claim and release.
@Suite(.serialized)
struct ZmxParticipantClientTests {
  @Test(.timeLimit(.minutes(1)))
  func introducesItselfAndAnswersTheLeadersSizeRequest() async throws {
    let daemon = try FakeZmxDaemon()
    defer { daemon.shutdown() }
    let seat = try ZmxParticipantClient(socketPath: daemon.socketPath, cols: 58, rows: 36)
    defer { seat.close() }
    #expect(await daemon.waitForClient())

    let hello = try #require(await daemon.waitForFrame(.`init`))
    #expect(hello.payload == ZmxResizePayload(cols: 58, rows: 36).encode())

    // Output every terminal client gets is dropped, not an error.
    try daemon.send(ZmxFrame(tag: .output, payload: Data("hello".utf8)))
    seat.setSize(cols: 60, rows: 40)
    // The daemon made the seat its leader and asks for its size.
    try daemon.send(ZmxFrame(tag: .resize))
    var events = seat.events.makeAsyncIterator()
    #expect(await events.next() == .becameLeader)
    let answers = await daemon.wait { daemon.receivedFrames.filter { $0.tag == .resize }.count >= 2 }
    #expect(answers)
    let lastAnswer = daemon.receivedFrames.filter { $0.tag == .resize }.last
    #expect(lastAnswer?.payload == ZmxResizePayload(cols: 60, rows: 40).encode())
  }

  @Test(.timeLimit(.minutes(1)))
  func forwardsInputClaimAndRelease() async throws {
    let daemon = try FakeZmxDaemon()
    defer { daemon.shutdown() }
    let seat = try ZmxParticipantClient(socketPath: daemon.socketPath, cols: 80, rows: 24)
    defer { seat.close() }
    #expect(await daemon.waitForClient())

    seat.sendInput(Data("ls\r".utf8))
    seat.sendInput(Data())
    seat.claim()
    seat.release()
    #expect(await daemon.waitForFrame(.release) != nil)
    #expect(daemon.receivedTags == [.`init`, .input, .claim, .release])
    #expect(daemon.receivedFrames[1].payload == Data("ls\r".utf8))
  }

  @Test(.timeLimit(.minutes(1)))
  func reportsTheDaemonGoingAway() async throws {
    let daemon = try FakeZmxDaemon()
    let seat = try ZmxParticipantClient(socketPath: daemon.socketPath, cols: 80, rows: 24)
    defer { seat.close() }
    #expect(await daemon.waitForClient())
    daemon.disconnectClient()
    var events = seat.events.makeAsyncIterator()
    #expect(await events.next() == .closed)
    daemon.shutdown()
  }
}
