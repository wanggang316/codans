# Design Doc: App Appearance & Terminal Theme

**Status:** Draft
**Author:** Gump
**Date:** 2026-04-22

## Context and Scope

codans ships a Settings → General → Appearance picker today (`system` / `light` / `dark`), backed by `CodansCore/Settings/AppearancePreference.swift`. The value is persisted by `SettingsStore` but **inert** — the enum's docstring and the picker caption both state "preview only — themes will ship in a later release." This doc designs the "later release," expanded to cover the full visual-theming surface area:

1. **App appearance** — making the existing Light / Dark / System picker actually drive the app's visual chrome, for both SwiftUI-managed and AppKit-hosted surfaces.
2. **Terminal theme** — a new Settings → Terminal pane that lets the user pick a light-mode palette and a dark-mode palette from Ghostty's bundled theme catalog. The app writes these selections into the user's Ghostty config file and reloads the running runtime so changes take effect immediately.

The two layers compose: when the app is in dark appearance, Ghostty renders the user-chosen dark palette; in light, the light palette; in system mode, follows macOS.

### Scope

In scope:

- SwiftUI-managed chrome (both `WindowGroup` main window and `Window("Settings")` scene in `CodansApp`).
- AppKit-hosted surfaces — primarily Ghostty terminal views in `apps/mac/codans/Runtime/Ghostty/` and `App/PaneHostView.swift`. These do not inherit SwiftUI's `.preferredColorScheme` automatically.
- The Ghostty terminal palette (foreground, background, ANSI colors) controlled via named themes stored in Ghostty's own config file.
- A new `Terminal` section in the Settings window.

Out of scope:

- A design-token / theme layer for codans's own chrome (shared `Color` namespace for brand colors). The existing `App/Theme/ThemeGit.swift` is a local namespace for diff rendering, not a global system, and should stay that way.
- Syntax-highlighting themes for the editor integration.
- Font family / font size / close-confirmation controls in the Terminal pane. These ride on the same managed-keys mechanism (see below) and are a natural future extension, but are not in this deliverable.
- Custom user-defined terminal palettes (hand-tuning individual color values). Users pick from Ghostty's catalog; anyone needing a custom palette can drop a theme file into Ghostty's themes directory and it will appear in the picker.
- High-contrast / accessibility-specific appearances.
- Per-project / per-worktree appearance override.

### Current state

- `AppearancePreference` is a plain `Codable` enum with three cases (`system`, `light`, `dark`).
- `GeneralSettings.appearance` persists via `SettingsStore`'s debounced writer; the JSON shape is already shipped to users.
- `SettingsGeneralView` renders a `Picker` bound to `settingsStore.setAppearance(_:)`; the caption declares it a preview.
- `SettingsSection` has no `terminal` case; settings sidebar (`SettingsWindowView`) lists only `general`, `notifications`, `developer`, `shortcuts`, `updates`, `about` plus per-repository rows.
- The app has two scenes (`WindowGroup` for the main window, `Window("Settings")`). Both default to whatever appearance macOS decides.
- `GhosttyRuntime` exposes `register(pane:)` / `unregister(paneID:)` / `surface(for:)` / `tick()` — **no appearance or config-reload API**. Ghostty terminal surfaces currently render whatever palette the user's global Ghostty config dictates at launch and do not react to the in-app picker.
- No code today reads or writes `~/.config/ghostty/config`.
- 54 color call sites across the UI layer: predominantly system semantic colors (`Color(nsColor: .textBackgroundColor)`, `.secondary`, materials) that auto-adapt, plus a handful of hand-tuned accents (`Color.red`, `Color.orange.opacity(0.08)`).

## Goals and Non-Goals

**Goals**

- Changing the Appearance picker in Settings → General updates the live app immediately, for the main window, the Settings window, and any window opened afterwards.
- `system` mode follows macOS's current appearance and reacts to the OS toggle without user action.
- Ghostty terminal surfaces follow the chosen app appearance — both the chrome (scrollbar, borders) and the palette (foreground, background, ANSI colors).
- A Settings → Terminal pane lets the user choose a light-mode palette and a dark-mode palette from the themes Ghostty ships with. Selection takes effect in live terminals immediately.
- Theme selections persist in the user's Ghostty config file (`~/.config/ghostty/config`), so they apply when Ghostty is used outside codans as well.
- Existing lines in the user's Ghostty config that codans does not manage are preserved byte-for-byte.
- The "preview only" caption and docstring are removed.
- No migration required for existing codans `settings.json` files.

