import Darwin
import Foundation

/// Resolve the codans Unix socket path. Env override wins; default is
/// build-channel aware. Debug builds use `/tmp/codans-dev-<uid>.sock`;
/// Release builds use `/tmp/codans-<uid>.sock`. Mirrors the app-side
/// `SocketPaths` helper — kept in lockstep via the shared convention
/// documented in plan 0003 DEC-3 and the M3.0.1 hardening commit.
public enum SocketDiscovery {
  public static func productionSocketPath(uid: uid_t = getuid()) -> String {
    "/tmp/codans-\(uid).sock"
  }

  public static func developmentSocketPath(uid: uid_t = getuid()) -> String {
    "/tmp/codans-dev-\(uid).sock"
  }

  public static func defaultSocketPath(uid: uid_t = getuid()) -> String {
    #if DEBUG
      developmentSocketPath(uid: uid)
    #else
      productionSocketPath(uid: uid)
    #endif
  }

  public static func resolve(
    override: String? = ProcessInfo.processInfo.environment["CODANS_SOCKET_PATH"]
  ) -> String {
    if let override, !override.isEmpty { return override }
    return defaultSocketPath()
  }

  /// Confirm a server is currently accepting on `path`. Returns true iff
  /// a fresh `connect(2)` succeeds.
  public static func isReachable(path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return false }
    defer { Darwin.close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
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
    return result == 0
  }
}
