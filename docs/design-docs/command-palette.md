# Command Palette (Quick Action)

**Status:** Approved
**Author:** Gump
**Date:** 2026-04-23

## 1. Context and Scope

codans exposes its functionality through three disjoint surfaces today:

- SwiftUI menu bar bindings in `App/Commands/MainWindowCommands.swift` (`⌘E`,
  `⌘⇧G`, `⌘K`, `⌘1`–`⌘9`).
- Sidebar and header buttons wired into TCA features under
  `App/Features/{HierarchySidebar, WorktreeHeader, SpaceManager, …}`.
- Ghostty keybindings decoded by `Runtime/Ghostty/GhosttyActionDecoder.swift`
  and fanned out through `PaneActionRouterFeature` / `WindowActionRouterFeature`.

To reach a non-default action the user has to *know where it lives* — which
menu, which context menu, which popover, or which ghostty keybind. As the
action surface grows (Spaces, Worktrees, Panes, Editor, Git viewer) this
cost climbs quadratically.

This design introduces a **Command Palette**: a single keyboard-first surface
that enumerates every actionable command and lets the user fuzzy-search and
execute by name. It is a discoverability and speed multiplier, not a new
capability layer — every command the palette exposes already has a
dedicated entry point elsewhere.

Two pieces of plumbing already anticipate this feature:

- `PaneActionRequest.toggleCommandPalette`
  (`apps/mac/CodansCore/PaneActionRequest.swift`) is decoded from
  ghostty's `toggle_command_palette` action.
- `PaneActionRouterFeature.Delegate.commandPaletteToggleRequested`
  (`apps/mac/codans/App/Features/PaneActionRouter/PaneActionRouterFeature.swift:42`)
  is emitted when that intent arrives. `RootFeature:421` currently consumes
  it as an explicit no-op.

This design wires the palette into that hook and binds a window-scope `⌘P`
chord to the same entry point.

## 2. Goals and Non-Goals

### Goals

- Single-chord entry (`⌘P`) from anywhere in the main window surfaces a
  floating search box.
- Every user-visible command reachable from one of the existing three
  surfaces must be reachable from the palette — in particular:
  Space switch / manage / `⌘1`–`⌘9`, Worktree switch / open in editor /
  toggle git viewer, Pane new-tab / split / focus / close,
  Window new / close / fullscreen / tab overview, App open-settings /
  check-for-updates / quit.
- Fuzzy matching with sensible ranking: prefix > contiguous > subsequence;
  recently-run commands float; no contextually-invalid commands shown.
- Activating a command dismisses the palette and the command executes
  through the feature's existing action; no code path is duplicated.
- Esc / click-outside / selecting an item dismisses the palette.
- Ghostty's `toggle_command_palette` intent (already emitted for a
  user-configurable ghostty keybind) opens the same palette.
- Recency state survives app relaunch.

### Non-Goals

- New first-class actions. Palette does not invent capabilities; it only
  surfaces existing ones.
- VS Code-style mode prefixes (`>` commands, `@` symbols, `:` lines). The
  palette is a flat fuzzy list — no mode switching.
- Section headers / category grouping in the UI. Ordering is purely by
  score and recency.
- User-defined custom commands or scripting. (A possible follow-on once
  the substrate proves itself.)
- Multi-window-aware palette (the app is single-window today; the palette
  lives on the single `WindowGroup`).

## 3. Design

### 3.1 Overview

A new TCA feature — `CommandPaletteFeature` — owns the palette's query,
selection, and presentation state. It sits as a child of `RootFeature` and
is presented as a full-surface ZStack overlay (not a `.sheet`), styled as
a floating card 30% from the top of the window.

The feature does **not** hold its own command catalog. Instead, on each
open / search-state-change it rebuilds the visible list from a pure
function `CommandPaletteItems.build(for:)` that reads the live
`HierarchyManager.catalog`, the current `HierarchySelection`, and the
`EditorFeature.State.descriptors` map. This "regenerate on demand" choice
keeps context-sensitivity trivial (no worktree selected ⇒ worktree-scoped
commands absent from the list without any additional filtering logic)
and avoids a registration protocol.

Activation is modeled as a `CommandPaletteFeature.Action.Delegate.activate(Kind)`
that `RootFeature` pattern-matches and forwards to the appropriate
pre-existing feature action (`.editor(.openRequested(…))`,
`.gitViewerToggledForCurrentWorktree`, `.switchToSpaceAtIndex(…)`,
`.panelActionRouter(.requested(…, …))`, etc.). No new dispatch path,
no new client.

