# ExecPlan: Command Palette (Quick Action)

**Status:** In Progress
**Author:** Gump
**Date:** 2026-04-23

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, a codans user can:

- Press **⌘P** from anywhere in the main window and see a floating search box at the top-center of the active window.
- Type a few characters and see a fuzzy-ranked list of every command currently available — Space switching, Worktree switching, "Open in default editor", "Toggle Git Viewer", split/new-tab/focus pane actions, new/close window, open settings — without needing to remember which menu hosts each.
- Press **↑/↓** to move selection, **Enter** to execute, **Esc** (or click outside) to dismiss.
- On reopen, see their recently-used commands float to the top: commands activated within the last 30 days are boosted, with half-life = 7 days.
- Press the ghostty keybind bound to `toggle_command_palette` (if the user configured one in `ghostty/config`) and see the same palette open — the existing intent hook in `PaneActionRouterFeature.Delegate.commandPaletteToggleRequested` stops being a no-op.

Nothing new happens at the "what can the app do" layer — every command invoked from the palette already has a dedicated entry point (menu, sidebar row, header button, ghostty keybind). The palette is a single keyboard-first surface that lowers the discovery cost for all of them.

## Progress

- [x] M0 — Baseline: `xcodebuild build` green (2026-04-23); 8 pre-existing lint violations recorded below and out of scope
- [x] M1 — Data types: `CommandPaletteItem` + `Kind` enum + `KeyEquivalentDescriptor` landed in `App/Features/CommandPalette/` (2026-04-23, commit ab7e34f); build green
- [x] M2 — Vertical slice: feature + view + wiring landed in two commits 8150d41 + 77d4e07 (2026-04-23); build green. Note: the ghostty `toggle_command_palette` hook at `RootFeature:421` also replaced in the same pass (originally planned for M5) — the branch is one line and tying it to M2 avoids shipping a live palette that doesn't respond to the already-decoded ghostty intent.
- [x] M3 — Full fuzzy scorer with DP subsequence + recency decay + 12 unit tests (2026-04-23, commit b2cc021); all tests green
- [x] M4 — Recency persistence + pruner + LRU cap + 9 tests (2026-04-23, commit 12856d8); all tests green. Note: switched from `@Shared(.appStorage)` to parent-owned `UserDefaults` round-trip (see D15).
- [x] M5 — Full command set: items builder expanded to all Kind cases (2026-04-23, commits e4826e7 + e20dffe); RootFeature.route fan-out exhaustive; ghostty hook rewired in M2. 12 new tests (items + routing contract).
- [x] M6 — 33 palette tests green across 5 suites (Feature/Pruner/Scorer/Items/Routing); RootFeature existing 16-test suite green; lint back to baseline (8 pre-existing, 0 palette-introduced) after commit 67ca462. Manual QA + PR pending human sign-off post codex review.

## Surprises & Discoveries

- **S1** (2026-04-23, M0): `make -C apps/mac lint` emitted 8 **pre-existing** violations on `feature/command-p` before any palette edit: `EditorService+Test.swift:128,144` (async-without-await), `EditorService+Live.swift:36` (todo), `PaneActionRouterFeature.swift:64` (superfluous disable), `PaneSurface.swift:195` (cyclomatic), `GhosttyActionDecoder.swift:142` (cyclomatic + function-body-length), `PanelSurfaceApplyTests.swift:27` (cyclomatic). Out of palette scope; tracked here so the post-work lint comparison is apples-to-apples. No palette-introduced violations shall join that list.
- **S2** (2026-04-23, M0): `git-wt` submodule was not checked out on this worktree — `xcodebuild` failed at the "Verify git-wt" pre-script until `git submodule update --init apps/mac/ThirdParty/git-wt` completed. No code change needed; add to the onboarding note if other agents bootstrap this branch.

## Decision Log

