import CodansCore
import Darwin
import Foundation
import Testing

@testable import Codans

/// A stand-in zmx daemon for many watchers: a listening socket that records the clients it
/// accepts and can broadcast frames to them.
private final class BroadcastingZmxDaemon: @unchecked Sendable {
  let path: String
  private var listener: Int32
  private let lock = NSLock()
  private var clients: [Int32] = []
  private var acceptThread: Thread?

  init() {
    path = "/tmp/czw-\(UUID().uuidString.prefix(8)).sock"
    listener = ListeningUnixSocket.bind(at: path)
    // A full backlog refuses connects on macOS; room for every watcher.
    _ = Darwin.listen(listener, 256)
    startAccepting()
  }

  private func startAccepting() {
    let listener = self.listener
    let thread = Thread { [weak self] in
      while true {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        guard let self else {
          Darwin.close(fd)
          return
        }
        self.lock.withLock { self.clients.append(fd) }
      }
    }
    acceptThread = thread
    thread.start()
  }

  var clientCount: Int { lock.withLock { clients.count } }

  /// Queue as many frames as the socket takes without blocking, after
  /// enlarging the send buffer. Returns how many frames went out whole.
  func preload(_ frames: [ZmxFrame]) -> Int {
    lock.withLock {
      guard let fd = clients.first else { return 0 }
      var size: Int32 = 4 * 1024 * 1024
      _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
      _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
      var sent = 0
      for frame in frames {
        let data = ZmxFraming.encode(frame)
        let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard n == data.count else { break }
        sent += 1
      }
      return sent
    }
  }

  func broadcast(_ frame: ZmxFrame) {
    let data = ZmxFraming.encode(frame)
    lock.withLock {
      for fd in clients {
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      }
    }
  }

  /// Bytes the clients sent, read without blocking.
  func bytesFromClients() -> Int {
    lock.withLock {
      clients.reduce(0) { total, fd in
        var buf = [UInt8](repeating: 0, count: 256)
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&pfd, 1, 0) > 0 else { return total }
        return total + max(0, Darwin.read(fd, &buf, buf.count))
      }
    }
  }

  /// Like `DetachAll`: drop every client, keep listening.
  func dropClients() {
    lock.withLock {
      for fd in clients { Darwin.close(fd) }
      clients.removeAll()
    }
  }

  /// Like a daemon exit: drop clients, stop listening, remove the socket.
  func exit() {
    dropClients()
    Darwin.shutdown(listener, SHUT_RDWR)
    Darwin.close(listener)
    listener = -1
    Darwin.unlink(path)
  }
}

/// Thread-safe event sink.
private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [ZmxPassiveWatcher.Event] = []

  func append(_ event: ZmxPassiveWatcher.Event) { lock.withLock { events.append(event) } }
  var all: [ZmxPassiveWatcher.Event] { lock.withLock { events } }
  var signals: [DetachedPaneSignal] {
    all.flatMap { event -> [DetachedPaneSignal] in
      if case .signals(let s) = event { return s }
      return []
    }
  }
}

private func waitUntil(
  timeout: TimeInterval = 3, _ condition: () -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() {
    guard Date() < deadline else { return }
    try await Task.sleep(for: .milliseconds(10))
  }
}

private let fastBackoff = ZmxPassiveWatcher.Backoff(
  initialDelay: 0.02, maxDelay: 0.1, refusalsUntilGone: 3)

struct ZmxPassiveWatcherTests {
  private func output(_ text: String) -> ZmxFrame {
    ZmxFrame(tag: .output, payload: Data(text.utf8))
  }

