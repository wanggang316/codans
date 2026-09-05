import CodansCore
import Darwin
import Foundation

/// Why a connection to the codans command socket failed.
///
/// Agents and shell scripts branch on these categories — via `CLIExitCode`
/// or the `socketStatus` field of `codans doctor --json` — so the raw
/// values are part of the CLI contract and must not change within a major
/// version. A single "cannot connect" bucket forces callers to grep stderr
/// to tell "the app isn't running" (relaunch) apart from "the socket is
/// owned by another uid" (human intervention).
public enum SocketFailureKind: String, Codable, Sendable, CaseIterable {
  /// Nothing exists at the socket path — the app has never run, or its
  /// socket was cleaned up on quit.
  case socketMissing = "socket-missing"
  /// The socket file exists but nobody is listening (stale file left by a
  /// crash, or the app quit without unlinking).
  case appNotRunning = "app-not-running"
  /// The socket exists and has a listener, but this uid may not connect.
  case permissionDenied = "permission-denied"
  /// The path resolves to something that is not a usable stream socket.
  case notASocket = "not-a-socket"
  /// The path exceeds the AF_UNIX `sun_path` limit, so it can never be
  /// connected to regardless of what lives there.
  case pathTooLong = "path-too-long"
  /// The app is listening but its accept backlog is full — transient.
  case serverBusy = "server-busy"
  /// connect(2) itself timed out; the app is up but wedged.
  case timedOut = "timed-out"
  /// The connection was established, then dropped mid-request.
  case connectionLost = "connection-lost"
  /// socket(2) failed before we ever addressed the path — a local
  /// resource problem (fd limit), not a codans problem.
  case socketCreateFailed = "socket-create-failed"
  /// An errno we have not classified. Callers get the raw number.
  case unknown = "unknown"

  /// Whether starting the app plausibly clears this failure. A permission
  /// or wrong-path problem needs a human, so `codans launch` fails fast on
  /// those instead of polling a socket it can never reach.
  public var isResolvedByLaunching: Bool {
    switch self {
    case .socketMissing, .appNotRunning, .connectionLost, .unknown:
      return true
    case .permissionDenied, .notASocket, .pathTooLong, .socketCreateFailed,
      .serverBusy, .timedOut:
      return false
    }
  }
}

/// A classified socket-connection failure: the category, the path we tried,
/// and the raw errno when one exists.
public struct SocketConnectionFailure: Error, Equatable, Sendable {
  public let kind: SocketFailureKind
  public let path: String
  public let errnoValue: Int32?

  public init(kind: SocketFailureKind, path: String, errnoValue: Int32? = nil) {
    self.kind = kind
    self.path = path
    self.errnoValue = errnoValue
  }

  /// Classify a `connect(2)` errno. Anything unmapped stays `.unknown`
  /// rather than being folded into a neighbouring category — a wrong
  /// category is worse for a branching script than an honest "unknown".
  public static func connect(errno code: Int32, path: String) -> Self {
    let kind: SocketFailureKind
    switch code {
    case ENOENT, ENOTDIR, ELOOP: kind = .socketMissing
    case ECONNREFUSED: kind = .appNotRunning
    case EACCES, EPERM: kind = .permissionDenied
    case ENOTSOCK, EPROTOTYPE, EAFNOSUPPORT, EOPNOTSUPP: kind = .notASocket
    case ENAMETOOLONG: kind = .pathTooLong
    case EAGAIN: kind = .serverBusy
    case ETIMEDOUT: kind = .timedOut
    case EPIPE, ECONNRESET, ENOTCONN, ESHUTDOWN: kind = .connectionLost
    default: kind = .unknown
    }
    return Self(kind: kind, path: path, errnoValue: code)
  }

  /// Classify a failure on an already-connected fd. The same errno means
  /// something different here than at connect time: EPIPE before connect
  /// is nonsense, EPIPE after it means the app went away mid-request.
  public static func inFlight(errno code: Int32, path: String) -> Self {
    switch code {
    case EPIPE, ECONNRESET, ENOTCONN, ESHUTDOWN, ENXIO:
      return Self(kind: .connectionLost, path: path, errnoValue: code)
    case ETIMEDOUT:
      return Self(kind: .timedOut, path: path, errnoValue: code)
    default:
      return Self(kind: .unknown, path: path, errnoValue: code)
    }
  }

  /// One-line stderr message. Never ends in punctuation — `CLIError`
  /// renders it as `error: <message>`.
  public var message: String {
    switch kind {
    case .socketMissing:
      return "Codans is not running (no socket at \(path))"
    case .appNotRunning:
      return "Codans is not running (stale socket at \(path))"
    case .permissionDenied:
      return "cannot connect to \(path): permission denied"
    case .notASocket:
      return "\(path) is not a Codans command socket"
    case .pathTooLong:
      return "socket path too long: \(path)"
    case .serverBusy:
      return "Codans is not accepting new connections (accept backlog full)"
    case .timedOut:
      return "connecting to \(path) timed out"
    case .connectionLost:
      return "connection to Codans closed mid-request (\(path))"
    case .socketCreateFailed:
      return "socket(2) failed\(errnoSuffix)"
    case .unknown:
      return "cannot connect to \(path)\(errnoSuffix)"
    }
  }

  /// Actionable next step, rendered as a `  hint: …` line under the error.
  /// Nil where no advice beats silence.
  public var hint: String? {
    switch kind {
    case .socketMissing, .appNotRunning:
      return "start it with `\(CLIInvocation.commandName) launch`"
    case .permissionDenied:
      return "the socket belongs to another user; check `ls -l \(path)` or point CODANS_SOCKET_PATH at your own"
    case .notASocket:
      return "remove that file, or point CODANS_SOCKET_PATH at the real socket"
    case .pathTooLong:
      return "AF_UNIX paths are capped near 104 bytes; set CODANS_SOCKET_PATH to a shorter one"
    case .serverBusy:
      return "retry in a moment"
    case .timedOut:
      return "the app may be wedged; check `\(CLIInvocation.commandName) status`"
    case .connectionLost:
      return "the app may have quit or crashed; check `\(CLIInvocation.commandName) doctor`"
    case .socketCreateFailed, .unknown:
      return nil
    }
  }

  private var errnoSuffix: String {
    guard let errnoValue else { return "" }
    return " (errno=\(errnoValue) \(String(cString: strerror(errnoValue))))"
  }
}