**Non-Goals**

- A `Theme` struct or semantic color token layer for codans's own UI. The existing 54 color sites are predominantly system-semantic and already adapt; a token layer is not justified by current requirements.
- Hand-tuned per-user terminal palettes edited in-app. Users can still drop theme files into Ghostty's themes directory — those will appear in the picker automatically — but we do not ship a color editor.
- Sidecar storage of terminal theme choices in codans's own `settings.json`. The Ghostty config file is the source of truth; codans only reads and writes it.

## Design

### Overview

Three cooperating pieces, driven from two independent sources of truth:

**Source of truth A — `settingsStore.settings.general.appearance` (already exists).**
Chooses the app's overall appearance (Light / Dark / System). Applied via a **dual-path** strategy at the scene root:

1. **SwiftUI path** — `.preferredColorScheme(preference.colorScheme)` on every scene's content. Propagates `@Environment(\.colorScheme)` to SwiftUI descendants, causing system semantic colors and materials to re-render.
2. **AppKit path** — an `NSViewRepresentable` in `.background { }` of the same content, whose `viewDidMoveToWindow` assigns `NSApp.appearance = preference.appearance` and walks `NSApp.windows`. This coerces AppKit-hosted surfaces (Ghostty) that do not observe the SwiftUI environment.

The dual-path design is necessary because Ghostty's terminal view is a Metal-backed `NSView` subclass that does not participate in SwiftUI's color-scheme environment, while SwiftUI views that read `@Environment(\.colorScheme)` are not driven by `NSApp.effectiveAppearance`. Both paths must be wired from the same enum value — in a single wrapper (`AppAppearanceView`) — or components silently desynchronize.

**Source of truth B — the user's Ghostty config file (`~/.config/ghostty/config`).**
Chooses the light-mode palette name and the dark-mode palette name. Owned by Ghostty; codans reads and writes a small, bounded set of directives using a **managed-keys** strategy (see below).

**The bridge — `GhosttyRuntime.setColorScheme(_:)` (new).**
A small wrapper view reads `@Environment(\.colorScheme)` (already resolved by path A) and calls `ghostty_app_set_color_scheme` + per-surface `ghostty_surface_set_color_scheme`. This tells Ghostty which of its two configured palettes — light or dark — to render, without reloading the whole config. Cheap, in-memory, synchronous.

**The config writer — `GhosttyConfigFile` (new).**
When the user picks a theme in Settings → Terminal, we rewrite the managed region of their Ghostty config file (atomic write via a temp-file sibling) and post a notification. `GhosttyRuntime` listens for the notification and calls `ghostty_app_update_config`, which re-parses and applies the new config to every live surface.

**Why separate "runtime color-scheme signal" from "config file write":**

- The runtime signal is cheap (microseconds) and fires on every OS appearance flip or user toggle — possibly dozens of times per session.
- The config write is I/O and file parsing — much heavier, and only fires when the user explicitly changes a palette name (rare).

Collapsing the two into a single path (e.g. rewriting the config file on every appearance change) would make every OS dark-mode toggle a disk write. Keeping them separate lets each run at its natural frequency.

### System Context Diagram

