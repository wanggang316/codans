import Darwin
import Foundation

/// Shared path convention for the codans Unix domain socket.
///
/// Centralises the default-path-vs-env-override precedence so both the
/// app-side `SocketServer` and the CLI-side `SocketDiscovery` (M4) agree on
/// exactly one place. No inline `getuid()` calls elsewhere.
public nonisolated enum SocketPaths {
  /// `/tmp/codans-<uid>.sock` — the production default.
  public static func productionSocketPath(uid: uid_t = getuid()) -> String {
    "/tmp/codans-\(uid).sock"
  }

  /// `/tmp/codans-dev-<uid>.sock` — the Debug/development default.
  public static func developmentSocketPath(uid: uid_t = getuid()) -> String {
    "/tmp/codans-dev-\(uid).sock"
  }

  /// Build-channel-aware default. Debug builds use the development socket;
  /// Release builds use the production socket.
  public static func defaultSocketPath(uid: uid_t = getuid()) -> String {
    #if DEBUG
      developmentSocketPath(uid: uid)
    #else
      productionSocketPath(uid: uid)
    #endif
  }

  /// Resolve the socket path, preferring `$CODANS_SOCKET_PATH` if set
  /// and non-empty, otherwise falling back to `defaultSocketPath()`.
  public static func resolve(
    override: String? = ProcessInfo.processInfo.environment["CODANS_SOCKET_PATH"]
  ) -> String {
    if let override, !override.isEmpty { return override }
    return defaultSocketPath()
  }
}
