import Foundation

/// Action applied to the script's spawned Tab once the pty's child process
/// exits.
///
/// Only meaningful for targets that spawn a session — `.newTab` and `.split`.
/// A split's Tab is the only Tab of its new Pane, so closing the Tab closes
/// the Pane with it; a Tab added to that Pane later keeps the Pane open. The
/// runtime treats `.focused` as `.none` regardless of the stored value
/// because `sendInput` has no observable "command finished" boundary.
///
/// The stored token `closePane` names the same action and is read as
/// `.closeTab`; the next save writes `closeTab`.
public enum ScriptOnFinished: String, Codable, Sendable, CaseIterable {
  case none
  case closeTab

  private static let legacyClosePane = "closePane"

  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    if raw == Self.legacyClosePane {
      self = .closeTab
      return
    }
    guard let value = ScriptOnFinished(rawValue: raw) else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath, debugDescription: "unknown onFinished value \(raw)"))
    }
    self = value
  }
}
