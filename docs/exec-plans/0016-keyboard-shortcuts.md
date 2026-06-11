# ExecPlan: Unified Keyboard Shortcut Management

**Status:** Completed
**Author:** Gump
**Date:** 2026-04-28

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, a codans user opens **Settings → Shortcuts** and sees every in-app keyboard shortcut listed by category — Quick Action, Tabs, Sidebar Worktrees, plus the read-only system row for `⌘,`. They can click any chord cell, press a new key combination, and have the change take effect immediately: the menu item updates, the new chord fires the action, and the previous chord no longer does. They can disable a shortcut without losing their previous binding, reset one row to its default (with the app explaining when a reset will cascade because of a swap-conflict), or reset everything at once. A user on a non-US-QWERTY keyboard sees keycaps that match what is physically printed on their keys, even after switching input source mid-session. On disk, only differences from the defaults are kept — `~/.config/codans/shortcuts.json` is empty for a fresh user and human-readable for power users. Internally, every existing hardcoded shortcut (`MainWindowCommands` thirteen entries plus the nine `⌃⌘1..9` sidebar hotkeys) routes through the same registry, so adding a new shortcut later is a one-line schema entry rather than another sprinkled `.keyboardShortcut(…)` call.

## Progress

- [x] M1 — CodansCore: `CommandID` enum, `ShortcutBinding`, `ModifierMask`, `ShortcutScope`, `ShortcutSchema` with defaults table; schema audit unit test pinning today's literals (commit `3892403`, 2026-04-28)
- [x] M2 — CodansCore: `ShortcutOverrideStore`, `ShortcutResolver`, `ShortcutResetPlanner`, three `ConflictDetectors`; unit coverage for each (27/27 tests pass, 2026-04-28)
  - [x] M2.0 prefix — override store + resolver (commit `095d55a`)
  - [x] M2.A — `ShortcutResetPlanner` (commit `cd4e3bd`)
  - [x] M2.B — `SystemReservedDetector` (commit `04ee2de`)
  - [x] M2.C — `AppKitReservedDetector` (commit `4e25624`)
  - [x] M2.D — `InternalConflictDetector` (commit `30191c6`)
- [x] M3 — App: `ShortcutsStore` (`@MainActor @Observable`, `AtomicFileStore`, 500 ms debounce, broken-file backup); store unit tests (commit `f17742a`, 10/10 tests pass, 2026-04-28)
- [x] M4 — App: `ShortcutDisplay` (UCKeyTranslate keycap + KeyEquivalent conversion); display unit tests (commit `1abc7a5`, 10/10 tests pass, 2026-04-28)
- [x] M5 — App: `ShortcutEnvironment` + `View+appKeyboardShortcut` modifier (two forms) (commit `ac50e08`, 4/4 tests pass, 2026-04-28)
- [x] M6 — App wiring: instantiate `ShortcutsStore` in `CodansApp`, inject environment, rewrite `MainWindowCommands` thirteen bindings to read from registry, migrate `StatusMotivationalView` and `CommandPaletteItems` palette-hint consumers, delete `CommandPaletteShortcut.swift` (commit `02bef09`, schema audit + palette tests pass; pre-existing `commandEDispatchesOpenDefaultForCurrentWorktreeAndForwardsToEditor` flake unrelated, 2026-04-28)
- [x] M7 — `HierarchySidebarView` row-hotkey rewrite: nine `⌃⌘1..9` invisible buttons read from registry; delete `hotkeyModifiers` constant (commit `321bc35`, audit + build pass, 2026-04-28)
- [x] M8 — `HotkeyRecorderNSView` + SwiftUI wrapper; validation (missing-modifier + modifier-only reject) (commit `0e4f6ae`, 7/7 tests pass, 2026-04-28). Internal-conflict popover lives in M9 since it depends on the resolved map.
- [x] M9 — `ShortcutsSettingsView` replacing `ComingSoonPane(title: "Shortcuts")`; search, category groups, recorder cell, disable, per-row reset with cascade dialog, restore-all (commit `433221c`, CodansCore 369/369 + app-tier shortcut suites 32/32 pass, 2026-04-28)
- [x] M10 — `agent-skills:code-reviewer` pass + follow-up fix commits; final lint + three-target test run (commit `3f6a698`, CodansCore 370/370 + app-tier shortcut suites pass, 2026-04-28)

## Surprises & Discoveries

(None yet)

## Decision Log

- **D1** (from design doc §6.1): bindings persist as virtual `keyCode` + `ModifierMask`, not `Character` + modifiers. Rationale lives in the design doc; the consequence for execution is that `ShortcutDisplay` (M4) must run `UCKeyTranslate` against the active keyboard layout for keycap rendering, against US-QWERTY for SwiftUI `KeyEquivalent` binding.
- **D2** (from design doc §6.2): shortcuts persist to a standalone `~/.config/codans/shortcuts.json` file, not into `Settings.json`. M3 mirrors `SettingsStore` boilerplate (atomic write, 500 ms debounce, broken-file backup) into a parallel `ShortcutsStore`.
- **D3** (from design doc §6.3): `CommandID` is a closed enum with `CaseIterable`. The numbered tab/sidebar cases (`switchToTab1..9`, `selectWorktreeAt1..9`) are spelled out individually so they appear as first-class JSON keys and participate in exhaustive switches.
- **D4** (per execution constraints from user, 2026-04-28): every milestone produces exactly one commit (or, where M2 splits, one per parallel sub-agent leaf). The commit only stages files that milestone touched — never `git add -A` / `git add -u`. Commit messages do **not** carry a `Co-Authored-By` trailer.
- **D5** (per execution constraints from user, 2026-04-28): M2's five pure-data leaves (override store, resolver, reset planner, three conflict detectors) parallelize via `Agent` sub-agents using `general-purpose` type after M1 lands. They share the base types from M1 but otherwise touch disjoint files; each sub-agent owns one or two new files plus its tests. Master agent commits each leaf as it completes. M4 (display) and M5 (env+modifier) similarly parallelize after M3 lands — they share zero files.
- **D6** (Project.swift handling): `CodansCore/Shortcuts/` is already declared as a `buildableFolder` in `apps/mac/Project.swift:38`, so new files dropped there are picked up by `make mac-generate` automatically. New nested test folders (`CodansCoreTests/Shortcuts`, `codans/Tests/Shortcuts`) require explicit `buildableFolders` entries — added in the same commit as the first test file under each path. New app-tier folders under `codans/App/Shortcuts/` are covered by the recursive `codans/App` parent entry; verified by analogy with `codans/App/Commands/` which is not separately listed and compiles fine.

## Outcomes & Retrospective

Shipped end-to-end on 2026-04-28 across 14 commits (`c0ce289` docs → `3f6a698` review fixups). All ten milestones landed, with M2 splitting into M2.0 (sequential prefix) plus four parallel sub-agent leaves (M2.A–M2.D) as planned.