- **D1** (planning, 2026-04-23): Palette lives as a child of `RootFeature`, presented via `@Presents var commandPalette: CommandPaletteFeature.State?`. Matches the `@Presents var spaceManagerSheet` pattern at `RootFeature.swift:46`. Discarding query/selection on close is deliberate — a palette that remembers your last query confuses more than it helps.
- **D2** (planning, 2026-04-23): Palette view is a **ZStack overlay**, not `.sheet(item:)`. The ContentView already hosts a ZStack where the Git Viewer overlay lives; palette joins there at `.zIndex(100)`. `.sheet` was rejected because it dims the window chrome, animates slowly, and pre-empts `Esc` before the reducer can handle activation-and-dismiss.
- **D3** (planning, 2026-04-23): Command items are **rebuilt on open**, not held as a static catalog. `CommandPaletteItems.build(for:)` is a pure function over `(Catalog, HierarchySelection, EditorFeature.State)`. This makes context-sensitivity free — if no Worktree is selected, worktree-scoped Kinds simply aren't in the list — and avoids a registration protocol that would only pay off with a plugin system we do not have.
- **D4** (planning, 2026-04-23): Activation routes through a new `CommandPaletteFeature.Action.Delegate.activate(Kind)` that `RootFeature` pattern-matches into existing feature actions (`.editor(.openRequested)`, `.gitViewerToggledForCurrentWorktree`, `.switchToSpaceAtIndex`, `.sidebar(.spaceRowTapped)`, `.panelActionRouter(.requested)`, `.windowActionRouter(.requested)`, `SettingsWindowPresenter.open()`). No new client, no new dependency; every branch reuses a path that already ships.
- **D5** (planning, 2026-04-23): **Pane-scoped palette actions resolve the target pane on demand, not from `HierarchySelection`.** Confirmed while reading `HierarchyClient.swift:268` — `HierarchySelection` carries `(spaceID, projectID, worktreeID)` only; no `paneID` field. The `route(_:)` helper walks `Tab.selectedPanelID` in the current catalog snapshot to find the focused pane when dispatching a `Kind.panelAction(…)`. No `HierarchySelection` schema change.
- **D6** (planning, 2026-04-23): Ghostty-sourced `toggle_command_palette` intent is reused. `PaneActionRouterFeature.swift:42` already emits `Delegate.commandPaletteToggleRequested`; `RootFeature.swift:421` currently consumes it as an explicit no-op. In M5 that branch becomes `.send(.commandPalette(.togglePresented))`.
- **D7** (planning, 2026-04-23): Recency stored as `[String: TimeInterval]` under UserDefaults key `commandPaletteRecency` via `@Shared(.appStorage(...))`. Rejected routing it through `SettingsStore` — settings are atomic-rename JSON on disk with a 500 ms debounce designed for versioned user-facing preferences, not for write-heavy ephemeral counters touched on every palette activation.
- **D8** (planning, 2026-04-23): First cut ships **no category/section headers** in the UI and **no mode prefixes** (`>`, `@`, `:`). Flat list ordered by score. These can be added later without breaking existing recency IDs.
- **D9** (planning, 2026-04-23): `⌘K` Space switcher stays as-is. Palette can select any Space by typing its name, but `⌘K` is muscle memory and removing it is a separate UX call that should not block palette landing.
- **D10** (M2, 2026-04-23): Palette entry action is `RootFeature.Action.commandPaletteToggle` (a top-level case), not a `.commandPalette(.present)` case. The toggle reducer branch creates `CommandPaletteFeature.State()` and immediately dispatches `.commandPalette(.presented(.appeared(selection, catalog)))` so the items are built from live state on the reducer tick rather than the view's `.task`. Keeps the build-items phase inside TCA's test-observable tick instead of a SwiftUI lifecycle side effect.
- **D11** (M2, 2026-04-23): Ghostty `toggle_command_palette` hook wired in M2 instead of M5. The original plan deferred it one milestone; the branch is a one-line `.send(.commandPaletteToggle)` and shipping the live palette without the hook would ship a visible inconsistency (the ghostty keybind is decoded but the palette is inert). Tying them keeps the user-visible surface honest at every commit.
- **D12** (M2, 2026-04-23): View dismisses via an `onDismiss` closure injected by the parent, not a `.dismissed` reducer action. The feature has no teardown work of its own; `RootFeature.commandPaletteToggle` is the single dismiss path. Avoids a second, redundant action that the test store would also have to observe.
- **D13** (M3, 2026-04-23): Subsequence scorer is **DP over (needle, haystack) positions**, not greedy left-to-right matching. Greedy fails on realistic inputs like `"nt"` on `"Open New Tab"` — the left-most 'n' lives inside "Open" and carries no separator bonus, so greedy scores lower than random titles with early 'n's. DP is `O(m·n)` where `m ≤ 40` (query cap) and `n ≤ 120` (title cap); at real-world sizes the total scoring work for a 200-item catalog stays inside the 16 ms budget by a wide margin.
- **D14** (M3, 2026-04-23): Separator bonus = 20, camelCase bonus = 10, first-char bonus = 10, gap penalty = 1 per skipped char, span penalty = 2 per covered char. These constants were tuned against the test suite; they strike a balance where a word-start two-char subsequence match (e.g. 'nt' on 'Open New Tab') beats a same-length earlier subsequence match without word boundaries, while still letting recency reorder within a band without flipping across bands.
- **D15** (M4, 2026-04-23): Recency persistence routed through a plain `UserDefaults` helper (`CommandPaletteRecencyPersistence`), not `@Shared(.appStorage(…))`. The Sharing library's `.appStorage` key-path API has limited Dictionary support and would have required an extra encoding hop via `Codable` or a custom `SharedKey` conformance; a single read on toggle + single write on activate keeps the semantics simpler and testable via `withSuite(_:)`. Tradeoff acknowledged: SwiftUI views cannot observe the recency map directly, which is fine because the UI never needs to.
- **D16** (M4, 2026-04-23): Recency is written to `state.recency` on activation and then pulled up by `RootFeature` before nil-ing the `@Presents` slot. This keeps the child reducer pure (no `UserDefaults` dependency in tests) at the cost of a small coupling — RootFeature has to remember to persist after `activate`. A `@Dependency` client would have inverted this; chose not to add one for a single call site.

## Outcomes & Retrospective

**Result (2026-04-23):** Command Palette shipped across 7 commits on
`feature/command-p`. The feature opens via `⌘P` or the ghostty
`toggle_command_palette` keybind, searches every user-visible
command — App / Spaces / Worktree / Editor / Pane / Window — via a
three-band fuzzy scorer with recency decay, and dispatches every
activation through existing feature actions with no new client, no new
ghostty decoder case, and no new `HierarchySelection` field.