  @Test
  func readsOutputFramesAndNeverWrites() async throws {
    let daemon = BroadcastingZmxDaemon()
    defer { daemon.exit() }
    let log = EventLog()
    let watcher = ZmxPassiveWatcher(socketPath: daemon.path, backoff: fastBackoff) {
      log.append($0)
    }
    watcher.start()
    defer { watcher.stop() }
    try await waitUntil { daemon.clientCount == 1 && watcher.isConnected }

    daemon.broadcast(ZmxFrame(tag: .resize))
    daemon.broadcast(output("\u{1B}]7501;state=working:app=claude-code\u{1B}"))
    daemon.broadcast(output("\\\u{1B}]0;title\u{07}"))
    try await waitUntil { log.signals.count == 2 }

    #expect(
      log.signals == [
        .programStatus(ProgramStatusReport(state: .working, app: "claude-code")),
        .title("title"),
      ])
    #expect(daemon.bytesFromClients() == 0)
  }

  @Test
  func reconnectsAfterTheDaemonDropsAllClients() async throws {
    let daemon = BroadcastingZmxDaemon()
    defer { daemon.exit() }
    let log = EventLog()
    let watcher = ZmxPassiveWatcher(socketPath: daemon.path, backoff: fastBackoff) {
      log.append($0)
    }
    watcher.start()
    defer { watcher.stop() }
    try await waitUntil { daemon.clientCount == 1 }

    daemon.dropClients()
    try await waitUntil { daemon.clientCount == 1 }
    try await waitUntil { watcher.isConnected }
    daemon.broadcast(output("\u{1B}]2;again\u{07}"))
    try await waitUntil { !log.signals.isEmpty }

    #expect(log.signals == [.title("again")])
    #expect(!log.all.contains(.daemonGone))
  }

  @Test
  func reportsDaemonGoneWhenTheSocketDisappears() async throws {
    let daemon = BroadcastingZmxDaemon()
    let log = EventLog()
    let watcher = ZmxPassiveWatcher(socketPath: daemon.path, backoff: fastBackoff) {
      log.append($0)
    }
    watcher.start()
    defer { watcher.stop() }
    try await waitUntil { daemon.clientCount == 1 }

    daemon.exit()
    try await waitUntil { log.all.contains(.daemonGone) }

    #expect(log.all == [.daemonGone])
    #expect(!watcher.isConnected)
  }

  @Test
  func reportsDaemonGoneWhenNoDaemonListens() async throws {
    let log = EventLog()
    let watcher = ZmxPassiveWatcher(
      socketPath: "/tmp/czw-missing-\(UUID().uuidString.prefix(8)).sock", backoff: fastBackoff
    ) { log.append($0) }
    watcher.start()
    try await waitUntil { log.all.contains(.daemonGone) }
    #expect(log.all == [.daemonGone])
  }

  @Test
  func stopClosesTheSocketAndSilencesTheWatcher() async throws {
    let daemon = BroadcastingZmxDaemon()
    let log = EventLog()
    let watcher = ZmxPassiveWatcher(socketPath: daemon.path, backoff: fastBackoff) {
      log.append($0)
    }
    watcher.start()
    try await waitUntil { watcher.isConnected }

    watcher.stop()
    #expect(!watcher.isConnected)
    daemon.broadcast(output("\u{1B}]0;late\u{07}"))
    daemon.exit()
    try await Task.sleep(for: .milliseconds(200))

    #expect(log.all.isEmpty)
  }

  /// One read callback handles a bounded batch, so a busy pane cannot hold
  /// the shared queue (or a main-actor `stop()`) for its whole backlog.
  @Test
  func drainsALargeBacklogInBoundedBatches() async throws {
    let daemon = BroadcastingZmxDaemon()
    defer { daemon.exit() }
    let log = EventLog()
    let queue = DispatchQueue(label: "test.watcher")
    let watcher = ZmxPassiveWatcher(
      socketPath: daemon.path, queue: queue, backoff: fastBackoff, readsPerEvent: 1
    ) { log.append($0) }
    watcher.start()
    defer { watcher.stop() }
    try await waitUntil { daemon.clientCount == 1 && watcher.isConnected }

    // Each frame is larger than one 64 KiB read and ends with a title.
    let padding = String(repeating: "x", count: 70 * 1024)
    let frames = (0..<8).map { output(padding + "\u{1B}]0;t\($0)\u{07}") }
    queue.suspend()
    let sent = daemon.preload(frames)
    queue.resume()
    try #require(sent >= 2)
    try await waitUntil { log.signals.count == sent }

    #expect(log.signals == (0..<sent).map { .title("t\($0)") })
    #expect(log.all.count >= 2)
  }

  /// Cost check: many watchers share one queue and need no thread each.
  @Test
  func manyWatchersShareOneQueue() async throws {
    let daemon = BroadcastingZmxDaemon()
    defer { daemon.exit() }
    let log = EventLog()
    let watchers = (0..<100).map { _ in
      ZmxPassiveWatcher(socketPath: daemon.path, backoff: fastBackoff) { log.append($0) }
    }
    watchers.forEach { $0.start() }
    defer { watchers.forEach { $0.stop() } }
    try await waitUntil { daemon.clientCount == 100 }

    daemon.broadcast(output("\u{1B}]0;all\u{07}"))
    try await waitUntil { log.signals.count == 100 }

    #expect(log.signals.count == 100)
  }
}