**What we got**:

- A closed `CommandID` enum and a single `ShortcutSchema.app` defaults table covering 28 user-bindable commands (13 main-window + 9 sidebar + 6 system/general).
- A persistent `~/.config/codans/shortcuts.json` overrides layer with 500 ms debounced atomic writes and broken-file backup.
- Three-tier conflict detection: macOS system-reserved (read at runtime from `com.apple.symbolichotkeys`), AppKit standard-menu reserved (hardcoded six-entry set), and app-internal (configurable-vs-configurable).
- Cascading reset planning that handles swap conflicts and three-way cycles deterministically.
- A SwiftUI `Settings → Shortcuts` pane with search, category grouping, an `NSViewRepresentable`-backed chord recorder, source pills, per-row reset, restore-all, and disable.
- Layout-aware display rendering via `UCKeyTranslate` plus stable SwiftUI bindings against the user's ASCII-capable layout.
- 64 unit tests across 11 suites — 6 in CodansCoreTests/Shortcuts, 4 in codansTests, plus the existing palette suites that now exercise the registry-aware row renderer.

**What changed during execution vs. the plan**:

- **D7 (M2.0 fix)**: `CommandID` needed an explicit `CodingKeyRepresentable` conformance for `[CommandID: ShortcutBinding]` to encode as a JSON object instead of a flat key/value array. Caught by the round-trip test in M2.0; one-line fix.
- **D8 (M4 conflict)**: `Carbon.HIToolbox.EventModifiers` (a `UInt32` typedef) collided with SwiftUI's `EventModifiers` struct. Fully qualified to `SwiftUI.EventModifiers` at every annotated call site; dropped the unnecessary AppKit import in `ShortcutDisplay.swift`.
- **D9 (M6 scope refinement)**: rather than threading a new dependency through `CommandPaletteFeature.appeared(...)` to give the palette its registry-aware shortcut hint, added an optional `commandID: CommandID?` field on `CommandPaletteItem` and let `CommandPaletteView.row(...)` derive the chord from `@Environment(\.resolvedShortcuts)` at render time. Avoids touching any TCA action/test signatures and keeps the build pure-additive.
- **D10 (M8 typing fix)**: `HotkeyRecorderNSView.RejectionReason` had to conform to `Error` so it could be the `Failure` type in `Result<…, RejectionReason>`. One-line addition.
- **D11 (M10 review)**: code-reviewer agent flagged five blocking/should-fix items; resolved in `3f6a698`:
  1. **(blocking)** wired `SystemReservedDetector` into `ShortcutsSettingsView.handleCapture` — it had been built and tested but never invoked from the user-facing flow;
  2. defensive guard on `parameters[2] < 0` in `SystemReservedDetector` (sentinel "no chord" markers no longer decode every modifier);
  3. `ShortcutsStore.deinit` cancels `pendingSaveTask`; recheck-on-cancellation hardened the debounce race window;
  4. `ShortcutsStore.update(_:to:)` now coalesces a no-op revert (override == schema default) into a `clear`, and a new `resolveConflict(disabling:assigning:to:)` batches the replace flow into a single observable mutation;
  5. `ShortcutSchemaAuditTests` swapped `kVK_ANSI_*` constants for numeric literals so the audit no longer tautologically reads from the same Carbon header the production schema imports.

  The `ShortcutDisplay` "US-QWERTY vs ASCII-capable" point was resolved as a doc alignment (the code's behavior — accept the user's chosen ASCII layout — is the right product call; the comment now states it accurately).

**Carryovers / non-blocking nits not addressed**:

- `HotkeyRecorderNSView.modifierKeyCodes` uses numeric `0x37` literals where it could use `kVK_Command` constants — cosmetic, deferred.
- A more defensive `DispatchQueue.main.async` wrapping inside `HotkeyRecorderView`'s closures — none of the existing call paths would actually race during `updateNSView`; deferred unless we see SwiftUI's runtime warnings.
- An explicit US-QWERTY layout lookup (instead of the user's ASCII-capable layout) — design decision punt; revisit if a Dvorak user reports surprise.

**Pre-existing test failure observed**:

- `MainWindowCommandsTests.commandEDispatchesOpenDefaultForCurrentWorktreeAndForwardsToEditor` records 3 issues at `await store.send(.openDefaultForCurrentWorktreeRequested)`. Confirmed pre-existing on `M5 baseline (ac50e08)`; unrelated to the shortcut feature; left for a separate fix in the codans test infra.

**Unrelated working-copy drift not committed by this branch**:

- `apps/mac/codans/App/Features/HierarchySidebar/TagChipFooter.swift` carries swift-format whitespace changes from a sub-agent's `make check` run; not part of this feature's diff.
- `apps/mac/codans/App/AppIcon.icon/Assets/Image 1.png` is an untracked asset file unrelated to this work.

**Lessons**:

- M2's parallel-leaf dispatch worked cleanly: 4 independent `general-purpose` agents finished within ~3 minutes of each other and all returned with green tests on first try. The shared types (M1 + M2.0) were small enough that the agents' isolated reading of the design doc plus type files was sufficient.
- The schema audit + golden-table pinning is the right safety net for migrations like this: M6/M7 each rewrote a chunk of literal `.keyboardShortcut(...)` calls and the audit caught zero drift, exactly because no drift happened.
- The reviewer's blocking finding (missing `SystemReservedDetector` wire) was a milestone-level miss that no test had a chance to catch (the detector's own tests asserted its behavior in isolation; the settings pane's behavior wasn't unit-tested at the integration level). Worth budgeting an integration test for the recorder→detector→store path next time a similar three-tier validator is built.

## Context and Orientation

Related documents:

- Design doc (this plan's source of truth): `docs/design-docs/keyboard-shortcuts.md`
- Architecture doc: `docs/architecture.md`
- Existing settings ExecPlans for atomic-store boilerplate reference: `docs/exec-plans/0009-mw-t1-sidebar.md`, plus `docs/design-docs/settings-base.md`

Key source files (full repository-relative paths):

- `apps/mac/CodansCore/Shortcuts/CommandPaletteShortcut.swift` — current `keyChar` / `displayString` constants for `⌘P`. **Deleted in M6** after consumers migrate to the registry.
- `apps/mac/CodansCore/Settings/Settings.swift` — pattern reference for the v3-versioned `Codable` struct, `defaultURL()` helper, and migration shape. M1's `ShortcutSchema.swift` and M3's `ShortcutsStore.swift` mirror these patterns at v1.
- `apps/mac/codans/App/Features/Settings/SettingsStore.swift` — pattern reference for `@MainActor @Observable` file-owning store with `AtomicFileStore`, 500 ms debounce, broken-file backup. M3's `ShortcutsStore` is a parallel implementation.
- `apps/mac/CodansCore/AtomicFileStore.swift` (or wherever the helper lives — `Bash` audit at M3 entry) — reused as-is for the new shortcuts file write path.
- `apps/mac/codans/App/Commands/MainWindowCommands.swift` — defines thirteen window-scope bindings. **Rewritten in M6** to read every chord from the env-injected `ResolvedShortcutMap`.
- `apps/mac/codans/App/CodansApp.swift` — app composition root and the `⌘,` settings binding (line 85). M6 instantiates `ShortcutsStore` here, injects `\.resolvedShortcuts` at the top of the view tree, and leaves the literal `⌘,` binding in place (registry tracks it as `.systemFixed` for display only).
- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift` — sidebar row hotkey block at lines 619–631 plus the `hotkeyModifiers` constant at line 614. **Rewritten in M7**.
- `apps/mac/codans/App/Features/Settings/SettingsSection.swift` — already enumerates `.shortcuts` (line 17). No edit needed; the section is already wired to the sidebar.
- `apps/mac/codans/App/Features/Settings/SettingsWindowView.swift` — line 83 currently routes `.shortcuts` to `ComingSoonPane(title: "Shortcuts")`. **One-line edit in M9** to point at the new `ShortcutsSettingsView`.
- `apps/mac/codans/App/Features/CommandPalette/CommandPaletteItems.swift` (lines 79–124) — currently builds `KeyEquivalentDescriptor` rows from inline literal arrays. **Rewritten in M6** to derive each hint from the resolved map.
- `apps/mac/codans/Runtime/Status/StatusMotivationalView.swift` — currently reads `CommandPaletteShortcut.displayString`. **Rewritten in M6** to derive the hint from the resolved map.
- `apps/mac/Project.swift` — Tuist project manifest; touched in M2 and M3 for new test `buildableFolders` entries (`CodansCoreTests/Shortcuts`, `codans/Tests/Shortcuts`).

Terms of art:

- **Registry** — the schema-defaults table plus the override-store overlay, exposed at runtime as a `ResolvedShortcutMap` keyed by `CommandID`. The single source of truth for every chord display, every menu binding, and every conflict check.
- **Schema audit** — a unit test that iterates `CommandID.allCases`, asserts each has exactly one entry in `ShortcutSchema.app.entries`, and snapshot-checks each default `(keyCode, modifiers)` pair against a hardcoded golden table that mirrors today's literal call sites. Pinned during M1 and unchanged thereafter; the test breaks if M6/M7 silently drift a chord during the migration.
- **Cascade reset** — when resetting command A would re-collide with command B's user override, `ShortcutResetPlanner` returns a plan that also clears B. The settings UI surfaces the cascade in the confirmation dialog so the user understands what they are about to lose.
- **Disabled binding** — `ShortcutBinding.isEnabled == false`. Persists the keyCode/modifiers but does not bind. Distinct from "no override" (defaults active) and from "no chord" (`binding == nil`, not used in v1 since every default is non-nil).
- **`buildableFolders`** — Tuist's mechanism for listing directories whose Swift files compile into a target. The CodansCore framework target lists `CodansCore/Shortcuts` (recursive); test targets list each nested subfolder explicitly.
- **Schema audit golden table** — a single array literal in `ShortcutSchemaAuditTests` that maps each `CommandID` to its expected `(keyCode, ModifierMask)` pair. Lifted from a one-time read of the current `MainWindowCommands` / `HierarchySidebarView` source. Updating it requires test failure as a forcing-function for review.

## Plan of Work

The work runs as ten milestones, vertically sliced — each milestone is independently buildable, lints clean, and either preserves or extends user-visible behavior. Behavior change starts at M6; M1–M5 add types and infrastructure that no live code path consumes yet, so they cannot regress anything.

### Milestone 1: CodansCore types and schema audit

This milestone introduces the typed registry as inert data: a closed `CommandID` enum, the immutable `ShortcutBinding` struct, the `ShortcutScope` enum, and the `ShortcutSchema.app` defaults table. Nothing imports any of it yet; the only test is the schema audit, which guards against future drift.

Work:

- Add `apps/mac/CodansCore/Shortcuts/CommandID.swift` declaring the closed `String`-raw-valued enum exactly as listed in the design doc §3.3.1. Conformances: `String`, `CaseIterable`, `Hashable`, `Sendable`, `Codable`.
- Add `apps/mac/CodansCore/Shortcuts/ShortcutBinding.swift` declaring `ShortcutBinding` (with `keyCode: UInt16`, `modifiers: ModifierMask`, `isEnabled: Bool`, all stored), `ModifierMask` (`OptionSet`-backed `UInt8` with `.command`, `.option`, `.control`, `.shift`), and the `Codable` shape that emits `modifiers` as a sorted string array (`["command", "shift"]`) for human-readable JSON.
- Add `apps/mac/CodansCore/Shortcuts/ShortcutScope.swift` declaring the three-case enum.
- Add `apps/mac/CodansCore/Shortcuts/ShortcutSchema.swift` declaring `ShortcutSchema`, `ShortcutSchema.Entry`, the `Category` enum (`general`, `tabs`, `sidebar`, `system`), and `ShortcutSchema.app: ShortcutSchema` with one entry per `CommandID` case. Defaults are read off the existing call sites: `⌘,` for `.openSettings`, `⌘P` for `.commandPaletteToggle`, `⌘E` for `.openInDefaultEditor`, `⌘⇧G` for `.toggleGitViewer`, `⌘F` for `.filterTags`, `⌘T` / `⌘W` / `⌘⇧[` / `⌘⇧]` for the tab quartet, `⌥⌘1..9` for `.switchToTab1..9`, `⌃⌘1..9` for `.selectWorktreeAt1..9`, plus `⌘Q` for `.quit` (`.systemFixed`, display-only — never bound by us, but listed for the Settings pane).
- Add `apps/mac/CodansCoreTests/Shortcuts/ShortcutSchemaAuditTests.swift` with two tests:
  - `everyCommandIDHasExactlyOneSchemaEntry` — iterate `CommandID.allCases`, verify membership in `Set(ShortcutSchema.app.entries.map(\.id))` and absence of duplicates.
  - `defaultsMatchGoldenTable` — compare `ShortcutSchema.app.entries` against an inline golden `[CommandID: (UInt16, ModifierMask)]` literal that mirrors the current `MainWindowCommands` and `HierarchySidebarView` call sites. Use the `Carbon.HIToolbox` `kVK_*` constants for keyCodes (e.g. `kVK_ANSI_P`, `kVK_ANSI_G`, `kVK_ANSI_LeftBracket`).
- Add `CodansCoreTests/Shortcuts` to `apps/mac/Project.swift` `buildableFolders` for the `CodansCoreTests` target.
- `make mac-generate && make mac-build` and `make mac-check` from `apps/mac/`.

Acceptance: the project builds, `CodansCoreTests` compiles, and the audit tests pass. No app-target code consumes any of the new types yet, so manual app behavior is unchanged. **Commit M1** stages only:

```
apps/mac/CodansCore/Shortcuts/CommandID.swift
apps/mac/CodansCore/Shortcuts/ShortcutBinding.swift
apps/mac/CodansCore/Shortcuts/ShortcutScope.swift
apps/mac/CodansCore/Shortcuts/ShortcutSchema.swift
apps/mac/CodansCoreTests/Shortcuts/ShortcutSchemaAuditTests.swift
apps/mac/Project.swift
```

### Milestone 2: Override store, resolver, reset planner, and conflict detectors

This milestone adds the resolution logic that turns the schema and a user override store into a `ResolvedShortcutMap`, plus the three conflict detectors and the cascading-reset planner. Everything stays in CodansCore (still SwiftUI-free, still AppKit-free for the most part — `SystemReservedDetector` reads `CFPreferences` directly via `Foundation`'s `UserDefaults(suiteName: "com.apple.symbolichotkeys")`, which is acceptable in CodansCore).

Work proceeds as one sequential prefix (the override store + resolver, since the rest of the milestone's leaves depend on `ResolvedShortcutMap`) followed by four parallel leaves dispatched as `Agent` sub-agents:

**Sequential prefix (master agent):**

- Add `apps/mac/CodansCore/Shortcuts/ShortcutOverrideStore.swift` declaring the `Codable` document type. JSON shape per design doc §3.3.5: top-level `version: Int` plus sparse `overrides: [CommandID: ShortcutBinding]`.
- Add `apps/mac/CodansCore/Shortcuts/ShortcutResolver.swift` declaring `ResolvedShortcut`, `ResolvedShortcut.Source`, `ResolvedShortcutMap` typealias, and the pure `ShortcutResolver.resolve(schema:overrides:)` function.
- Add `apps/mac/CodansCoreTests/Shortcuts/ShortcutOverrideStoreCodableTests.swift` exercising round-trip Codable with the documented JSON shape.
- Add `apps/mac/CodansCoreTests/Shortcuts/ShortcutResolverTests.swift` with three cases: empty overrides ⇒ schema verbatim; one override ⇒ merged; one disabled override ⇒ resolved with `isEnabled = false` and `source = .userOverride`.
- **Commit M2.0** stages: `ShortcutOverrideStore.swift`, `ShortcutResolver.swift`, the two new test files.

**Parallel leaves (four `Agent` sub-agents, dispatched concurrently):**

The four leaves below share read-only access to the M2.0 types and write to disjoint files. Master dispatches them as four `Agent` calls in a single message, using `subagent_type: "general-purpose"`. Each agent's brief: read the design doc §3.4 / §3.4.1 plus the listed reference files, implement its own file plus tests, run `make mac-check` from `apps/mac/`, and report the diff.

- **Leaf A — `ShortcutResetPlanner`** (one agent): `apps/mac/CodansCore/Shortcuts/ShortcutResetPlanner.swift` plus `apps/mac/CodansCoreTests/Shortcuts/ShortcutResetPlannerTests.swift`. Tests must cover the swap-conflict case (A's default == B's user override; B's default == A's user override → reset of A cascades to reset B).
- **Leaf B — `SystemReservedDetector`** (one agent): `apps/mac/CodansCore/Shortcuts/ConflictDetectors/SystemReservedDetector.swift` plus tests. Reads `com.apple.symbolichotkeys` via `UserDefaults(suiteName:)`. Parses `AppleSymbolicHotKeys` plist into a set of `(keyCode, ModifierMask)` triples for chords with `enabled == true`. Cached per-process; refresh hook for `UserDefaults.didChangeNotification`. Tests use a mock `UserDefaults` instance with a hand-crafted plist.
- **Leaf C — `AppKitReservedDetector`** (one agent): `apps/mac/CodansCore/Shortcuts/ConflictDetectors/AppKitReservedDetector.swift` plus tests. Static hardcoded set: `⌘Q`, `⌘W`, `⌘H`, `⌘M`, `⌘,`, `⌘?`. Pure function `isReserved(keyCode:modifiers:) -> Bool`.
- **Leaf D — `InternalConflictDetector`** (one agent): `apps/mac/CodansCore/Shortcuts/ConflictDetectors/InternalConflictDetector.swift` plus tests. Pure function `conflicts(in: ResolvedShortcutMap, candidate: ShortcutBinding, excluding: CommandID) -> CommandID?`. Returns the colliding command's ID or `nil`. Tests cover: same chord different scope (no conflict reported for `.systemFixed` rows), disabled override (no conflict), exact match (conflict).

Each leaf produces its own commit (**M2.A**, **M2.B**, **M2.C**, **M2.D**). Master enforces the no-`git-add-A` rule by reviewing each agent's reported file list and staging only those paths.

After all four leaves land:

- Master adds `apps/mac/Project.swift` entry for `CodansCoreTests/Shortcuts/ConflictDetectors` if `buildableFolders` requires nested registration; otherwise merges the conflict-detector test files into the flat `CodansCoreTests/Shortcuts` directory to keep the manifest minimal. Default plan: flat.
- `make mac-generate && make mac-build && make mac-check` from `apps/mac/`.

Acceptance: all five new types compile under CodansCore; their unit tests pass; no app-target code consumes any of them yet; behavior unchanged.

### Milestone 3: ShortcutsStore (persistence)

This milestone introduces the live store that owns `~/.config/codans/shortcuts.json`, mirroring `SettingsStore` in shape and lifecycle.

Work:

- Add `apps/mac/codans/App/Shortcuts/ShortcutsStore.swift` declaring an `@MainActor @Observable final class ShortcutsStore` with: `private(set) var overrides: ShortcutOverrideStore`, computed `var resolved: ResolvedShortcutMap`, `update(_ id: CommandID, to binding: ShortcutBinding)`, `disable(_ id: CommandID)`, `clear(_ id: CommandID)`, `resetAll()`. Use `AtomicFileStore` (locate via `grep -rn "AtomicFileStore" apps/mac/`) and the `SettingsStore`-style 500 ms debounce + broken-file backup. File URL helper: `static func defaultURL(home:) -> URL` returning `~/.config/codans/shortcuts.json`.
- Add `apps/mac/codans/Tests/Shortcuts/ShortcutsStoreTests.swift` with three cases: round-trip write/read; debounce coalesces a burst of three `update` calls into one save (assert `AtomicFileStore` write count); broken-file backup on corrupted JSON.
- Add `codans/Tests/Shortcuts` to `apps/mac/Project.swift` `buildableFolders` for the `codansTests` target.
- `make mac-generate && make mac-build && make mac-check`.

Acceptance: tests pass; app still launches with no behavior change because no caller constructs a `ShortcutsStore` yet. **Commit M3** stages: `ShortcutsStore.swift`, the test file, `Project.swift`.

### Milestone 4: ShortcutDisplay (UCKeyTranslate layer)

This milestone implements the layout-aware keycap renderer plus the SwiftUI `KeyEquivalent` conversion helper. It is independent of M3 and could be parallelized; in this plan it follows M3 sequentially because both are small and the cumulative diff stays clean.

Work:

- Add `apps/mac/codans/App/Shortcuts/ShortcutDisplay.swift` exposing:
  - `static func keycap(for keyCode: UInt16) -> String` — runs `UCKeyTranslate` against `TISCopyCurrentKeyboardLayoutInputSource()`. Special-cases arrows / function keys / Esc / Return / Tab / Space / numeric keypad to fixed glyphs. Fallback chain on `UCKeyTranslate` failure: active layout → US-QWERTY → `<0xNN>` hex stub.
  - `static func chord(for binding: ShortcutBinding) -> String` — concatenates modifier glyphs (⌃⌥⇧⌘ canonical order) plus `keycap(for:)`.
  - `static func keyEquivalent(for keyCode: UInt16) -> KeyEquivalent?` — maps to SwiftUI's `KeyEquivalent`. For arrow / function / Return / Tab / Space / Esc, returns the SwiftUI typed value. For character keys, runs `UCKeyTranslate` against US-QWERTY and wraps the resulting `Character`. Returns `nil` only for keyCodes that have no SwiftUI mapping.
  - `static var displayInvalidationToken: AnyPublisher<Void, Never>` — emits on `kTISNotifySelectedKeyboardInputSourceChanged` distributed notifications. Used by `ShortcutsStore` to bump an observable token that forces SwiftUI re-renders.
- Add `apps/mac/codans/Tests/Shortcuts/ShortcutDisplayTests.swift`. Tests programmatically install the U.S. ABC layout via `TISCreateInputSourceList` (or equivalent) for determinism, then assert that `keyCode = kVK_ANSI_G` renders `"G"`, that `kVK_ANSI_LeftBracket` renders `"["`, that `kVK_UpArrow` renders `"↑"`, that an invalid keyCode falls through to the hex stub.

Acceptance: tests pass; no behavior change. **Commit M4** stages: `ShortcutDisplay.swift`, the test file.

### Milestone 5: SwiftUI environment + view modifier

This milestone introduces the wiring that lets call sites read shortcuts from the registry. Like M4, independent of M3; sequenced after for diff hygiene.

Work:

- Add `apps/mac/codans/App/Shortcuts/ShortcutEnvironment.swift` declaring `private struct ResolvedShortcutsKey: EnvironmentKey { static let defaultValue: ResolvedShortcutMap = [:] }` and the `EnvironmentValues.resolvedShortcuts` accessor.
- Add `apps/mac/codans/App/Shortcuts/View+appKeyboardShortcut.swift` declaring two overloads:
  - `View.appKeyboardShortcut(_ id: CommandID, in map: ResolvedShortcutMap) -> some View` — explicit-map form for `Commands` scenes.
  - `View.appKeyboardShortcut(_ id: CommandID) -> some View` — env-driven form for ordinary view contexts; reads `@Environment(\.resolvedShortcuts)`.
  Both short-circuit (return `self` unchanged) when the resolved entry is missing, disabled, or its keyCode has no `KeyEquivalent`.
- Add `apps/mac/codans/Tests/Shortcuts/AppKeyboardShortcutTests.swift` with one snapshot-style test: a `@Test func appliedBindingMatchesRegistry` that constructs a tiny view tree, injects a known `ResolvedShortcutMap`, and asserts via Inspector or a behaviour proxy that the modifier produced the expected binding. If view-introspection is too heavy, instead unit-test the helper that lives behind the modifier (a non-view `static func resolve(_ id: CommandID, in map: ResolvedShortcutMap) -> (KeyEquivalent, EventModifiers)?`) and trust the modifier's three-line `@ViewBuilder` body.

Acceptance: tests pass. **Commit M5** stages: `ShortcutEnvironment.swift`, `View+appKeyboardShortcut.swift`, the test file.

### Milestone 6: Wire registry into the app — first behavior-touching milestone

This is the load-bearing migration. The thirteen `MainWindowCommands` literals plus the two `CommandPaletteShortcut` consumers all switch to reading from the registry. Defaults are unchanged, so the visible behavior is identical to today's hardcoded build.

Work (single sequential thread; the file count is high enough that splitting would risk audit-test churn):

- Edit `apps/mac/codans/App/CodansApp.swift`:
  - Instantiate a single `ShortcutsStore` alongside the existing `SettingsStore` (look for the `appState` / `store` setup in the `CodansApp` `init` or the `WindowGroup` body; mirror the `SettingsStore` pattern).
  - Inject `\.resolvedShortcuts` at the top of the view tree: `ContentView(store: …).environment(\.resolvedShortcuts, shortcutsStore.resolved)`.
  - Pass the same store into the `MainWindowCommands` constructor (it cannot read `@Environment` directly inside `Commands`).
- Edit `apps/mac/codans/App/Commands/MainWindowCommands.swift`:
  - Add a `let shortcuts: ResolvedShortcutMap` stored property; the `CodansApp` body passes the store's `resolved` value.
  - Replace each of the thirteen `.keyboardShortcut("…", modifiers: …)` calls with `.appKeyboardShortcut(.commandID, in: shortcuts)`. The `ForEach(1...9)` block uses a small switch to pick the right `CommandID` per index.
  - Update the doc-comment block at the top: replace the inline chord listing with a pointer to `ShortcutSchema.app` and the registry doc.
- Edit `apps/mac/codans/Runtime/Status/StatusMotivationalView.swift`:
  - Read `@Environment(\.resolvedShortcuts)` and derive the palette hint via `ShortcutDisplay.chord(for: shortcuts[.commandPaletteToggle]?.binding ?? defaultBinding)`. Fallback: the original literal `"⌘P"` if the resolved map is empty (defensive — env should always be populated).
- Edit `apps/mac/codans/App/Features/CommandPalette/CommandPaletteItems.swift`:
  - The two literal `KeyEquivalentDescriptor(["⌘", "⇧", "G"])`-style call sites at lines 85, 98, 124 derive their hint from the resolved map. Pass the map in via the `build(for:)` arguments (the `CommandPaletteFeature.State` / call-site signature already takes a context object; extend it minimally).
- Delete `apps/mac/CodansCore/Shortcuts/CommandPaletteShortcut.swift`. Verify no lingering references via `grep -rn "CommandPaletteShortcut" apps/mac/`.
- `make mac-generate && make mac-build && make mac-check`. Run `xcodebuild test -scheme CodansCoreTests` and the codans test scheme.
- Manual smoke: build, run, exercise each chord — `⌘P` toggles palette, `⌘E` opens editor, `⌘⇧G` toggles git viewer, `⌘F` focuses tag filter, `⌘T` / `⌘W` / `⌘⇧[` / `⌘⇧]` operate tabs, `⌥⌘1..9` switches tabs.

Acceptance: schema audit (M1 test) still passes — proves no chord drifted during the rewrite. All thirteen window chords behave identically to pre-M6. Palette hint and motivational hint render `⌘P`. **Commit M6** stages exactly:

```
apps/mac/codans/App/CodansApp.swift
apps/mac/codans/App/Commands/MainWindowCommands.swift
apps/mac/codans/Runtime/Status/StatusMotivationalView.swift
apps/mac/codans/App/Features/CommandPalette/CommandPaletteItems.swift
apps/mac/CodansCore/Shortcuts/CommandPaletteShortcut.swift   (deletion)
```

### Milestone 7: Sidebar row hotkeys

Migrate the nine `⌃⌘1..9` invisible-Button hotkeys to read from the registry. Behavior preserved.

Work:

- Edit `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift`:
  - Inject `@Environment(\.resolvedShortcuts) private var shortcuts` on the row view.
  - Inside the row's `if let hotkeyNumber` branch (lines 619–631), swap `.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: Self.hotkeyModifiers)` for `.appKeyboardShortcut(commandID(forSidebarRow: hotkeyNumber))` where the helper maps `1...9 → CommandID.selectWorktreeAt1...9`.
  - Delete `private static let hotkeyModifiers: EventModifiers = [.command, .control]` at line 614 — no longer referenced.
- Manual smoke: `⌃⌘1..9` still selects the matching worktree row; the keycap chip rendered next to the row title (lines 600–611) keeps showing `⌃⌘N` (it reads from `hotkeyNumber` directly, not from the modifier set, so no edit needed).

Acceptance: identical sidebar selection behavior; lint clean. **Commit M7** stages exactly: `HierarchySidebarView.swift`.

### Milestone 8: Hotkey recorder

Introduce the recorder UI used by M9's settings pane. Self-contained — nothing consumes it yet.

Work:

- Add `apps/mac/codans/App/Shortcuts/HotkeyRecorder/HotkeyRecorderNSView.swift`:
  - `final class HotkeyRecorderNSView: NSView, NSTextFieldDelegate-equivalent` (use raw `acceptsFirstResponder`, `becomeFirstResponder`, `resignFirstResponder`, and `keyDown(with:)` overrides).
  - On `becomeFirstResponder`, install a local-only `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` returning `nil` to swallow events. Captures `(keyCode: UInt16, modifiers: NSEvent.ModifierFlags)`.
  - Validation pipeline: reject if `modifiers` lacks `⌘`/`⌥`/`⌃` (shows "Add at least one modifier" via callback). Reject if only modifier is `⇧`. Otherwise convert to `ModifierMask` and run conflict detectors via callbacks the host injects.
  - Emits via callback closures: `onCommit(ShortcutBinding)`, `onReject(reason: RejectionReason)`, `onCancel()`.
- Add `apps/mac/codans/App/Shortcuts/HotkeyRecorder/HotkeyRecorderView.swift`:
  - `struct HotkeyRecorderView: NSViewRepresentable` wrapping the AppKit view.
  - SwiftUI surface: `init(currentBinding: ShortcutBinding?, conflictDetector: (ShortcutBinding) -> ConflictResult, onCommit: (ShortcutBinding) -> Void)`.
  - Renders the current binding via `ShortcutDisplay.chord(for:)` when not recording; placeholder "Type a chord…" while recording. 200 ms shake animation on rejection.
- Add `apps/mac/codans/Tests/Shortcuts/HotkeyRecorderViewTests.swift` — assert the NSView's keyDown handler converts a known `(keyCode, modifierFlags)` pair into the expected `ShortcutBinding`, and that bare ⇧ + letter is rejected. This is doable without a running RunLoop by invoking the view's `keyDown(with:)` directly with a synthesized `NSEvent`.

Acceptance: tests pass; nothing consumes the recorder yet so app behavior unchanged. **Commit M8** stages: the two recorder files plus its test file.

### Milestone 9: Shortcuts settings pane

Replace the `ComingSoonPane` stub with the real Shortcuts pane. This is the user-visible payoff.

Work:

- Add `apps/mac/codans/App/Features/Settings/Panes/ShortcutsSettingsView.swift` rendering the layout sketched in design doc §3.9: search bar, restore-all button, four category sections (`general`, `tabs`, `sidebar`, `system`), one row per `ShortcutSchema.Entry`. Each row shows the title, the recorder cell, a per-row reset glyph (visible only when source is `.userOverride`), and a source pill (`Default` / `Custom` / `Disabled`). Context menu on the recorder offers "Disable shortcut".
  - The view reads `@Environment(\.resolvedShortcuts)` for display and writes via a `@Bindable var store: ShortcutsStore` for mutations.
  - Search filters by lowercased substring against the rendered title and `ShortcutDisplay.chord(...)`.
  - Cascade reset: when the per-row reset is tapped, call `ShortcutResetPlanner.plan(resetting:)` and present a `confirmationDialog` whose body lists every cascaded `CommandID` by title. On confirm, apply the plan via `store.applyResetPlan(...)`. (M9 adds the matching method to `ShortcutsStore` if absent — small extension.)
  - Internal-conflict popover during recorder commit: the recorder's `conflictDetector` callback wraps `InternalConflictDetector.conflicts(in:candidate:excluding:)`. When non-`nil`, the pane shows a confirmation popover ("Replace? Currently bound to *Toggle Git Viewer*.") with Replace / Cancel.
- Edit `apps/mac/codans/App/Features/Settings/SettingsWindowView.swift` line 83: change `case .shortcuts: ComingSoonPane(title: "Shortcuts")` to `case .shortcuts: ShortcutsSettingsView(store: shortcutsStore)`. Wire `shortcutsStore` through the same path `SettingsStore` already uses (likely an `@Bindable` from `CodansApp` or via a child `Environment`).
- Add `apps/mac/codans/Tests/Shortcuts/ShortcutsSettingsViewTests.swift` with two snapshot tests via `SnapshotTesting` (already a test target dependency per `Project.swift:270`):
  - Default state — empty overrides, every row shows `Default`.
  - One overridden + one disabled — the appropriate pills, the reset glyph on the overridden row.
- `make mac-generate && make mac-build && make mac-check`.
- Manual smoke: open Settings → Shortcuts. Rebind `⌘T → ⌃T`, verify menu updates and `⌃T` opens a new tab and `⌘T` no longer does. Disable `⌘⇧G`, verify the menu item shows no chord and the chord no longer fires the action. Click reset on `⌘T`, verify it reverts. Click Restore All, verify all overrides clear. Switch input source (English ABC → Pinyin – Simplified) and verify keycaps re-render.

Acceptance: Settings pane is usable end-to-end; all three test schemes still pass. **Commit M9** stages: `ShortcutsSettingsView.swift`, `SettingsWindowView.swift`, the snapshot test file plus its `__Snapshots__` directory output, and any tiny `ShortcutsStore` API additions made in this milestone.

### Milestone 10: Code review and follow-up

Hand the branch off to `agent-skills:code-reviewer` for a five-axis review (correctness, readability, architecture, security, performance). Apply fixes per its findings.

Work:

- Run the code-reviewer agent with prompt anchored to the design doc and this ExecPlan as context. Provide the diff range `git log main..HEAD --oneline` produced by M1–M9.
- For each actionable finding, apply the fix in a focused commit. Trivial style nits roll up into one fixup commit; substantive fixes get their own.
- Re-run lint and three test schemes after each fixup.

Acceptance: reviewer's "blocking" findings are resolved; "non-blocking" findings are either resolved or recorded in this plan's Surprises & Discoveries with rationale. **Commit M10.x** for each fix; final `git log main..HEAD --oneline` reads as a clean linear history of M1 → M2.0 → M2.A..M2.D → M3..M9 → M10.x fixups.

## Concrete Steps

The standard cadence inside `apps/mac/`:

```
$ make mac-generate                # after Project.swift edits
$ make mac-build
$ make mac-check                   # swift-format + swiftlint
```

Test runs (issue from `apps/mac/`):

```
$ xcodebuild -workspace codans.xcworkspace -scheme CodansCoreTests \
    -destination 'platform=macOS,arch=arm64' test | xcbeautify