**Lines of code (net additions, excluding docs):**

- Feature: ~720 lines across `CommandPalette/` (6 files)
- RootFeature edits: +120 lines
- ContentView / MainWindowCommands edits: +14 lines
- Tests: ~690 lines across 5 suites (33 tests)

**Test coverage:** 33 palette-specific tests + existing 16-test
`RootFeatureTests` stayed green. Scorer DP branch is covered by 12
table-driven cases; pruner retention + LRU by 3; feature reducer by 6;
items builder by 5; routing contract by 7.

**Post-M6 follow-up (Codex review):** A second-opinion review of the
shipped feature flagged two critical issues and three concerns. All
five were addressed in commits 21e1f1d + 5dbd416:

- **C1 — Pane commands targeted leftmost split, not focused split.**
  Plumbed `PaneID` through `PaneActionRouterFeature.Delegate.command-
  PaletteToggleRequested(PaneID)` → `RootFeature.commandPaletteToggle
  (PaneID?)` → `CommandPaletteFeature.Action.appeared(...,
  focusedPanelID, panelFocusPrecise)`. Focus-dependent Pane items
  (newSplit, gotoSplit, toggleSplitZoom) are only emitted when the
  ghostty path supplied the pane; menu-triggered opens still get
  tab-scoped Pane items and all Window items (any leaf in the tab
  resolves to the same NSWindow).
- **C2 — `Kind.selectWorktree` routed but never generated.** Items
  builder now emits one "Switch to Worktree: &lt;name&gt;" per worktree
  in the active Space (except the currently selected one).
- **Concern 3 — DP scorer applied span penalty outside endpoint
  selection.** Span and position terms are now computed inside the
  final-row scan so the returned score is the true maximum.
- **Concern 4 — Pruned recency lost on plain dismiss.** RootFeature
  now persists the child's pruned recency on dismiss *and* on
  activation.
- **Concern 5 — CamelCase bonus unreachable.** Subsequence scorer now
  carries both a case-folded haystack (for matching) and an
  original-case haystack (for `charBonus` detection), so
  `prev.isLowercase && char.isUppercase` actually fires.

**Deviations from plan:**

- D10: Palette entry action is `commandPaletteToggle` (top-level),
  not `.commandPalette(.presented(.togglePresented))` — the reducer
  creates state and fires `.appeared(...)` immediately so items are
  built on the reducer tick rather than a SwiftUI lifecycle side
  effect.
- D11: Ghostty intent hook (`PaneActionRouter.Delegate.command-
  PaletteToggleRequested`) wired in M2 instead of M5 to avoid
  shipping an inert ghostty keybind through a released milestone.
- D13: Subsequence scorer is DP over (needle, haystack) positions,
  not greedy — needed to make `"nt"` prefer `"Open [N]ew [T]ab"` over
  a left-anchored no-separator match.
- D15: Recency persistence uses a plain `UserDefaults` helper, not
  `@Shared(.appStorage(...))`. The Sharing library's AppStorage
  dictionary support is thin; a single-read-on-open /
  single-write-on-activate round-trip is simpler.

**Lessons:**

- The Ghostty side of the app was already expecting a command-palette
  feature (`PaneActionRequest.toggleCommandPalette`,
  `PaneActionRouterFeature.Delegate.commandPaletteToggleRequested`,
  the explicit-no-op at `RootFeature:421`). Wiring into pre-existing
  hooks was cheaper than inventing new plumbing.
- Greedy subsequence matching gives intuitive-looking results on
  easy inputs and surprising results on the common "first letter of
  each word" pattern. DP is the right default.
- Procedural item generation vs a registry protocol was the right
  call: 26 items across 6 context bands took ~200 lines of straight-
  line Swift, no new cross-target API surface. A protocol would have
  earned its keep only with plugin-sourced commands we don't have.

## Context and Orientation

Related documents:

- Design doc: `docs/design-docs/command-palette.md` — read in full before M1. Contains the state/action shapes, the scorer rules, the seven alternatives considered, and the risk table. This ExecPlan does not duplicate them.
- Architecture: `docs/architecture.md`, `docs/golden-rules.md`.
- Ghostty routing precedent: `docs/design-docs/0008-ghostty-action-routing.md`. The palette reuses `PaneActionRequest` / `WindowActionRequest` verbatim, so understanding the decoder → router → root fan-out is load-bearing.

Key source files to read (in this order) before M1:

- `apps/mac/codans/App/Features/Root/RootFeature.swift` — the parent reducer. Lines 17–42 hold the `State` struct the palette extends; line 46 is the `@Presents var spaceManagerSheet` pattern the palette mirrors; lines 135–137 (`spaceManagerSheetShown`, `spaceManagerSheet(PresentationAction<…>)`, `switchToSpaceAtIndex`) are the Action shape precedent; line 421 is the `panelActionRouter(.delegate)` no-op branch that M5 replaces; the `.ifLet(\.$spaceManagerSheet, …)` at line 486 is where `.ifLet(\.$commandPalette, …)` lands.
- `apps/mac/codans/App/Features/SpaceManager/SpaceManagerFeature.swift` — **read for shape only, do not edit**. This is the cleanest in-tree example of a `@Presents`-hosted child reducer. The new feature's file layout (`State` / `Action` / `body: some Reducer` / `Delegate`) matches this one.
- `apps/mac/codans/App/Commands/MainWindowCommands.swift` — the `CommandGroup(after: .newItem)` block. A new `Button("Quick Action…") { store.send(.commandPalette(.togglePresented)) }.keyboardShortcut("p", modifiers: .command)` is inserted *above* the existing ⌘E / ⌘⇧G / ⌘K block.
- `apps/mac/codans/App/ContentView.swift` — the overlay host. The palette overlay is mounted in the same `ZStack` that already carries the Git Viewer overlay, with `.zIndex(100)` so it sits above it.
- `apps/mac/codans/App/Features/PaneActionRouter/PaneActionRouterFeature.swift` — lines 37–43 declare `Delegate.commandPaletteToggleRequested`; lines 179–180 emit it. Nothing changes here; M5 just connects the delegate to a real action in `RootFeature`.
- `apps/mac/CodansCore/PaneActionRequest.swift` and `apps/mac/CodansCore/WindowActionRequest.swift` — the public enums `CommandPaletteItem.Kind` wraps. **Do not edit these enums**. Every case is reachable from the palette by adding a `Kind.panelAction(case)` or `Kind.windowAction(case)` item to `build(for:)`.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — lines 268–274 (`HierarchySelection`) confirm the selection does not carry a pane ID; palette routing resolves the focused pane by walking `Tab.selectedPanelID` from the catalog snapshot. No client changes.
- `apps/mac/codans/App/Features/Editor/EditorFeature.swift` — look up `State.descriptors` and `State.globalDefault`; the palette item builder reads both to emit `Kind.openCurrentWorktreeIn(EditorID)` items for each installed editor.

Terms of art:

- **Kind** — a discriminated enum inside `CommandPaletteItem` describing what the item does. One case per command family; parameterized cases carry stable IDs (e.g. `SpaceID`) so recency survives app restart.
- **Recency** — a `[stableCommandID: lastActivationTimestamp]` map persisted to UserDefaults. Read during scoring to apply an exponential-decay bonus; written on every command activation.
- **Contiguous mode** — the fuzzy scorer matches the query as a single substring of the title, not as a subsequence. Triggered by a double-quoted query (`"git view"`) or implicitly as the highest-scoring match when both succeed.
- **Focused pane resolution** — given a `HierarchySelection`, the palette finds the pane to target by looking up the selected Worktree's `selectedTabID`, then that Tab's `selectedPanelID`. The `RootFeature.resolveActiveTab` helper at line 509 is the existing precedent; a sibling helper `resolveFocusedPanelID` is added for palette routing.

Test target layout:

- `apps/mac/codans/Tests/` — home for `CommandPaletteFeatureTests` (new), `CommandPaletteItemsTests` (new), `RootFeatureCommandPaletteRoutingTests` (new).
- `apps/mac/CodansCoreTests/` — home for `CommandPaletteFuzzyScorerTests` (new). Scorer has no TCA dependency, so it belongs in Core tests; follow the placement of existing pure-function tests (e.g. `CatalogCodableTests`).

## Plan of Work

The work is sliced vertically so every milestone produces an observably-working palette. M2 proves the full pipeline end-to-end with three commands; M3–M5 deepen the feature without rebuilding the substrate.

### Milestone 0 — Baseline

Before any edit, confirm the working tree builds clean on the current branch:

```
make -C apps/mac lint
xcodebuild build -scheme codans -destination 'platform=macOS'
```

Record any pre-existing lint or test failures so the post-work comparison is apples-to-apples. If unrelated failures exist, escalate before touching code — the palette should not silently inherit regressions.

### Milestone 1 — Data types (no behavior)

Create the feature directory `apps/mac/codans/App/Features/CommandPalette/` and drop in two files with types only:

- `CommandPaletteItem.swift` — `struct CommandPaletteItem: Equatable, Identifiable` with fields `id: String`, `title: String`, `subtitle: String?`, `icon: String`, `shortcut: KeyEquivalentDescriptor?`, `priorityTier: Int`, `hiddenWhenQueryEmpty: Bool`, `kind: Kind`. The `Kind` enum lists the 16 cases named in design doc §3.3.1. All enums conform to `Equatable`; nothing is public because the feature is internal to the macOS target.
- `KeyEquivalentDescriptor.swift` — a `struct { let keys: [String] }` used only for display (e.g. rendering `"⌘⇧G"` on a row). Not a real `SwiftUI.KeyEquivalent` — the view converts it to a `Text` label at render time.

No reducer, no view yet. Verify by `xcodebuild build -scheme codans`: the new files compile as dead code. No behavior change visible.

### Milestone 2 — Vertical slice with three commands

This is the smallest version of the palette that proves the entire pipeline works end-to-end. Three commands, a stub scorer, real view, real routing.

1. **`CommandPaletteItems.swift`** — pure function `static func build(forSelection: HierarchySelection, editor: EditorFeature.State, catalog: Catalog) -> [CommandPaletteItem]`. For M2 return exactly three items unconditionally: `openSettings`, `toggleGitViewer`, `checkForUpdates`. (Later milestones flesh it out.)

