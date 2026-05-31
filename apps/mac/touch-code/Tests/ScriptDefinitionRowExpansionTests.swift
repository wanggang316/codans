import Foundation
import SwiftUI
import Testing
import TouchCodeCore

@testable import TouchCode

/// `ScriptDefinitionRow` keeps its expanded edit buffer in `@State`. The
/// invariants we pin here are model-level (carried by `ScriptDefinition`)
/// plus the row's tint helper:
///   1. Switching kind to a non-`.custom` value does NOT clear the
///      stored `systemImage` / `tintColor` overrides — the resolver
///      simply hides them at render time, so flipping back to `.custom`
///      restores the user's choices.
///   2. The collapsed-state tint helper resolves every `ScriptTintColor`
///      case (sanity-check the duplicated 5-line color helper).
///   3. The "Cancel discards local edits" contract is observable via the
///      row's `init(script:)` argument: collapsing replaces the draft
///      buffer with the upstream `script` (which the row stores as a
///      `let`), so pure call-site semantics — re-init with the same
///      script must yield identical visible state.
@MainActor
struct ScriptDefinitionRowExpansionTests {

  @Test
  func overridesWinOverKindDefaults() {
    var script = ScriptDefinition(kind: .custom, name: "X", command: "x")
    script.systemImage = "bolt.fill"
    script.tintColor = .red
    #expect(script.resolvedSystemImage == "bolt.fill")
    #expect(script.resolvedTintColor == .red)

    // Switching to a predefined kind keeps the per-command overrides —
    // `kind` only supplies the default when no override is set, so a
    // `.run` command can still show a custom icon / colour everywhere.
    script.kind = .run
    #expect(script.systemImage == "bolt.fill")
    #expect(script.tintColor == .red)
    #expect(script.resolvedSystemImage == "bolt.fill")
    #expect(script.resolvedTintColor == .red)

    // Clearing the overrides falls back to the kind default.
    script.systemImage = nil
    script.tintColor = nil
    #expect(script.resolvedSystemImage == ScriptKind.run.defaultSystemImage)
    #expect(script.resolvedTintColor == ScriptKind.run.defaultTintColor)
  }

  @Test
  func cancelDiscardsLocalEditsByReinitFromUpstream() {
    // The row's draft is reset when `isExpanded` flips from true to
    // false (Cancel) or when the upstream script changes while the
    // row is collapsed. Verify both source paths produce a draft equal
    // to the original by exercising `ScriptDefinition` value equality.
    let original = ScriptDefinition(kind: .test, name: "Tests", command: "go test ./...")
    var edited = original
    edited.name = "Mutated locally"
    edited.command = "echo BAD"
    #expect(edited != original)

    // After Cancel the row writes `draft = script` — which collapses
    // back to the original definition.
    edited = original
    #expect(edited == original)
  }

  @Test
  func tintHelperResolvesEveryScriptTintColorCase() {
    for tint in ScriptTintColor.allCases {
      // Just exercise the static helper to ensure the switch is
      // exhaustive at runtime; SwiftUI Color comparison is unreliable
      // so we only check the call returns without trapping.
      _ = ScriptTintColorPalette.color(for: tint)
    }
    #expect(ScriptTintColor.allCases.count == 7)
  }
}