**Central trade-off:** *procedural generation* and *TCA delegate routing* over
a *provider registry* and *closure-bearing commands*. Procedural generation
is a few dozen lines of straight-line Swift; adding a command means adding
a `Kind` case plus a `RootFeature` branch. A registry pattern would pay a
real complexity cost up front to save a marginal cost per new command —
premature given the ~25-command first cut.

### 3.2 System Context

```
       ⌘P menu command ┐
                       ├──► RootFeature.Action.commandPalette(.togglePresented)
 ghostty keybind ──────┤
 (PaneActionRouter)   │
                       │
┌──────────────────────▼──────────────────────┐
│         CommandPaletteFeature               │
│  State: isPresented, query, selectionID,    │
│         items [rebuilt on open + recompute] │
│         @Shared recency: [ID: Timestamp]    │
│  ──────────────────────────────────────     │
│  Reducer filters items via FuzzyScorer,     │
│  emits .delegate(.activate(Kind))           │
└──────────────────────┬──────────────────────┘
                       │
                       │  RootFeature pattern-matches Kind and forwards
                       ▼
   ┌──────────────┬────────────────┬────────────────────┬──────────────┐
   │  .editor(…)  │ .gitViewer-…   │ .switchToSpace…    │ .panelAction │
   │              │                │  / .sidebar(…)     │  Router(…)   │
   └──────────────┴────────────────┴────────────────────┴──────────────┘
                       │
                       ▼
           existing features execute the work
             (no new business logic added)
```

The palette view is mounted in `ContentView.swift` as a conditional overlay
on top of the main `NavigationSplitView`, inside the same `ZStack` the
Git Viewer overlay already uses.

### 3.3 Data Model

#### 3.3.1 `CommandPaletteItem` and `Kind`

```swift
struct CommandPaletteItem: Equatable, Identifiable {
  let id: String              // stable key, used for recency persistence
  let title: String           // "Switch to Space: Personal"
  let subtitle: String?       // "3 projects, 7 worktrees"
  let icon: String            // SF Symbol name
  let shortcut: KeyEquivalentDescriptor?  // display-only; e.g. "⌘⇧G"
  let priorityTier: Int       // lower = floated; default 100
  let kind: Kind

  enum Kind: Equatable {
    // App
    case openSettings
    case checkForUpdates
    case quit

    // Space
    case selectSpace(Space.ID)
    case openSpaceManager
    case switchToSpaceAtIndex(Int)   // ⌘1..⌘9 mirror

    // Worktree
    case selectWorktree(SpaceID, ProjectID, WorktreeID)
    case closeCurrentWorktree
    case refreshCurrentWorktree
    case toggleGitViewer

    // Editor
    case openCurrentWorktreeInDefaultEditor
    case openCurrentWorktreeIn(EditorID)
    case revealCurrentWorktreeInFinder

    // Pane — thin wrappers over PaneActionRequest
    case panelAction(PaneActionRequest)

    // Window — thin wrappers over WindowActionRequest
    case windowAction(WindowActionRequest)
  }
}
```

ID naming convention (stable across launches):

- Static commands: `"app.open-settings"`, `"git.toggle-viewer"`.
- Parameterized commands with persistent entities:
  `"space.select.<SpaceID>"`, `"worktree.select.<WorktreeID>"`,
  `"editor.open.<EditorID>"`.
- Parameterized commands with transient targets:
  `"pane.split.right"`, `"window.goto-tab.3"` — the parameter is part
  of the ID, not the current pane identity.

This lets recency for "switch to Worktree X" survive even when X moves
between Projects; recency entries whose IDs no longer resolve to an item
in the current catalog are pruned on next open.

#### 3.3.2 `CommandPaletteFeature.State`

```swift
@ObservableState
struct State: Equatable {
  var query: String = ""
  var selectionID: CommandPaletteItem.ID?
  /// Rebuilt on `.togglePresented` and on `.catalogChanged`; filtering
  /// then runs in-reducer on each `.queryChanged`. Kept here rather than
  /// as a `var items: [Item] { get }` computed-property so tests can assert
  /// filter output deterministically.
  var items: [CommandPaletteItem] = []
  var filtered: [CommandPaletteItem] = []
}
```

Recency is *not* on the feature state; it lives in `@Shared`:

```swift
@Shared(.appStorage("commandPaletteRecency"))
var recency: [String: TimeInterval] = [:]
```

Rationale: recency is write-heavy (every activation) and read-only during
filtering. Lifting it to `@Shared` lets us avoid threading it through every
action payload. The same approach is used for other display preferences
in the app.

#### 3.3.3 `CommandPaletteFuzzyScorer`

Pure function module with a single entry point:

```swift
enum CommandPaletteFuzzyScorer {
  static func score(item: CommandPaletteItem,
                    query: String,
                    recency: [String: TimeInterval],
                    now: TimeInterval) -> Int?
}
```

Score rules (higher wins; `nil` = no match, item dropped):

1. **Empty query:** `nil` for items whose `Kind` is *contextual only*
   (i.e. flagged `hiddenWhenQueryEmpty = true` on the Item; reserved for
   destructive operations like "Close Current Worktree" that should not
   appear at rest). Other items return `recencyScore + priorityBoost`.
2. **Non-empty query:**
   - Attempt to fit `query` as a *contiguous* substring of `title`
     (case-folded). Found → base `0x2_0000` + length-ratio bonus (shorter
     title relative to query wins).
   - Else attempt *subsequence* match (characters in order, gaps allowed):
     title → base `0x1_0000`; subtitle fallback → `0x0_8000`. Score adds a
     bonus for each character that follows a separator (`/`, `-`, `_`,
     `.`, space) or an uppercase letter at start-of-word. Penalizes total
     match span (shorter span = better).
   - Multiple chars between `"..."` force contiguous mode.
3. **Recency term:** `recencyScore = K · 0.5^(ageDays / 7)`, capped at 30
   days; K chosen so recency can reorder within a score bucket but cannot
   flip a contiguous match below a subsequence match.
4. **Priority tier:** items can set `priorityTier < 100` to float (e.g.
   "Switch to Space" when no Space is active). Tier adds a constant delta
   that again stays within a bucket.

Tiebreakers, in order: higher score, shorter title, earlier match
position, alphabetical. Deterministic on identical input.

### 3.4 Component Boundaries

New files, all under `apps/mac/codans/App/Features/CommandPalette/`:

- `CommandPaletteFeature.swift` — reducer, state, actions, delegate enum.
- `CommandPaletteItem.swift` — `Item` struct + `Kind` enum; no behavior.
- `CommandPaletteItems.swift` — `build(for:)` pure function that turns
  `(Catalog, HierarchySelection, EditorFeature.State)` into `[Item]`. No
  TCA imports; unit-testable in isolation.
- `CommandPaletteFuzzyScorer.swift` — pure scoring; no TCA imports.
- `CommandPaletteView.swift` — overlay card, text field, list, row view.
- `CommandPaletteKeyboard.swift` — a small `KeyEquivalentDescriptor`
  helper for rendering shortcut hints on rows (display only; not a
  real binding).

Touched files outside the feature directory:

- `App/Features/Root/RootFeature.swift` — new `@Presents var commandPalette`,
  new action branch, compose via `Scope` + `ifLet`, pattern-match
  `Delegate.activate(_:)` and forward to existing features. Replace the
  current explicit-no-op at line 421 for `.panelActionRouter(.delegate(.commandPaletteToggleRequested))`.
- `App/Commands/MainWindowCommands.swift` — add the `⌘P` menu button and a
  *"Quick Action…"* label. Disabled state: never (the palette opens even
  with no worktree; global commands remain available).
- `App/ContentView.swift` — mount the overlay inside the existing `ZStack`
  (alongside the Git Viewer overlay) with `.zIndex(100)` so it sits above
  everything else, and attach `.onKeyPress(.escape)` for dismiss at the
  overlay scope.

### 3.5 Action / Delegate Shape

```swift
enum Action: Equatable {
  case togglePresented
  case dismissed
  case queryChanged(String)
  case selectionMoved(Direction)        // up/down, with wrap
  case selectionCommitted
  case rowTapped(CommandPaletteItem.ID)
  case catalogChanged                    // re-build items
  case delegate(Delegate)

  enum Delegate: Equatable {
    case activate(CommandPaletteItem.Kind)
  }
}
```

`RootFeature` owns the activation switch:

