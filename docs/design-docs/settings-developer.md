---
name: Settings Developer Pane (T3)
type: design-doc
status: Draft
author: Gump (agent: feat/settings-developer)
date: 2026-04-21
product_spec: docs/product-specs/ui-settings-window.md
depends_on:
  - docs/design-docs/settings-base.md   # T1 contracts (frozen)
  - docs/design-docs/c4-cli.md          # ~/.local/bin decision (C4 D3)
  - docs/exec-plans/0003-hooks-and-cli.md
---

# Design Doc: Settings Window — Developer Pane (T3)

## Context and Scope

T1 froze the Settings window shell, persistence, and 7 pane view files. The
Developer pane (`apps/mac/codans/App/Features/Settings/Panes/DeveloperSettingsView.swift`)
is currently `Text("TODO: supplied by T3")`. T3 replaces that body with the
spec M6 controls and ships the reusable `HookMergeView` component that T4
will compose in the Repository Hooks pane.

In scope (spec M6):

1. **M6.1 — `codans` CLI install status + Install / Uninstall / Retry.**
2. **M6.2 — User hooks list (read-only)** with a "Reveal hooks.json in Finder" entry.
3. **M6.3 — Diagnostics** — Reveal settings.json, Reveal hooks.json, Copy app version.

Out of scope (explicitly not T3):

- Notifications pane (T2) / Repository panes (T4).
- `SettingsWindowView`'s detail-switch case → view-type mapping (frozen by T1).
- New `HookConfig` schema fields; `HookConfigStore` mutations; hook enable/disable (N3).
- `/usr/local/bin` or any admin-priv install path (see §Decisions D1).