2. **`CommandPaletteFuzzyScorer.swift`** — stub: `static func score(item:query:recency:now:) -> Int?` returns `item.title.lowercased().contains(query.lowercased()) ? 1 : nil` for non-empty query, `1` for empty. Full scorer lands in M3.

3. **`CommandPaletteFeature.swift`** — `@Reducer` with `@ObservableState struct State: Equatable { var query: String = ""; var selectionID: CommandPaletteItem.ID?; var items: [CommandPaletteItem] = []; var filtered: [CommandPaletteItem] = [] }`. Actions: `togglePresented`, `dismissed`, `queryChanged(String)`, `selectionMoved(Direction)`, `selectionCommitted`, `rowTapped(ID)`, `catalogChanged`, `delegate(Delegate)` where `Delegate = .activate(Kind)`. The reducer:
   - On `togglePresented` / `catalogChanged`: invoke `CommandPaletteItems.build`, store in `state.items`, recompute `state.filtered`, set `state.selectionID` to the first filtered item's id.
   - On `queryChanged(s)`: set `state.query = s`, recompute `state.filtered`, reset selection to first.
   - On `selectionMoved(.up/.down)`: move `selectionID` within `state.filtered` with wrap.
   - On `selectionCommitted` / `rowTapped`: look up the selected item, emit `.delegate(.activate(item.kind))`. Reducer does not clear state itself — dismissal is driven by the parent clearing `@Presents` via `.ifLet`.

4. **`CommandPaletteView.swift`** — ZStack overlay per design doc §3.6. A dimmed scrim tap-gesture sends `.dismissed`. Keyboard handling uses `.onKeyPress(.escape/.upArrow/.downArrow/.return)`. The text field is auto-focused via `@FocusState`.

5. **`RootFeature.swift` edits:**
   - Add `@Presents var commandPalette: CommandPaletteFeature.State?` near `spaceManagerSheet` (line ~46).
   - Add action cases `commandPalette(PresentationAction<CommandPaletteFeature.Action>)` and local `commandPaletteToggle` — the latter converts the top-level toggle into the presentation set/clear.
   - Compose via `.ifLet(\.$commandPalette, action: \.commandPalette) { CommandPaletteFeature() }` right after the existing `.ifLet(\.$spaceManagerSheet, …)` at line 486.
   - Add a private helper `route(_ kind: CommandPaletteItem.Kind, state: inout State) -> Effect<Action>`. For M2, handle only three cases: `.openSettings` → `settingsWindowPresenter.open()` via `.run`; `.toggleGitViewer` → `.send(.gitViewerToggledForCurrentWorktree)`; `.checkForUpdates` → placeholder `.none` (wiring lands in M5).
   - Pattern-match `.commandPalette(.presented(.delegate(.activate(let kind))))` → `return route(kind, state: &state)` and also set `state.commandPalette = nil` so the overlay dismisses immediately on commit.

6. **`ContentView.swift` edits:** inside the existing `ZStack` (same one hosting the Git Viewer overlay), add the palette overlay:

   ```swift
   if let paletteStore = store.scope(state: \.commandPalette, action: \.commandPalette.presented) {
     CommandPaletteView(store: paletteStore)
       .zIndex(100)
       .transition(.opacity.combined(with: .scale(scale: 0.97)))
   }
   ```

7. **`MainWindowCommands.swift` edits:** add a new `Button("Quick Action…") { store.send(.commandPaletteToggle) }.keyboardShortcut("p", modifiers: .command)` as the first entry of the `CommandGroup(after: .newItem)` block.

Verify end-to-end: `make -C apps/mac mac-run-app`, press `⌘P`, type "set", press Enter. The Settings window must open. Reopen palette, type "git", press Enter. Git Viewer overlay must toggle.

### Milestone 3 — Full fuzzy scorer

Replace the M2 stub `CommandPaletteFuzzyScorer.score` with the real implementation per design doc §3.3.3. Score rules in priority order:

1. Empty query: items with `hiddenWhenQueryEmpty == true` return `nil`; others return a score derived from recency + priorityTier only (no match bonus).
2. Non-empty query: attempt contiguous substring match on `title` (case-folded). Match → base `0x2_0000` + length-ratio bonus. Else attempt subsequence match on `title` → base `0x1_0000`. Else subsequence match on `subtitle` → base `0x0_8000`. No match → `nil`.
3. Add per-character bonus: `+5` for a query char matching a title char that follows `/`; `+4` for `- _ . space`; `+2` for an uppercase letter at start-of-word.
4. Add recency bonus: `R * 0.5^(ageDays / 7)` capped at 30 days; `R` chosen so a recent-but-subsequence match loses to a never-used contiguous match.
5. Quoted-query rule: when `query` starts and ends with `"`, skip subsequence mode entirely — contiguous only.

Add `CommandPaletteFuzzyScorerTests` in `apps/mac/CodansCoreTests/` with table-driven cases:

