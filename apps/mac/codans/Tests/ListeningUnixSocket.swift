import Darwin
import Foundation

/// Bind + listen a throwaway AF_UNIX socket so `SessionReaper.probe`'s
/// `connect(2)` sees a live daemon. Returns the fd; the caller closes it
/// and removes the path. Keep paths short: `sun_path` caps at ~104 bytes.
enum ListeningUnixSocket {
  static func bind(at path: String) -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    precondition(fd >= 0, "socket() failed")
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    // Copy the path into a local buffer first, then memcpy into sun_path —
    // mirrors `SessionReaper.probe` and avoids overlapping exclusive access
    // to `addr` that a nested `withCString` + `withUnsafeMutablePointer`
    // would trigger under Swift's exclusivity checker.
    let pathBytes = Array(path.utf8CString)
    precondition(pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path), "socket path too long")
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
        pathBytes.withUnsafeBufferPointer { src in
          _ = memcpy(dst, src.baseAddress, pathBytes.count)
        }
      }
    }
    _ = Darwin.unlink(path)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    precondition(bound == 0, "bind() failed errno=\(errno)")
    precondition(Darwin.listen(fd, 1) == 0, "listen() failed")
    return fd
  }
}
