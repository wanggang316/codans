# Keyboard Shortcuts (Unified Management)

**Status:** Draft
**Author:** Gump
**Date:** 2026-04-28

## 1. Context and Scope

codans defines its keyboard shortcuts in three disjoint locations today,
each hardcoded:

- **Window-scope SwiftUI bindings** in
  `App/Commands/MainWindowCommands.swift` — `⌘P` (Quick Action), `⌘E` (Open
  in Default Editor), `⌘⇧G` (Toggle Git Viewer), `⌘F` (Filter Tags), `⌘T`
  (New Tab), `⌘W` (Close Tab), `⌘⇧[` / `⌘⇧]` (Prev/Next Tab), and `⌥⌘1`–`⌥⌘9`
  (Switch to Tab N). Thirteen entries in total.
- **Sidebar row hotkeys** in
  `App/Features/HierarchySidebar/HierarchySidebarView.swift:619` — `⌃⌘1`–`⌃⌘9`
  attached to a zero-frame invisible Button per visible Worktree row.
- **App-scope binding** in `App/CodansApp.swift:85` — `⌘,` for the
  Settings window via `CommandGroup(replacing: .appSettings)`.

Two further consumers display shortcut hints but do not bind keys:

- `Features/CommandPalette/CommandPaletteItems.swift` renders display strings
  (`["⌘", "⇧", "G"]`) on rows via `KeyEquivalentDescriptor`.
- `CodansCore/Shortcuts/CommandPaletteShortcut.swift` exports `keyChar`
  and `displayString` constants so `MainWindowCommands` and
  `StatusMotivationalView` agree on the `⌘P` chord.

The Settings window already enumerates a `.shortcuts` section
(`SettingsSection.swift:17`) that today renders `ComingSoonPane(title:
"Shortcuts")`. There is no persistence layer for user customizations and no
machinery for detecting conflicts, displaying chords in the active keyboard
layout, or resolving a default-vs-override fallback.

This design replaces the per-call-site hardcoding with a single registry of
shortcut commands, a persistent override store, and a Settings pane that
lets users rebind, disable, or reset any registered command. It deliberately
covers the full set of in-app shortcuts (window commands, sidebar hotkeys,
the implicit `⌘,` settings chord) so that future additions go through the
same path rather than re-introducing per-feature drift.

## 2. Goals and Non-Goals

### Goals

- A single registry of every user-bindable in-app shortcut, keyed by a
  stable `CommandID`, with the default chord encoded once.
- Persistence of user overrides in a dedicated file
  `~/.config/codans/shortcuts.json`, separate from `settings.json`.
- A Settings → Shortcuts pane that replaces `ComingSoonPane`: search,
  group by category, record-new-chord, disable, per-row reset, reset-all.
- Conflict detection across three tiers: macOS system-reserved chords, the
  AppKit menu reserved set (`⌘Q`, `⌘W`, `⌘H`, `⌘M`, …), and other
  user-configurable commands inside the app.
- Display of chords in the user's active keyboard layout (so `⌘[` on a
  French AZERTY keyboard renders the keycap that physically produces `[`,
  not the U.S. literal).
- Persisted bindings expressed in *physical* terms (key code + modifier
  flags) so the same override survives a layout switch.
- Migration of the existing thirteen window commands and nine sidebar
  hotkeys into the registry without changing observable behavior on a
  fresh install.

### Non-Goals

- Import / export of shortcut profiles (deferred; the on-disk format is
  designed to permit a future export step but no UI is built).
- Global system hotkeys (`Carbon.RegisterEventHotKey` / `MASShortcut`-style
  always-on bindings that fire while another app is frontmost). All
  bindings are window- or app-scoped via SwiftUI.