$ xcodebuild -workspace codans.xcworkspace -scheme codans \
    -destination 'platform=macOS,arch=arm64' test | xcbeautify
$ xcodebuild -workspace codans.xcworkspace -scheme CodansKitTests \
    -destination 'platform=macOS,arch=arm64' test | xcbeautify
```

Expected after a clean M1 run: `CodansCoreTests` reports `2 tests, 0 failures` for the new `ShortcutSchemaAuditTests`. Adjust totals after each milestone.

Per-milestone commit pattern (issued from repo root):

```
$ git status -s                                   # confirm only intended files
$ git add <explicit paths from milestone>
$ git diff --cached --stat                        # confirm scope
$ git commit -m "<message>"                       # NO --amend, NO -A, NO co-author
```

Commit message convention (matches existing `git log main..HEAD`-equivalent):

- `feat(shortcuts): add CommandID + schema with audit test (M1)`
- `feat(shortcuts): add override store + resolver (M2.0)`
- `feat(shortcuts): add reset planner (M2.A)`
- `feat(shortcuts): add system reserved detector (M2.B)`
- `feat(shortcuts): add appkit reserved detector (M2.C)`
- `feat(shortcuts): add internal conflict detector (M2.D)`
- `feat(shortcuts): persist overrides to shortcuts.json (M3)`
- `feat(shortcuts): layout-aware display via UCKeyTranslate (M4)`
- `feat(shortcuts): SwiftUI environment + appKeyboardShortcut modifier (M5)`
- `refactor(shortcuts): main window commands read from registry (M6)`
- `refactor(shortcuts): sidebar row hotkeys read from registry (M7)`
- `feat(shortcuts): hotkey recorder NSViewRepresentable (M8)`
- `feat(shortcuts): settings shortcuts pane (M9)`
- `fix(shortcuts): <reviewer finding> (M10.x)`

## Validation and Acceptance

The system is complete when:

1. `make mac-build` and `make mac-check` succeed from a fresh `make mac-generate`.
2. All three test schemes pass: `CodansCoreTests`, `codansTests`, `CodansKitTests`.
3. The schema audit test exercised in M1 still passes after M9 — proof that no chord silently drifted during the migration.
4. Manual end-to-end script (run after M9):
   - Build app, launch.
   - Press `⌘P` → palette opens. Press `Esc`. Press `⌘E` → editor opens (or noop if no worktree). Press `⌘⇧G` → git viewer toggles. Press `⌘F` → tag filter focuses. Press `⌘T` → new tab. Press `⌘W` → close tab. Press `⌥⌘3` → switch to tab 3. Press `⌃⌘2` → select sidebar worktree row 2. (All thirteen + nine bindings observed working.)
   - Open Settings → Shortcuts. Verify all rows render with correct chords. Search "git" → only matching rows visible. Click Toggle Git Viewer's chord cell, press `⌃⌥G`, click out → menu chord updates immediately, `⌃⌥G` now toggles git viewer, `⌘⇧G` no longer does.
   - Click the `⟲` next to Toggle Git Viewer → confirmation says "Reset to ⌘⇧G?" → confirm → original chord restored.
   - Right-click a chord cell → "Disable shortcut" → row pill flips to `Disabled`, menu item shows no chord, pressing the chord does nothing. Right-click again → "Enable" → chord restored.
   - Click Restore All → confirmation → every row reverts. `~/.config/codans/shortcuts.json` becomes `{"version":1,"overrides":{}}` (or non-existent).
   - Switch input source to a non-Latin layout (System Settings → Keyboard → Input Sources). Reopen the pane. Keycaps re-render in the active layout's glyphs.

## Idempotence and Recovery

- Each milestone's commit is independently revertible. M6's `CommandPaletteShortcut.swift` deletion is the only structural deletion; reverting M6 restores the file from git.
- `make mac-generate` is idempotent — re-running after no `Project.swift` change is a no-op (Tuist caches).
- The schema audit test is the safety net for M6/M7: if either milestone accidentally drifts a default, the test fails loudly. Rolling back is `git revert <SHA>` of the offending commit.
- `~/.config/codans/shortcuts.json` is created lazily on first user override. To reset state during development, delete the file; the store recreates an empty document on next save.
- If `make mac-generate` fails after a `Project.swift` edit (typically a missing nested `buildableFolder`), the fix is to add the path; no recovery beyond re-running `make mac-generate`.

## Artifacts and Notes

The Carbon `kVK_*` constants used in M1 live in `Carbon.HIToolbox.Events.h`. Representative values referenced by the schema:

```
kVK_ANSI_P            = 0x23
kVK_ANSI_G            = 0x05
kVK_ANSI_E            = 0x0E
kVK_ANSI_F            = 0x03
kVK_ANSI_T            = 0x11
kVK_ANSI_W            = 0x0D
kVK_ANSI_Q            = 0x0C
kVK_ANSI_LeftBracket  = 0x21
kVK_ANSI_RightBracket = 0x1E
kVK_ANSI_Comma        = 0x2B
kVK_ANSI_1 ... 9      = 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19
```

(Note: `kVK_ANSI_5` and `kVK_ANSI_6` are 0x17 / 0x16 respectively — easy to swap. The audit test catches drift either way.)

Schema golden table (paste into `ShortcutSchemaAuditTests.swift`):

```swift
let golden: [CommandID: (UInt16, ModifierMask)] = [
  .openSettings: (UInt16(kVK_ANSI_Comma), [.command]),
  .quit: (UInt16(kVK_ANSI_Q), [.command]),
  .commandPaletteToggle: (UInt16(kVK_ANSI_P), [.command]),
  .openInDefaultEditor: (UInt16(kVK_ANSI_E), [.command]),
  .toggleGitViewer: (UInt16(kVK_ANSI_G), [.command, .shift]),
  .filterTags: (UInt16(kVK_ANSI_F), [.command]),
  .newTab: (UInt16(kVK_ANSI_T), [.command]),
  .closeTab: (UInt16(kVK_ANSI_W), [.command]),
  .previousTab: (UInt16(kVK_ANSI_LeftBracket), [.command, .shift]),
  .nextTab: (UInt16(kVK_ANSI_RightBracket), [.command, .shift]),
  .switchToTab1: (UInt16(kVK_ANSI_1), [.command, .option]),
  // … through switchToTab9
  .selectWorktreeAt1: (UInt16(kVK_ANSI_1), [.command, .control]),
  // … through selectWorktreeAt9
]
```

## Interfaces and Dependencies

Public surfaces that must exist after M5 (the last infrastructure milestone before behavior change):

In `CodansCore/Shortcuts/CommandID.swift`:

```swift
public enum CommandID: String, CaseIterable, Hashable, Sendable, Codable {
  case openSettings, quit, commandPaletteToggle, openInDefaultEditor
  case toggleGitViewer, filterTags
  case newTab, closeTab, previousTab, nextTab
  case switchToTab1, switchToTab2, switchToTab3, switchToTab4, switchToTab5
  case switchToTab6, switchToTab7, switchToTab8, switchToTab9
  case selectWorktreeAt1, selectWorktreeAt2, selectWorktreeAt3
  case selectWorktreeAt4, selectWorktreeAt5, selectWorktreeAt6
  case selectWorktreeAt7, selectWorktreeAt8, selectWorktreeAt9
}
```

In `CodansCore/Shortcuts/ShortcutBinding.swift`:

```swift
public struct ShortcutBinding: Equatable, Hashable, Sendable, Codable {
  public let keyCode: UInt16
  public let modifiers: ModifierMask
  public let isEnabled: Bool
  public init(keyCode: UInt16, modifiers: ModifierMask, isEnabled: Bool = true)
}

