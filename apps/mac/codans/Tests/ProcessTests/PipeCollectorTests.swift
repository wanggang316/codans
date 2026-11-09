import Darwin
import Foundation
import Testing

@testable import Codans

struct PipeCollectorTests {
  @Test
  func finishReturnsOutputAtEOF() async throws {
    let pipe = Pipe()
    let collector = PipeCollector(pipe: pipe)
    try pipe.fileHandleForWriting.write(contentsOf: Data("hello".utf8))
    try pipe.fileHandleForWriting.close()

    let result = await collector.finish(grace: .seconds(30))

    #expect(String(bytes: result.data, encoding: .utf8) == "hello")
    #expect(result.overflow == false)
  }

  @Test
  func finishStopsAtGraceWhenAnotherWriteEndStaysOpen() async throws {
    // A forked process that inherited the write end keeps the pipe from
    // reaching EOF; the collector must still return what the child wrote.
    let pipe = Pipe()
    let strayWriteEnd = dup(pipe.fileHandleForWriting.fileDescriptor)
    defer { close(strayWriteEnd) }
    let collector = PipeCollector(pipe: pipe)
    try pipe.fileHandleForWriting.write(contentsOf: Data("partial".utf8))
    try pipe.fileHandleForWriting.close()

    let clock = ContinuousClock()
    let start = clock.now
    let result = await collector.finish(grace: .milliseconds(200))

    #expect(String(bytes: result.data, encoding: .utf8) == "partial")
    #expect(clock.now - start < .seconds(5))
  }

  @Test
  func finishBlockingStopsAtGraceWhenAnotherWriteEndStaysOpen() throws {
    let pipe = Pipe()
    let strayWriteEnd = dup(pipe.fileHandleForWriting.fileDescriptor)
    defer { close(strayWriteEnd) }
    let collector = PipeCollector(pipe: pipe)
    try pipe.fileHandleForWriting.write(contentsOf: Data("sync".utf8))
    try pipe.fileHandleForWriting.close()

    let result = collector.finishBlocking(grace: .milliseconds(200))

    #expect(String(bytes: result.data, encoding: .utf8) == "sync")
  }

  @Test
  func bytesPastTheCapAreDiscardedAndFlagged() async throws {
    let pipe = Pipe()
    let collector = PipeCollector(pipe: pipe, maxBytes: 2)
    try pipe.fileHandleForWriting.write(contentsOf: Data("abcd".utf8))
    try pipe.fileHandleForWriting.close()

    let result = await collector.finish(grace: .seconds(30))

    #expect(String(bytes: result.data, encoding: .utf8) == "ab")
    #expect(result.overflow)
  }

  @Test
  func onChunkSeesEveryByte() async throws {
    let pipe = Pipe()
    let seen = LockedData()
    let collector = PipeCollector(pipe: pipe, onChunk: { seen.append($0) })
    try pipe.fileHandleForWriting.write(contentsOf: Data("streamed".utf8))
    try pipe.fileHandleForWriting.close()

    _ = await collector.finish(grace: .seconds(30))

    #expect(String(bytes: seen.value, encoding: .utf8) == "streamed")
  }

  @Test
  func closeOnExecPipeSetsTheFlagOnBothEnds() {
    let pipe = Pipe.closeOnExec()
    for fd in [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor] {
      #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
    }
  }
}

private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  var value: Data { lock.withLock { data } }

  func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
}