```
 Source of truth A                          Source of truth B
 ─────────────────────                      ──────────────────────
 SettingsStore                              ~/.config/ghostty/config
 .general.appearance                        (managed region:
 (Light/Dark/System)                         theme = light:X,dark:Y)
       │                                           ▲
       ▼                                           │ atomic write
 ┌─────────────────┐                        ┌──────────────────┐
 │ AppAppearance   │                        │ GhosttyConfigFile│
 │ View            │                        │  load / apply    │
 └──┬────────────┬─┘                        └────────┬─────────┘
    │            │                                   │
SwiftUI path │ AppKit path                     posts │ .ghosttyRuntimeReload
    │            │                                   │   Requested
    ▼            ▼                                   ▼
preferredColor   NSApp.appearance           ┌──────────────────┐
Scheme           + windows[n].appearance    │  GhosttyRuntime  │
    │                                       │  .reloadAppConfig│
    └─→ @Environment(\.colorScheme)─────┐   │  (ghostty_app_   │
                                        ▼   │   update_config) │
                       ┌──────────────────┐ └──────────────────┘
                       │ GhosttyColor     │         │
                       │ SchemeSyncView   │         │ applies to all
                       └────────┬─────────┘         │ live surfaces
                                │                   ▼
                      setColorScheme(_:)    All Ghostty surfaces
                                │           render new palette
                                ▼
                       GhosttyRuntime
                       ghostty_app_set_color_scheme
                       + per-surface refresh
```

### API Design

**`AppearancePreference` — extend with two projections.**

```swift
extension AppearancePreference {
  var colorScheme: ColorScheme? { ... }   // .system → nil, .light → .light, .dark → .dark
  var appearance: NSAppearance?   { ... } // .system → nil, .light → .aqua,  .dark → .darkAqua
}
```

Two variants because the SwiftUI and AppKit paths need different types. `.system` maps to `nil` on both — letting macOS's current appearance take effect.

Because `CodansCore` must remain `AppKit`-free (it is consumed by non-UI targets), the `NSAppearance` projection lives in an **app-module** extension file under `apps/mac/codans/App/Theme/`. The `ColorScheme` projection can live either place; colocating both app-side keeps the pair together and `CodansCore` pure.

**`AppAppearanceView<Content>` — scene wrapper (new).**

```swift
struct AppAppearanceView<Content: View>: View {
  @Environment(SettingsStore.self) private var settingsStore
  let content: Content
  var body: some View {
    content
      .preferredColorScheme(settingsStore.settings.general.appearance.colorScheme)
      .background {
        WindowAppearanceSetter(preference: settingsStore.settings.general.appearance)
      }
  }
}
```

Reads `SettingsStore` reactively via the existing `@Environment` injection (`CodansApp` already installs it on both scenes). Placing `AppAppearanceView` at the root of *every* scene ensures `viewDidMoveToWindow` fires at least once per scene attachment — picking up newly opened windows automatically.

**`WindowAppearanceSetter` — `NSViewRepresentable` (new).**

Thin `NSView` wrapper. `viewDidMoveToWindow` (and the `didSet` on `preference`) triggers `applyAppearance()`:

```swift
private func applyAppearance() {
  guard window != nil else { return }
  let appearance = preference.appearance
  NSApp.appearance = appearance
  for window in NSApp.windows {
    window.appearance = appearance
    window.contentView?.needsLayout = true
    window.contentView?.needsDisplay = true
    window.invalidateShadow()
  }
}
```

Walking `NSApp.windows` and re-assigning each is belt-and-suspenders: `NSApp.appearance` alone should propagate, but windows created or configured before the global was set can end up stale. The explicit per-window loop plus `invalidateShadow()` forces chrome (title bar, traffic lights, window shadow) to re-render immediately.

**`GhosttyColorSchemeSyncView<Content>` — terminal runtime sync wrapper (new).**

```swift
struct GhosttyColorSchemeSyncView<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  let ghostty: GhosttyRuntime
  let content: Content
  var body: some View {
    content.onChange(of: colorScheme, initial: true) { _, new in
      ghostty.setColorScheme(new)
    }
  }
}
```

Wraps the pane-host subtree in `ContentView` / `PaneHostView` at a point where `GhosttyRuntime` is accessible. Reads `@Environment(\.colorScheme)` (already resolved by `AppAppearanceView`). `initial: true` so freshly created Ghostty surfaces inherit the current scheme without waiting for a user change.

**`GhosttyRuntime` — two new methods.**

