import Foundation

/// The `state` of an OSC 7501 (Program Status Protocol) report.
/// `clear` is not a state: it removes the addressed record and its children.
public nonisolated enum ProgramStatusState: String, Sendable, Equatable, Codable, CaseIterable {
  case idle
  case working
  case done
  case blocked
  case error
  case clear
}

/// What a `blocked` program needs from the user.
public nonisolated enum ProgramStatusKind: String, Sendable, Equatable, Codable, CaseIterable {
  case permission
  case question
  case auth
}

/// One OSC 7501 report, copied out of the libghostty action. The terminal
/// already validated it (limits, base64, no control characters). Text is
/// still untrusted program output: never interpret it, and keep it out of
/// durable logs.
public nonisolated struct ProgramStatusReport: Sendable, Equatable {
  public var state: ProgramStatusState
  /// Only set for `blocked`.
  public var kind: ProgramStatusKind?
  /// 0–100, nil when indeterminate.
  public var progress: Int?
  /// Empty for the root record. `/` separates a child from its parent.
  public var id: String
  public var app: String?
  public var title: String?
  public var message: String?

  public init(
    state: ProgramStatusState,
    kind: ProgramStatusKind? = nil,
    progress: Int? = nil,
    id: String = "",
    app: String? = nil,
    title: String? = nil,
    message: String? = nil
  ) {
    self.state = state
    self.kind = state == .blocked ? kind : nil
    self.progress = progress
    self.id = id
    self.app = Self.nonEmpty(app)
    self.title = Self.displayText(title)
    self.message = Self.displayText(message)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  /// Text shown outside the terminal grid must not carry bidirectional
  /// overrides or invisible formatting characters (the protocol's security
  /// guidance): they can reorder or hide what the user reads.
  private static func displayText(_ value: String?) -> String? {
    guard let value else { return nil }
    let scalars = value.unicodeScalars.filter { !isInvisibleFormatting($0) }
    return nonEmpty(String(String.UnicodeScalarView(scalars)))
  }

  private static func isInvisibleFormatting(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF:
      return true
    default:
      return false
    }
  }
}
