import Foundation

@testable import TouchCode

/// Test-only fake for `PrivilegedShell`. Records each `run(_:prompt:)`
/// invocation and replays an injectable result. Tests use it to assert the
/// composed shell script and the dialog prompt without ever invoking
/// `osascript`.
final class RecordingPrivilegedShell: PrivilegedShell, @unchecked Sendable {
  struct Call: Equatable {
    let command: String
    let prompt: String
  }

  enum Result {
    case succeed
    case throwError(PrivilegedShellError)
  }

  private(set) var calls: [Call] = []
  var result: Result = .succeed

  func run(_ command: String, prompt: String) throws {
    calls.append(Call(command: command, prompt: prompt))
    switch result {
    case .succeed:
      return
    case .throwError(let error):
      throw error
    }
  }
}
