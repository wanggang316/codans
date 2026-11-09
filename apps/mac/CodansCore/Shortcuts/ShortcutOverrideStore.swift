import Foundation

/// User overrides for the schema defaults. Persisted as `~/.codans/config/shortcuts.json`
/// by `ShortcutsStore`. Sparse — only commands the user has touched appear in `overrides`;
/// commands not present resolve to their schema default.
///
/// JSON shape (v1):
///
///     {
///       "version": 1,
///       "overrides": {
///         "newTab": { "keyCode": 17, "modifiers": ["command", "option"], "isEnabled": true },
///         "toggleGitViewer": { "keyCode": 5, "modifiers": ["command"], "isEnabled": false }
///       }
///     }
///
/// `CommandID`'s `String` raw value drives the dictionary key encoding via Swift's
/// auto-synthesized `CodingKeyRepresentable` conformance for `RawRepresentable where
/// RawValue: LosslessStringConvertible`.
public struct ShortcutOverrideStore: Equatable, Sendable, Codable {
  public static let currentVersion = 1

  public var version: Int
  public var overrides: [CommandID: ShortcutBinding]

  public init(
    version: Int = ShortcutOverrideStore.currentVersion,
    overrides: [CommandID: ShortcutBinding] = [:]
  ) {
    self.version = version
    self.overrides = overrides
  }

  public static let empty = ShortcutOverrideStore()

  /// Raw values of commands that no longer exist. Their overrides are
  /// dropped on decode so the rest of the file still loads; any other
  /// unknown key is a decoding error.
  static let retiredCommandIDs: Set<String> = ["renameActiveTab", "changeActiveTabColor"]

  private enum CodingKeys: String, CodingKey {
    case version, overrides
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.version = try container.decode(Int.self, forKey: .version)
    let raw = try container.decode([String: ShortcutBinding].self, forKey: .overrides)
    var overrides: [CommandID: ShortcutBinding] = [:]
    for (key, binding) in raw where !Self.retiredCommandIDs.contains(key) {
      guard let id = CommandID(rawValue: key) else {
        throw DecodingError.dataCorruptedError(
          forKey: .overrides, in: container, debugDescription: "Unknown command \(key)")
      }
      overrides[id] = binding
    }
    self.overrides = overrides
  }
}
