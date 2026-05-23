import Darwin
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

@MainActor
struct ZmxClientTests {
  @Test
  func attachReceivesInitialOutput() async throws {
    let socketPath = Self.tempSocketPath()
    let daemon = MockZmxDaemon(socketPath: socketPath)
    try daemon.start()
    defer { daemon.stop() }

    let paneID = PaneID()
    let client = try await ZmxClient(paneID: paneID, socketPath: socketPath)
    defer { client.close() }

    // Arrange the daemon to send a single `.output` frame as soon as it
    // receives the client's `.init` — that's the contract attach() waits
    // on. Done before attach() to avoid a race where the daemon writes
    // before the client wires its decode loop.
    let helloPayload = Data("hello".utf8)
    daemon.onInit = { [weak daemon] _ in
      daemon?.sendFrame(ZmxFrame(tag: .output, payload: helloPayload))
    }

    try await client.attach(cols: 80, rows: 24)

    // Verify the `.output` payload showed up on the external backend fd.
    let read = try Self.readBytes(
      fd: client.externalBackendFD,
      count: helloPayload.count,
      timeout: 2.0
    )
    #expect(read == helloPayload)
  }

  @Test
  func resizeForwardsFrame() async throws {
    let socketPath = Self.tempSocketPath()
    let daemon = MockZmxDaemon(socketPath: socketPath)
    try daemon.start()
    defer { daemon.stop() }

    let paneID = PaneID()
    let client = try await ZmxClient(paneID: paneID, socketPath: socketPath)
    defer { client.close() }

    // attach() resolves on the first `.output` frame the daemon sends.
    daemon.onInit = { [weak daemon] _ in
      daemon?.sendFrame(ZmxFrame(tag: .output, payload: Data([0x01])))
    }
    try await client.attach(cols: 80, rows: 24)

    let frameArrived = AsyncMessage<ZmxResizePayload>()
    daemon.onResize = { payload in
      Task { await frameArrived.send(payload) }
    }

    client.resize(cols: 132, rows: 43)

    let payload = try await frameArrived.receive(timeout: 2.0)
    #expect(payload == ZmxResizePayload(cols: 132, rows: 43))
  }

  @Test
  func killWaitsForSocketGone() async throws {
    let socketPath = Self.tempSocketPath()
    let daemon = MockZmxDaemon(socketPath: socketPath)
    try daemon.start()

    let paneID = PaneID()
    let client = try await ZmxClient(paneID: paneID, socketPath: socketPath)

    daemon.onKill = { [weak daemon] in
      daemon?.stop()  // removes the socket file
    }

    let killStart = Date()
    await client.kill()
    let killDuration = Date().timeIntervalSince(killStart)

    #expect(killDuration < 2.0)
    #expect(access(socketPath, F_OK) != 0)
  }

  // MARK: - Helpers

  private static func tempSocketPath() -> String {
    let unique = UUID().uuidString.prefix(8)
    // macOS sockaddr_un.sun_path is 104 bytes; keep paths under that cap.
    return "/tmp/zmx-test-\(unique).sock"
  }

  /// Read exactly `count` bytes from `fd`, polling until satisfied or
  /// `timeout` elapses. Uses POLLIN on the file descriptor to avoid
  /// burning CPU between reads.
  private static func readBytes(fd: Int32, count: Int, timeout: TimeInterval) throws -> Data {
    var collected = Data()
    let deadline = Date().addingTimeInterval(timeout)
    var buf = [UInt8](repeating: 0, count: count)
    while collected.count < count {
      let remaining = deadline.timeIntervalSinceNow
      if remaining <= 0 {
        throw MockZmxDaemon.MockError.timeout
      }
      var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let pr = withUnsafeMutablePointer(to: &pfd) {
        Darwin.poll($0, 1, Int32(remaining * 1000))
      }
      if pr <= 0 { throw MockZmxDaemon.MockError.timeout }
      let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
        Darwin.read(fd, ptr.baseAddress, count - collected.count)
      }
      if n > 0 {
        collected.append(contentsOf: buf.prefix(n))
        continue
      }
      if n == 0 { break }
      if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
      throw MockZmxDaemon.MockError.readFailed(errno: errno)
    }
    return collected
  }
}

/// One-shot rendezvous primitive — `send` resolves the next pending
/// `receive`, or buffers a single value if no receiver is waiting.
/// Suitable for the "I expect exactly one event of type X" tests.
actor AsyncMessage<Value: Sendable> {
  private var buffered: Value?
  private var pending: CheckedContinuation<Value, Error>?

  func send(_ value: Value) {
    if let cont = pending {
      pending = nil
      cont.resume(returning: value)
      return
    }
    buffered = value
  }

  func receive(timeout: TimeInterval) async throws -> Value {
    if let value = buffered {
      buffered = nil
      return value
    }
    return try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Value, Error>) in
          Task { await self.installContinuation(cont) }
        }
      }
      group.addTask {
        try await Task.sleep(for: .seconds(timeout))
        throw MockZmxDaemon.MockError.timeout
      }
      guard let value = try await group.next() else {
        throw MockZmxDaemon.MockError.timeout
      }
      group.cancelAll()
      return value
    }
  }

  private func installContinuation(_ cont: CheckedContinuation<Value, Error>) {
    if let value = buffered {
      buffered = nil
      cont.resume(returning: value)
      return
    }
    pending = cont
  }
}