```swift
extension GhosttyRuntime {
  func setColorScheme(_ scheme: ColorScheme) {
    // ghostty_app_set_color_scheme(app, GHOSTTY_COLOR_SCHEME_DARK / _LIGHT)
    // for each registered surface: ghostty_surface_set_color_scheme + ghostty_surface_refresh
    // cache last scheme so freshly registered surfaces can be initialized with it
  }

  func reloadAppConfig() {
    // rebuild ghostty_config_t from configPath via Ghostty's default load path,
    // then ghostty_app_update_config(app, config); free the temporary config.
  }
}
```

`setColorScheme` also tracks the last-applied scheme, so when a new `PaneSurface` registers the runtime can immediately apply the correct scheme to it (otherwise new panes open in the wrong palette until the next scheme toggle).

`reloadAppConfig` is invoked from the notification listener registered in `GhosttyRuntime.init`:

```swift
NotificationCenter.default.addObserver(forName: .ghosttyRuntimeReloadRequested, ...) { [weak self] _ in
  self?.reloadAppConfig()
}
```

This decouples the config writer from the runtime — the writer doesn't hold a reference; any future source of config edits (not just the Settings pane) just posts the notification.

**`GhosttyConfigFile` — config file reader / writer (new, `@MainActor`).**

```swift
struct GhosttyConfigFile {
  func load() throws -> GhosttyTerminalSettings        // snapshot + available themes
  func apply(_ settings: GhosttyTerminalSettingsDraft) throws  // atomic write + notify
}

struct GhosttyTerminalSettings {
  let configPath: String
  let lightTheme: String?        // currently-configured names
  let darkTheme: String?
  let availableLightThemes: [String]   // enumerated from Ghostty resources
  let availableDarkThemes: [String]
  let warning: String?           // "config file had parse issues on line X", non-fatal
}

struct GhosttyTerminalSettingsDraft {
  let lightTheme: String?        // nil means "don't set"
  let darkTheme: String?
}
```

**Managed-keys strategy.** The config file is a mix of user-written lines and lines codans owns. `GhosttyConfigFile.apply` defines a set of managed keys (v1: just `theme`; extensible to `font-family`, `font-size`, `confirm-close-surface` later). On write:

