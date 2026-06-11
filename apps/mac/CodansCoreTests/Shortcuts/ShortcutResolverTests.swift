import Foundation
import Testing

@testable import CodansCore

struct ShortcutResolverTests {
  @Test
  func emptyOverridesReturnsSchemaDefaults() {
    let map = ShortcutResolver.resolve(overrides: .empty)

    for entry in ShortcutSchema.app.entries {
      let resolved = map[entry.id]
      #expect(resolved?.binding == entry.defaultBinding)
      #expect(resolved?.source == .schemaDefault)
      #expect(resolved?.isEnabled == (entry.defaultBinding?.isEnabled ?? false))
    }
  }

  @Test
  func userOverrideReplacesDefault() {
    let custom = ShortcutBinding(keyCode: 99, modifiers: [.command, .control])
    let store = ShortcutOverrideStore(overrides: [.newTab: custom])
    let map = ShortcutResolver.resolve(overrides: store)

    let resolved = map[.newTab]
    #expect(resolved?.binding == custom)
    #expect(resolved?.source == .userOverride)
    #expect(resolved?.isEnabled == true)
  }

  @Test
  func disabledOverrideKeepsBindingButReportsDisabled() {
    let disabled = ShortcutBinding(keyCode: 5, modifiers: [.command, .shift], isEnabled: false)
    let store = ShortcutOverrideStore(overrides: [.toggleDiffInspector: disabled])
    let map = ShortcutResolver.resolve(overrides: store)

    let resolved = map[.toggleDiffInspector]
    #expect(resolved?.binding == disabled)
    #expect(resolved?.isEnabled == false)
    #expect(resolved?.source == .userOverride)
  }

  @Test
  func unrelatedOverridesDoNotPerturbOtherCommands() {
    let store = ShortcutOverrideStore(overrides: [
      .newTab: .init(keyCode: 50, modifiers: .command),
    ])
    let map = ShortcutResolver.resolve(overrides: store)

    let untouched = map[.toggleDiffInspector]
    let schemaDefault = ShortcutSchema.app.entry(for: .toggleDiffInspector)?.defaultBinding
    #expect(untouched?.binding == schemaDefault)
    #expect(untouched?.source == .schemaDefault)
  }

  @Test
  func resolvedMapHasOneEntryPerCommandID() {
    let map = ShortcutResolver.resolve(overrides: .empty)
    #expect(map.count == CommandID.allCases.count)
    for id in CommandID.allCases {
      #expect(map[id] != nil, "Resolver missing entry for \(id).")
    }
  }
}
