import Darwin
import Foundation

@testable import Codans

/// A stand-in for a pane's zmx daemon: an `AF_UNIX` listener under /tmp
/// that accepts one client, records every frame it sends, and writes
/// whatever frames the test hands it. Frames are decoded strictly, so a
/// client that sends an unknown tag fails the recording loudly.
///
/// The socket path is short on purpose: `sun_path` caps at 104 bytes.
final class FakeZmxDaemon: @unchecked Sendable {
  let socketPath: String
  private let listenFD: Int32
  private let lock = NSLock()
  private var clientFD: Int32 = -1
  private var frames: [ZmxFrame] = []
  private var clientClosed = false
  private var decodeError: (any Error)?
  private var isShutdown = false

  init() throws {
    socketPath = "/tmp/zfd-\(UUID().uuidString.prefix(8)).sock"
    unlink(socketPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8CString)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
        bytes.withUnsafeBufferPointer { src in _ = memcpy(dst, src.baseAddress, bytes.count) }
      }
    }
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, listen(fd, 4) == 0 else {
      close(fd)
      throw POSIXError(.EADDRINUSE)
    }
    listenFD = fd
    Thread.detachNewThread { [self] in serve() }
  }

  deinit {
    shutdown()
  }

  /// Every frame the client has sent so far, in order.
  var receivedFrames: [ZmxFrame] {
    lock.withLock { frames }
  }

  var receivedTags: [ZmxTag] {
    receivedFrames.map(\.tag)
  }

  var sawClientClose: Bool {
    lock.withLock { clientClosed }
  }

  var sawUndecodableFrame: Bool {
    lock.withLock { decodeError != nil }
  }

  /// Writes `frame` to the connected client.
  func send(_ frame: ZmxFrame) throws {
    try sendRaw(ZmxFraming.encode(frame))
  }

  func sendRaw(_ data: Data) throws {
    let fd = lock.withLock { clientFD }
    guard fd >= 0 else { throw POSIXError(.ENOTCONN) }
    try data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
        if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        offset += n
      }
    }
  }

  /// Closes the client connection, as a daemon does when its session ends.
  func disconnectClient() {
    lock.withLock {
      if clientFD >= 0 {
        Darwin.shutdown(clientFD, SHUT_RDWR)
      }
    }
  }

  func shutdown() {
    let alreadyShut = lock.withLock {
      defer { isShutdown = true }
      return isShutdown
    }
    guard !alreadyShut else { return }
    lock.withLock {
      if clientFD >= 0 {
        Darwin.shutdown(clientFD, SHUT_RDWR)
      }
    }
    Darwin.shutdown(listenFD, SHUT_RDWR)
    close(listenFD)
    unlink(socketPath)
  }

  /// Polls `condition` until it holds or `timeout` passes.
  func wait(timeout: Duration = .seconds(5), until condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
  }

  func waitForClient(timeout: Duration = .seconds(5)) async -> Bool {
    await wait(timeout: timeout) { lock.withLock { clientFD >= 0 } }
  }

  func waitForFrame(_ tag: ZmxTag, count: Int = 1, timeout: Duration = .seconds(5)) async -> ZmxFrame? {
    _ = await wait(timeout: timeout) { receivedTags.filter { $0 == tag }.count >= count }
    return receivedFrames.filter { $0.tag == tag }.dropFirst(count - 1).first
  }

  // MARK: - Accept thread

  private func serve() {
    let fd = accept(listenFD, nil, nil)
    guard fd >= 0 else { return }
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    lock.withLock { clientFD = fd }
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let n = buffer.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
      if n < 0, errno == EINTR { continue }
      if n <= 0 { break }
      pending.append(contentsOf: buffer.prefix(n))
      do {
        while let frame = try ZmxFraming.decode(buffer: &pending) {
          lock.withLock { frames.append(frame) }
        }
      } catch {
        lock.withLock { decodeError = error }
        break
      }
    }
    lock.withLock {
      clientClosed = true
      close(fd)
      clientFD = -1
    }
  }
}
