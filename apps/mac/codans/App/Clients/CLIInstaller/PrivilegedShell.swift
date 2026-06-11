import AppKit
import Foundation

/// Runs a shell command under macOS administrator privileges via in-process
/// `NSAppleScript`. Used by `CLIInstallerClient` to install / uninstall the
/// `codans` symlink under `/usr/local/bin`. In-process AppleScript makes the
/// auth dialog show the codans app icon and bundle name instead of a generic
/// `osascript` prompt.
public protocol PrivilegedShell: Sendable {
  /// Runs `command` (a `/bin/sh`-compatible script) with administrator
  /// privileges, surfacing the system auth dialog with `prompt`.
  /// Throws `.userCancelled` when the dialog is dismissed (NSAppleScript
  /// errno `-128`). Throws `.scriptFailed(stderr:)` on any other failure.
  func run(_ command: String, prompt: String) throws
}

public enum PrivilegedShellError: Error, Equatable {
  case userCancelled
  case scriptFailed(stderr: String)
}

public struct AppleScriptPrivilegedShell: PrivilegedShell {
  public init() {}

  public func run(_ command: String, prompt: String) throws {
    let source = Self.composeSource(command: command, prompt: prompt)
    guard let script = NSAppleScript(source: source) else {
      throw PrivilegedShellError.scriptFailed(stderr: "Failed to prepare authorization script.")
    }
    var errorInfo: NSDictionary?
    script.executeAndReturnError(&errorInfo)
    guard let errorInfo else { return }
    let errorNumber = errorInfo[NSAppleScript.errorNumber] as? Int
    if errorNumber == -128 {
      throw PrivilegedShellError.userCancelled
    }
    let message = errorInfo[NSAppleScript.errorMessage] as? String ?? ""
    throw PrivilegedShellError.scriptFailed(stderr: message)
  }

  /// Builds the AppleScript source that runs `command` with admin privileges
  /// and the given dialog `prompt`. Multi-line commands are split on `\n`
  /// and rejoined via `& linefeed &` because AppleScript string literals do
  /// not accept raw newline bytes; backslash and double-quote inside any
  /// segment are escaped per AppleScript literal rules.
  /// Internal so unit tests can verify the generated source.
  static func composeSource(command: String, prompt: String) -> String {
    let escapedPrompt = escapeForAppleScriptLiteral(prompt)
    let commandExpression =
      command
      .components(separatedBy: "\n")
      .map { "\"\(escapeForAppleScriptLiteral($0))\"" }
      .joined(separator: " & linefeed & ")
    return
      "do shell script \(commandExpression) with prompt \"\(escapedPrompt)\" with administrator privileges"
  }

  /// Escapes a string for embedding inside an AppleScript double-quoted
  /// literal. Only `\` and `"` are escaped — newlines must be handled at the
  /// caller level by splitting and concatenating with `& linefeed &`,
  /// because AppleScript string literals do not accept raw newline bytes.
  private static func escapeForAppleScriptLiteral(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}

/// Wraps a value in single quotes for safe embedding in a `/bin/sh` script.
/// Escapes embedded single quotes via the `'\''` idiom so the result remains
/// a single shell token even if `value` contains apostrophes.
func shellEscape(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