public struct ModifierMask: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8)
  public static let command, option, control, shift: ModifierMask
}
```

In `CodansCore/Shortcuts/ShortcutSchema.swift`:

```swift
public struct ShortcutSchema: Sendable {
  public static let currentVersion: Int
  public static let app: ShortcutSchema
  public let version: Int
  public let entries: [Entry]

  public struct Entry: Sendable {
    public let id: CommandID
    public let title: String
    public let category: Category
    public let scope: ShortcutScope
    public let defaultBinding: ShortcutBinding?
  }

  public enum Category: String, CaseIterable, Sendable { case general, tabs, sidebar, system }
}
```

In `CodansCore/Shortcuts/ShortcutOverrideStore.swift`:

```swift
public struct ShortcutOverrideStore: Equatable, Sendable, Codable {
  public var version: Int
  public var overrides: [CommandID: ShortcutBinding]
  public static var empty: ShortcutOverrideStore
}
```

In `CodansCore/Shortcuts/ShortcutResolver.swift`:

```swift
public struct ResolvedShortcut: Equatable, Sendable {
  public let id: CommandID
  public let binding: ShortcutBinding?
  public let isEnabled: Bool
  public let source: Source
  public enum Source: Equatable, Sendable { case schemaDefault, userOverride }
}

public typealias ResolvedShortcutMap = [CommandID: ResolvedShortcut]

