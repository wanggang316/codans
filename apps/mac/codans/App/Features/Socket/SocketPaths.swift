import CodansCore
import Darwin
import Foundation

/// The socket the *app* binds and advertises. Spellings come from
/// `BuildChannel`, shared with the CLI-side `SocketDiscovery`; what is
/// specific to this side is the foreign-channel guard in `resolve`.
public nonisolated enum SocketPaths {
  /// `/tmp/codans-<uid>.sock` — the production default.
  public static func productionSocketPath(uid: uid_t = getuid()) -> String {
    BuildChannel.release.socketPath(uid: uid)
  }

  /// `/tmp/codans-dev-<uid>.sock` — the Debug/development default.
  public static func developmentSocketPath(uid: uid_t = getuid()) -> String {
    BuildChannel.development.socketPath(uid: uid)
  }

  /// This build's own socket.
  public static func defaultSocketPath(uid: uid_t = getuid()) -> String {
    BuildChannel.current.socketPath(uid: uid)
  }

  /// Resolve the socket path, preferring `$CODANS_SOCKET_PATH` if set and
  /// non-empty, otherwise falling back to `defaultSocketPath()`.
  ///
  /// One guard: an override equal to the *other* build channel's default
  /// socket is treated as an **inherited** host path and ignored. codans
  /// injects `CODANS_SOCKET_PATH` into every pane it spawns (pointing at its
  /// own socket) so the pane's `codans` CLI dials back to its host. A codans
  /// *app* launched from inside such a pane (e.g. `make mac-run-app` from the
  /// Release app's terminal) inherits it too — and would otherwise bind the
  /// host's socket here, failing with `alreadyInUse` so its own `SocketServer`
  /// never comes up (and advertising the wrong socket to its own panes). If the
  /// override is the other channel's default, it's an inherited host path, not
  /// an override meant for this process: fall back to our own channel default.
  /// An explicit override to any *other* path (isolation, custom dev socket)
  /// is still honored.
  public static func resolve(
    override: String? = ProcessInfo.processInfo.environment["CODANS_SOCKET_PATH"],
    uid: uid_t = getuid()
  ) -> String {
    guard let override, !override.isEmpty else { return defaultSocketPath(uid: uid) }
    if override == foreignChannelDefaultSocketPath(uid: uid) { return defaultSocketPath(uid: uid) }
    return override
  }

  /// The *other* build channel's default socket — the value a child app
  /// inherits via `$CODANS_SOCKET_PATH` when launched from a host app's pane.
  /// Debug's foreign default is the production socket; Release's is the
  /// development socket. Used by `resolve` to discard an inherited host path.
  static func foreignChannelDefaultSocketPath(uid: uid_t = getuid()) -> String {
    BuildChannel.current.other.socketPath(uid: uid)
  }
}
