import Darwin
import Foundation

/// Resolve the codans Unix socket path. Env override wins; default is
/// build-channel aware. Debug builds use `/tmp/codans-dev-<uid>.sock`;
/// Release builds use `/tmp/codans-<uid>.sock`. Must stay in lockstep
/// with the app-side `SocketPaths` helper.
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

  /// Outcome of a single connect(2) probe against a socket path.
  public enum Probe: Equatable, Sendable {
    case reachable
    case unreachable(SocketConnectionFailure)

    public var isReachable: Bool {
      if case .reachable = self { return true }
      return false
    }

    /// Category of the failure, or nil when the probe succeeded. This is
    /// what `codans doctor` reports and what scripts branch on.
    public var failure: SocketConnectionFailure? {
      if case .unreachable(let failure) = self { return failure }
      return nil
    }
  }

  /// Dial `path` once and classify the outcome. Uses the same dial path as
  /// the live transport, so a probe cannot disagree with what a real
  /// command would hit.
  public static func probe(path: String) -> Probe {
    do {
      let fd = try UnixSocketDial.open(path: path)
      Darwin.close(fd)
      return .reachable
    } catch let failure as SocketConnectionFailure {
      return .unreachable(failure)
    } catch {
      return .unreachable(SocketConnectionFailure(kind: .unknown, path: path))
    }
  }

  /// Confirm a server is currently accepting on `path`. Returns true iff
  /// a fresh `connect(2)` succeeds. Prefer `probe(path:)` when the caller
  /// can act on *why* the socket is unreachable.
  public static func isReachable(path: String) -> Bool {
    probe(path: path).isReachable
  }
}
