import Foundation
import Testing

@testable import CodansCore

/// Tests for the cascading-reset planner. All scenarios use small, hand-built schemas so
/// the colliding-default scenarios are explicit and don't depend on the production registry's
/// chord choices. The production schema currently carries no `.systemFixed` rows, so the
/// system-fixed contract test plants a synthetic `.systemFixed` entry into a custom schema.
struct ShortcutResetPlannerTests {
  // MARK: - Helpers

  private static func binding(_ keyCode: UInt16, _ modifiers: ModifierMask = .command) -> ShortcutBinding {
    ShortcutBinding(keyCode: keyCode, modifiers: modifiers)
  }

  /// A miniature schema using the tab-related `CommandID` cases as stand-in commands. The
  /// defaults are deliberately picked to be non-colliding among themselves so that any
  /// collision the planner sees comes from user overrides we install in the test.
  private static func miniSchema(
    a: ShortcutBinding,
    b: ShortcutBinding,
    c: ShortcutBinding? = nil
  ) -> ShortcutSchema {
    var entries: [ShortcutSchema.Entry] = [
      .init(id: .newTab, title: "A", category: .terminal, scope: .configurable, defaultBinding: a),
      .init(id: .closeTab, title: "B", category: .terminal, scope: .configurable, defaultBinding: b),
    ]
    if let c {
      entries.append(
        .init(id: .previousTab, title: "C", category: .terminal, scope: .configurable, defaultBinding: c)
      )
    }
    return ShortcutSchema(entries: entries)
  }

  // MARK: - Tests

  @Test
  func resettingCommandWithoutOverrideIsNoOp() {
    let schema = Self.miniSchema(a: Self.binding(0x01), b: Self.binding(0x02))
    let plan = ShortcutResetPlanner.plan(
      resetting: .newTab,
      schema: schema,
      overrides: .empty
    )

    #expect(plan.target == .newTab)
    #expect(plan.cascadingResets.isEmpty)
    #expect(plan.resultingMap == ShortcutResolver.resolve(schema: schema, overrides: .empty))
  }

  @Test
  func resettingWhenDefaultDoesNotCollideHasEmptyCascade() {
    // A's default is 0x01; we override A to 0x99. B has its default 0x02.
    // Resetting A puts A back on 0x01 — no collision with B (0x02).
    let schema = Self.miniSchema(a: Self.binding(0x01), b: Self.binding(0x02))
    let overrides = ShortcutOverrideStore(overrides: [
      .newTab: Self.binding(0x99, [.command, .shift]),
    ])

    let plan = ShortcutResetPlanner.plan(
      resetting: .newTab,
      schema: schema,
      overrides: overrides
    )

    #expect(plan.target == .newTab)
    #expect(plan.cascadingResets.isEmpty)
    let aResolved = plan.resultingMap[.newTab]
    #expect(aResolved?.binding == Self.binding(0x01))
    #expect(aResolved?.source == .schemaDefault)
  }

  @Test
  func swapConflictCascadesToClearOpposingOverride() {
    // The canonical swap: A's default == B's user override, B's default == A's user override.
    // Resetting A → A reverts to A_default (== B's override) → cascade clears B → B reverts
    // to B_default. Final: A on A_default, B on B_default.
    let aDefault = Self.binding(0x10)
    let bDefault = Self.binding(0x20)
    let schema = Self.miniSchema(a: aDefault, b: bDefault)

    let overrides = ShortcutOverrideStore(overrides: [
      .newTab: bDefault, // A overridden to B's default
      .closeTab: aDefault, // B overridden to A's default
    ])

    let plan = ShortcutResetPlanner.plan(
      resetting: .newTab,
      schema: schema,
      overrides: overrides
    )

    #expect(plan.target == .newTab)
    #expect(plan.cascadingResets == [.closeTab])

    let aResolved = plan.resultingMap[.newTab]
    let bResolved = plan.resultingMap[.closeTab]
    #expect(aResolved?.binding == aDefault)
    #expect(aResolved?.source == .schemaDefault)
    #expect(bResolved?.binding == bDefault)
    #expect(bResolved?.source == .schemaDefault)
  }

  @Test
  func systemFixedCommandsNeverAppearInCascadeList() {
    // Custom schema with one synthetic `.systemFixed` row (`.openSettings` on ⌘,) plus two
    // `.configurable` rows. Bind `.commandPaletteToggle` (configurable) to the same chord
    // as the system-fixed row. Resetting an unrelated configurable target must not
    // cascade-clear the configurable holder because of the `.systemFixed` collision, and
    // the `.systemFixed` row itself must never appear as a cascade victim.
    let systemFixedChord = Self.binding(0x2B, .command)
    let schema = ShortcutSchema(entries: [
      .init(
        id: .openSettings,
        title: "Open Settings",
        category: .general,
        scope: .systemFixed,
        defaultBinding: systemFixedChord
      ),
      .init(
        id: .commandPaletteToggle,
        title: "Quick Action",
        category: .general,
        scope: .configurable,
        defaultBinding: Self.binding(0x23, .command)
      ),
      .init(
        id: .newTab,
        title: "New Tab",
        category: .terminal,
        scope: .configurable,
        defaultBinding: Self.binding(0x11, .command)
      ),
    ])

    // Override `.commandPaletteToggle` to the same chord as the system-fixed row, plus
    // an unrelated override on `.newTab` so we have a well-defined reset target.
    let overrides = ShortcutOverrideStore(overrides: [
      .commandPaletteToggle: systemFixedChord,
      .newTab: Self.binding(0xFE, [.command, .control, .option, .shift]),
    ])

    let plan = ShortcutResetPlanner.plan(
      resetting: .newTab,
      schema: schema,
      overrides: overrides
    )

    #expect(plan.target == .newTab)
    #expect(!plan.cascadingResets.contains(.openSettings))
    #expect(!plan.cascadingResets.contains(.commandPaletteToggle))

    // The intentional configurable-vs-systemFixed collision survives the reset: the user's
    // deliberate `.commandPaletteToggle` override is still in place.
    let palette = plan.resultingMap[.commandPaletteToggle]
    #expect(palette?.binding == systemFixedChord)
    #expect(palette?.source == .userOverride)
  }

  @Test
  func threeWayCycleTerminatesAndProducesCleanState() {
    // A_default = X1, B_default = X2, C_default = X3.
    // Overrides form a rotation: A → X2, B → X3, C → X1.
    // Reset A → A reverts to X1 (== C's override) → cascade clears C → C reverts to X3
    // (== B's override) → cascade clears B → B reverts to X2. Final: every command on its
    // default, no further work to do.
    let x1 = Self.binding(0x30)
    let x2 = Self.binding(0x31)
    let x3 = Self.binding(0x32)
    let schema = Self.miniSchema(a: x1, b: x2, c: x3)

    let overrides = ShortcutOverrideStore(overrides: [
      .newTab: x2,
      .closeTab: x3,
      .previousTab: x1,
    ])

    let plan = ShortcutResetPlanner.plan(
      resetting: .newTab,
      schema: schema,
      overrides: overrides
    )

    #expect(plan.target == .newTab)
    #expect(Set(plan.cascadingResets) == Set([.closeTab, .previousTab]))

    for id in [CommandID.newTab, .closeTab, .previousTab] {
      let resolved = plan.resultingMap[id]
      #expect(resolved?.source == .schemaDefault, "\(id) should be back on its schema default.")
    }
    #expect(plan.resultingMap[.newTab]?.binding == x1)
    #expect(plan.resultingMap[.closeTab]?.binding == x2)
    #expect(plan.resultingMap[.previousTab]?.binding == x3)
  }
}
