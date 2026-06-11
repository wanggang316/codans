import Foundation
import Testing

@testable import CodansCore

struct ScriptDefinitionCodableTests {
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
  }()
  private let decoder = JSONDecoder()

  @Test
  func defaultInitialiserUsesRunKind() {
    let s = ScriptDefinition()
    #expect(s.kind == .run)
    #expect(s.name == "")
    #expect(s.command == "")
    #expect(s.systemImage == nil)
    #expect(s.tintColor == nil)
  }

  @Test
  func roundTripsAcrossEveryScriptKind() throws {
    for kind in ScriptKind.allCases {
      let original = ScriptDefinition(kind: kind, name: kind.defaultName, command: "echo \(kind.rawValue)")
      let data = try encoder.encode(original)
      let decoded = try decoder.decode(ScriptDefinition.self, from: data)
      #expect(decoded == original)
    }
  }

  @Test
  func legacyPayloadWithoutKindDecodesAsRun() throws {
    // Phase 1 reserved-empty payloads: `{ "id": "<uuid>", "name": "x", "command": "y" }`.
    // Decoder defaults `kind` to `.run` so existing settings.json files round-trip.
    let id = UUID()
    let payload = Data(#"""
      { "id": "\#(id.uuidString)", "name": "legacy", "command": "echo hi" }
      """#.utf8)
    let decoded = try decoder.decode(ScriptDefinition.self, from: payload)
    #expect(decoded.id == id)
    #expect(decoded.kind == .run)
    #expect(decoded.name == "legacy")
    #expect(decoded.command == "echo hi")
  }

  @Test
  func displayNameFallsBackToKindDefaultWhenEmpty() {
    let unnamed = ScriptDefinition(kind: .test, name: "", command: "go test ./...")
    #expect(unnamed.displayName == "Test")

    let named = ScriptDefinition(kind: .test, name: "Unit Tests", command: "go test ./...")
    #expect(named.displayName == "Unit Tests")
  }

  @Test
  func resolvedSystemImageHonoursOverrideThenKindDefault() {
    // A per-command override wins over the kind default, regardless of kind —
    // so a `.run` command can carry a custom icon everywhere it renders.
    let runScript = ScriptDefinition(
      kind: .run,
      name: "x",
      command: "y",
      systemImage: "questionmark"
    )
    #expect(runScript.resolvedSystemImage == "questionmark")

    let customScript = ScriptDefinition(
      kind: .custom,
      name: "x",
      command: "y",
      systemImage: "star.fill"
    )
    #expect(customScript.resolvedSystemImage == "star.fill")

    // No override → fall back to the kind default.
    let runWithoutOverride = ScriptDefinition(kind: .run, name: "x", command: "y")
    #expect(runWithoutOverride.resolvedSystemImage == ScriptKind.run.defaultSystemImage)
    let customWithoutOverride = ScriptDefinition(kind: .custom, name: "x", command: "y")
    #expect(customWithoutOverride.resolvedSystemImage == ScriptKind.custom.defaultSystemImage)
  }

  @Test
  func resolvedTintColorHonoursOverrideThenKindDefault() {
    let testScript = ScriptDefinition(
      kind: .test,
      name: "x",
      command: "y",
      tintColor: .red
    )
    #expect(testScript.resolvedTintColor == .red)

    let customScript = ScriptDefinition(
      kind: .custom,
      name: "x",
      command: "y",
      tintColor: .purple
    )
    #expect(customScript.resolvedTintColor == .purple)

    // No override → fall back to the kind default.
    let testWithoutOverride = ScriptDefinition(kind: .test, name: "x", command: "y")
    #expect(testWithoutOverride.resolvedTintColor == ScriptKind.test.defaultTintColor)
  }

  @Test
  func encoderOmitsEmptyOptionalFields() throws {
    let s = ScriptDefinition(kind: .run, name: "", command: "")
    let data = try encoder.encode(s)
    let text = try #require(String(bytes: data, encoding: .utf8))
    #expect(text.contains("\"name\"") == false)
    #expect(text.contains("\"command\"") == false)
    #expect(text.contains("\"systemImage\"") == false)
    #expect(text.contains("\"tintColor\"") == false)
    // id and kind always present.
    #expect(text.contains("\"id\""))
    #expect(text.contains("\"kind\":\"run\""))
  }

  @Test
  func customKindWithIconAndColorEncodesAndRoundTrips() throws {
    let s = ScriptDefinition(
      kind: .custom,
      name: "Tail logs",
      command: "ssh prod 'tail -f /var/log/app.log'",
      systemImage: "doc.text.magnifyingglass",
      tintColor: .blue
    )
    let data = try encoder.encode(s)
    let decoded = try decoder.decode(ScriptDefinition.self, from: data)
    #expect(decoded == s)
    #expect(decoded.resolvedSystemImage == "doc.text.magnifyingglass")
    #expect(decoded.resolvedTintColor == .blue)
  }

  // MARK: - target / direction / onFinished

  @Test
  func defaultsForDispatchFields() {
    let s = ScriptDefinition()
    #expect(s.target == .newTab)
    #expect(s.direction == .right)
    #expect(s.onFinished == .none)
  }

  @Test
  func encoderOmitsDispatchFieldsAtDefault() throws {
    let s = ScriptDefinition(kind: .run, command: "echo hi")
    let data = try encoder.encode(s)
    let text = try #require(String(bytes: data, encoding: .utf8))
    #expect(text.contains("\"target\"") == false)
    #expect(text.contains("\"direction\"") == false)
    #expect(text.contains("\"onFinished\"") == false)
  }

  @Test
  func directionEncodedOnlyWhenTargetIsSplit() throws {
    let newTabScript = ScriptDefinition(command: "echo", target: .newTab, direction: .left)
    let newTabText = try #require(String(bytes: try encoder.encode(newTabScript), encoding: .utf8))
    // direction is meaningless for newTab — never emitted.
    #expect(newTabText.contains("\"direction\"") == false)

    let splitDefault = ScriptDefinition(command: "echo", target: .split, direction: .right)
    let splitDefaultText = try #require(String(bytes: try encoder.encode(splitDefault), encoding: .utf8))
    // .right is the default — still omitted under split.
    #expect(splitDefaultText.contains("\"direction\"") == false)
    #expect(splitDefaultText.contains("\"target\":\"split\""))

    let splitDown = ScriptDefinition(command: "echo", target: .split, direction: .down)
    let splitDownText = try #require(String(bytes: try encoder.encode(splitDown), encoding: .utf8))
    #expect(splitDownText.contains("\"direction\":\"down\""))
  }

  @Test
  func onFinishedRoundTripsAndIsValidatedByTarget() throws {
    // newTab + closeTab: kept.
    let nt = ScriptDefinition(command: "echo", target: .newTab, onFinished: .closeTab)
    #expect(nt.resolvedOnFinished == .closeTab)
    let ntDecoded = try decoder.decode(ScriptDefinition.self, from: try encoder.encode(nt))
    #expect(ntDecoded == nt)

    // split + closePane: kept.
    let sp = ScriptDefinition(command: "echo", target: .split, direction: .left, onFinished: .closePane)
    #expect(sp.resolvedOnFinished == .closePane)
    let spDecoded = try decoder.decode(ScriptDefinition.self, from: try encoder.encode(sp))
    #expect(spDecoded == sp)

    // focused + anything: forced .none at runtime.
    let foc = ScriptDefinition(command: "echo", target: .focused, onFinished: .closeTab)
    #expect(foc.resolvedOnFinished == .none)
    let focText = try #require(String(bytes: try encoder.encode(foc), encoding: .utf8))
    // onFinished encodes the *validated* value, so .focused never writes it.
    #expect(focText.contains("\"onFinished\"") == false)

    // Invalid combo from disk (split + closeTab): tolerated, runtime treats as .none.
    let invalid = ScriptDefinition(command: "echo", target: .split, onFinished: .closeTab)
    #expect(invalid.resolvedOnFinished == .none)
  }

  @Test
  func roundTripsAcrossEveryTarget() throws {
    for target in ScriptTarget.allCases {
      let s = ScriptDefinition(command: "echo \(target.rawValue)", target: target)
      let decoded = try decoder.decode(ScriptDefinition.self, from: try encoder.encode(s))
      #expect(decoded == s)
    }
  }

  @Test
  func roundTripsAcrossEverySplitDirection() throws {
    for direction in ScriptSplitDirection.allCases {
      let s = ScriptDefinition(command: "echo", target: .split, direction: direction)
      let decoded = try decoder.decode(ScriptDefinition.self, from: try encoder.encode(s))
      #expect(decoded == s)
    }
  }
}