```swift
case .commandPalette(.presented(.delegate(.activate(let kind)))):
  return route(kind, state: &state)

private func route(_ kind: CommandPaletteItem.Kind, state: inout State) -> Effect<Action> {
  switch kind {
  case .openSettings:
    return .run { _ in await MainActor.run { settingsWindowPresenter.open() } }
  case .toggleGitViewer:
    return .send(.gitViewerToggledForCurrentWorktree)
  case .selectSpace(let id):
    return .send(.sidebar(.spaceRowTapped(id)))
  case .switchToSpaceAtIndex(let n):
    return .send(.switchToSpaceAtIndex(n))
  case .openCurrentWorktreeInDefaultEditor:
    return .send(.openDefaultForCurrentWorktreeRequested)
  case .panelAction(let req):
    guard let paneID = state.selection.focusedPanelID else { return .none }
    return .send(.panelActionRouter(.requested(paneID, req)))
  case .windowAction(let req):
    return .send(.windowActionRouter(.requested(req)))
  // … remaining 8 cases
  }
}
```

The `route` helper is the *complete* integration surface with the rest of
the app — fewer than 60 lines. Every case reuses an existing action.

### 3.6 View

Overlay card composition (pseudocode):

```
ZStack {
  Color.black.opacity(0.08)              // scrim; tap dismisses
    .onTapGesture { store.send(.dismissed) }

  VStack(spacing: 0) {
    HStack { Image(systemName: "magnifyingglass"); TextField(...) }
      .padding(12).frame(height: 48)

    if !store.filtered.isEmpty {
      List(store.filtered, selection: $store.selectionID) {
        CommandPaletteRow(item: $0)
      }
      .frame(maxHeight: 360)
    } else {
      Text("No matching commands").padding(24)
    }
  }
  .frame(maxWidth: 560)
  .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
  .shadow(radius: 20)
  .padding(.top, geometry.size.height * 0.15)
}
.onKeyPress(.escape) { store.send(.dismissed); return .handled }
.onKeyPress(.upArrow)   { store.send(.selectionMoved(.up)); return .handled }
.onKeyPress(.downArrow) { store.send(.selectionMoved(.down)); return .handled }
.onKeyPress(.return)    { store.send(.selectionCommitted); return .handled }
```

A `FocusState` binding forces the `TextField` into focus on appear, so
typing begins immediately. The overlay is 560pt wide max, 360pt list
height max (≈ 8 rows), and positioned at 15% from the top — tuned for
13"–16" displays without a layout conditional.

Row layout:

```
┌─ SF Symbol ─┬─ Title                        ┬─ ⌘⇧G ─┐
│             │  Subtitle (when present)       │       │
└─────────────┴───────────────────────────────┴───────┘
```

### 3.7 Persistence

Only the recency dictionary persists. Stored under UserDefaults key
`commandPaletteRecency` as `[String: TimeInterval]` via `@Shared(.appStorage)`.

On `.togglePresented`:

1. Rebuild `items` from the current catalog/selection/editor state.
2. Prune recency: drop entries whose ID is not in the current items set
   and whose prefix is `space.select.`, `worktree.select.`, or
   `editor.open.` (i.e. IDs that reference entities that may have been
   deleted). Static command IDs are never pruned.
3. Recompute `filtered` from `items` ∩ `query`.

The pruning is O(n) and runs only on open, so the cost is bounded by the
one-keystroke gap between Cmd down and first render (~16 ms budget).

Not persisted: query text, selection, presentation state. Each open
starts at blank query with the first-ranked item pre-selected.

## 4. Alternatives Considered

### 4.1 Provider/Registry pattern instead of procedural generation

Each feature would conform to a `CommandPaletteContributor` protocol and
return its own `[Item]`. `CommandPaletteFeature` would wire them up at
composition time.

**Rejected.** The first cut has ~25 commands across 6 features, and every
command already has a one-to-one match to an existing action. A registry
buys extensibility we have no evidence we need, at the cost of:

- New protocol in `CodansCore` (cross-target public API surface).
- Each feature pays a boilerplate tax (`contributions` var, catalog
  dependency, caching policy).
- The ordering and dedup logic has to move into the registry — currently
  free in procedural code.

If a third-party extension surface ever becomes real (plugin-style, or
driven by `.claude/skills`), refactoring from procedural to registry is
mechanical and can wait.

### 4.2 SwiftUI `.sheet` instead of ZStack overlay

`.sheet(item: $store.scope(state: \.$commandPalette))` is the lowest-code
option.

