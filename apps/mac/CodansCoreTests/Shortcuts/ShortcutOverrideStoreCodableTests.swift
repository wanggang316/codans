import Foundation
import Testing

@testable import CodansCore

struct ShortcutOverrideStoreCodableTests {
  @Test
  func emptyStoreEncodesEmptyOverrideDictionary() throws {
    let store = ShortcutOverrideStore.empty
    let data = try JSONEncoder.touchCodeDefault.encode(store)
    let decoded = try JSONDecoder.touchCodeDefault.decode(ShortcutOverrideStore.self, from: data)
    #expect(decoded == store)
    #expect(decoded.overrides.isEmpty)
  }

  @Test
  func sparseOverridesRoundTrip() throws {
    let store = ShortcutOverrideStore(overrides: [
      .newTab: .init(keyCode: 17, modifiers: [.command, .option], isEnabled: true),
      .toggleDiffInspector: .init(keyCode: 5, modifiers: .command, isEnabled: false),
    ])
    let data = try JSONEncoder.touchCodeDefault.encode(store)
    let decoded = try JSONDecoder.touchCodeDefault.decode(ShortcutOverrideStore.self, from: data)
    #expect(decoded == store)
  }

  @Test
  func emittedJSONMatchesExpectedShape() throws {
    let store = ShortcutOverrideStore(overrides: [
      .newTab: .init(keyCode: 17, modifiers: [.command, .option], isEnabled: true),
    ])
    let data = try JSONEncoder.touchCodeDefault.encode(store)
    let json = String(data: data, encoding: .utf8) ?? ""

    #expect(json.contains("\"version\" : 1"))
    #expect(json.contains("\"newTab\""))
    #expect(json.contains("\"keyCode\" : 17"))
    #expect(json.contains("\"isEnabled\" : true"))
    // Modifier order: control < option < shift < command, sorted in canonical order on encode.
    #expect(json.contains("\"option\""))
    #expect(json.contains("\"command\""))
  }

  @Test
  func toggleDiffInspectorPersistsAsLegacyToggleGitViewerKey() throws {
    // The Swift identifier renamed during the Diff inspector refactor, but
    // the persisted JSON key must keep the original `toggleGitViewer`
    // string so existing user overrides survive the rename.
    let store = ShortcutOverrideStore(overrides: [
      .toggleDiffInspector: .init(keyCode: 5, modifiers: [.command, .shift], isEnabled: true),
    ])
    let data = try JSONEncoder.touchCodeDefault.encode(store)
    let json = String(data: data, encoding: .utf8) ?? ""
    #expect(json.contains("\"toggleGitViewer\""))
    #expect(!json.contains("\"toggleDiffInspector\""))
  }

  @Test
  func unknownModifierTokenFailsDecoding() throws {
    let bad = """
    {
      "version": 1,
      "overrides": {
        "newTab": { "keyCode": 17, "modifiers": ["meta"], "isEnabled": true }
      }
    }
    """.data(using: .utf8)!

    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder.touchCodeDefault.decode(ShortcutOverrideStore.self, from: bad)
    }
  }

  @Test
  func modifierTokensDecodeRegardlessOfOrder() throws {
    // JSON key remains `toggleGitViewer` even after the Swift identifier
    // was renamed to `toggleDiffInspector` — pinned via `CommandID`'s raw
    // value so existing user overrides of the ⌘⇧G binding aren't orphaned.
    let json = """
    {
      "version": 1,
      "overrides": {
        "toggleGitViewer": { "keyCode": 5, "modifiers": ["shift", "command"], "isEnabled": true }
      }
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder.touchCodeDefault.decode(ShortcutOverrideStore.self, from: json)
    #expect(decoded.overrides[.toggleDiffInspector]?.modifiers == [.command, .shift])
  }
}
