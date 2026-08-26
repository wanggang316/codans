import Foundation

/// POSIX single-quote wrapping for values codans interpolates into a command
/// it types into a pane. Domain-tier home so both the agent resume commands
/// and the agent launch renderer quote identically; app-tier callers that
/// build ssh / zmx invocations keep their own transport-specific helpers.
public nonisolated enum ShellQuoting {
  /// Wraps `raw` in single quotes with the standard `'\''` escape. Always
  /// quotes — values reaching here originate from settings files and agent
  /// session stores we don't own, so charset assumptions are not safe.
  public static func quoted(_ raw: String) -> String {
    "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