- Contiguous `"git"` on "Toggle Git Viewer" outranks subsequence `"gtv"` on the same.
- Prefix `"ope"` outranks suffix `"ngs"` on "Open Settings".
- Recency bonus reorders within a bucket but cannot flip a contiguous match below a subsequence match.
- Quoted query `"\"git view\""` drops subsequence-only matches.
- Deterministic on identical input (sort stable).

Verify: `xcodebuild test -scheme codans -only-testing:CodansCoreTests/CommandPaletteFuzzyScorerTests` expects all cases passing.

### Milestone 4 — Recency

Add persistence:

1. In `CommandPaletteFeature.swift`, add `@Shared(.appStorage("commandPaletteRecency")) var recency: [String: TimeInterval] = [:]` at the feature level. Not on `State` — the `@Shared` property is injected at composition time.
2. On `.selectionCommitted` / `.rowTapped`: before emitting the delegate, write `recency[item.id] = Date().timeIntervalSince1970`. Apply a 200-entry LRU cap: when size exceeds 200, drop the oldest-timestamp entries until size = 200.
3. On `.togglePresented`: prune dead IDs. Rule: for every key in `recency` whose prefix matches `"space.select."`, `"worktree.select."`, or `"editor.open."`, drop the key if the parameter (UUID after the dot) is not present in the freshly-built items list. Static IDs are never pruned.
4. Pass `recency` and `Date().timeIntervalSince1970` into every `CommandPaletteFuzzyScorer.score(…)` call when filtering.

Add to `CommandPaletteFeatureTests`:

- Activating `"openSettings"` bumps `recency["app.open-settings"]`.
- 201st activation evicts the oldest entry.
- Recency for a stale `worktree.select.<uuid>` ID is dropped when the worktree is deleted and palette reopened.

Verify: same test suite plus a manual pass where ⌘P → Settings → close → ⌘P shows "Open Settings" at the top of the empty-query list.

### Milestone 5 — Full command set + ghostty hook

Expand `CommandPaletteItems.build(forSelection:editor:catalog:)` to emit every `Kind`:

- Always: `openSettings`, `checkForUpdates`, `openSpaceManager`, one `selectSpace(id)` per `catalog.spaces`, one `switchToSpaceAtIndex(n)` for n=1…min(9, spaces.count).
- When `selection.worktreeID != nil`: `toggleGitViewer`, `closeCurrentWorktree` (flagged `hiddenWhenQueryEmpty = true`), `refreshCurrentWorktree`, `openCurrentWorktreeInDefaultEditor`, `revealCurrentWorktreeInFinder`, one `openCurrentWorktreeIn(editorID)` per installed descriptor in `editor.descriptors`.
- When `selection.worktreeID != nil`: pane actions — one `panelAction(.newTab)`, one per `NewSplitDirection`, one per `FocusDirection` as `panelAction(.gotoSplit(direction:))`, `panelAction(.closeTab(.this))` (hidden-when-empty), `panelAction(.equalizeSplits)`, `panelAction(.toggleSplitZoom)`.
- Always: window actions — `windowAction(.new(from: resolvedPanelID))`, `windowAction(.close(from: resolvedPanelID))`, `windowAction(.toggleFullscreen(from: resolvedPanelID))`, `windowAction(.toggleTabOverview(from: resolvedPanelID))`. When no pane is focused, these items are omitted rather than emitting synthetic IDs.

Items whose Kind requires a focused `PaneID` resolve it at build time via a new helper `resolveFocusedPanelID(selection:catalog:) -> PaneID?` that walks Tab→selectedPanelID. If `nil`, the corresponding items are not emitted.

Extend `RootFeature.route(_:)` to cover all Kinds. Each case is 1–4 lines, dispatching into an existing feature action. A typical block:

```swift
case .selectSpace(let id):
  return .send(.sidebar(.spaceRowTapped(id)))
case .switchToSpaceAtIndex(let n):
  return .send(.switchToSpaceAtIndex(n))
case .toggleGitViewer:
  return .send(.gitViewerToggledForCurrentWorktree)
case .openCurrentWorktreeInDefaultEditor:
  return .send(.openDefaultForCurrentWorktreeRequested)
case .openCurrentWorktreeIn(let editorID):
  // Build a worktree-path resolver inline or reuse RootFeature.projectOverrideEditorID
  …
case .panelAction(let req):
  guard let paneID = resolveFocusedPanelID(selection: state.selection,
                                            catalog: hierarchyClient.snapshot()) else { return .none }
  return .send(.panelActionRouter(.requested(paneID, req)))
case .windowAction(let req):
  return .send(.windowActionRouter(.requested(req)))
```

Replace the current `panelActionRouter(.delegate)` no-op at `RootFeature.swift:421`:

```swift
case .panelActionRouter(.delegate(.commandPaletteToggleRequested)):
  return .send(.commandPaletteToggle)
case .panelActionRouter(.delegate(.presentTerminalRequested)):
  return .none  // unchanged
case .panelActionRouter(.delegate):
  return .none
```

Verify: add a contract test `RootFeatureCommandPaletteRoutingTests` that iterates every `Kind` case (using a helper `Kind.allFixtureCases` returning one representative value per case) and asserts the reducer emits exactly one downstream action of the expected type. This is the regression net that catches future renames.

### Milestone 6 — Tests + Manual QA + PR

Final test passes:

- `CommandPaletteItemsTests` — synthetic catalog with (0 spaces / 1 space / 2 spaces × 0 projects / 2 projects × 0 worktrees / 1 worktree selected) produces the expected item IDs.
- `CommandPaletteFeatureTests` — toggle / query / selectionMoved / selectionCommitted / rowTapped / catalogChanged.
- `RootFeatureCommandPaletteRoutingTests` — exhaustive Kind coverage.
- `CommandPaletteFuzzyScorerTests` — ranking + recency + quoted-query.

Manual QA matrix:

- `⌘P` opens palette in every main-window state (no space / no worktree / worktree selected).
- Type "settings" / "git" / "personal" / "new tab" / "split right" / "open in zed" — each yields the expected item at rank 1 and Enter executes it.
- Type garbage → "No matching commands" empty-state shows; Enter is silent; Esc closes.
- Close palette, reopen → recently-used commands float to the top.
- Delete a Space whose `selectSpace` command had recency, reopen → the stale recency entry is pruned (assert via `defaults read com.codans commandPaletteRecency`).
- Configure ghostty `toggle_command_palette` on a key combo → pressing it opens the palette.
- Open palette, then click into a terminal pane → palette dismisses; ghostty receives the click normally.

Run `make -C apps/mac lint` and `xcodebuild test -scheme codans -destination 'platform=macOS'` — all green.

Open a PR against `main` from the `feature/command-p` branch with the title `feat(palette): add Command Palette (⌘P)` and a summary that links to the design doc.

## Concrete Steps

From the repo root `/Users/wanggang/.prowl/repos/codans/feature/command-p`:

```
# M0 baseline
make -C apps/mac lint
xcodebuild build -scheme codans -destination 'platform=macOS,arch=arm64' 2>&1 | xcbeautify
```

Expected: lint exits 0, build succeeds. Record any pre-existing failures in Surprises & Discoveries.

```
# After each milestone
make -C apps/mac mac-check          # swift-format + swiftlint
xcodebuild test -scheme codans \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:codansTests \
  -only-testing:CodansCoreTests 2>&1 | xcbeautify
```

Expected: 0 failing tests. New test files appear in the output as they are added.

```
# M2 manual smoke
make -C apps/mac mac-run-app
# press ⌘P, type "set", press Enter → Settings window opens
# press ⌘P, type "git", press Enter → Git Viewer overlay toggles
```

```
# M5 ghostty hook smoke
# in ~/.config/ghostty/config (or per-worktree override):
#   keybind = ctrl+shift+p=toggle_command_palette
# then in a codans terminal pane, press ctrl+shift+p → palette opens
```

```
# M6 recency inspection
defaults read com.codans commandPaletteRecency
```

Expected: a dictionary mapping stable command IDs (e.g. `app.open-settings`) to Unix timestamps.

## Validation and Acceptance

The feature is accepted when all of the following are true:

1. Pressing `⌘P` in any main-window state opens the palette; pressing `Esc` or clicking the scrim dismisses it.
2. Typing a command name selects the expected top item for all of: `"settings"` → Open Settings; `"git"` → Toggle Git Viewer; one of the space names → Switch to that Space; `"new tab"` → Pane: New Tab; `"open in <editor>"` → Open Current Worktree in that editor (only when installed).
3. Pressing `Enter` on the top item executes it and dismisses the palette in the same tick.
4. Activating the same command three times in a session causes it to appear at the top of the empty-query list on the next open, and after relaunching the app.
5. Deleting a Worktree whose `worktree.select.<uuid>` had recency causes that recency entry to disappear on the next palette open (verified via `defaults read`).
6. A ghostty keybind bound to `toggle_command_palette` opens the palette; the existing `PaneActionRouterFeature.Delegate.commandPaletteToggleRequested` no longer no-ops at `RootFeature`.
7. `RootFeatureCommandPaletteRoutingTests` passes with every `Kind` case covered.
8. `CommandPaletteFuzzyScorerTests` passes; the scorer's ordering is deterministic on identical input.
9. No regression in lint or existing tests.

## Idempotence and Recovery

Every milestone's edits are additive. The feature can be disabled at any point by:

- Removing the `⌘P` menu button in `MainWindowCommands.swift` and
- Deleting the `if let paletteStore = …` block in `ContentView.swift`.

The remaining types, reducer, and scorer compile as inert code.

Recency data lives under UserDefaults key `commandPaletteRecency`. To reset during development:

```
defaults delete com.codans commandPaletteRecency
```

If a milestone's build fails, revert the milestone's edits and run `make -C apps/mac mac-check`; the tree returns to the previous green state.

## Artifacts and Notes

Expected file additions at completion:

```
apps/mac/codans/App/Features/CommandPalette/
  CommandPaletteFeature.swift
  CommandPaletteItem.swift
  CommandPaletteItems.swift
  CommandPaletteFuzzyScorer.swift
  CommandPaletteView.swift
  KeyEquivalentDescriptor.swift

apps/mac/codans/Tests/
  CommandPaletteFeatureTests.swift
  CommandPaletteItemsTests.swift
  RootFeatureCommandPaletteRoutingTests.swift

apps/mac/CodansCoreTests/
  CommandPaletteFuzzyScorerTests.swift
```