- Mode-specific keymaps (Vim-style "this chord means X in pane focus, Y in
  sidebar focus"). Each `CommandID` resolves to a single chord regardless
  of which control has focus; SwiftUI's existing focus-system rules
  determine whether the chord fires.
- Per-Project shortcut overrides. Shortcuts are global to the app.
- Multi-stroke chords (`⌘K ⌘O`-style). Single chord only.
- Rebinding shortcuts that live inside Ghostty (e.g. terminal scrollback
  navigation). Those are owned by the embedded terminal config and out of
  scope.
- The Command Palette's display-only `KeyEquivalentDescriptor` becomes
  *fed* by the registry (so the hint matches the user's binding) but the
  palette's row-hint rendering itself is unchanged.

## 3. Design

### 3.1 Overview

Three layers, with strict dependency direction:

```
┌─────────────────────────────────────────────────────┐
│  CodansCore/Shortcuts/   (no SwiftUI / no AppKit)│
│    CommandID enum                                   │
│    ShortcutBinding                                  │
│    ShortcutSchema (defaults, version)               │
│    ShortcutOverrideStore (Codable)                  │
│    ShortcutResolver → ResolvedShortcutMap           │
│    ShortcutResetPlanner                             │
│    Conflict detectors (system / appKit / internal)  │
└──────────────────────┬──────────────────────────────┘
                       │ pure data only
┌──────────────────────▼──────────────────────────────┐
│  codans/App/Shortcuts/   (SwiftUI + AppKit glue)│
│    ShortcutsStore (file I/O, debounced)             │
│    ShortcutDisplay (UCKeyTranslate)                 │
│    HotkeyRecorderNSView + SwiftUI wrapper           │
│    View+appKeyboardShortcut modifier                │
│    EnvironmentKey<ResolvedShortcutMap>              │
└──────────────────────┬──────────────────────────────┘
                       │ environment injection
┌──────────────────────▼──────────────────────────────┐
│  Existing call sites                                │
│    MainWindowCommands.swift (rewritten)             │
│    HierarchySidebarView.swift (rewritten)           │
│    Settings/Panes/ShortcutsSettingsView.swift (new) │
└─────────────────────────────────────────────────────┘
```

**Central trade-off:** *closed `CommandID` enum + procedural defaults table*
over an *open registration protocol*. Touch-code's complete shortcut surface
is enumerable at compile time (~25 commands first cut, sub-50 long-term);
the closed enum gives exhaustive switch coverage in routing code and
machine-checkable migration when a command is renamed. An open registry
would buy plugin-style extensibility we have no concrete need for, at the
cost of runtime ordering, dedup, and ID-collision rules — all of which are
free in the closed model.

A secondary trade-off: bindings are persisted as **`keyCode` + modifier
flags** (physical-key terms) rather than `Character` + modifiers. This
makes the override stable across input-source changes, but complicates the
display layer (we run `UCKeyTranslate` against the active layout to render
the keycap). The complexity is paid once in `ShortcutDisplay` and unlocks
correct behavior for non-US-QWERTY users without per-layout overrides.

### 3.2 System Context

```
                ┌──────────────────────────┐
                │  shortcuts.json (disk)   │
                │  ~/.config/codans/   │
                └────────────┬─────────────┘
                             │ AtomicFileStore
                             │ (500 ms debounce)
                             ▼
   ┌──────────────────────────────────────────────────┐
   │  ShortcutsStore (@MainActor, @Observable)        │
   │    overrides: ShortcutOverrideStore              │
   │    resolved:  ResolvedShortcutMap                │
   │    publishes change notifications                │
   └──────────┬─────────────────────────┬─────────────┘
              │ resolved                │ overrides
              │ (read)                  │ (read+write)
              ▼                         ▼
   ┌────────────────────┐     ┌────────────────────────┐
   │  Environment       │     │  ShortcutsSettingsView │
   │  injection         │     │  (record / reset / UI) │
   └──────────┬─────────┘     └────────────────────────┘
              │
   ┌──────────▼──────────────────────────────────────┐
   │  Call sites read via                            │
   │  @Environment(\.resolvedShortcuts)              │
   │  and apply .appKeyboardShortcut(.commandID)     │
   │                                                 │
   │    MainWindowCommands                           │
   │    HierarchySidebarView (row hotkeys)           │
   │    StatusMotivationalView (display only)        │
   │    CommandPalette rows (display only)           │
   └─────────────────────────────────────────────────┘
```

### 3.3 Data Model

#### 3.3.1 `CommandID`

A closed enum in `CodansCore/Shortcuts/CommandID.swift`. Conforms to
`Hashable`, `Sendable`, and a custom `RawRepresentable` over `String` whose
raw values are stable JSON keys (the persisted file uses these strings
verbatim).

```swift
public enum CommandID: String, CaseIterable, Hashable, Sendable, Codable {
  // App scope
  case openSettings
  case quit                            // displayed only — non-rebindable

  // Quick action
  case commandPaletteToggle

  // Window — main commands
  case openInDefaultEditor
  case toggleGitViewer
  case filterTags
  case newTab
  case closeTab
  case previousTab
  case nextTab
  case switchToTab1, switchToTab2, switchToTab3, switchToTab4, switchToTab5
  case switchToTab6, switchToTab7, switchToTab8, switchToTab9

  // Sidebar row hotkeys
  case selectWorktreeAt1, selectWorktreeAt2, selectWorktreeAt3
  case selectWorktreeAt4, selectWorktreeAt5, selectWorktreeAt6
  case selectWorktreeAt7, selectWorktreeAt8, selectWorktreeAt9
}
```

The numbered cases are spelled out (rather than parameterized) so they
become first-class JSON keys (`"switchToTab3": …`), participate in
`CaseIterable`, and remain compile-time exhaustive in routing switches.

#### 3.3.2 `ShortcutBinding`

```swift
public struct ShortcutBinding: Equatable, Hashable, Sendable, Codable {
  public let keyCode: UInt16              // virtual key code (kVK_* values)
  public let modifiers: ModifierMask      // .command / .option / .control / .shift
  public let isEnabled: Bool              // false → user disabled this command
}
```

`ModifierMask` is an `OptionSet<UInt8>` defined alongside, deliberately not
SwiftUI's `EventModifiers` or AppKit's `NSEvent.ModifierFlags` — those are
platform types in the upper layer; this struct lives in CodansCore which
has no SwiftUI/AppKit dependency. Conversions are one-line in
`ShortcutDisplay`.

A binding with `isEnabled == false` represents *the user explicitly turned
this command off*, and is distinct from "no binding at all" (no entry in
the override store; the default applies). This three-state model
(default / overridden / disabled) is necessary because users sometimes
want to suppress an inherited default without picking a replacement.

#### 3.3.3 `ShortcutScope`

```swift
public enum ShortcutScope: Sendable {
  case configurable        // user may rebind / disable
  case systemFixed         // shown in UI but read-only (e.g. ⌘,)
  case localOnly           // not surfaced in the UI at all (e.g. ⎋ in sheets)
}
```

The first cut uses only `.configurable` and `.systemFixed` — `.localOnly`
is reserved for future use (modal Esc/Return keys, in-text-field cursor
movements) so the registry can model them without polluting the
configurable surface.

#### 3.3.4 `ShortcutSchema` (defaults table)

A static value type, version-stamped:

```swift
public struct ShortcutSchema: Sendable {
  public static let currentVersion = 1
  public let version: Int
  public let entries: [Entry]

  public struct Entry: Sendable {
    public let id: CommandID
    public let title: LocalizedStringKey
    public let category: Category           // .general / .tabs / .sidebar / .system
    public let scope: ShortcutScope
    public let defaultBinding: ShortcutBinding?
  }
}

extension ShortcutSchema {
  public static let app: ShortcutSchema = .init(
    version: currentVersion,
    entries: [
      .init(.openSettings, "Open Settings", .system, .systemFixed,
            .init(keyCode: kVK_ANSI_Comma, modifiers: .command, isEnabled: true)),
      .init(.commandPaletteToggle, "Quick Action", .general, .configurable,
            .init(keyCode: kVK_ANSI_P, modifiers: .command, isEnabled: true)),
      .init(.toggleGitViewer, "Toggle Git Viewer", .general, .configurable,
            .init(keyCode: kVK_ANSI_G, modifiers: [.command, .shift], isEnabled: true)),
      // … remaining ~22 entries
    ]
  )
}
```

The schema is the single point of truth for category grouping and pane
ordering. UI does not enumerate `CommandID.allCases` directly — it reads
`ShortcutSchema.app.entries` so newly-added cases without a schema entry
are caught at code-review time (the audit unit test, §5.3, asserts every
`CommandID` case has a schema entry).

#### 3.3.5 `ShortcutOverrideStore`

The persisted document. Plain Codable struct; only carries differences
from the schema:

```swift
public struct ShortcutOverrideStore: Equatable, Sendable, Codable {
  public var version: Int                                      // = 1
  public var overrides: [CommandID: ShortcutBinding]          // sparse
}
```

Empty store = "all defaults active". The keys are `CommandID` raw values,
making the JSON human-grepable:

```json
{
  "version": 1,
  "overrides": {
    "newTab": { "keyCode": 17, "modifiers": ["command", "option"], "isEnabled": true },
    "toggleGitViewer": { "keyCode": 5, "modifiers": ["command"], "isEnabled": false }
  }
}
```

#### 3.3.6 `ShortcutResolver` and `ResolvedShortcutMap`

Pure function. Given a schema and an override store, produce the effective
binding for every command, with a source tag for UI display ("Default" vs
"Custom") and disabled-state surfaced separately from `nil`:

```swift
public struct ResolvedShortcut: Equatable, Sendable {
  public let id: CommandID
  public let binding: ShortcutBinding?       // nil ⇒ no chord (e.g. user-cleared)
  public let isEnabled: Bool                 // false ⇒ chord exists but suppressed
  public let source: Source

  public enum Source: Equatable, Sendable {
    case schemaDefault
    case userOverride
  }
}

public typealias ResolvedShortcutMap = [CommandID: ResolvedShortcut]

public enum ShortcutResolver {
  public static func resolve(
    schema: ShortcutSchema = .app,
    overrides: ShortcutOverrideStore
  ) -> ResolvedShortcutMap
}
```

### 3.4 Conflict Detection

Three detectors, each a pure function over `(ResolvedShortcutMap, candidate
ShortcutBinding)`:

- `SystemReservedDetector` — reads
  `com.apple.symbolichotkeys / AppleSymbolicHotKeys` from `CFPreferences` at
  startup, parsing the Apple-internal keycode/modifier triples for chords
  the OS owns (Spotlight, Mission Control, Input-source switch, …). The
  read happens once per app launch, cached for the lifetime of the process;
  a UserDefaults change notification triggers a refresh.
- `AppKitReservedDetector` — a small hardcoded list of menu chords the
  AppKit standard menus claim by default: `⌘Q`, `⌘W`, `⌘H`, `⌘M`, `⌘,`,
  `⌘?`. Static; no runtime lookup.
- `InternalConflictDetector` — scans the resolved map for any other
  `.configurable` command currently bound to the same `(keyCode, modifiers)`
  with `isEnabled == true`.

A candidate that fails detector 1 or 2 is *rejected* by the recorder UI
with a typed error (`SystemReserved` / `AppKitReserved`). A candidate that
fails detector 3 prompts the user with a confirmation dialog ("Replace?
This will unassign Toggle Git Viewer."); on confirm, the conflicting
command's override is updated to a disabled or empty binding.

#### 3.4.1 Cascading reset

Resetting command *A* to its schema default may make A's default conflict
with B's user override. Naive reset would leave the user with a silent
collision. `ShortcutResetPlanner` produces a plan:

```swift
public struct ShortcutResetPlan: Equatable, Sendable {
  public let target: CommandID
  public let cascadingResets: [CommandID]   // overrides cleared transitively
  public let resultingMap: ResolvedShortcutMap
}

public enum ShortcutResetPlanner {
  public static func plan(
    resetting target: CommandID,
    schema: ShortcutSchema,
    overrides: ShortcutOverrideStore
  ) -> ShortcutResetPlan
}
```

The settings pane shows the plan in the confirmation dialog ("Resetting
‘New Tab’ will also reset ‘Switch to Tab 1’ because they would otherwise
share `⌘1`. Continue?"). Reset-all is the degenerate case: clear the
entire override map and accept the schema-only resolution.

### 3.5 Layout-Aware Display

Persisted bindings carry `keyCode` (physical position). The display string
is computed at render time:

```swift
enum ShortcutDisplay {
  static func keycap(for keyCode: UInt16) -> String { … }
  static func chord(for binding: ShortcutBinding) -> String { … }   // "⌘⇧G"
}
```

Implementation uses `TISCopyCurrentKeyboardLayoutInputSource()` +
`UCKeyTranslate` to ask the active layout what unicode character a given
keyCode produces with no modifiers (special-cased: arrow keys, function
keys, Return/Tab/Esc/Space, numeric keypad map to fixed glyphs by
keyCode). The result is uppercased for the keycap convention.

The active layout can change at runtime via input-source switch.
`ShortcutDisplay` registers a `kTISNotifySelectedKeyboardInputSourceChanged`
distributed-notification observer that bumps a `@Published` invalidation
token on `ShortcutsStore`; the Environment-injected resolved map's display
strings recompute on next read, and SwiftUI rebinds menu items via the
view-update cycle.

The recorder UI uses the same layer in reverse: it captures
`NSEvent.keyCode` (physical) and stores it; the displayed keycap during
recording is `ShortcutDisplay.keycap(for: capturedKeyCode)`.

### 3.6 Persistence

Owner: a new `ShortcutsStore` in `App/Shortcuts/`. Mirrors the existing
`SettingsStore` pattern (`@MainActor @Observable`, `AtomicFileStore`-backed
writes with a 500 ms trailing debounce, broken-file backup on decode
failure). Justification for parallel-store rather than fold-into-Settings:

- Update cadence is different: shortcut edits are interactive (every chord
  capture commits), whereas `Settings` is mostly stable per-session. A
  separate debounce avoids mutual interference.
- `Settings.json` is at v3 with a strict migrator
  (`SettingsMigration.swift`); adding a `shortcuts` field would force a
  schema bump and a defensive migration step for a feature whose data is
  cleanly extricable.
- A standalone file is the right shape for the deferred export feature:
  the user can already inspect and copy `shortcuts.json` directly.

File path: `~/.config/codans/shortcuts.json`. Discovered via the same
`NSHomeDirectory()` + `.config/codans/` convention `Settings.defaultURL()`
uses, factored into a shared helper if both stores end up needing it.

Schema versioning: an explicit `version: 1` field at the document root.
On read, mismatched versions trigger a side-aside backup (`shortcuts.json.v{N}-<ts>`)
and a fresh-default load — the same conservative policy `SettingsStore` applies.

### 3.7 SwiftUI Integration

#### 3.7.1 Environment

```swift
private struct ResolvedShortcutsKey: EnvironmentKey {
  static let defaultValue: ResolvedShortcutMap = [:]
}

extension EnvironmentValues {
  public var resolvedShortcuts: ResolvedShortcutMap {
    get { self[ResolvedShortcutsKey.self] }
    set { self[ResolvedShortcutsKey.self] = newValue }
  }
}
```

`CodansApp.swift` injects the store's resolved map at the top of the
view tree:

```swift
WindowGroup { ContentView(store: …) }
  .environment(\.resolvedShortcuts, shortcutsStore.resolved)
```

On Commands scenes, the same map is read via `@Environment` because
`Commands` participates in environment propagation.

#### 3.7.2 The view modifier

```swift
extension View {
  @ViewBuilder
  public func appKeyboardShortcut(_ id: CommandID,
                                  in map: ResolvedShortcutMap) -> some View {
    if let r = map[id], r.isEnabled, let b = r.binding,
       let key = ShortcutDisplay.keyEquivalent(for: b.keyCode) {
      self.keyboardShortcut(key, modifiers: b.modifiers.eventModifiers)
    } else {
      self
    }
  }
}
```

Two-argument form (taking the map explicitly) because `@Environment` is
not directly accessible from the `Commands` body. A one-argument view
overload that reads `@Environment(\.resolvedShortcuts)` is provided for
ordinary view contexts.

Key conversion: `ShortcutDisplay.keyEquivalent(for:)` maps the keyCode to
a `KeyEquivalent`. For arrow keys, function keys, Esc/Return/Tab/Space we
return the SwiftUI special values (`.upArrow`, `.return`, etc.); for
character keys we run `UCKeyTranslate` once with the *US-QWERTY* layout
(not the user's active layout) so the menu binding is stable regardless
of what the user has selected — SwiftUI matches `KeyEquivalent` against
the typed character, and we want the binding to fire when the user
presses the *physical* `G` key on their keyboard, which the OS reports as
the layout-translated character. The display string in the menu is
separately rendered via the user's active layout (§3.5). This split — bind
in US, display in active — is how AppKit/SwiftUI menu items behave by
default for hardcoded `.keyboardShortcut("g", …)` and is what users
expect.

#### 3.7.3 Call-site rewrites

`MainWindowCommands.swift` — every binding becomes:

```swift
Button("Open in Default Editor") { store.send(.openDefaultForCurrentWorktreeRequested) }
  .appKeyboardShortcut(.openInDefaultEditor, in: shortcuts)
  .disabled(!hasActiveWorktree)
```

`HierarchySidebarView.swift` — the `⌃⌘N` invisible-Button block (lines
619–631) reads from the registry instead of building `KeyEquivalent`
inline:

```swift
if let cmd = CommandID.selectWorktreeAt(index: hotkeyNumber) {  // helper
  Button { store.send(.worktreeRowTapped(worktree.id, inProject: project.id)) }
    label: { EmptyView() }
    .appKeyboardShortcut(cmd, in: shortcuts)
    .frame(width: 0, height: 0)
    .opacity(0)
}
```

The `selectWorktreeAt(index:)` helper maps `1...9 → .selectWorktreeAt1 …
.selectWorktreeAt9`. Indices outside that range (rows 10+) get no hotkey,
matching today's behavior.

`CodansApp.swift` — the `⌘,` button stays inline (it is `.systemFixed`
and the chord is `kVK_ANSI_Comma + .command`); the registry contains the
entry for *display* purposes in the Settings pane, but the actual binding
is left as the existing literal `.keyboardShortcut(",", modifiers: .command)`
to avoid threading the resolver through the App scene.

`StatusMotivationalView` and the Command Palette row renderer pull the
display string from `ResolvedShortcutMap` instead of the
`CommandPaletteShortcut` constant. `CommandPaletteShortcut` is then
deleted, since the registry subsumes it.

### 3.8 Recorder UI

`HotkeyRecorderNSView: NSView` plus a SwiftUI `NSViewRepresentable`
wrapper. AppKit because `NSEvent.addLocalMonitorForEvents` is the only
reliable way to capture chords without SwiftUI's text-input system
interfering, and because keyDown handling needs `acceptsFirstResponder`
overrides that SwiftUI doesn't expose cleanly.

Behavior:

- Click the recorder field → it becomes first responder; placeholder reads
  "Type a chord…".
- A keyDown event with no modifiers is rejected (sets a transient error
  state "Add at least one modifier"). At least one of `⌘`, `⌥`, `⌃` is
  required. `⇧` alone is not accepted as the sole modifier (it would let
  the user shadow plain typing keys); when present alongside another
  modifier, it counts.
- On a valid chord, the recorder calls into `ConflictDetectors`. On
  `SystemReserved` / `AppKitReserved` it shakes (a 200 ms horizontal
  spring) and shows the rejection reason for ~1.5 s. On
  `InternalConflict` it shows a confirmation popover ("Replace? Currently
  bound to *Toggle Git Viewer*.") with Replace / Cancel.
- Esc clears any pending capture and returns the field to its prior
  binding; click-outside commits whatever's currently captured.
- Successful capture writes through `ShortcutsStore.update(.commandID,
  to: binding)`, which triggers the debounced save and recomputes the
  resolved map; UI updates via `@Observable`.

### 3.9 Settings → Shortcuts Pane

Replaces `ComingSoonPane(title: "Shortcuts")` in
`Features/Settings/SettingsWindowView.swift:83`.

Layout: a single scrollable column inside the standard settings detail
frame.

```
┌──────────────────────────────────────────────────────────┐
│  [search…________________]                  [Restore All]│
├──────────────────────────────────────────────────────────┤
│  GENERAL                                                 │
│  ──────                                                  │
│  Quick Action            ⌘P                       ⟲      │
│  Filter Tags             ⌘F                       ⟲      │
│  Open Settings           ⌘,         (System)             │
│                                                          │
│  TABS                                                    │
│  ────                                                    │
│  New Tab                 ⌘T                       ⟲      │
│  Close Tab               ⌘W                       ⟲      │
│  Switch to Tab 1         ⌥⌘1                      ⟲      │
│  …                                                       │
│                                                          │
│  SIDEBAR                                                 │
│  ───────                                                 │
│  Select Worktree 1       ⌃⌘1                      ⟲      │
│  …                                                       │
└──────────────────────────────────────────────────────────┘
```

- The chord cell is the recorder field (clickable).
- `(System)` badge marks `.systemFixed` rows; the recorder is
  non-interactive on those.
- The reset glyph (`⟲`) is shown only when the row is actively overridden
  (resolved `source == .userOverride`). Click → confirmation dialog
  showing the cascading reset plan (§3.4.1).
- A "Custom" / "Default" pill on the right edge mirrors the source tag.
  Disabled commands show a strikethrough on the chord plus a "Disabled"
  pill; a context-menu item on the recorder ("Disable shortcut") sets
  `isEnabled = false` without clearing the chord.
- Restore All triggers a single confirmation; on confirm the entire
  override store is cleared.
- Search filters by the rendered title and the rendered chord string
  (case-insensitive substring); category headers hide when their rows are
  fully filtered out.

## 4. Component Boundaries

New files in `apps/mac/CodansCore/Shortcuts/`:

- `CommandID.swift` — the closed enum.
- `ShortcutBinding.swift` — `ShortcutBinding`, `ModifierMask`.
- `ShortcutScope.swift` — the scope enum.
- `ShortcutSchema.swift` — schema struct + the `static let app` table.
- `ShortcutOverrideStore.swift` — persisted Codable document.
- `ShortcutResolver.swift` — pure resolver.
- `ShortcutResetPlanner.swift` — pure cascading-reset planner.
- `ConflictDetectors/SystemReservedDetector.swift`
- `ConflictDetectors/AppKitReservedDetector.swift`
- `ConflictDetectors/InternalConflictDetector.swift`

Existing `CodansCore/Shortcuts/CommandPaletteShortcut.swift` is
**deleted**; its two consumers (`MainWindowCommands`,
`StatusMotivationalView`) migrate to the registry.

New files in `apps/mac/codans/App/Shortcuts/`:

- `ShortcutsStore.swift` — `@MainActor @Observable` owner of
  `shortcuts.json`. Mirrors `SettingsStore` boilerplate (atomic write,
  debounce, broken-file backup).
- `ShortcutDisplay.swift` — UCKeyTranslate-driven display + KeyEquivalent
  conversion.
- `ShortcutEnvironment.swift` — environment key + accessor.
- `View+appKeyboardShortcut.swift` — the modifier (both forms).
- `HotkeyRecorder/HotkeyRecorderNSView.swift`
- `HotkeyRecorder/HotkeyRecorderView.swift` — SwiftUI wrapper.

New file in `apps/mac/codans/App/Features/Settings/Panes/`:

- `ShortcutsSettingsView.swift` — replaces the `ComingSoonPane` mount.

Touched outside these directories:

- `App/Commands/MainWindowCommands.swift` — every `.keyboardShortcut(…)`
  call replaced with `.appKeyboardShortcut(.commandID, in: shortcuts)`,
  where `shortcuts` is read via `@Environment`. The doc-comment block at
  the top is updated to point at the registry.
- `App/Features/HierarchySidebar/HierarchySidebarView.swift` — the
  invisible-Button hotkey wiring at lines 619–631 swaps to the resolver.
  `Self.hotkeyModifiers` (line 614) is deleted; the mapping lives in
  `ShortcutSchema.app`.
- `App/Features/Settings/SettingsWindowView.swift` — line 83 swaps
  `ComingSoonPane` for `ShortcutsSettingsView`.
- `App/CodansApp.swift` — instantiates `ShortcutsStore`, injects
  `\.resolvedShortcuts` at the top of the view tree.
- `Features/CommandPalette/CommandPaletteItems.swift` — the
  `KeyEquivalentDescriptor` for each row is built from the resolved map
  rather than from inline `["⌘", "⇧", "G"]` literals.
- `Runtime/Status/StatusMotivationalView.swift` — palette hint reads from
  the resolved map.

Dependency direction: CodansCore stays SwiftUI-free and AppKit-free;
the `App/Shortcuts/` glue layer is the only place that imports SwiftUI,
AppKit, and `CodansCore`. Nothing in CodansCore reaches up.

## 5. Cross-Cutting Concerns

### 5.1 Migration / Rollout

This change is silent on first launch: `shortcuts.json` does not exist,
the override store is empty, and `ShortcutResolver` returns the schema
defaults — which match today's hardcoded chords. A user on the new build
sees identical behavior until they open the Settings pane and rebind
something. There is no v1→v2 migration to consider; v1 is the first
version.

The rewrite of `MainWindowCommands` and `HierarchySidebarView` is the
substantive refactor risk. The audit unit test (§5.3) asserts that for
every `CommandID` case, the schema default produces a `KeyEquivalent +
EventModifiers` pair that exactly matches the literal that was there
before (a snapshot check). This catches accidental drift during the
sed-and-substitute step.

### 5.2 Observability

A single signpost stream:

```swift
let logger = Logger(subsystem: "com.gumpw.codans.shortcuts", category: "registry")
```

Events:

- `loaded` — store startup, `n` overrides applied.
- `override` — user changed a binding; payload `(commandID, source: "record" | "disable" | "reset")`.
- `conflict.rejected` — recorder rejected a chord; payload `(commandID,
  reason: "systemReserved" | "appKitReserved")`.
- `conflict.confirmed` — internal-conflict replace was confirmed; payload
  `(commandID, displaced: CommandID)`.
- `cascadingReset` — payload `(target, cascaded: [CommandID])`.

No PII (CommandIDs are application enum values; no filesystem paths or
user content).

### 5.3 Testing Strategy

Unit tests in `CodansCoreTests/Shortcuts/`:

- `ShortcutResolverTests` — empty overrides ⇒ schema; partial overrides ⇒
  merged; disabled override ⇒ resolved with `isEnabled = false` and
  `source = .userOverride`.
- `ShortcutResetPlannerTests` — table-driven, including the swap-conflict
  case (A's default == B's user override, A's user override == B's
  default → resetting A cascades to reset B).
- `InternalConflictDetectorTests` — chord clashes detected only across
  `.configurable` entries with `isEnabled` true; disabled entries do not
  block.
- `AppKitReservedDetectorTests` — exhaustive over the hardcoded reserved
  list; case sensitivity / modifier-set canonicalization.
- `ShortcutSchemaAuditTests` — for every `CommandID.allCases`, the schema
  has exactly one entry; for every schema entry, the `defaultBinding`
  matches the literal previously used at the call site (snapshot check
  pinned during the migration commit).

Unit tests in `apps/mac/codans/Tests/Shortcuts/` (App-target tests
because they depend on AppKit / SwiftUI shims):

- `ShortcutDisplayTests` — fixed-fixture layout (programmatically install
  a known layout for the test) renders the expected keycap; arrow / Esc
  / Tab / function keys map to their fixed glyphs.
- `ShortcutsStoreTests` — atomic write, debounce coalesces multi-edit
  bursts, broken-file backup.

Manual: open Settings → Shortcuts, rebind `⌘T → ⌃T`, verify menu updates
without restart, type `⌃T` and confirm New Tab fires; rebind `⌘T → ⌘W`
and confirm the conflict dialog mentions Close Tab; click Restore All
and confirm both overrides revert.

### 5.4 Accessibility

- The recorder field exposes `accessibilityLabel("Shortcut for \(title)")`
  and `accessibilityValue` set to the rendered chord ("Command Shift G")
  rendered in long form via `NSEvent.modifierFlags` localized
  descriptions, not the glyphs.
- Reset and Disable controls are independently focusable and labelled.
- Conflict dialogs are standard SwiftUI alerts and inherit the system
  accessibility behavior.
- The chord's keycap symbols (⌘, ⇧, …) are visual; VoiceOver reads the
  `accessibilityValue` long form, never the glyph string.

### 5.5 Performance

- Resolution is `O(|CommandID.allCases| + |overrides|)` once per save;
  with ~25 commands it is microseconds and runs only when overrides
  change. The resolved map is cached on `ShortcutsStore`.
- Display rendering (`UCKeyTranslate` per keycap) is microseconds per
  call; the Settings pane caches per-row display strings via SwiftUI's
  view identity.
- File I/O is debounced 500 ms (matches `SettingsStore`); a burst of
  rebinds during recorder use coalesces into one write.

### 5.6 Security & Privacy

`shortcuts.json` is user-readable, user-writable, and contains no
sensitive data — only command IDs and key codes. Permissions follow the
default umask of the parent directory. No network egress.

## 6. Alternatives Considered

### 6.1 Persist the chord as `Character` + modifiers

Store `"keyChar": "g", "modifiers": ["command", "shift"]` instead of a
keyCode. Simpler to read by humans; matches the SwiftUI
`KeyEquivalent`/`EventModifiers` API directly.

**Rejected.** A user who maps `⌘[` on a U.S. layout and then switches to
French AZERTY would find the chord moves to a different physical position
(because `[` on AZERTY requires `⌥(` ). Persisting the keyCode makes the
chord stable to the *physical key* the user actually trained their muscle
memory on. The complexity cost is contained inside `ShortcutDisplay`; the
UI never exposes keyCodes.

### 6.2 Fold shortcuts into `settings.json`

Add a `shortcuts: ShortcutOverrideStore` field on `Settings`. One file,
one writer, one migrator.

**Rejected for three reasons.**

- `Settings` is currently at v3 with a strict migrator; adding a field
  forces a v4 bump for a feature that has clean lifetime separability.
- The two stores' write cadences differ enough that interleaving their
  debounces creates avoidable contention (a recorder commit during a
  Settings pane edit would coalesce both into one write).
- A standalone file is the natural shape for the deferred export feature
  — the user can already inspect or copy the file without further
  tooling. Folding in would force us to add an extractor later.

The cost of separation is one extra `@Observable` store and ~50 lines of
parallel boilerplate, both of which we already have a known-good template
for in `SettingsStore`.

### 6.3 Open registration protocol instead of a closed enum

A `ShortcutCommand` protocol with each feature module conforming and
contributing entries at composition time.

**Rejected.** The first-cut surface (~25 commands) and the long-term
ceiling (under 50) make exhaustive `switch` over a closed enum strictly
better:

- Routing code (the Settings pane, the audit test, conflict-display row
  ordering) gets compile-time exhaustiveness for free.
- Renaming a command is a compile-time error at every call site —
  invaluable during refactors.
- The registry pattern would need a stable-string ID layer anyway (for
  the JSON format), introducing duplication between the protocol's typed
  identity and the persisted string.

If a plugin surface ever appears, we can introduce an open registry
alongside the closed enum (the persisted schema already carries a
`version`, so a v2 with a `customCommands: [String: ShortcutBinding]`
extension is a non-breaking add).

### 6.4 Use a custom AppKit `NSEvent` global monitor instead of SwiftUI `.keyboardShortcut`

`NSEvent.addLocalMonitorForEvents(matching: .keyDown)` would intercept
keys before SwiftUI sees them, letting us implement chord matching
without going through SwiftUI menu items.

**Rejected.** SwiftUI's `.keyboardShortcut` already plumbs into the
NSMenu chain, gives us free menu-bar display, free disable-when-button-disabled
behavior, and inherits the standard responder rules (a chord doesn't fire
into the terminal pane while the user is typing in the search field).
A custom monitor would re-implement all of that at the cost of subtle
focus-routing bugs. The recorder UI is a different story (§3.8) — it
*does* use `NSEvent` because it specifically wants to capture chords
that *would otherwise fire menu items* during recording.

### 6.5 Reset-without-cascade

Treat reset as "clear the override; on conflict, ignore." Simpler code.

**Rejected.** A non-cascading reset on a swap-conflict (A's default ==
B's override; B's default == A's override) leaves both A and B bound to
the same chord, with neither user-facing UI surfacing the silent
collision. The cascading planner adds ~30 lines and one confirmation
dialog and prevents a class of bugs that would be hard to diagnose by
report.

### 6.6 Multi-stroke chord support (`⌘K ⌘O`)

Add a `secondary: ShortcutBinding?` field to support sequences.

**Rejected for v1.** No call site today requires it, and the recorder
UI gets significantly more complex (timing windows, partial-match
display). The persisted schema reserves the ability to extend
`ShortcutBinding` to a `ShortcutChord` aggregate later without breaking
v1 documents (we add a version bump and an opt-in `chord: …` field;
existing single-binding documents continue to load).

### 6.7 Per-Project shortcut overrides

`Settings.projects[id].shortcuts` letting different repos rebind chords
differently.

**Rejected.** Shortcut muscle memory is per-user, not per-project; the
case for divergence is weak and the UX cost (which project is "active"
for shortcut purposes when no Worktree is selected?) is high. Project
settings already cover the cases where divergence makes sense (default
editor, scripts).

### 6.8 Inject shortcuts via `@Dependency` instead of `@Environment`

TCA's dependency system rather than SwiftUI's environment.

**Rejected.** The shortcut map is a *view-tier* concern — bindings
attach to view modifiers, the Settings pane is a SwiftUI view, the
recorder is a SwiftUI view. `@Environment` is the idiomatic conduit.
Reducer code does not need to read shortcuts (it does not care which
chord triggered an action, only that it arrived). Pulling the map into
`@Dependency` would let reducers read it but pay an indirection cost
across every view-tier call site.

## 7. Risks

| Risk | Mitigation |
|---|---|
| The schema audit test drifts out of sync with `MainWindowCommands` literals during the migration commit, so a chord silently changes value | The migration is structured as two commits: (1) introduce the registry + audit test pinned to today's literals, (2) rewrite call sites to read from the registry. Step (1)'s test passing is the gate for step (2). |
| `UCKeyTranslate` returns a non-printable for an exotic keyCode on an unusual layout, leading to a blank keycap in the UI | Fallback chain: layout-translated character → US-QWERTY translation → raw keyCode in hex (e.g. `<0x4A>`) so the row never shows blank. Logged at `.info`. |
| A user records a chord that conflicts with an internal command we forgot to register (because the command predates the registry) | The audit test (§5.3) catches missing entries at compile time for declared commands. For undeclared/undiscovered chords (e.g. AppKit-internal text-edit shortcuts that we don't list), the AppKit-reserved detector's hardcoded list is the catch-all; we extend the list as we discover holes. The risk is "user can choose `⌘C` and get surprise text-copy interference"; mitigation is documenting the reserved list as the authoritative cut and adding entries when bug reports arrive. |
| Input-source change at runtime doesn't refresh menu display strings because the SwiftUI view tree doesn't observe the kTIS notification | `ShortcutsStore` exposes a `displayInvalidationToken: Int` that bumps on the notification; the environment-injected map carries it, and `appKeyboardShortcut` (which already takes the map) re-renders. Menu items participate in the same environment in SwiftUI. Verified manually by switching layouts mid-session. |
| The chord recorder's `NSEvent.addLocalMonitorForEvents` interferes with `.keyboardShortcut` bindings while the recorder field is focused — a user could accidentally fire `⌘W` and close a tab while trying to record `⌘W` for a different command | The recorder's local monitor returns `nil` from its handler for any keyDown event while it has focus, swallowing the event before it reaches the responder chain. The monitor is removed on field resign-first-responder. Verified by recording `⌘W` and confirming the active tab is not closed. |
| `shortcuts.json` is hand-edited to malformed state and the user loses overrides on next launch | Decode failure backs the broken file aside as `shortcuts.json.broken-<ts>` (parallel to `SettingsStore`'s policy) and starts with empty overrides. Logged at `.error`. |
| The recorder accepts `⇧` + plain letter and the user records `⇧A`, shadowing typed text everywhere | Recorder rejects bindings whose only modifier is `⇧`. This is enforced before invoking the conflict detectors. |
