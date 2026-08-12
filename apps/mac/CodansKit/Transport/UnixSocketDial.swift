import Darwin
import Foundation

/// Opens a connected AF_UNIX stream fd, or throws a classified
/// `SocketConnectionFailure`.
///
/// Both the live transport and `SocketDiscovery.probe` dial the socket the
/// same way; keeping one implementation means a probe can never disagree
/// with the connection an actual command would make. Every call is fully
/// synchronous — `UnixSocketTransport` relies on connect(2) and its first
/// send(2) sharing one block with no scheduler hop (see the comment there).
enum UnixSocketDial {
  /// Connect to `path`. The caller owns the returned fd.
  static func open(path: String) throws -> Int32 {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      throw SocketConnectionFailure(kind: .pathTooLong, path: path)
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 {
      throw SocketConnectionFailure(kind: .socketCreateFailed, path: path, errnoValue: errno)
    }
    // SO_NOSIGPIPE: turn writes to a half-closed peer into EPIPE instead
    // of SIGPIPE-killing the CLI process before any error path can run.
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
        pathBytes.withUnsafeBufferPointer { src in
          _ = memcpy(dst, src.baseAddress, pathBytes.count)
        }
      }
    }
    let result = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if result < 0 {
      let code = errno
      Darwin.close(fd)
      throw SocketConnectionFailure.connect(errno: code, path: path)
    }
    return fd
  }
}
