import Foundation

/// One row of the resolved view of the registry. Merges a schema default with the user
/// override (if any), surfaces the override-vs-default `source` for UI display, and reports
/// `isEnabled` separately from the binding so callers can distinguish "user disabled the
/// chord" (binding present, isEnabled false) from "user removed the chord" (binding nil).
public struct ResolvedShortcut: Equatable, Sendable {
  public let id: CommandID
  public let binding: ShortcutBinding?
  public let isEnabled: Bool
  public let source: Source

  public enum Source: Equatable, Sendable {
    case schemaDefault
    case userOverride
  }

  public init(id: CommandID, binding: ShortcutBinding?, isEnabled: Bool, source: Source) {
    self.id = id
    self.binding = binding
    self.isEnabled = isEnabled
    self.source = source
  }
}

/// Lookup table keyed by `CommandID`. Every entry in the schema produces one row; commands
/// without a `defaultBinding` and without an override produce a row with `binding == nil`,
/// `source == .schemaDefault`. Callers use `ShortcutDisplay.chord(for:)` to render and
/// `keyEquivalent(for:)` to bind via SwiftUI.
public typealias ResolvedShortcutMap = [CommandID: ResolvedShortcut]

/// Pure resolution: schema ⊕ overrides → resolved map.
public enum ShortcutResolver {
  public static func resolve(
    schema: ShortcutSchema = .app,
    overrides: ShortcutOverrideStore
  ) -> ResolvedShortcutMap {
    var map: ResolvedShortcutMap = [:]
    map.reserveCapacity(schema.entries.count)

    for entry in schema.entries {
      if let override = overrides.overrides[entry.id] {
        map[entry.id] = ResolvedShortcut(
          id: entry.id,
          binding: override,
          isEnabled: override.isEnabled,
          source: .userOverride
        )
      } else if let defaultBinding = entry.defaultBinding {
        map[entry.id] = ResolvedShortcut(
          id: entry.id,
          binding: defaultBinding,
          isEnabled: defaultBinding.isEnabled,
          source: .schemaDefault
        )
      } else {
        map[entry.id] = ResolvedShortcut(
          id: entry.id,
          binding: nil,
          isEnabled: false,
          source: .schemaDefault
        )
      }
    }

    return map
  }
}