public enum ShortcutResolver {
  public static func resolve(schema: ShortcutSchema, overrides: ShortcutOverrideStore) -> ResolvedShortcutMap
}
```

In `CodansCore/Shortcuts/ShortcutResetPlanner.swift`:

```swift
public struct ShortcutResetPlan: Equatable, Sendable {
  public let target: CommandID
  public let cascadingResets: [CommandID]
  public let resultingMap: ResolvedShortcutMap
}

public enum ShortcutResetPlanner {
  public static func plan(resetting target: CommandID,
                          schema: ShortcutSchema,
                          overrides: ShortcutOverrideStore) -> ShortcutResetPlan
}
```

In `CodansCore/Shortcuts/ConflictDetectors/`:

```swift
public enum SystemReservedDetector {
  public static func isReserved(keyCode: UInt16, modifiers: ModifierMask,
                                in defaults: UserDefaults) -> Bool
}

public enum AppKitReservedDetector {
  public static func isReserved(keyCode: UInt16, modifiers: ModifierMask) -> Bool
}

public enum InternalConflictDetector {
  public static func conflicts(in map: ResolvedShortcutMap,
                               candidate: ShortcutBinding,
                               excluding: CommandID) -> CommandID?
}
```

In `App/Shortcuts/ShortcutsStore.swift`:

```swift
@MainActor @Observable
public final class ShortcutsStore {
  public private(set) var overrides: ShortcutOverrideStore
  public var resolved: ResolvedShortcutMap { get }
  public func update(_ id: CommandID, to binding: ShortcutBinding)
  public func disable(_ id: CommandID)
  public func clear(_ id: CommandID)
  public func resetAll()
  public func applyResetPlan(_ plan: ShortcutResetPlan)
  public init(fileURL: URL = ShortcutsStore.defaultURL(),
              debounceWindow: Duration = .milliseconds(500))
  public static func defaultURL(home: URL = ...) -> URL
}
```

In `App/Shortcuts/ShortcutDisplay.swift`:

```swift
public enum ShortcutDisplay {
  public static func keycap(for keyCode: UInt16) -> String
  public static func chord(for binding: ShortcutBinding) -> String
  public static func keyEquivalent(for keyCode: UInt16) -> KeyEquivalent?
  public static func eventModifiers(for mask: ModifierMask) -> EventModifiers
}
```

In `App/Shortcuts/ShortcutEnvironment.swift` and `App/Shortcuts/View+appKeyboardShortcut.swift`:

```swift
public extension EnvironmentValues {
  var resolvedShortcuts: ResolvedShortcutMap { get set }
}

public extension View {
  @ViewBuilder
  func appKeyboardShortcut(_ id: CommandID, in map: ResolvedShortcutMap) -> some View
  @ViewBuilder
  func appKeyboardShortcut(_ id: CommandID) -> some View
}
```

External libraries: none added. Existing dependencies (`ComposableArchitecture`, `SnapshotTesting`, the Carbon framework already linked via `OTHER_LDFLAGS` at `Project.swift:242`) cover everything.
