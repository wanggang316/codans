import Darwin
import Foundation
import os

/// Defense-in-depth peer authorisation for accepted Unix-socket
/// connections. The socket inode is already `chmod 0600 + owner UID`
/// by `SocketServer.start`, so at the filesystem level only the server
/// UID can `connect(2)`; this helper adds a process-level cross-check
/// using `getpeereid(3)` (Darwin) to reject any peer whose real UID
/// doesn't match the server's UID.
///
/// Guards against two scenarios the file mode alone can miss:
///   1. A misconfigured filesystem ignores mode bits (e.g. a mounted
///      tmpfs or a user-namespaced sandbox).
///   2. The socket path was moved / chmod'd by another process
///      between `start` and `accept` (TOCTOU tail).
///
/// Called from `SocketServer.startConnection` on each accepted fd.
/// Failure closes the fd before any framing / handshake work runs.
nonisolated enum SocketPeerAuth {
  enum Failure: Error, Equatable {
    case getpeereidFailed(errno: Int32)
    case uidMismatch(expected: uid_t, got: uid_t)
  }

  /// Extract the peer's effective UID from the kernel. Returns nil on
  /// any `getpeereid` error (the caller should treat nil as
  /// untrusted).
  static func peerUID(fd: Int32) -> uid_t? {
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    let result = getpeereid(fd, &peerUID, &peerGID)
    return result == 0 ? peerUID : nil
  }

  /// Authorise `fd`. Default `expectedUID` is the server process's
  /// own UID — reject anything else.
  static func authorize(
    fd: Int32,
    expectedUID: uid_t = getuid()
  ) -> Result<Void, Failure> {
    guard let peer = peerUID(fd: fd) else {
      return .failure(.getpeereidFailed(errno: errno))
    }
    guard peer == expectedUID else {
      return .failure(.uidMismatch(expected: expectedUID, got: peer))
    }
    return .success(())
  }
}
