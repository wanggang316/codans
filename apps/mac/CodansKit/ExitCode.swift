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
  case noSocket = 10
  case requestTimeout = 11  // server did not respond within --timeout
  case launchTimeout = 12  // codans launch / auto-launch never saw the socket come up
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
}