**Rejected.** Three concrete drawbacks:

- On macOS 14+, sheets animate slower (~250 ms) and dim the window chrome
  with a grey scrim that feels heavier than a palette warrants.
- Sheets take over keyboard focus completely and steal `Esc` semantics
  before our reducer sees them, which complicates the "select-and-execute"
  flow where we want the reducer to dismiss after activation.
- Layout-wise, sheets position themselves according to the window, not the
  content area — a problem when the sidebar is collapsed and the effective
  centre shifts.

The ZStack overlay gives us pixel-accurate positioning, native `.onKeyPress`
handling, and a cheap `.transition(.scale(0.95).combined(with: .opacity))`
appear animation.

### 4.3 Separate floating `NSPanel` window

`NSPanel` with `.nonactivatingPanel` + `.hudWindow` style would give a
Spotlight-style always-on-top window that survives window focus changes.

**Rejected for v1.** Extra complexity (AppKit bridging, NSWindow lifetime,
manual key-window management) for a capability we don't need — codans
is a single-window app; opening the palette from another app is not a
goal. If multi-window lands later, revisit.

### 4.4 VS Code-style mode prefixes

Prefix `>` for commands, `@` for symbols, `:` for goto line, `#` for
search, etc.

**Rejected.** The app has no symbol or line-number concept. The palette
is *only* commands, so a prefix mode adds no information. If file-search
or symbol-search features arrive later, we can add prefixes then without
a breaking change to the current single-mode UX.

### 4.5 Third-party fuzzy matching library (Fuse.swift et al.)

**Rejected.** Adds a Swift Package dependency for ~120 lines of scoring
code. Hand-rolling the scorer keeps the ranking policy reviewable in a
single file and testable with deterministic pure-function tests.

### 4.6 Move Space switcher (`⌘K`) into the palette and deprecate it

The palette can select any Space, so the existing `⌘K` popover becomes
strictly weaker.

**Deferred, not rejected.** Keep `⌘K` as-is in this PR. The Space
switcher is muscle memory for existing users, and removing it is a
separate UX decision that should not block the palette landing. Re-evaluate
once palette recency has telemetry.

### 4.7 Use `@Presents var commandPalette` vs plain `Bool` flag

`@Presents` gives automatic child-lifecycle handling (dismiss on effect
completion, `.ifLet` composition) but requires the child state to be
`nil` when hidden, which throws away query & scroll position between
opens. A plain `Bool isPresented` with always-live child state preserves
state across opens.

**Chose `@Presents`.** Discarding query on close is the correct behavior —
a palette that remembers your last query would confuse more than it
helps. Getting automatic dismiss-on-effect-completion for free is worth
more than preserving ephemeral state. Matches `SpaceManagerFeature`'s
pattern in the same parent.

## 5. Cross-Cutting Concerns

### 5.1 Observability

All command activations log a structured event:

```swift
static let logger = Logger(subsystem: "com.gumpw.codans.command-palette",
                           category: "activate")
```

Fields: `id` (stable), `query` (truncated to 40 chars), `rank` (position
in filtered list when activated), `scoreBucket` (contiguous / subsequence
/ recency-only). This is the data needed to tune the scorer later; no
PII because IDs are derived from entity UUIDs and do not contain
filesystem paths.

### 5.2 Accessibility

- The overlay container has `.accessibilityAddTraits(.isModal)` so
  VoiceOver scopes announcements to the palette.
- Each row declares `.accessibilityLabel(item.title)` and
  `.accessibilityHint(item.subtitle ?? "")`; shortcut hints are
  *excluded* from VoiceOver (visual-only decoration).
- Up/down arrow navigation works identically with VoiceOver's rotor.

### 5.3 Testing Strategy

- **`CommandPaletteFuzzyScorerTests`** (`CodansCoreTests` or
  `apps/mac/codans/Tests/`): table-driven — pairs of `(item, query)`
  with expected rank ordering. Covers contiguous vs subsequence,
  separator bonus, recency float, quoted-contiguous mode.
- **`CommandPaletteItemsTests`**: `build(for:)` against synthetic
  catalogs — empty catalog emits only global items; 2-space catalog
  emits both `selectSpace` items; selected-worktree state pulls in
  worktree-scoped items.
- **`CommandPaletteFeatureTests`**: `togglePresented` → items populated;
  `queryChanged("git")` → filtered subset; `selectionCommitted` emits
  `.delegate(.activate(.toggleGitViewer))`.
