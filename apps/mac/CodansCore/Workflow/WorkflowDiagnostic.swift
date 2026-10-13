import Foundation

/// One finding from parsing or validating a workflow file. `path` names the
/// offending node the way a reader would find it (`steps[2].expect.verdicts`)
/// rather than by line, because the validator reasons about the parsed
/// structure and most mistakes are structural.
public nonisolated struct WorkflowDiagnostic: Equatable, Sendable, Codable, Hashable {
  public enum Severity: String, Equatable, Sendable, Codable, CaseIterable {
    case error
    case warning
  }

  public var severity: Severity
  /// Stable machine-readable code (`unknown_key`, `undefined_role`, …).
  public var code: String
  public var message: String
  public var path: String?

  public init(severity: Severity, code: String, message: String, path: String? = nil) {
    self.severity = severity
    self.code = code
    self.message = message
    self.path = path
  }

  public static func error(_ code: String, _ message: String, at path: String? = nil) -> Self {
    Self(severity: .error, code: code, message: message, path: path)
  }

  public static func warning(_ code: String, _ message: String, at path: String? = nil) -> Self {
    Self(severity: .warning, code: code, message: message, path: path)
  }

  public var isError: Bool { severity == .error }
}

extension Array where Element == WorkflowDiagnostic {
  public var hasErrors: Bool { contains(where: \.isError) }
}
