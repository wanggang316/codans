import Foundation
import CodansIPC

/// Stable CLI exit codes. Agents and shell scripts branch on these
/// values, so they must not change across releases within the same
/// major version.
public enum CLIExitCode: Int32, Sendable {
  case ok = 0
  case userError = 1
  case notFound = 2
  case conflict = 3
  case unsupported = 4
  case overloaded = 5
  case versionMismatch = 6
  case noSocket = 10  // app unreachable: socket missing, stale, or dropped mid-request
  case requestTimeout = 11  // server did not respond within --timeout
  case launchTimeout = 12  // codans launch / auto-launch never saw the socket come up
  case socketPermissionDenied = 13  // socket exists but this uid may not connect
  case socketUnusable = 14  // path is not a usable socket (wrong file, too long, fd exhaustion)
  case `internal` = 20

  /// Map an `IPCError` to the matching exit code. Unknown/novel error
  /// shapes fall to `.internal` rather than silently succeeding.
  public static func from(_ error: IPCError) -> CLIExitCode {
    switch error {
    case .unknownMethod: return .userError
    case .invalidParams: return .userError
    case .notFound: return .notFound
    case .conflict: return .conflict
    case .unsupported: return .unsupported
    case .overloaded: return .overloaded
    case .versionMismatch: return .versionMismatch
    case .invalidFrame: return .internal
    case .internal: return .internal
    }
  }

  /// Map a classified socket failure to an exit code. The split is by what
  /// a script should *do*: retry after launching (10), retry as-is (5/11),
  /// or stop and get a human (13/14).
  public static func from(_ failure: SocketConnectionFailure) -> CLIExitCode {
    switch failure.kind {
    case .socketMissing, .appNotRunning, .connectionLost: return .noSocket
    case .permissionDenied: return .socketPermissionDenied
    case .notASocket, .pathTooLong, .socketCreateFailed: return .socketUnusable
    case .serverBusy: return .overloaded
    case .timedOut: return .requestTimeout
    case .unknown: return .noSocket
    }
  }
}