- **`RootFeatureTests`** extension: assert every `Kind` case routes to
  an existing feature action (exhaustive switch test — one per case).
  This is the contract test that prevents silent command rot when a
  feature renames its action.
- **Manual**: open palette with `⌘P`, type "git", Enter → viewer
  toggles; reopen, type "space", Enter → sheet opens; reopen, arrow
  down twice, Enter → third command executes.

### 5.4 Error Handling

The palette is fire-and-forget: a command that fails (e.g. closing the
last pane in an already-empty worktree) logs via its owning feature's
existing error path. The palette itself has no error states — it closes
on activation regardless of downstream outcome. This matches the menu
bar's behavior and avoids an error-UI design scope creep.

### 5.5 Migration / Rollout

Purely additive. No schema changes, no catalog changes, no new clients.
Feature can be disabled by deleting the `⌘P` menu binding and not mounting
the overlay — no other code path depends on it. Recency dictionary starts
empty on first run; users see score-only ordering until they activate
their first command.

### 5.6 Performance

Budget: <16 ms from keystroke to re-rendered list at 200 items.

- `items` is rebuilt once per palette open (not per keystroke).
- `filtered` recomputes on every `queryChanged`. Cost is `O(n · m)` where
  `n ≤ 200` commands and `m ≤ 40` chars; each inner iteration is a few
  arithmetic ops. Expected worst case: ~8 µs/item × 200 = 1.6 ms.
- No diffing: SwiftUI's `List` with `.id(\.id)` re-uses row identity, so
  only order/visibility changes.
- Recency prune is `O(r)` where `r = recency.count`; cap r at 200 by
  dropping the oldest on write.

## 6. Risks

| Risk | Mitigation |
|---|---|
| `⌘P` collides with a ghostty keybind the user has configured for print-to-PDF or similar | The menu binding wins at window scope for SwiftUI. For in-ghostty shortcuts that bubble through `performKeyEquivalent`, we verify during manual QA that `⌘P` does not double-fire (once as menu, once as ghostty action). If collision appears, make `⌘P` user-remappable in Settings → Keybindings. |
| Scorer ranking feels wrong on real catalogs | Ship the feature with logging (§5.1) and tune constants based on the first week's activation logs. Scorer is a single file with no dependents — re-tuning is trivially revertible. |
| Dynamic-entity command IDs (`worktree.select.<uuid>`) accumulate in recency after entity deletion | Prune on open (§3.7). Additionally cap dictionary size at 200 entries, LRU-evicting. |
| Full-surface ZStack overlay blocks ghostty's key event handling when palette is open | The overlay consumes `.onKeyPress` before it bubbles to the split viewport. This is the *intended* behavior for `Esc`, arrows, Enter, and typing into the search field. When the overlay is dismissed (`isPresented = false`), the overlay view isn't in the view tree so ghostty receives keys normally. Verify by toggling palette and typing into a terminal pane afterwards. |
| Recency persists across app reinstalls only as long as UserDefaults survives | Acceptable. If a user resets preferences, the palette falls back to score-only ranking — no functional break. |
| Adding a new feature action later requires remembering to add it to the palette | Low-grade tax, addressed by convention only (no enforced contract). Revisit if we see drift via log analysis: features that log zero palette activations over ≥4 weeks are candidates for either removal or missing palette entries. |

## 7. Resolved Decisions

- **OQ-1 — Enter on empty list:** no-op. Silence beats flash; the
  reducer short-circuits `.selectionCommitted` when `filtered.isEmpty`.
- **OQ-2 — Pre-filled chord variant:** deferred. Design admits this
  additively via a `prefilled: String` argument on `togglePresented` if
  we need it later; no code shape changes required today.
- **Primary key `⌘P`; `⌘K` Space-switcher remains:** confirmed. Both
  entry points coexist. The palette can still select any Space by name;
  `⌘K` stays as muscle-memory access to the popover with `⌘1`–`⌘9`
  index chords intact.
- **Destructive commands gated by `hiddenWhenQueryEmpty`:** confirmed.
  "Close Current Worktree" and similar sharp-edge commands only appear
  once the user has typed a non-empty query that matches them, never in
  the default "just opened the palette" list.
- **Recency store:** `@Shared(.appStorage("commandPaletteRecency"))`
  `[String: TimeInterval]` as described in §3.7. Not routed through
  `SettingsStore`.