/// Minimal stand-in for the zmx daemon. Binds a Unix-domain socket,
/// accepts the first connection, and decodes incoming frames using the
/// same framing as ``ZmxFraming``. Tests register callbacks for each
/// inbound tag and call ``sendFrame`` to push frames back to the client.
final class MockZmxDaemon: @unchecked Sendable {
  enum MockError: Error, Equatable, Sendable {
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case timeout
    case readFailed(errno: Int32)
  }

  let socketPath: String
  private let lock = NSLock()
  private var listenFD: Int32 = -1
  private var clientFD: Int32 = -1
  private var acceptThread: Thread?
  private var readThread: Thread?
  private var stopped = false

  var onInit: ((ZmxResizePayload) -> Void)?
  var onResize: ((ZmxResizePayload) -> Void)?
  var onInput: ((Data) -> Void)?
  var onSnapshot: (() -> Void)?
  var onDetach: (() -> Void)?
  var onKill: (() -> Void)?

  init(socketPath: String) {
    self.socketPath = socketPath
  }

  func start() throws {
    // Best-effort cleanup of a stale socket file from a previous run.
    unlink(socketPath)

    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { throw MockError.bindFailed(errno: errno) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
        pathBytes.withUnsafeBufferPointer { src in
          _ = memcpy(dst, src.baseAddress, pathBytes.count)
        }
      }
    }
    let bindResult = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if bindResult != 0 {
      let err = errno
      Darwin.close(fd)
      throw MockError.bindFailed(errno: err)
    }
    if Darwin.listen(fd, 1) != 0 {
      let err = errno
      Darwin.close(fd)
      unlink(socketPath)
      throw MockError.listenFailed(errno: err)
    }
    listenFD = fd

    let thread = Thread { [weak self] in self?.acceptLoop() }
    thread.name = "MockZmxDaemon.accept"
    acceptThread = thread
    thread.start()
  }

  func stop() {
    lock.lock()
    if stopped {
      lock.unlock()
      return
    }
    stopped = true
    let lfd = listenFD
    let cfd = clientFD
    listenFD = -1
    clientFD = -1
    lock.unlock()

    if lfd >= 0 {
      _ = Darwin.shutdown(lfd, SHUT_RDWR)
      _ = Darwin.close(lfd)
    }
    if cfd >= 0 {
      _ = Darwin.shutdown(cfd, SHUT_RDWR)
      _ = Darwin.close(cfd)
    }
    unlink(socketPath)
  }

  /// Encode and write a single frame to the connected client. No-op if
  /// the client hasn't connected yet (this should not happen in the
  /// tests; mocks set up onInit/onResize before issuing the client call).
  func sendFrame(_ frame: ZmxFrame) {
    lock.lock()
    let fd = clientFD
    lock.unlock()
    guard fd >= 0 else { return }
    var data = ZmxFraming.encode(frame)
    while !data.isEmpty {
      let written = data.withUnsafeBytes { ptr -> Int in
        Darwin.send(fd, ptr.baseAddress, data.count, 0)
      }
      if written < 0 {
        if errno == EINTR { continue }
        break
      }
      if written == 0 { break }
      data.removeFirst(written)
    }
  }

  private func acceptLoop() {
    let lfd = listenFD
    if lfd < 0 { return }
    var addr = sockaddr_un()
    var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let cfd = withUnsafeMutablePointer(to: &addr) { addrPtr -> Int32 in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.accept(lfd, sockPtr, &addrLen)
      }
    }
    if cfd < 0 { return }
    lock.lock()
    clientFD = cfd
    lock.unlock()

    let thread = Thread { [weak self] in self?.readLoop(fd: cfd) }
    thread.name = "MockZmxDaemon.read"
    readThread = thread
    thread.start()
  }

  private func readLoop(fd: Int32) {
    var pending = Data()
    let bufferSize = 4096
    var raw = [UInt8](repeating: 0, count: bufferSize)
    while true {
      let n = raw.withUnsafeMutableBufferPointer { ptr -> Int in
        Darwin.read(fd, ptr.baseAddress, bufferSize)
      }
      if n > 0 {
        pending.append(contentsOf: raw.prefix(n))
        while true {
          do {
            guard let frame = try ZmxFraming.decode(buffer: &pending) else { break }
            dispatch(frame)
          } catch {
            return
          }
        }
        continue
      }
      if n == 0 { return }
      if errno == EINTR { continue }
      return
    }
  }

  private func dispatch(_ frame: ZmxFrame) {
    switch frame.tag {
    case .`init`:
      if let payload = try? ZmxResizePayload.decode(frame.payload) {
        onInit?(payload)
      }
    case .resize:
      if let payload = try? ZmxResizePayload.decode(frame.payload) {
        onResize?(payload)
      }
    case .input:
      onInput?(frame.payload)
    case .snapshot:
      onSnapshot?()
    case .detach:
      onDetach?()
    case .kill:
      onKill?()
    default:
      break
    }
  }
}