Reference files (read-only from T3's perspective):

- `apps/mac/codans/App/Features/Settings/SettingsStore.swift` — exposes
  `mutateDeveloper` and `settings.developer.cli.lastInstallAttemptAt`.
- `apps/mac/CodansCore/Settings/DeveloperSettings.swift` — already carries
  `DeveloperCLISettings.lastInstallAttemptAt`.
- `apps/mac/codans/Hooks/HookConfigStore.swift` — provides `load() throws -> HookConfig`.
- `apps/mac/CodansCore/Hooks/HookSubscription.swift` — value type the pane renders.
- `apps/mac/CodansCore/Hooks/HookConfig.swift` — provides `defaultURL()`.
- `apps/mac/CodansKit/HomeScopeGuard.swift` — reusable symlink-safety guard.
- `apps/mac/CodansKit/SkillBundleLocator.swift` — model for locating bundled assets.
- `apps/mac/codans/App/CodansApp.swift` — `AppState.bundleVersion()` / `hookConfigStore`.

## Goals and Non-Goals

### Goals

- Ship M6.1 / M6.2 / M6.3 end-to-end in the Developer pane.
- Install `codans` to `~/.local/bin/codans` + peer `~/.local/bin/tcode` symlink via a
  sudo-free, Home-scoped installer. Never touch `/usr/local/bin`.
- Provide a clean, idempotent `CLIInstallerClient` with unit-test coverage
  for install / uninstall / failure-with-retry.
- Publish a **frozen public API for `HookMergeView`** — a SwiftUI component that
  T4's Repository Hooks pane reuses verbatim. T3 is its first consumer
  (single-source: "Global") so the API proves out end-to-end before T4 starts.
- Stay inside the T1 freeze: do **not** add `case` rows to the
  `SettingsWindowView` detail switch, do **not** touch other panes, do **not**
  rename the `DeveloperSettingsView` type.

### Non-Goals

- Editing hooks through the window (spec N3 is explicitly v1-out-of-scope).
- Starting / stopping the running app, or restarting `codans` on install.
- First-launch CLI auto-install (C4 exec-plan 0003 M8 item — separate wave).
- Changing `DeveloperSettings` schema — the existing
  `DeveloperCLISettings.lastInstallAttemptAt` slot is reused unchanged.
- Writing to `settings.json` from inside `CLIInstallerClient` directly. The
  pane's ViewModel is the only writer and mutates through
  `SettingsStore.mutateDeveloper { ... }` so the single-writer invariant
  holds.

## Decisions

- **D1 (Open Question #1 from product spec — resolved in C4 D3 + architecture
  Open Q #3): install target is `~/.local/bin/codans`, never `/usr/local/bin`.**
  T3 inherits this decision without introducing admin-priv prompts. If the
  directory is missing it is created (`0755`, standard). No shell-rc
  PATH editing is performed in T3 — if `~/.local/bin` is not on `$PATH`, the
  status UI shows an amber "Installed, but not on `$PATH`" affordance with a
  one-sentence hint (`export PATH="$HOME/.local/bin:$PATH"`). This keeps T3
  out of rc-file editing, which is the riskiest hunk of the C4 M8 installer
  and better owned by a dedicated wave. **Confirm or override this
  inheritance before I leave Design.** If master wants admin-priv
  `/usr/local/bin`, I redo the risk/test plan.
- **D2 — Shared helpers live in `CodansCore`.** A new
  `CodansCore/CLI/CLIBundleLocator.swift` sits alongside
  `SkillBundleLocator` for app-bundle resolution of the built `codans`. This lets
  the unit test harness fake the bundle path without a synthesized .app.
- **D3 — `CLIInstallerClient` lives in the app target** (not CodansKit), because
  it is only invoked from SwiftUI, never from the `codans` binary itself.
  Placement: `apps/mac/codans/App/Clients/CLIInstallerClient.swift`,
  parallel to `EditorClient.swift` / `InboxClient.swift`.
- **D4 — Dependency injection through `@Environment`, not through
  `SettingsWindowView`'s constructor.** The T1-frozen switch does already
  pass `settingsStore:` to `SettingsGeneralView`, but I want to minimise
  shell-level churn so T2 and T4 do not race the same file. `DeveloperSettingsView`
  reads:
  - `@Environment(SettingsStore.self) private var settingsStore`
  - `@Environment(DeveloperPaneDependencies.self) private var deps`
  where `DeveloperPaneDependencies` is a small `@Observable final class`
  carrying the hook-config loader closure and the CLIInstallerClient. The
  Settings scene body (`CodansApp.body` inside `Window("Settings", ...)`)
  installs them via `.environment(...)`; one line per injection, zero
  changes to `SettingsWindowView.swift`'s detail switch.
- **D5 — Hook list is read-on-demand.** `HookConfigStore` is not
  `@Observable`; no T3 mutation. On pane `.task {}` the view calls
  `deps.loadHookConfig()`, assigns to `@State` `subscriptions`, and exposes
  a "Reload" affordance alongside "Reveal hooks.json in Finder". This is
  consistent with the spec's only-out edit entry being the JSON file.
- **D6 — Version line and "Copy app version" both use
  `AppState.bundleVersion()`** (already the one surfaced by
  `SkillVersionBanner`). The clipboard string is
  `"<short> (Build <build>)"`, matching spec Acceptance Criteria's example
  "`0.x.y (Build N)`".

## Design

### Overview

```
┌─ DeveloperSettingsView ────────────────────────────────────────────┐
│  ┌─ codans CLI section (M6.1) ────────────────────────────────────────┐ │
│  │  CLIInstallStatusCard(viewModel: CLIInstallViewModel)         │ │
│  │   — status pill, Install/Uninstall/Retry, error disclosure    │ │
│  └────────────────────────────────────────────────────────────────┘ │
│  ┌─ Hooks section (M6.2) ─────────────────────────────────────────┐ │
│  │  HookMergeView(rows: […HookRow], trailingAction: RevealHooks) │ │
│  │   — reusable; T4 feeds merged Global+Repository rows in       │ │
│  └────────────────────────────────────────────────────────────────┘ │
│  ┌─ Diagnostics section (M6.3) ───────────────────────────────────┐ │
│  │  [Reveal settings.json] [Reveal hooks.json] [Copy app version]│ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘

  Dependencies injected via @Environment:
    SettingsStore           (T1 contract, already in env for main window)
    DeveloperPaneDependencies  (new; see §API — Dependency container)
```

### API — Data types and view-model

#### `DeveloperPaneDependencies` (app target, new)

```swift
@MainActor @Observable
final class DeveloperPaneDependencies {
  let installer: CLIInstallerClient
  /// Loads the user hook configuration on demand. Returns an empty config if
  /// the file is missing or the store failed to initialise (test / early-boot).
  /// Running on the caller actor; HookConfigStore is @MainActor-bound.
  let loadHookConfig: @MainActor () -> HookConfig
  /// Reveals a file in Finder. Injected for unit/UI test substitution.
  let revealInFinder: @MainActor (URL) -> Void
  /// Copies a string to the general pasteboard. Injected for tests.
  let copyToPasteboard: @MainActor (String) -> Void
  /// Bundle version string, preserving the `AppState.bundleVersion()` source.
  let bundleVersion: @MainActor () -> BundleVersion

  init(...)
}

struct BundleVersion: Equatable {
  var short: String   // CFBundleShortVersionString, e.g. "0.3.0"
  var build: String   // CFBundleVersion, e.g. "1"
  var display: String { build.isEmpty ? short : "\(short) (Build \(build))" }
}
```

Wired up in `AppState.bringUp()` after `startIPC()` so the (potentially nil)
`hookConfigStore` is captured into the closure; in headless tests the pane
is constructed with a hand-rolled `DeveloperPaneDependencies` and never
touches the real filesystem.

#### `CLIInstallerClient` — sudo-free, Home-scoped (new)

```swift
@MainActor
final class CLIInstallerClient {
  struct Paths {
    var localBin: URL           // default ~/.local/bin
    var tcSymlink: URL          // default ~/.local/bin/codans
    var tcodeSymlink: URL       // default ~/.local/bin/tcode
    var bundledTcBinary: URL    // resolved via CLIBundleLocator
    static let `default`: Paths
  }

  enum InstallStatus: Equatable {
    case unknown                      // probing
    case notInstalled                 // neither symlink exists (or exists but points elsewhere)
    case installed(at: URL, pointsToBundle: Bool)
    case collision(owner: URL)        // codans on PATH in a non-codans location
    case failed(CLIInstallError, lastAttempt: Date?)
  }

  enum CLIInstallError: Error, Equatable {
    case bundleMissing(URL)
    case directoryCreateFailed(URL, underlyingDescription: String)
    case destinationExistsNotOurs(URL)            // symlink target != bundledTcBinary
    case destinationOutsideHome(URL)              // HomeScopeGuard rejected
    case symlinkFailed(URL, underlyingDescription: String)
    case uninstallFailed(URL, underlyingDescription: String)
    case pathNotOnSearchPath(checked: [URL])       // soft — not a hard install failure
  }

  init(paths: Paths = .default,
       fileSystem: SkillFileSystem = RealSkillFileSystem(),
       pathLookup: @escaping () -> [URL] = CLIInstallerClient.defaultPathEntries)

  /// Returns the current status without mutating the filesystem. Never throws —
  /// maps every failure into `.failed`. Safe to call at view-appear.
  func probe() -> InstallStatus

  /// Creates `~/.local/bin` if missing, symlinks codans + tcode. Idempotent — returns
  /// `.installed(...)` if links already point at our bundle. Updates the
  /// mutated `lastInstallAttemptAt` passthrough closure so the caller can
  /// persist through `SettingsStore.mutateDeveloper`.
  func install() -> Result<InstallStatus, CLIInstallError>

  /// Removes codans + tcode symlinks if and only if they point at our bundle.
  /// Returns `.notInstalled` on success; refuses to delete foreign files.
  func uninstall() -> Result<InstallStatus, CLIInstallError>
}
```

Contract rules:

- All filesystem mutation goes through `SkillFileSystem` (already used by
  `SkillInstaller`); no `FileManager` singletons directly. Enables unit tests
  against a tmp directory.
- Home-scope enforcement reuses `HomeScopeGuard.isInsideHome(_:)` to
  guarantee no symlink is written outside `$HOME`.
- **"Foreign file at `~/.local/bin/codans`"** is treated as `collision`, not
  `installed`. We never overwrite a file we did not create. Uninstall on
  collision is a no-op; install on collision refuses unless user confirms
  (a confirmation alert fires from the view layer; the client returns
  `.destinationExistsNotOurs` and the view decides whether to retry). **v1
  picks "refuse silently"** — the error line shows "Another `codans` exists at
  /opt/homebrew/bin/codans; rename it or run `codans install-cli --force-tc` from
  the CLI". Aligns with C4's `--force-tc` flag (deferred from T3).

#### `CLIInstallViewModel` — view-model bound to the pane (new)

Thin `@Observable @MainActor` class — holds the `InstallStatus` + last error,
exposes `install()` / `uninstall()` async methods that run on MainActor,
and calls through to `SettingsStore.mutateDeveloper { $0.cli.lastInstallAttemptAt = .now }`
on every attempt.

#### `HookMergeView` — **public / frozen API for T4 reuse**

Location: `apps/mac/codans/App/Features/Settings/Panes/HookMergeView.swift`.

```swift
/// One row in the Hooks list. Immutable value type; pane owners compose it from
/// `HookSubscription` plus a source label. Frozen contract — T4 feeds both
/// Global and Repository-sourced subscriptions into this shape.
public struct HookRow: Identifiable, Hashable, Sendable {
  public let id: UUID                 // HookSubscription.id
  public let displayName: String      // e.g. short command or derived label
  public let eventLabel: String       // HookEvent.rawValue or short form
  public let matchSummary: String?    // nil == "no match filter"
  public let enabled: Bool            // == !subscription.disabled
  public let source: HookSource       // see below
  public init(id: UUID,
              displayName: String,
              eventLabel: String,
              matchSummary: String?,
              enabled: Bool,
              source: HookSource)
}

public enum HookSource: Hashable, Sendable {
  case global
  /// Used by T4 only; T3 only produces `.global`.
  case repository
}

/// Read-only list renderer. Owners construct HookRow values by any mapping
/// rule they like — the view does not know about `HookSubscription` or
/// `HookConfig`. Keeps the T3 and T4 consumers decoupled from each other.
public struct HookMergeView: View {
  public init(
    rows: [HookRow],
    emptyStateTitle: String = "No hooks configured.",
    emptyStateMessage: String? = nil,
    showsSourceTag: Bool = false,          // T3 passes false (single-source)
    trailingAction: TrailingAction? = nil  // e.g. "Reveal hooks.json"
  )
}

public struct TrailingAction: Equatable {
  public let title: String
  public let systemImage: String?
  public let handler: @MainActor () -> Void
  public init(title: String, systemImage: String? = nil,
              handler: @escaping @MainActor () -> Void)
}

/// Helper — shared mapping rule. Both T3 and T4 use this so "Hook X looks the
/// same everywhere". Keeps the display-derivation rule in one place.
public enum HookRowBuilder {
  public static func make(from subscription: HookSubscription,
                          source: HookSource) -> HookRow
}
```

`HookRowBuilder.make(from:source:)` derivation:

- `displayName`: if `command.count <= 60` → `command`; else
  `String(command.prefix(57)) + "…"`. Monospaced in the view.
- `eventLabel`: `HookEvent.rawValue` (matches what users type in `hooks.json`).
- `matchSummary`: truncated `matchPattern` if set; else `"scope: <Scope kind>"`
  when `scope != .anyPanel`; else nil.
- `enabled`: `!subscription.disabled` (matches the inversion rule documented
  on `HookSubscription.disabled`).

The `showsSourceTag` flag is what lets T4 flip the "Global / Repository"
column on without a new component. T3 passes `false`; T4 passes `true` and
builds rows from both sources.

**Freeze note.** Once this doc is APPROVEd, the `HookMergeView`, `HookRow`,
`HookSource`, `TrailingAction` symbols above become a frozen contract — T3's
PR lands them verbatim, T4's PR consumes them without modification. Any
change flows back through master.

### Component layout (final tree after T3 lands)

```
apps/mac/codans/App/
├── Clients/
│   └── CLIInstallerClient.swift          (new)
└── Features/Settings/
    ├── DeveloperPaneDependencies.swift   (new — @Observable container)
    └── Panes/
        ├── DeveloperSettingsView.swift   (body replaced)
        ├── DeveloperSettingsSubviews/
        │   ├── CLIInstallStatusCard.swift
        │   └── DiagnosticsSection.swift
        └── HookMergeView.swift           (new — FROZEN API for T4)

apps/mac/CodansCore/CLI/
└── CLIBundleLocator.swift                (new — mirrors SkillBundleLocator)

apps/mac/codans/Tests/Developer/      (new directory)
├── CLIInstallerClientTests.swift
└── HookRowBuilderTests.swift
```

`CLIInstallerClient` stays in the app target for dependency direction: it
needs `@MainActor` + `SkillFileSystem` (already in CodansKit) but no AppKit
beyond the view layer's `NSWorkspace.activateFileViewerSelecting` /
`NSPasteboard`. The view layer owns those — the client doesn't.

### Data and state flow

```
Settings.developer.cli.lastInstallAttemptAt  (persisted)
        ▲
        │  mutateDeveloper { ... }
        │
CLIInstallViewModel ─── install() / uninstall()
        │
        ▼  Result<InstallStatus, CLIInstallError>
CLIInstallStatusCard    (SwiftUI — button state, error row)

HookConfigStore ──load()──▶ deps.loadHookConfig()
                               │ onAppear / onReload
                               ▼
                        DeveloperSettingsView.@State subscriptions
                               │
                               ▼  HookRowBuilder.make(…, source: .global)
                        HookMergeView
```

### Testing strategy

- **`CLIInstallerClientTests`** — new file under `apps/mac/codans/Tests/Developer/`.
  Fixture: a tmp directory standing in for `~`, a fake "bundled codans" file.
  Cases (one XCTestCase method each):
  1. `probe_freshFilesystem_returnsNotInstalled`
  2. `install_createsBothSymlinks_statusBecomesInstalled`
  3. `install_isIdempotent`
  4. `install_whenDestExistsAndIsForeign_returnsDestinationExistsNotOurs`
  5. `uninstall_whenInstalledByUs_removesBothAndReturnsNotInstalled`
  6. `uninstall_whenForeignPresent_refusesAndReturnsCollision`
  7. `install_failure_thenRetry_succeeds` — first call gets a failing FS
     injection, second call gets a real FS; asserts transition
     `notInstalled → failed → installed`.
  8. `install_insideTmpButOutsideHome_withEnforceHomeScope_returnsOutsideHome`
     (negative test — covers the HomeScopeGuard wire-up).
- **`HookRowBuilderTests`** — small, pure; no filesystem. One case per
  derivation branch (short command / long command / no matchPattern /
  scope-based summary / enabled-vs-disabled inversion).
- **Manual verification** — walk spec Acceptance Criteria "Developer 分段"
  (5 items) on a fresh `~/.config/codans/` install.
- `xcodebuild test -scheme codans` must remain green (T1 tests +
  new tests). `make lint` clean. `make format` clean.

### Security / safety

- All writes occur under `$HOME`; `HomeScopeGuard.isInsideHome(_:)` is the
  gatekeeper. No admin-priv code path.
- Symlinks are only ever deleted if they resolve to our own bundled binary.
  Foreign `codans` remains untouched.
- `~/.local/bin` is created with mode `0755` (via `FileManager.createDirectory`
  default); inherited. No sensitive data written by the installer.
- Pasteboard write for "Copy app version" carries only the version string;
  pasteboard overrides `.string` (type `.string`), not rich content.
- Reveal actions use `NSWorkspace.activateFileViewerSelecting(_:)`; the
  target URL is always a canonical `~/.config/codans/*.json` path.
  If the file does not exist, `HookConfig.defaultURL()` / `Settings.defaultURL()`
  helpers create the parent directory + empty file through the existing
  atomic-rename path (AtomicFileStore), matching spec Acceptance Criteria
  "点击 Reveal hooks.json 而本地尚无该文件，则创建一个默认空文件并在 Finder
  中显示它".

### Observability

- `Logger(subsystem: "com.gumpw.codans.ui", category: "settings-developer")` —
  one info log per install / uninstall attempt (outcome only, no paths
  beyond the install-root `~/.local/bin/codans`).
- No telemetry / network access.

### Rollback

- New files only; no schema migration. Reverting T3's PR drops the pane back
  to the T1 placeholder. `DeveloperSettings.cli.lastInstallAttemptAt` is
  already in v2; removing T3's writes to it leaves the field untouched.

## Risks

- **R1: Bundled `codans` binary is not where we think it is.** Tuist's
  `commandLineTool`-as-dependency placement inside the `.app` is not
  asserted today. CLIBundleLocator mirrors SkillBundleLocator's 3-phase
  resolution (env var → `Bundle.main.resourceURL`/`Contents/MacOS` sibling
  → dev repo walk). If all three miss, `install()` fails loudly with
  `.bundleMissing(URL)` — the card shows a plain-English error and the
  Install button stays enabled for retry.
- **R2: `~/.local/bin` not on `$PATH`.** Surfaced as an amber advisory
  under the status pill, not as a failure. v1 does not edit rc files.
- **R3: T4 needs a `HookMergeView` API shape we cannot predict.** The
  component is intentionally skinny: rows in, action out. T3 uses
  `source == .global` only; T4 flips `showsSourceTag = true` and
  supplies both sources. If T4 discovers the API is insufficient it
  escalates to master rather than fork.
- **R4: Hook snapshot goes stale.** Because `HookConfigStore` is not
  `@Observable`, an external edit to `hooks.json` is not reflected until
  the user hits "Reload" or re-enters the pane. Out of spec scope (the
  edit flow is explicitly Reveal+external). Noted in the UI affordance
  copy.
- **R5: @Environment injection not available in SwiftUI previews.** The
  pane's `#Preview` wraps a fake `DeveloperPaneDependencies` so previews
  stay live without AppState.

## Alternatives Considered

### A1. Install to `/usr/local/bin` with `osascript … with administrator privileges`

- Pros: Matches macOS platform tradition; `/usr/local/bin` is almost always
  on `$PATH` out of the box.
- Cons: Prompts an admin dialog; conflicts with C4 D3 + architecture Open Q
  #3; gets codans into SIP-adjacent territory; uninstall needs another
  prompt; CI / hermetic tests cannot exercise it. Worse fit for "ship now
  / low friction" and contradicts a decision already propagated into
  `docs/product-spec.md` and `docs/architecture.md`.
- Verdict: Rejected unless master explicitly overrides D1.

### A2. Pane reads `HookConfigStore` directly via `@Environment`

- Pros: One fewer indirection.
- Cons: `HookConfigStore` is `@MainActor final class` without `@Observable`
  — putting it in Environment gives us snapshot capture only. The closure
  wrapper in `DeveloperPaneDependencies` makes testability trivial (inject
  a fake loader, no AppState required) and keeps `HookConfigStore`'s
  existing public surface intact.
- Verdict: Rejected — small abstraction is worth the testability.

### A3. Push `CLIInstallerClient` into `CodansKit`

- Pros: Co-locates CLI code.
- Cons: CodansKit is linked into the `codans` binary itself. Shipping a SwiftUI-
  coupled service there would violate the dependency direction (CodansKit
  depends on CodansCore + CodansIPC + ArgumentParser only). Keep
  CodansKit pure; the installer is an app-side client.
- Verdict: Rejected.

### A4. Merge `HookMergeView` into a generic `SettingsReadonlyList`

- Pros: One less component.
- Cons: Hooks have structure (event + match + enabled) that does not
  generalise. Absorbing it into a "generic list" would force either an
  overly-wide API or downstream duplication.
- Verdict: Rejected.

## Open Questions

**Q1 — CLI install target.** Product spec Open Question #1 is still listed
open, but C4 D3 + architecture Open Q #3 already committed the project to
`~/.local/bin`. I'm proceeding with that inheritance (D1). **Confirm or
override** before I enter Plan. If you want `/usr/local/bin`, the install
story changes (admin prompt, uninstall prompt, test harness shape) and I'll
revise.

**Q2 — "Reload hooks" affordance placement.** Spec doesn't call for one,
but without it the pane goes stale across external JSON edits. My plan: a
small text "Reload" button next to "Reveal hooks.json in Finder". If you'd
rather rely on pane-reopen to refresh, drop me a note and I'll remove it.

**Q3 — Soft "not on $PATH" warning.** D1 proposes an amber advisory. If
you want strict success-or-failure semantics instead (fail the install if
PATH is not wired), I'll invert.

All other shape is inherited from T1 or C4; no new behavior beyond M6.
