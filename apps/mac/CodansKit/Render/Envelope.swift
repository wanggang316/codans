import Foundation

/// Stable error codes carried in the JSON envelope's `error.code`. Scripts
/// and agents branch on these strings (and on the exit code, which they
/// refine), so they must not change within a major version. Every
/// `CLIExitCode` has a default code; the specific ones name a situation the
/// exit code alone cannot distinguish.
public enum CLIErrorCode: String, Codable, Sendable, CaseIterable {
  case invalidArgument = "INVALID_ARGUMENT"
  case notFound = "NOT_FOUND"
  case conflict = "CONFLICT"
  case unsupported = "UNSUPPORTED"
  case overloaded = "OVERLOADED"
  case versionMismatch = "VERSION_MISMATCH"
  case appNotRunning = "APP_NOT_RUNNING"
  case requestTimeout = "REQUEST_TIMEOUT"
  case launchTimeout = "LAUNCH_TIMEOUT"
  case socketPermissionDenied = "SOCKET_PERMISSION_DENIED"
  case socketUnusable = "SOCKET_UNUSABLE"
  case wrongChannel = "WRONG_CHANNEL"
  case `internal` = "INTERNAL"
  /// `current` / `.` used outside a Codans pane (exit 2).
  case noCurrentContext = "NO_CURRENT_CONTEXT"
  /// Text or stdin body was empty (exit 1).
  case emptyInput = "EMPTY_INPUT"
  /// A `--wait` / `--until` condition did not hold before the deadline
  /// (exit 11).
  case waitTimeout = "WAIT_TIMEOUT"
  /// The pane's shell reports no shell integration, so the requested
  /// command-completion tracking is unavailable (exit 4).
  case captureUnsupported = "CAPTURE_UNSUPPORTED"

  /// The code every exit code maps to when nothing more specific applies.
  public static func `default`(for exit: CLIExitCode) -> CLIErrorCode {
    switch exit {
    case .ok, .userError: return .invalidArgument
    case .notFound: return .notFound
    case .conflict: return .conflict
    case .unsupported: return .unsupported
    case .overloaded: return .overloaded
    case .versionMismatch: return .versionMismatch
    case .noSocket: return .appNotRunning
    case .requestTimeout: return .requestTimeout
    case .launchTimeout: return .launchTimeout
    case .socketPermissionDenied: return .socketPermissionDenied
    case .socketUnusable: return .socketUnusable
    case .wrongChannel: return .wrongChannel
    case .internal: return .internal
    }
  }
}

/// `error` member of a failed JSON envelope.
public struct CLIErrorPayload: Codable, Equatable, Sendable {
  public let code: CLIErrorCode
  public let message: String
  public let hint: String?
  /// Structured context (`kind` / `id` for not-found, `timeoutMs` for a
  /// wait, …). Omitted when empty.
  public let details: [String: String]?

  public init(code: CLIErrorCode, message: String, hint: String? = nil, details: [String: String] = [:]) {
    self.code = code
    self.message = message
    self.hint = hint
    self.details = details.isEmpty ? nil : details
  }
}

/// What `--json` prints: one object with `schemaVersion` and exactly one of
/// `data` / `error`. `schemaVersion` is `codans.cli.<command path>.v1`
/// (`codans.cli.pane.send.v1`), the same for every build channel, so a
/// consumer can pin the shape it parses.
public enum OutputEnvelope {
  public static let schemaPrefix = "codans.cli"
  public static let schemaSuffix = "v1"

  public static func schemaVersion(command: String) -> String {
    "\(schemaPrefix).\(command).\(schemaSuffix)"
  }
}

/// The command a render happens for, carried as a task-local so every
/// `Renderer` call in a command's body stamps the same `schemaVersion`
/// without threading it through each call site.
public struct RenderContext: Sendable {
  /// Dotted command path without the executable name: `pane.send`.
  public let command: String

  public init(command: String) {
    self.command = command
  }
}