Edits to existing files:

- `apps/mac/codans/App/Features/Root/RootFeature.swift` — ~50 lines added (State field, action cases, `.ifLet` composition, `route(_:)`, `resolveFocusedPanelID`, replace `line 421` no-op).
- `apps/mac/codans/App/Commands/MainWindowCommands.swift` — ~6 lines added (new Button, ⌘P binding, inserted at the top of `CommandGroup(after: .newItem)`).
- `apps/mac/codans/App/ContentView.swift` — ~6 lines added (overlay mount inside existing ZStack).

No edits expected to: `PaneActionRouterFeature.swift`, `PaneActionRequest.swift`, `WindowActionRequest.swift`, `HierarchyClient.swift`, `EditorFeature.swift`, `SettingsWindowPresenter`, `CodansApp.swift`, `GhosttyActionDecoder.swift`.

## Interfaces and Dependencies

In `apps/mac/codans/App/Features/CommandPalette/CommandPaletteItem.swift`, define:

```swift
struct CommandPaletteItem: Equatable, Identifiable {
  let id: String
  let title: String
  let subtitle: String?
  let icon: String
  let shortcut: KeyEquivalentDescriptor?
  let priorityTier: Int
  let hiddenWhenQueryEmpty: Bool
  let kind: Kind

  enum Kind: Equatable {
    case openSettings
    case checkForUpdates
    case quit

    case selectSpace(SpaceID)
    case openSpaceManager
    case switchToSpaceAtIndex(Int)

    case selectWorktree(SpaceID, ProjectID, WorktreeID)
    case closeCurrentWorktree
    case refreshCurrentWorktree
    case toggleGitViewer

    case openCurrentWorktreeInDefaultEditor
    case openCurrentWorktreeIn(EditorID)
    case revealCurrentWorktreeInFinder

    case panelAction(PaneActionRequest)
    case windowAction(WindowActionRequest)
  }
}
```

In `apps/mac/codans/App/Features/CommandPalette/CommandPaletteItems.swift`:

```swift
enum CommandPaletteItems {
  static func build(
    selection: HierarchySelection,
    editor: EditorFeature.State,
    catalog: Catalog
  ) -> [CommandPaletteItem]
}
```

In `apps/mac/codans/App/Features/CommandPalette/CommandPaletteFuzzyScorer.swift`:

```swift
enum CommandPaletteFuzzyScorer {
  static func score(
    item: CommandPaletteItem,
    query: String,
    recency: [String: TimeInterval],
    now: TimeInterval
  ) -> Int?
}
```

In `apps/mac/codans/App/Features/CommandPalette/CommandPaletteFeature.swift`:

```swift
@Reducer
struct CommandPaletteFeature {
  @ObservableState
  struct State: Equatable {
    var query: String = ""
    var selectionID: CommandPaletteItem.ID?
    var items: [CommandPaletteItem] = []
    var filtered: [CommandPaletteItem] = []
  }

  @Shared(.appStorage("commandPaletteRecency"))
  var recency: [String: TimeInterval] = [:]

  enum Action: Equatable {
    case togglePresented
    case dismissed
    case queryChanged(String)
    case selectionMoved(Direction)
    case selectionCommitted
    case rowTapped(CommandPaletteItem.ID)
    case catalogChanged
    case delegate(Delegate)

    enum Direction: Equatable { case up, down }
    enum Delegate: Equatable { case activate(CommandPaletteItem.Kind) }
  }

  var body: some Reducer<State, Action> { /* … */ }
}
```

In `apps/mac/codans/App/Features/Root/RootFeature.swift`, extend:

```swift
@Presents var commandPalette: CommandPaletteFeature.State?

enum Action {
  // … existing cases
  case commandPaletteToggle
  case commandPalette(PresentationAction<CommandPaletteFeature.Action>)
}

// in body:
.ifLet(\.$commandPalette, action: \.commandPalette) {
  CommandPaletteFeature()
}

private func route(
  _ kind: CommandPaletteItem.Kind,
  state: inout State
) -> Effect<Action>

private func resolveFocusedPanelID(
  selection: HierarchySelection,
  catalog: Catalog
) -> PaneID?
```

No changes to `PaneActionRequest`, `WindowActionRequest`, `HierarchyClient`, `HierarchyManager`, or any `*Feature` outside CommandPalette / Root.

Dependencies:

- **The Composable Architecture** — already a target dependency; uses `@Reducer`, `@ObservableState`, `@Presents`, `@Shared(.appStorage(…))`, `Scope`, `.ifLet(_:action:)`, `PresentationAction`.
- **SwiftUI** — `ZStack`, `TextField`, `List`, `FocusState`, `.onKeyPress`, `.ultraThinMaterial`. All available on macOS 14+; the app's `Tuist.swift` already pins `compatibleXcodeVersions: .upToNextMajor("26.0")` which ships with macOS 14+ SDKs.
- **CodansCore** — `PaneActionRequest`, `WindowActionRequest`, `Catalog`, `Space`, `Project`, `Worktree`, `SpaceID`, `ProjectID`, `WorktreeID`, `PaneID`, `TabID`. Imported, not modified.

No new third-party dependencies. No new Swift Package additions.