1. Read the file as UTF-8 lines.
2. Scan each line; if its key is in the managed set, drop it; otherwise preserve verbatim (comments, whitespace, unknown keys, other users' directives).
3. Remember the index of the first dropped managed line — that's the insertion point.
4. Build the canonical managed block from the draft (e.g. `theme = light:Zenbones Light,dark:Zenbones Dark`).
5. Insert the managed block at the remembered index (or at end-of-file if no managed line existed before).
6. Write to a temp file sibling, then `replaceItem` onto the real path atomically.
7. Post `.ghosttyRuntimeReloadRequested`.

The managed block is always emitted in the same order and format regardless of draft order — keeps diffs between app-edits minimal and human-readable.

If the user has no config file yet, `ensureConfigFile` creates it at `~/.config/ghostty/config` with just the managed block. If the directory doesn't exist, create it.

**Theme catalog discovery.** Ghostty ships theme files in its resources bundle. `GhosttyConfigFile.load` enumerates the themes directory (resolved from `Bundle.main.resourceURL` and/or `$XDG_CONFIG_HOME/ghostty/themes`), parses each file just enough to read its `background` color, and classifies it as light or dark by background luminance (e.g. `Y = 0.299R + 0.587G + 0.114B > 0.5` → light). Returns `availableLightThemes` and `availableDarkThemes` sorted alphabetically. If a user has selected a theme that is not present in the catalog (e.g. old name, removed theme), it is prepended to the list so the Picker still shows the current value.

**Settings → Terminal TCA feature (new).**

```swift
enum SettingsSection {
  case general, notifications, developer, shortcuts, updates, about, terminal  // ← new
  case repositoryGeneral(ProjectID), repositoryHooks(ProjectID)
}
```

A new reducer `SettingsTerminalFeature` with state:

```swift
struct State {
  var snapshot: GhosttyTerminalSettings?   // nil until loaded
  var isLoading: Bool
  var isApplying: Bool
  var errorMessage: String?
  var warningMessage: String?
}
```

Actions: `.onAppear` (async-load via the client), `.lightThemeSelected(String?)`, `.darkThemeSelected(String?)`, `.applyResult(TaskResult<GhosttyTerminalSettings>)`. The reducer throttles applies: a fast re-selection supersedes the in-flight call. Not dependency-injectable for tests:

```swift
struct GhosttyTerminalSettingsClient: Sendable {
  var load: @Sendable () async throws -> GhosttyTerminalSettings
  var apply: @Sendable (GhosttyTerminalSettingsDraft) async throws -> GhosttyTerminalSettings
}
```

The live value binds to `GhosttyConfigFile` on `MainActor`. The test value serves fixture data in-memory.

**Settings → Terminal pane UI.**

```
┌──────────────────────────────────────────────────────────────┐
│ Terminal                                                     │
│                                                              │
│  Light/Dark Theme    [ Zenbones Light  ▼]  [ Zenbones Dark▼] │
│                                                              │
│  Config File                                                 │
│    ~/.config/ghostty/config                                  │
│                                                              │
│  Footer: "codans reads and writes your Ghostty config,   │
│           so changes here stay in sync with Ghostty itself." │
└──────────────────────────────────────────────────────────────┘
```

Plain two `Picker`s, side by side. Pickers show "Select Theme" when the current value is nil. Pickers are disabled while `isApplying || isLoading`. Warning / error messages render above the controls when present (e.g. "Config file had parse issues on line 14 — unmanaged content preserved, themes updated.").

**Unchanged:** `SettingsStore`, `AppearancePreference.CodingKeys`, `GeneralSettings`, `SettingsGeneralView`'s `Picker` binding. Only the `SettingsGeneralView` caption copy changes.

### Data Storage

**codans `settings.json`:** No schema changes. `GeneralSettings.appearance: AppearancePreference` already persists via `SettingsStore`'s debounced save pipeline. Default stays `.system`. Existing `settings.json` files decode unchanged.

**Ghostty config file (`~/.config/ghostty/config`):** Resolved using Ghostty's own convention — `$XDG_CONFIG_HOME/ghostty/config` when set, else `$HOME/.config/ghostty/config`. Format is the key-value line format Ghostty already parses; codans writes plain lines, never a structured representation. Only the managed keys are rewritten; everything else is preserved byte-for-byte.

Concurrent editing risk (user has Ghostty open in a text editor while codans writes) is mitigated by atomic replace: `replaceItem` preserves inode identity on overwrite, so a concurrent read sees either the old or the new file, never a partial state. If the user saves in their editor after our write, their save wins (last-write-wins) — standard filesystem semantics, acceptable for a rarely-edited config.

### Component Boundaries

```
CodansCore/Settings/
  AppearancePreference.swift           unchanged (Codable enum) — drop "preview only" wording
  GeneralSettings.swift                unchanged

apps/mac/codans/App/Theme/         (new files; sibling of ThemeGit.swift)
  AppearancePreference+UI.swift        ColorScheme + NSAppearance projections
  AppAppearanceView.swift              scene wrapper (~30 LOC)
  WindowAppearanceSetter.swift         NSViewRepresentable + AppearanceApplyingView (~40 LOC)
  GhosttyColorSchemeSyncView.swift     ghostty runtime color-scheme sync (~20 LOC)
  AppearanceDiagnostics.swift          structured log helper (~30 LOC)

apps/mac/codans/App/
  CodansApp.swift                   wrap both scene contents in AppAppearanceView { }
  ContentView.swift                    wrap terminal subtree in GhosttyColorSchemeSyncView

apps/mac/codans/Runtime/Ghostty/
  GhosttyRuntime.swift                 add setColorScheme(_:), reloadAppConfig(),
                                       register notification listener in init
  GhosttyConfigFile.swift              new — load/apply managed region of config file
  GhosttyThemeCatalog.swift            new — enumerate + classify bundled themes

apps/mac/codans/App/Features/Settings/
  SettingsSection.swift                add .terminal case
  SettingsWindowView.swift             sidebar row + switch case for .terminal pane
  Panes/SettingsGeneralView.swift      remove "preview only" caption (one-line copy change)
  Panes/SettingsTerminalView.swift     new pane (~120 LOC)
  SettingsTerminalFeature.swift        new TCA reducer + client (~150 LOC combined)

apps/mac/codans/App/Clients/
  GhosttyTerminalSettingsClient.swift  new — Dependency wrapper around GhosttyConfigFile

CodansCore/Support/ or similar
  Notification.Name extension for .ghosttyRuntimeReloadRequested (or keep app-side)
```

Dependency directions:

- `App/Theme/` depends on `CodansCore` and `AppKit`/`SwiftUI`. Never the reverse.
- `CodansCore` stays `AppKit`-free.
- `Runtime/Ghostty/GhosttyConfigFile` has no dependency on the Settings feature — it defines data types that the Settings feature imports. Notification is the only coupling between writer and runtime.
- `SettingsTerminalFeature` depends on `GhosttyTerminalSettingsClient` (TCA `DependencyKey`), which in turn wraps `GhosttyConfigFile` in its `liveValue`. Test dependencies inject a fake client without touching the filesystem.

## Alternatives Considered

### Alt 1 — SwiftUI `.preferredColorScheme` only

Apply `.preferredColorScheme(preference.colorScheme)` to each scene's content and stop there. No `NSViewRepresentable`, no AppKit appearance assignment.

**Rejected because:** Ghostty's terminal view is an AppKit-hosted `NSView` subclass with Metal-backed rendering. It does not observe SwiftUI's `@Environment(\.colorScheme)` — chrome and palette remain tied to `NSAppearance`, which `.preferredColorScheme` sets on SwiftUI-managed windows but not necessarily on every AppKit host nested inside them (behavior inconsistent across macOS versions). The AppKit path is not optional; it is what makes non-SwiftUI surfaces follow along.

### Alt 2 — AppKit `NSApp.appearance` only

Assign `NSApp.appearance` at app launch and on every preference change, skip `.preferredColorScheme`.

**Rejected because:** `@Environment(\.colorScheme)` in SwiftUI is driven by `.preferredColorScheme`, not by `NSApp.effectiveAppearance`. Skipping the SwiftUI modifier leaves any SwiftUI view that reads `colorScheme` — including `GhosttyColorSchemeSyncView` — keyed to the system default rather than the user's preference. The two paths must both be wired or dependent components silently desynchronize.

### Alt 3 — Store terminal theme choices in codans's `settings.json`

Persist the light/dark theme names in `GeneralSettings` alongside `appearance`. On change, patch the live Ghostty config in memory but leave the user's config file alone.

**Rejected because:** The user's expectation is that a terminal palette choice holds across all Ghostty usage, not just codans. Splitting the source of truth (codans's JSON for in-app, Ghostty's config for standalone) creates drift the first time the user edits one and not the other. Writing Ghostty's config is how Ghostty itself expects this state to be owned — one file, one truth.

### Alt 4 — Shell out to Ghostty's own CLI / IPC to set themes

If Ghostty exposes a "set theme" command externally (e.g. via `ghostty +theme set light:X,dark:Y`), call that instead of editing the config file.

**Rejected because:** No such command exists in the Ghostty version we embed, and even if it did, the canonical persistence would still be the config file — the CLI would just write to it. Skipping the intermediary avoids a dependency on Ghostty CLI behavior that may differ across versions.

### Alt 5 — Rewrite the entire Ghostty config on apply (not just managed lines)

Parse the whole file, emit a canonical re-serialization.

**Rejected because:** Ghostty's config format includes comments, blank lines, and directive ordering that users deliberately maintain (grouping, conditional blocks via `config-file = ...`). Canonical re-serialization destroys intent. The managed-keys strategy — preserve everything except the bounded set codans owns — is the minimum-disruption approach.

### Alt 6 — Introduce a codans `Theme` struct / design-token layer

Define `Theme` types with `accent`, `surface`, `warning`, etc., injected via `@Environment(\.theme)`; migrate the 54 color sites.

**Rejected because:** 54 existing color uses are overwhelmingly system-semantic and already adapt. The marginal value of tokens is brand customization / alternative palettes / high-contrast mode, none of which is a current product requirement. Moves scope from "a few new files" to "visual-audit every view" — large regression risk for no immediate user-visible improvement. Revisit if brand customization, alternative palettes, or high-contrast mode becomes a goal. The existing `App/Theme/ThemeGit.swift` — a contained git-diff namespace — is the right precedent: make a small namespace *when and where* a specific feature needs coordinated colors, not a global layer pre-emptively.

### Alt 7 — Preview-card Appearance picker

Replace the three-option `Picker` in Settings → General with three large tiles (each an image set with Light/Dark variants) that convey the visual result.

**Deferred, not rejected.** Requires designing / exporting three images per appearance. Ship the functional `Picker` first; add cards in a follow-up. Keeps the initial change reviewable and does not block the capability.

## Cross-Cutting Concerns

**Observability.** Introduce `AppearanceDiagnostics.log(_:)` — an `os_log`-style helper that emits single-line structured records on:

- User-initiated appearance-mode changes.
- `viewDidMoveToWindow` and per-window `NSApp.appearance` application.
- Ghostty runtime scheme changes (before / after, per surface count).
- Ghostty config-file reads and writes (path, managed-key diff, parse warnings).

Fields include the current preference, resolved `NSAppearance` name, `NSApp.effectiveAppearance`, and window identifiers. Forensic: when a user reports "one window didn't update" or "my Ghostty palette didn't change," we can ask for a log dump and see which path fired for which target.

**Testing strategy.**

- Unit-testable: mapping `AppearancePreference → ColorScheme?` and `AppearancePreference → NSAppearance?` (trivial; three assertions each).
- Unit-testable: `GhosttyConfigFile.updatedContents(from:settings:)` — pure string transformation. Test cases:
  - Empty file → managed block added.
  - File with unrelated directives only → managed block appended, others preserved.
  - File with existing managed `theme = ...` line → replaced in place.
  - File with multiple managed lines interleaved → all dropped, single canonical block at the earliest position.
  - File with comments and blank lines mixed with managed keys → comments/blanks preserved, managed keys collapsed.
  - Trailing-newline preservation.
- Unit-testable: theme classification (light vs dark by luminance) — given sample `background = #RRGGBB`, assert the split.
- Unit-testable: `SettingsTerminalFeature` reducer — `TestStore` with a fake `GhosttyTerminalSettingsClient` covers load / select / apply / error paths.
- Not meaningfully unit-testable: `WindowAppearanceSetter` side effects and the wrapper views' bodies. Covered by manual visual walk-through: `light` / `dark` / `system` × {main window, Settings window, newly-opened sheets, system Appearance toggle while in `system` mode}.
- Not unit-testable: live Ghostty runtime re-application. Covered by manual verification with a real terminal open during theme changes.

**Rollback.** Pure-additive change. If `AppAppearanceView` misbehaves, revert the wrapping in `CodansApp.swift` — wrapped scene content continues to work under macOS's default appearance. If the Terminal pane misbehaves, revert the `.terminal` `SettingsSection` case — existing panes are unaffected. `GhosttyRuntime.setColorScheme` and `reloadAppConfig` are additive and only invoked by new wiring.

The user's Ghostty config file has a failure mode worth calling out: if a bad managed block is written (e.g. unknown theme name), Ghostty refuses to parse it and falls back to defaults. Because we validate by writing to a temp file and invoking Ghostty's parser on it *before* overwriting the real path, this is guarded — on validation failure, the real file is untouched and the user sees an error message in the Settings pane.

**Performance.** `NSApp.appearance` assignment triggers one re-layout per open window, once per user-initiated change — not a hot path. The `GhosttyColorSchemeSyncView.onChange` fires once at mount and once per actual change; each fire is a constant-time libghostty call. `GhosttyConfigFile.apply` is file I/O + parse + notify — order of milliseconds, incurred only on explicit user picker change. Not a concern.

**Security / privacy.** Reading and writing `~/.config/ghostty/config` is user-scoped filesystem activity with no elevation or external I/O. No credentials or sensitive data flow through this feature. Theme names are opaque strings from a known catalog — no injection surface; the config format is line-based key=value without shell interpretation.

**Accessibility.** The three appearance options are presented as localized labels (System / Light / Dark), matching macOS's System Settings → Appearance conventions. Theme names are rendered verbatim from Ghostty's catalog. No keyboard-nav changes — `Picker` handles that.

## Risks

**Risk 1 — `ghostty_app_set_color_scheme` and `ghostty_surface_set_color_scheme` behave unexpectedly.**
libghostty's runtime scheme-switch may not produce a visible palette change without a surface refresh, or may interact oddly with the config-specified theme pair.

*Mitigation:* Prototype `setColorScheme(_:)` against a live Ghostty surface as the first implementation step, before committing to the rest of the wiring. Include a `ghostty_surface_refresh` call per surface if the scheme-set alone is insufficient. If runtime scheme switching turns out to be infeasible or too coarse, fall back to re-applying the config on each scheme change — noisier (disk re-read) but still correct.

**Risk 2 — Ghostty theme catalog location differs from expectations.**
The themes directory path, or the way Ghostty classifies themes as light/dark, may differ from what the implementation assumes.

*Mitigation:* The catalog discovery is localized in `GhosttyThemeCatalog`; any misdetection shows up as wrong or missing theme names in the picker — visible immediately in manual testing. Include a prototype step to list the themes directory from a real install. If classification by background luminance produces wrong splits for a handful of themes, we can refine the heuristic or let Ghostty's own theme metadata (if any) drive the split.

**Risk 3 — User's existing Ghostty config has an unexpected shape.**
Comments, conditional `config-file = ...` includes, or multi-line values could trip the line-based parser.

*Mitigation:* The managed-keys strategy is strictly **line-level**: each line is either managed or opaque, never parsed deeply. `config-file = ...` includes are preserved verbatim (not a managed key). The temp-file validation step (write candidate → invoke Ghostty's own parser → only overwrite on success) catches any case where our rewrite produces an unparseable file.

**Risk 4 — Hand-tuned colors look wrong under one appearance.**
`Color.red` (unread badge), `Color.orange.opacity(0.08)` (Developer warning), and direct `Color(nsColor: .systemRed)` calls are intended to read correctly in both modes — untested assumption.

*Mitigation:* After wiring, manually walk Settings panes, header bell, tab bar, and git viewer in both modes. File follow-ups individually; none should block the appearance feature. If systemic issues surface, revisit Alt 6 (token layer) with concrete failure cases.

**Risk 5 — New windows opened after a preference change miss the AppKit appearance.**
`WindowAppearanceSetter.applyAppearance` iterates `NSApp.windows` at fire time — catches existing windows but would miss windows opened later if the setter lives only on the main scene.

*Mitigation:* Place `AppAppearanceView` at the root of *every* scene. `viewDidMoveToWindow` in each scene's representable catches new windows at birth. For new scene types added later without the wrapping, the degradation mode is "follows last-set `NSApp.appearance`" — acceptable.

**Risk 6 — AppKit and SwiftUI paths drift.**
A window somehow receives SwiftUI's `.preferredColorScheme` but not `NSApp.appearance` (or vice versa) and renders inconsistently.

*Mitigation:* Both paths are driven from a single `AppearancePreference` read inside `AppAppearanceView` — drift requires a code bug, not a state split. The diagnostics log records both `NSApp.effectiveAppearance` and the preference on every event, making mismatches visible.

**Risk 7 — Concurrent edits to the Ghostty config file.**
User has the config file open in a text editor while codans writes, or Ghostty itself reloads during our write.

*Mitigation:* Atomic replace via `FileManager.replaceItem` ensures any reader sees either the old complete file or the new complete file, never a partial state. Last-write-wins semantics if the user saves from their editor after our write — standard filesystem expectations, acceptable for a rarely-edited config.

**Risk 8 — Future engineer re-litigates the Theme-layer decision.**
Someone looks at the 54 uncentralized color sites and proposes a token refactor.

*Mitigation:* Link the Alternatives section of this doc from any such proposal. The rejection rationale is explicit and enumerates the conditions under which revisiting is warranted (brand customization, alternative palettes, high-contrast mode). Any of those arriving as a real requirement should trigger a follow-up design doc rather than a direct refactor.
