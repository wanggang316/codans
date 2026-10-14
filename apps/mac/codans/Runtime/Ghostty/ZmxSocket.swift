import Darwin
import Foundation

/// Blocking `AF_UNIX` helpers shared by every client of a zmx daemon's
/// control socket: the one-shot `ZmxControlClient` queries and the
/// long-lived `ZmxStreamClient` observer.
nonisolated enum ZmxSocket {
  enum SocketError: Error, Equatable, Sendable {
    case socketCreateFailed(errno: Int32)
    case pathTooLong(String)
    case connectFailed(errno: Int32)
  }

  /// Opens a blocking connection to `socketPath`. `SO_NOSIGPIPE` is set so
  /// a daemon that exits mid-write surfaces as `EPIPE`, not a signal.
  static func openConnection(socketPath: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { throw SocketError.socketCreateFailed(errno: errno) }
    var noSigPipe: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(fd)
      throw SocketError.pathTooLong(socketPath)
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
        pathBytes.withUnsafeBufferPointer { src in
          _ = memcpy(dst, src.baseAddress, pathBytes.count)
        }
      }
    }
    let connected = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if connected < 0 {
      let err = errno
      Darwin.close(fd)
      throw SocketError.connectFailed(errno: err)
    }
    return fd
  }

  /// Writes all of `data`, retrying short writes and `EINTR`. On a
  /// non-blocking fd, `EAGAIN` waits for writability with `poll`.
  static func sendAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      var off = 0
      while off < raw.count {
        let n = Darwin.send(fd, base + off, raw.count - off, 0)
        if n < 0 {
          let err = errno
          if err == EINTR { continue }
          if err == EAGAIN || err == EWOULDBLOCK {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = withUnsafeMutablePointer(to: &pfd) { Darwin.poll($0, 1, 1000) }
            continue
          }
          throw SocketError.connectFailed(errno: err)
        }
        off += n
      }
    }
  }
}
