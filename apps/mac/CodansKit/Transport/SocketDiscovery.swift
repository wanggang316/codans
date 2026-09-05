import CodansCore
import Darwin
import Foundation

/// Resolve the codans Unix socket path from the CLI's side. The spellings
/// come from `BuildChannel`, which the app-side `SocketPaths` reads too, so
/// the two cannot drift.
///
/// This resolver has no foreign-channel guard, and must not grow one: a CLI
/// run inside a pane is *supposed* to dial whatever socket that pane's host
/// exported, whichever channel the host is. The guard belongs only to an app
/// deciding which socket to *bind* — see `SocketPaths.resolve`.
public enum SocketDiscovery {
  public static func productionSocketPath(uid: uid_t = getuid()) -> String {
    BuildChannel.release.socketPath(uid: uid)
  }

  public static func developmentSocketPath(uid: uid_t = getuid()) -> String {
    BuildChannel.development.socketPath(uid: uid)
  }

  public static func defaultSocketPath(uid: uid_t = getuid()) -> String {
    BuildChannel.current.socketPath(uid: uid)
  }

  /// Precedence: an explicit `override` (a `--socket` flag), then
  /// `$CODANS_SOCKET_PATH`, then the build default.
  ///
  /// The environment is consulted in the body rather than as a default
  /// argument. As a default it silently dropped out whenever a caller passed
  /// its own optional through — `resolve(override: flag)` with no flag
  /// supplies an explicit `nil`, which replaces the default and skipped the
  /// env lookup entirely. Every CLI command run inside a Debug app's pane
  /// then dialled the Release socket, because the pane exports
  /// `CODANS_SOCKET_PATH` for exactly this purpose and it was ignored.
  public static func resolve(
    override: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    if let override, !override.isEmpty { return override }
    if let fromEnvironment = environment["CODANS_SOCKET_PATH"], !fromEnvironment.isEmpty {
      return fromEnvironment
    }
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
