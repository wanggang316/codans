import CodansCore
import Darwin
import Foundation

/// Resolve the codans Unix socket path from the CLI's side. The spellings
/// come from `BuildChannel`, which the app-side `SocketPaths` reads too, so
/// the two cannot drift.
///
/// The CLI's name is its channel: `codans` drives the release app and
/// `codans-dev` the development app. `$CODANS_SOCKET_PATH`, which every pane
/// exports naming its own app's socket, refines the target *within* that
/// channel; when it names the other channel's default socket, the wrong CLI
/// was invoked for this pane and `resolve` says so rather than crossing.
public enum SocketDiscovery {
  /// The CLI refused to act on a pane that belongs to the other build
  /// channel. Rendered as exit code `CLIExitCode.wrongChannel` with the
  /// command to use instead.
  public struct ForeignPaneRefusal: Error, Equatable, Sendable {
    /// Channel that owns the pane, per the socket its environment exports.
    public let paneChannel: BuildChannel
    /// The socket the pane exported.
    public let socketPath: String

    public init(paneChannel: BuildChannel, socketPath: String) {
      self.paneChannel = paneChannel
      self.socketPath = socketPath
    }

    public var message: String {
      "this pane belongs to a \(paneChannel.rawValue) build of Codans (\(socketPath)); "
        + "`\(paneChannel.other.slug)` will not act on it"
    }

    public var hint: String {
      "run `\(paneChannel.slug)` here instead, or pass --socket to target the "
        + "\(paneChannel.other.rawValue) app on purpose"
    }
  }

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
  /// An environment value equal to the *other* channel's default socket means
  /// the pane was spawned by the other build, and the two directions differ:
  ///
  /// - The release `codans` inside a development pane **refuses**. Nothing an
  ///   agent types into a development pane may reach the release app by
  ///   accident; the refusal names the command to use instead.
  /// - The development `codans-dev` inside a release pane **ignores** the
  ///   inherited path and dials the development socket. It is the developer's
  ///   tool for the development app, and a release pane is where a developer
  ///   usually runs it from.
  ///
  /// An explicit `--socket` always wins: crossing on purpose is a legitimate
  /// way to drive one app from the other's pane. Any other environment value
  /// is a custom socket and is honoured by both channels.
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
    environment: [String: String] = ProcessInfo.processInfo.environment,
    channel: BuildChannel = .current,
    uid: uid_t = getuid()
  ) throws(ForeignPaneRefusal) -> String {
    if let override, !override.isEmpty { return override }
    guard let fromEnvironment = environment[CodansEnvironment.Key.socketPath.rawValue],
      !fromEnvironment.isEmpty
    else {
      return channel.socketPath(uid: uid)
    }
    if fromEnvironment == channel.other.socketPath(uid: uid) {
      switch channel {
      case .release:
        throw ForeignPaneRefusal(paneChannel: .development, socketPath: fromEnvironment)
      case .development:
        return channel.socketPath(uid: uid)
      }
    }
    return fromEnvironment
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
