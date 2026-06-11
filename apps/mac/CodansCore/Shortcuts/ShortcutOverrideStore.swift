import Foundation

/// User overrides for the schema defaults. Persisted as `~/.config/codans/shortcuts.json`
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
}
