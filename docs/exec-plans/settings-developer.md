# ExecPlan: Settings Window — Developer Pane (T3)

**Status:** Draft
**Author:** Gump (agent: feat/settings-developer)
**Date:** 2026-04-21
**Branch:** `feat/settings-developer` (off `feature/settings-base @ 6d4af57`)
**PR target:** `feature/settings-base`

This is a living document. Update `Progress`, `Surprises & Discoveries`,
`Decision Log`, and `Outcomes & Retrospective` as steps land.

## Purpose

After this change the Developer section of the Settings window is fully
functional per product-spec M6:

- **M6.1 — `codans` CLI card.** Status pill (Not installed / Installed /
  Failed / Collision). Install / Uninstall / Retry buttons. Errors
  surface inline with an actionable message. Installation lives at
  `~/.local/bin/codans` + peer `~/.local/bin/tcode` symlink — sudo-free,
  HomeScopeGuard-fenced, idempotent.
- **M6.2 — Hooks list (read-only).** Renders the user's `hooks.json`
  subscriptions through the frozen `HookMergeView` component (one row
  per subscription, tagged `Global` in T3's single-source view; T4 will
  flip on `showsSourceTag` to render merged Global + Repository rows).
  Trailing "Reveal hooks.json in Finder" action + "Reload from hooks.json"
  button for external-edit refresh.
- **M6.3 — Diagnostics.** Three actions: Reveal settings.json / Reveal
  hooks.json / Copy app version.

**T4 unblock.** Step 1 lands `HookMergeView`, `HookRow`, `HookSource`,
`TrailingAction`, `HookRowBuilder` as a *pure additive* commit so T4 can
rebase on that commit immediately and start composing its Repository
Hooks pane without waiting for T3 to finish.

## Progress

- [ ] Step 0 — Pre-flight: `make generate`, baseline `xcodebuild test`,
      baseline `make lint` (no commit).
- [ ] Step 1 — **HookMergeView + contract types + HookRowBuilderTests**
      (pure additive — unblocks T4). One `/commit`.
- [ ] Step 2 — **CLIBundleLocator + CLIInstallerClient + CLIInstallerClientTests**
      (new files only — no UI integration yet). One `/commit`.
- [ ] Step 3 — **DeveloperPaneDependencies + DeveloperSettingsView body
      replacement + CLIInstallStatusCard + DiagnosticsSection + scene-level
      `.environment(...)` wiring in `CodansApp.swift`**. One `/commit`.
- [ ] Step 4 — Polish: Hooks Reload button, PATH amber advisory, copy
      edits, manual QA fixups (commit only if a QA finding needs fixing).
- [ ] Step 5 — Final: push + `gh pr create --base feature/settings-base`.

Master constraint (restated for the implementer):
> commit 排序必须让 T4 能尽早 rebase 上 HookMergeView —— Step 1 最先落，单独
> 成步；后续 Step 2/3/4 不再触碰 Step 1 新增的符号。

## Surprises & Discoveries

_(to be filled in as the plan runs)_

## Decision Log

_(to be filled in — Step 0 baselines, deviations from Plan, etc.)_

## Outcomes & Retrospective

_(to be filled in at Final)_

## Context and Orientation

Related documents:

- Product spec: `docs/product-specs/ui-settings-window.md` (§M6, §Acceptance Criteria — Developer)
- Design doc (T3): `docs/design-docs/settings-developer.md` — decisions D1–D6
- Design doc (T1 shell): `docs/design-docs/settings-base.md` — frozen contracts
- CLI install decision: `docs/design-docs/c4-cli.md` §D3 + `docs/architecture.md` Open Q #3
- Golden rules: rules 2 (validate boundaries), 3 (shared utilities), 8 (small commits)

### Files T3 touches

**New files (created by this plan):**

- `apps/mac/CodansCore/CLI/CLIBundleLocator.swift` — 3-phase resolver for the bundled `codans` binary.
- `apps/mac/codans/App/Clients/CLIInstallerClient.swift` — sudo-free installer.
- `apps/mac/codans/App/Features/Settings/DeveloperPaneDependencies.swift` — `@Observable` DI container.
- `apps/mac/codans/App/Features/Settings/Panes/HookMergeView.swift` — **FROZEN API for T4**.
- `apps/mac/codans/App/Features/Settings/Panes/DeveloperSettingsSubviews/CLIInstallStatusCard.swift`
- `apps/mac/codans/App/Features/Settings/Panes/DeveloperSettingsSubviews/DiagnosticsSection.swift`
- `apps/mac/codans/Tests/Developer/CLIInstallerClientTests.swift`
- `apps/mac/codans/Tests/Developer/HookRowBuilderTests.swift`

**Modified files:**

- `apps/mac/codans/App/Features/Settings/Panes/DeveloperSettingsView.swift` — body replaced (signature unchanged).
- `apps/mac/codans/App/CodansApp.swift` — one-line `.environment(...)` on the Settings `Window` scene; `AppState` exposes a lazily-built `DeveloperPaneDependencies`.

**Explicitly NOT touched:**

- `apps/mac/codans/App/Features/Settings/SettingsWindowView.swift` — detail switch is T1-frozen.
- `apps/mac/codans/App/Features/Settings/SettingsStore.swift` — public API unchanged.
- Any `CodansCore/Settings/*.swift` — schema unchanged (T3 reuses `DeveloperCLISettings.lastInstallAttemptAt` already in v2).
- Any `CodansCore/Hooks/*` or `apps/mac/codans/Hooks/HookConfigStore.swift` — consumed read-only.
- T2 / T4 pane bodies (Notifications / RepositoryGeneral / RepositoryHooks).

### Terms of art

- **Frozen contract.** Symbols introduced in Step 1 (`HookMergeView`, `HookRow`,
  `HookSource`, `TrailingAction`, `HookRowBuilder`) are frozen from that commit
  forward — T4 consumes them verbatim. Any change goes through master.
- **Owned install.** A symlink at `~/.local/bin/codans` whose target resolves to
  the `codans` binary inside our running `.app` bundle (canonicalised). Anything
  else is *foreign*: the installer never writes over it and never deletes it.
- **HomeScopeGuard.** Existing `apps/mac/CodansKit/HomeScopeGuard.swift`, reused
  unchanged. Rejects any destination whose ancestor chain contains a symlink
  that escapes `$HOME`, including dangling ones.

## Plan of Work

Four code-bearing steps. The ordering is chosen to let T4 rebase on Step 1
the instant it lands.

### Step 0 — Pre-flight (no commit)

Run at `apps/mac/`:

```
make generate
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace codans.xcworkspace -scheme CodansCoreTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
make lint
make format   # should be a no-op on a freshly merged T1
```

Expected: all `** TEST SUCCEEDED **`, `make lint` clean, `make format`
idempotent. Record outputs in `Decision Log` so any later failure can be
attributed to T3 rather than a pre-existing issue.

Also verify `CodansCore/CLI/` is recursed by Tuist's
`buildableFolders: ["CodansCore", "CodansCore/Hooks"]` — T1 already
proved recursion empirically in its ExecPlan Step 0 (see
`docs/exec-plans/settings-base.md`). A drop of `CodansCore/CLI/_probe.swift`
containing `// probe`, `make generate`, and `grep _probe apps/mac/codans.xcodeproj/project.pbxproj`
confirms. Delete the probe. If it does **not** pick up, add
`"CodansCore/CLI"` to the `CodansCore` target's `buildableFolders` and
land the `chore(mac): declare CodansCore/CLI as a buildable folder`
commit before Step 1.

### Step 1 — HookMergeView + contract types (pure additive; unblocks T4)

Single `/commit`. The only code this step lands is *new files*; no existing
file changes.

New files:

- `apps/mac/codans/App/Features/Settings/Panes/HookMergeView.swift` —

  ```swift
  import SwiftUI
  import CodansCore

  public struct HookRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let displayName: String
    public let eventLabel: String
    public let matchSummary: String?
    public let enabled: Bool
    public let source: HookSource

    public init(id: UUID, displayName: String, eventLabel: String,
                matchSummary: String?, enabled: Bool, source: HookSource)
  }

  public enum HookSource: String, Hashable, Sendable {
    case global
    case repository
  }

  public struct TrailingAction: Equatable {
    public let title: String
    public let systemImage: String?
    public let handler: @MainActor () -> Void
    public init(title: String, systemImage: String? = nil,
                handler: @escaping @MainActor () -> Void)

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.title == rhs.title && lhs.systemImage == rhs.systemImage
    }
  }

  public struct HookMergeView: View {
    public init(rows: [HookRow],
                emptyStateTitle: String = "No hooks configured.",
                emptyStateMessage: String? = nil,
                showsSourceTag: Bool = false,
                trailingAction: TrailingAction? = nil)

    public var body: some View { /* list + empty-state + trailing action */ }
  }

  public enum HookRowBuilder {
    public static func make(from subscription: HookSubscription,
                            source: HookSource) -> HookRow
  }
  ```

  Derivation inside `HookRowBuilder.make(from:source:)` (exact rules —
  frozen):

  - `displayName`: if `command.count <= 60` → `command`; else
    `String(command.prefix(57)) + "…"`. Rendered monospaced by the row view.
  - `eventLabel`: `subscription.event.rawValue`.
  - `matchSummary`:
    1. If `matchPattern` is set and non-empty → truncated pattern
       (`prefix(80)` + "…" if longer).
    2. Else if `scope != .anyPanel` → `"scope: <kind>"` where `<kind>` is
       a short label for the Scope case (e.g. `panelLabel`, `worktreePathGlob`).
    3. Else `nil`.
  - `enabled`: `!subscription.disabled` (matches the inversion documented
    on `HookSubscription.disabled`).
  - `id`: `subscription.id`.

  Row view structure:

  - `HStack` with a leading status dot (`Circle`, `.green` when enabled,
    `.secondary` when disabled) + `VStack(alignment: .leading)` stacking
    `displayName` (monospaced body) and a caption combining `eventLabel`
    and `matchSummary` (dim). Trailing Source pill (`Text("Global")` /
    `Text("Repository")`) rendered only when `showsSourceTag == true`.
  - `trailingAction`, when non-nil, appears under the list as a
    `Button(Label(title, systemImage))`.
  - Empty state shows `emptyStateTitle` + optional `emptyStateMessage`
    in a centred VStack (`.secondary` foreground).

- `apps/mac/codans/Tests/Developer/HookRowBuilderTests.swift` — unit
  tests, pure + hermetic:

  1. `buildsShortCommandDisplayNameVerbatim` — subscription with a 40-char
     command → `HookRow.displayName == subscription.command`.
  2. `truncatesLongCommandWithEllipsis` — 100-char command →
     `displayName.count == 58` (57 chars + `…`).
  3. `prefersMatchPatternSummary` — `matchPattern: "error.*"` →
     `matchSummary == "error.*"`.
  4. `fallsBackToScopeSummary` — no `matchPattern`, `scope ==
     .panelLabel("x")` → `matchSummary == "scope: panelLabel"`.
  5. `nilSummaryWhenNoMatchAndAnyPanel` — no `matchPattern`, `scope ==
     .anyPanel` → `matchSummary == nil`.
  6. `enabledInvertsDisabledFlag` — `disabled: true` → `enabled: false`;
     `disabled: false` → `enabled: true`.
  7. `sourceIsPropagated` — builder respects the caller's `source`.

Commit message: `feat(settings): add HookMergeView reusable component for T3/T4`.

**Verification for Step 1.**

```
make -C apps/mac generate
xcodebuild -workspace apps/mac/codans.xcworkspace -scheme codans \
  -configuration Debug build -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace apps/mac/codans.xcworkspace -scheme codans \
  -configuration Debug test -destination 'platform=macOS' \
  -only-testing:codansTests/HookRowBuilderTests | xcbeautify
make -C apps/mac lint
```

Expect `** BUILD SUCCEEDED **`, the seven `HookRowBuilderTests` pass, lint
clean. At this point master can signal T4 to rebase on this commit.

### Step 2 — CLIBundleLocator + CLIInstallerClient + tests

Single `/commit`. New files only; no UI integration yet.

New files:

- `apps/mac/CodansCore/CLI/CLIBundleLocator.swift`:

  ```swift
  import Foundation

  /// Resolves the app-bundled `codans` binary's URL, mirroring
  /// SkillBundleLocator's 3-phase discovery.
  public enum CLIBundleLocator {
    public enum LocatorError: Error, Equatable {
      case binaryNotFound
    }

    public enum EnvKey {
      public static let binary = "CODANS_CLI_BINARY"   // dev override
    }

    public static func locateBinary(
      executableURL: URL? = Bundle.main.executableURL,
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL
  }
  ```

  Resolution order:
  1. `$CODANS_CLI_BINARY` if set and pointing at an existing file.
  2. `<Bundle.main.executableURL>.deletingLastPathComponent().appendingPathComponent("codans")`
     — sibling inside `Contents/MacOS/`. This is Tuist's default placement
     when an `.app` depends on a `commandLineTool` target.
  3. Repo walk from the current executable upward, searching
     `<ancestor>/.build/**/codans` — dev runs via `xcodebuild`/`swift build`.
     Reuses the same 12-level walk as `SkillBundleLocator.repoWalk`.

- `apps/mac/codans/App/Clients/CLIInstallerClient.swift` — shape exactly
  per design doc §`CLIInstallerClient`. Highlights:

  - `@MainActor final class CLIInstallerClient`.
  - Paths struct with `localBin` / `tcSymlink` / `tcodeSymlink` /
    `bundledTcBinary`. `Paths.default` resolves home + calls
    `CLIBundleLocator.locateBinary()`; propagates binary-missing through
    `.failed` in `probe()` rather than throwing at init.
  - All mutation through the existing `SkillFileSystem` protocol (from
    `apps/mac/CodansKit/SkillInstaller.swift`). `RealSkillFileSystem` is the
    default; tests inject an in-memory fake or a tmp-rooted real one.
  - **HomeScopeGuard at every mutating path.** `install`, `uninstall`,
    *and* `probe` all run every candidate URL through
    `HomeScopeGuard.isInsideHome(_:fileSystem:homeDirectory:)`. The
    `homeDirectory:` parameter is parameterised so tests can aim it at a
    tmp dir. If probe detects a symlink whose target escapes `$HOME`, it
    returns `.failed(.destinationOutsideHome(url), lastAttempt: nil)`
    rather than silently reclassifying it as foreign.
  - Install algorithm:
    1. Verify `bundledTcBinary` exists (→ `.bundleMissing` otherwise).
    2. Validate each destination through `HomeScopeGuard`
       (→ `.destinationOutsideHome` on failure).
    3. `createDirectory(at: localBin, withIntermediateDirectories: true)`;
       map a throw to `.directoryCreateFailed`.
    4. For each of `tcSymlink` / `tcodeSymlink`:
       - If the link exists **and** `readLink` resolves to `bundledTcBinary.path`
         (canonicalised via `URL.standardizedFileURL.path`), keep it
         (idempotent).
       - If the link exists and resolves elsewhere → return
         `.destinationExistsNotOurs(url)`; do not delete or overwrite.
       - If no link (or a dangling one pointing at our bundled binary) →
         atomically rewrite: `unlink` (if dangling-ours) then
         `createSymbolicLink(at:withDestinationURL:)`. Errors map to
         `.symlinkFailed`.
    5. Return `.installed(at: tcSymlink, pointsToBundle: true)`.
  - Uninstall algorithm: for each of the two symlinks, if it exists and
    resolves to our bundled binary → `removeItem`; foreign links untouched.
    Return `.notInstalled` on success; `.uninstallFailed` on throw.
  - PATH-check helper `defaultPathEntries()` splits
    `ProcessInfo.processInfo.environment["PATH"]` on `:` and returns
    `[URL]`. `isLocalBinOnPath(paths: Paths, entries: [URL]) -> Bool`
    compares canonicalised paths. The pane renders the amber advisory
    when this returns `false` *and* status is `.installed`.

- `apps/mac/codans/Tests/Developer/CLIInstallerClientTests.swift` —
  all eight cases from the design doc's Testing strategy, each using a
  freshly-created `tmpDirectoryURL()` home + a stub `codans` binary:

  1. `probe_freshFilesystem_returnsNotInstalled`
  2. `install_createsBothSymlinks_statusBecomesInstalled`
  3. `install_isIdempotent` (install twice → same state, no error)
  4. `install_whenDestExistsAndIsForeign_returnsDestinationExistsNotOurs`
  5. `uninstall_whenInstalledByUs_removesBothAndReturnsNotInstalled`
  6. `uninstall_whenForeignPresent_refusesAndReturnsCollision`
     (foreign `codans`, calling `uninstall()` returns status
     `.collision(owner:)` and leaves the file in place)
  7. `install_failure_thenRetry_succeeds` — first call: inject a
     `SkillFileSystem` whose `createSymbolicLink` throws once; assert
     state `.failed`. Second call with a healthy FS: assert
     `.installed(..., pointsToBundle: true)`.
  8. `escape_attempt_is_rejected_by_HomeScopeGuard` — fake home at
     `/tmp/fakeHome`; create `fakeHome/.local` as a symlink pointing at
     `/tmp/outside`; `install()` returns `.destinationOutsideHome(url)`
     and no mutation is performed. Mirrors the pattern already used by
     `SkillInstallerTests`.

  Test helpers (in-file):

  - `makeTempHome() -> URL` creates a disposable dir + a stub `codans` file
    at `<tmp>/bundledTcBin/codans` with mode `0755`.
  - `installer(at home: URL, fs: SkillFileSystem = RealSkillFileSystem()) -> CLIInstallerClient`
    constructs the client with overridden paths and fs.

Commit message: `feat(settings): add CLIInstallerClient (HomeScopeGuard-fenced) + locator`.

**Verification for Step 2.**

```
make -C apps/mac generate
xcodebuild -workspace apps/mac/codans.xcworkspace -scheme codans \
  -configuration Debug test -destination 'platform=macOS' \
  -only-testing:codansTests/CLIInstallerClientTests | xcbeautify
# Full test matrix still green:
xcodebuild -workspace apps/mac/codans.xcworkspace -scheme codans \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace apps/mac/codans.xcworkspace -scheme CodansCoreTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
make -C apps/mac lint
```

Expect: eight `CLIInstallerClientTests` pass + prior suites green + lint
clean.

### Step 3 — DeveloperPaneDependencies + DeveloperSettingsView body + subviews + scene wiring

Single `/commit`. This is the step that makes the UI real.

New files:

- `apps/mac/codans/App/Features/Settings/DeveloperPaneDependencies.swift`:

  ```swift
  import Foundation
  import Observation
  import CodansCore

  @MainActor @Observable
  final class DeveloperPaneDependencies {
    let installer: CLIInstallerClient
    let loadHookConfig: @MainActor () -> HookConfig
    let revealInFinder: @MainActor (URL) -> Void
    let copyToPasteboard: @MainActor (String) -> Void
    let bundleVersion: @MainActor () -> BundleVersion

    init(installer: CLIInstallerClient,
         loadHookConfig: @escaping @MainActor () -> HookConfig,
         revealInFinder: @escaping @MainActor (URL) -> Void,
         copyToPasteboard: @escaping @MainActor (String) -> Void,
         bundleVersion: @escaping @MainActor () -> BundleVersion)
  }

  struct BundleVersion: Equatable, Sendable {
    var short: String
    var build: String
    var display: String {
      build.isEmpty ? short : "\(short) (Build \(build))"
    }
  }
  ```

  The production `revealInFinder` closure calls
  `NSWorkspace.shared.activateFileViewerSelecting([url])`; if `url` is
  missing, it creates the parent directory + an empty file via the
  existing `AtomicFileStore.write(_:to:)` path with an empty
  `Settings.default` (for settings.json) or `HookConfig.empty` (for
  hooks.json). This satisfies spec Acceptance Criteria "点击 Reveal
  hooks.json 而本地尚无该文件，则创建一个默认空文件并在 Finder 中显示它".

  Production `copyToPasteboard` runs
  `NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)`.

  Production `bundleVersion` reads `Bundle.main.infoDictionary?`'s
  `CFBundleShortVersionString` / `CFBundleVersion`, mirroring
  `AppState.bundleVersion()`.

- `apps/mac/codans/App/Features/Settings/Panes/DeveloperSettingsSubviews/CLIInstallStatusCard.swift`:

  Encapsulates M6.1. Owns a `@State var status: CLIInstallerClient.InstallStatus = .unknown`,
  a `@State var lastError: CLIInstallerClient.CLIInstallError? = nil`, and a
  `@State var isBusy = false`. Renders:
  - Status pill using `HookSource`-style coloured `Circle` + label.
  - Primary button: `Install` (when `.notInstalled`), `Uninstall` (when
    `.installed`), `Retry` (when `.failed`).
  - Secondary button: `Open in Finder` showing `~/.local/bin/codans` (visible
    only when installed).
  - Error disclosure: expandable row showing `errorDescription`
    (`LocalizedError` conformance is added to `CLIInstallError` in the
    same file).
  - PATH amber advisory: when `status == .installed(..., pointsToBundle: true)`
    and `installer.isLocalBinOnPath(...) == false`, a label reading
    `"codans installed but ~/.local/bin is not on PATH. Add it to your
    shell profile to run \`codans\` directly."` in `.orange`/`.secondary`
    (matches the rest of the pane's caption styling).
  - On `.task`: `status = installer.probe()` (synchronous; never throws).
  - On Install button: set `isBusy`, call `installer.install()`, update
    `status`, unpack `lastError`, and call
    `settingsStore.mutateDeveloper { $0.cli.lastInstallAttemptAt = .now }`
    regardless of outcome (design D6 + SettingsStore single-writer
    invariant).
  - On Uninstall: symmetric to Install.

- `apps/mac/codans/App/Features/Settings/Panes/DeveloperSettingsSubviews/DiagnosticsSection.swift`:

  Three `Button`s (Reveal settings.json / Reveal hooks.json / Copy app
  version) arranged horizontally with `.buttonStyle(.bordered)`. Each
  invokes `deps.revealInFinder(...)` or `deps.copyToPasteboard(...)`.
  Below the buttons, a small caption `Text(deps.bundleVersion().display)`
  in `.caption` + `.secondary` so the user can see what will be copied.

Replaced file:

- `apps/mac/codans/App/Features/Settings/Panes/DeveloperSettingsView.swift` —
  type name, accessibility, and `#Preview` target are preserved:

  ```swift
  struct DeveloperSettingsView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(DeveloperPaneDependencies.self) private var deps

    @State private var subscriptions: [HookSubscription] = []
    @State private var hookLoadError: Error?

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          cliSection          // -> CLIInstallStatusCard(deps.installer, settingsStore)
          hooksSection        // -> HookMergeView(rows: rows, trailingAction: ...)
          diagnosticsSection  // -> DiagnosticsSection(deps:)
        }
        .padding(24)
      }
      .task { reloadHooks() }
    }

    private var hooksSection: some View { /* … */ }
    private func reloadHooks() { /* calls deps.loadHookConfig() */ }
  }

  #Preview {
    DeveloperSettingsView()
      .environment(SettingsStore.preview)    // if preview helper exists; else construct
      .environment(DeveloperPaneDependencies.preview)
      .frame(width: 640, height: 640)
  }
  ```

  `reloadHooks`:
  - Call `deps.loadHookConfig()` on `.task` / when Reload button pressed.
  - On success: `subscriptions = config.subscriptions`; `hookLoadError = nil`.
  - On failure: `hookLoadError = e` but **retain** the previous
    `subscriptions`; the view shows an inline error row under the list
    (spec requirement per master reminder #5).
  - Build `[HookRow]` via `HookRowBuilder.make(from: sub, source: .global)`.
  - Pass to `HookMergeView(rows: rows, showsSourceTag: false,
    trailingAction: TrailingAction(title: "Reveal hooks.json", systemImage: "folder") { deps.revealInFinder(HookConfig.defaultURL()) })`.
  - A sibling Reload button (`Label("Reload from hooks.json", systemImage: "arrow.clockwise")`)
    sits above the list; pressing it calls `reloadHooks()`.

Modified files:

- `apps/mac/codans/App/CodansApp.swift`:

  - Add a lazy `developerPaneDependencies` to `AppState`, built after
    `bringUp()` / `startIPC()` so `hookConfigStore` is available. Declare
    as:

    ```swift
    private(set) var developerPaneDependencies: DeveloperPaneDependencies?
    ```

    and assemble inside `bringUp()`'s tail, using
    `[weak self]`-captured closures:

    ```swift
    self.developerPaneDependencies = DeveloperPaneDependencies(
      installer: CLIInstallerClient(),
      loadHookConfig: { [weak self] in
        (try? self?.hookConfigStore?.load()) ?? .empty
      },
      revealInFinder: { url in Self.revealInFinder(url) },
      copyToPasteboard: { Self.copy($0) },
      bundleVersion: { Self.bundleVersion() }
    )
    ```

    `Self.revealInFinder` / `Self.copy` / `bundleVersion` are tiny static
    helpers co-located in the file. `revealInFinder` honours the
    "create empty file + parent dir if missing" requirement for the two
    JSON paths by matching on `HookConfig.defaultURL()` /
    `Settings.defaultURL()` and delegating to `AtomicFileStore` when
    absent.

  - One-line `.environment(...)` on the Settings `Window` scene body:

    ```swift
    Window("Settings", id: CodansApp.settingsWindowID) {
      if let store = appState.settingsWindowStore,
         let deps = appState.developerPaneDependencies {
        SettingsWindowView(store: store, settingsStore: appState.settingsStore)
          .environment(appState.hierarchyManager)
          .environment(appState.settingsStore)          // ADDED
          .environment(deps)                            // ADDED
      } else {
        ProgressView().frame(minWidth: 750, minHeight: 500)
      }
    }
    ```

    Two `.environment(...)` lines. **No touch** to the detail switch in
    `SettingsWindowView`.

Commit message: `feat(settings): deliver Developer pane (M6 — CLI, Hooks, Diagnostics)`.

**Verification for Step 3.**

Automated:

```
make -C apps/mac generate
xcodebuild -workspace apps/mac/codans.xcworkspace -scheme codans \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace apps/mac/codans.xcworkspace -scheme CodansCoreTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
make -C apps/mac lint
make -C apps/mac format   # idempotent no-op expected
```

Expect all schemes `** TEST SUCCEEDED **`, lint clean, format clean.

Manual QA (each item maps to spec Acceptance Criteria §Developer 5
bullets):

1. Launch the app, press `⌘,`, select Developer.
2. **M6.1.a** — Status pill initially reads **Not installed** with an
   `Install` button. Click Install. After ~100 ms the pill flips to
   **Installed** and the button becomes `Uninstall`. Verify
   `ls -l ~/.local/bin/codans ~/.local/bin/tcode` → both are symlinks,
   targets point at the live `.app`'s `Contents/MacOS/codans`.
3. **M6.1.b** — With Step 2 installed, click Uninstall. Pill returns to
   **Not installed**; `~/.local/bin/codans` and `tcode` disappear.
4. **M6.1.c** — Preseed a foreign file at `~/.local/bin/codans` (e.g.
   `echo '#!/bin/sh' > ~/.local/bin/codans`); reopen Developer; click
   Install. Card shows Collision error + retry button; no files
   clobbered. Remove the foreign file, click Retry → Installed.
5. **M6.2** — `hooks.json` empty: Hooks list shows the empty-state
   message + Reveal button. Seed a subscription:

   ```jsonc
   // ~/.config/codans/hooks.json
   {
     "version": 1,
     "subscriptions": [
       { "id": "<uuid>", "event": "pane.output", "command": "notify",
         "matchPattern": "error.*", "scope": { "kind": "anyPanel" } }
     ]
   }
   ```

   Click Reload → row appears: enabled green dot, display name
   `notify`, event `pane.output`, match summary `error.*`. Toggle
   `"disabled": true` in the file, Reload → dot greys out.
6. **M6.3** — Click Reveal settings.json → Finder highlights
   `~/.config/codans/settings.json`. Click Reveal hooks.json → same.
   Click Copy app version → `pbpaste` matches `<short> (Build <build>)`
   (e.g. `0.1.0 (Build 1)`).
7. **PATH advisory.** Ensure `~/.local/bin` is not on `$PATH` (a typical
   fresh Mac); after Install, the amber advisory caption appears
   under the status pill. Add `~/.local/bin` to PATH, relaunch the app,
   advisory disappears.
8. **`lastInstallAttemptAt` persists.** After an install, inspect
   `jq .developer.cli.lastInstallAttemptAt ~/.config/codans/settings.json`
   — the value is a recent ISO-8601 timestamp. Wait ≥ 600 ms after
   click so the 500 ms debounce flushes; alternatively quit the app to
   force `flushAllPersistedState()`.
9. **Reload error.** Corrupt `hooks.json` (`echo '{' >`), Reload →
   inline error row under the list; previously-loaded rows remain
   visible; no crash.

If any QA item fails, record it under Surprises & Discoveries, open a
Step 4 fix commit.

### Step 4 — QA polish (conditional; commit only on fix)

Manual QA follow-ups. If all Step 3 QA items passed, Step 4 is
no-op-plan-ends-here. Otherwise each finding gets its own `fix(settings):
…` commit; update Progress + Surprises & Discoveries.

Common expected finds:

- Amber advisory styling tweaks.
- Missing keyboard focus on the primary button.
- Hooks list empty-state wording polish.

### Step 5 — Final push + PR

Run the full acceptance gauntlet:

```
make -C apps/mac generate
xcodebuild -workspace apps/mac/codans.xcworkspace -scheme codans \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace apps/mac/codans.xcworkspace -scheme CodansCoreTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace apps/mac/codans.xcworkspace -scheme CodansKitTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace apps/mac/codans.xcworkspace -scheme tcTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
make -C apps/mac lint
make -C apps/mac format
```

Expect every scheme `** TEST SUCCEEDED **`, lint/format clean.

Then:

```
git push -u origin feat/settings-developer
gh pr create --base feature/settings-base \
  --title "feat(settings): Developer pane — codans CLI install, hooks view, diagnostics (T3)" \
  --body-file - <<'EOF'
## Summary

- Deliver the Developer section of the Settings window per product-spec
  M6.1 / M6.2 / M6.3.
- Add `CLIInstallerClient` — a sudo-free, HomeScopeGuard-fenced installer
  that symlinks `codans` + `tcode` into `~/.local/bin/`, idempotent, with a
  PATH advisory when `~/.local/bin` isn't exported.
- Publish the frozen `HookMergeView` component (`HookRow` / `HookSource`
  / `TrailingAction` / `HookRowBuilder`) for T3 (Global-only rendering)
  and T4 (Global + Repository merge) to share.
- Wire Developer-pane dependencies through a new `@Observable
  DeveloperPaneDependencies` injected at the Settings scene — zero
  changes to `SettingsWindowView`'s T1-frozen detail switch.

## Contracts

Design doc: `docs/design-docs/settings-developer.md`
ExecPlan:   `docs/exec-plans/settings-developer.md`
Frozen for T4: `HookMergeView`, `HookRow`, `HookSource`, `TrailingAction`,
`HookRowBuilder.make(from:source:)`.

## Test plan

- [x] `xcodebuild test` — codans / CodansCoreTests / CodansKitTests / tcTests
- [x] `make lint` + `make format` clean
- [x] Manual QA of spec Acceptance Criteria §Developer (5 bullets):
      Not installed → Install → Installed; Uninstall; Install failure +
      Retry; Reveal settings.json / hooks.json; Copy app version.
- [x] PATH amber advisory appears/disappears as expected.
- [x] `lastInstallAttemptAt` persists to `settings.json` after install.
- [x] Hooks Reload handles malformed JSON without wiping the UI.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
```

Send `PR_READY: <pr_url>` to master.

## Concrete Steps

Working directory: `apps/mac/`.

### Generate Tuist project

```
make generate
```

### Build the app (sanity)

```
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug build -destination 'platform=macOS' | xcbeautify
```

### Full test matrix

```
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace codans.xcworkspace -scheme CodansCoreTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace codans.xcworkspace -scheme CodansKitTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace codans.xcworkspace -scheme tcTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
```

### Run the app for manual QA

```
make run-app
```

### Seed foreign collision fixture (M6.1 collision test)

```
mkdir -p ~/.local/bin
printf '#!/bin/sh\necho foreign\n' > ~/.local/bin/codans
chmod +x ~/.local/bin/codans
# Then open Settings > Developer and attempt Install.
```

Restore afterwards: `rm ~/.local/bin/codans`.

## Validation and Acceptance

Each item maps to spec §Acceptance Criteria — Developer.

- **codans unavailable, then installed.** Fresh home (no `~/.local/bin/codans`).
  Open Settings → Developer. Pill: `Not installed`. Click Install. Pill:
  `Installed`. `readlink ~/.local/bin/codans` points into the running `.app`.
- **Uninstall round-trip.** Post-install, click Uninstall. Symlinks
  removed; pill flips back; a fresh Install works.
- **Collision safety.** Pre-seeded foreign `~/.local/bin/codans`. Install
  surfaces `Collision` without clobbering. Removing the foreign file +
  Retry installs normally.
- **`lastInstallAttemptAt` persisted.** `jq .developer.cli.lastInstallAttemptAt
  ~/.config/codans/settings.json` shows a recent ISO-8601 timestamp
  after any Install / Uninstall attempt.
- **Hooks list mirrors hooks.json.** With a seeded subscription, the
  row's event / displayName / matchSummary / enabled render according to
  `HookRowBuilder.make(from:source:)` rules.
- **Hooks reload on external edit.** Edit `hooks.json`, click Reload —
  list reflects the change. Corrupt the file, Reload — inline error +
  previously-loaded rows still visible.
- **Reveal entries.** Reveal settings.json / Reveal hooks.json each
  open Finder with the target file selected; if hooks.json is absent,
  an empty file is created at the canonical path before reveal.
- **Copy app version.** Clipboard carries `"<short> (Build <build>)"`
  after click; format matches the `AppState.bundleVersion()` source.
- **PATH advisory.** When `~/.local/bin` is not on `$PATH`, the amber
  advisory appears under the status pill post-install; adding the
  directory to `$PATH` (and relaunching) clears the advisory.

Test-matrix green:

```
all four xcodebuild test schemes → ** TEST SUCCEEDED **
make lint → clean
make format → idempotent
```

## Idempotence and Recovery

All step-level work is additive or a localised edit; `git reset --hard
HEAD~1` drops any step and returns to the T1 baseline. **No amends** —
NEW commits for every retry, per project CLAUDE.md.

Installer-level idempotence: running `install()` N times from `.installed`
returns `.installed` with no filesystem change. `uninstall()` from
`.notInstalled` returns `.notInstalled`. Foreign files are never
overwritten.

If `make generate` fails because `CodansCore/CLI` isn't picked up
(Step 0 pathological result), land the explicit `buildableFolders`
append **before** Step 1's content commit. Recovery is a forward-only
chore commit; nothing destructive.

## Artifacts and Notes

### Expected on-disk layout after Install

```
~/.local/bin/codans     → <path to running .app>/Contents/MacOS/codans       # symlink
~/.local/bin/tcode  → <path to running .app>/Contents/MacOS/codans       # symlink (peer)
~/.config/codans/settings.json
{
  "developer": { "cli": { "lastInstallAttemptAt": "2026-04-21T13:05:02Z" } },
  ...
}
```

### Example CLIInstallError surface strings (Step 3)

- `.bundleMissing(url)` → "`codans` binary not found in app bundle. Please
  reinstall codans."
- `.directoryCreateFailed(url, desc)` → "Could not create `\(url.path)`:
  `\(desc)`."
- `.destinationExistsNotOurs(url)` → "Another `codans` exists at
  `\(url.path)`. Rename it, then retry — codans will not overwrite
  a tool it didn't install."
- `.destinationOutsideHome(url)` → "Refusing to write outside your home
  directory: `\(url.path)`."
- `.symlinkFailed(url, desc)` → "Could not link `\(url.lastPathComponent)`:
  `\(desc)`."
- `.uninstallFailed(url, desc)` → "Could not remove `\(url.path)`:
  `\(desc)`."
- `.pathNotOnSearchPath(checked:)` → (amber advisory, not error)
  `"codans installed, but ~/.local/bin is not on PATH. Add
   `export PATH=\"$HOME/.local/bin:$PATH\"` to your shell profile."`

## Interfaces and Dependencies

Symbols whose shape is frozen the moment Step 1 lands (T4 depends on
these verbatim):

```swift
// apps/mac/codans/App/Features/Settings/Panes/HookMergeView.swift

public struct HookRow: Identifiable, Hashable, Sendable {
  public let id: UUID
  public let displayName: String
  public let eventLabel: String
  public let matchSummary: String?
  public let enabled: Bool
  public let source: HookSource
  public init(id: UUID, displayName: String, eventLabel: String,
              matchSummary: String?, enabled: Bool, source: HookSource)
}

public enum HookSource: String, Hashable, Sendable {
  case global, repository
}

public struct TrailingAction: Equatable {
  public let title: String
  public let systemImage: String?
  public let handler: @MainActor () -> Void
  public init(title: String, systemImage: String? = nil,
              handler: @escaping @MainActor () -> Void)
}

public struct HookMergeView: View {
  public init(rows: [HookRow],
              emptyStateTitle: String = "No hooks configured.",
              emptyStateMessage: String? = nil,
              showsSourceTag: Bool = false,
              trailingAction: TrailingAction? = nil)
}

public enum HookRowBuilder {
  public static func make(from subscription: HookSubscription,
                          source: HookSource) -> HookRow
}
```

Symbols introduced by T3 but T3-internal (not frozen for T4):

```swift
// apps/mac/CodansCore/CLI/CLIBundleLocator.swift
public enum CLIBundleLocator {
  public enum LocatorError: Error, Equatable { case binaryNotFound }
  public enum EnvKey { public static let binary: String }
  public static func locateBinary(executableURL: URL?,
                                  environment: [String: String]) throws -> URL
}

// apps/mac/codans/App/Clients/CLIInstallerClient.swift
@MainActor
final class CLIInstallerClient {
  struct Paths { /* see Step 2 */ }
  enum InstallStatus: Equatable { /* see design doc */ }
  enum CLIInstallError: Error, Equatable, LocalizedError { /* see design doc */ }
  init(paths: Paths = .default,
       fileSystem: SkillFileSystem = RealSkillFileSystem(),
       pathLookup: @escaping () -> [URL] = Self.defaultPathEntries)
  func probe() -> InstallStatus
  func install() -> Result<InstallStatus, CLIInstallError>
  func uninstall() -> Result<InstallStatus, CLIInstallError>
  func isLocalBinOnPath() -> Bool
}

// apps/mac/codans/App/Features/Settings/DeveloperPaneDependencies.swift
@MainActor @Observable
final class DeveloperPaneDependencies { /* see Step 3 */ }
struct BundleVersion: Equatable, Sendable { var short, build: String; var display: String }
```

External dependencies used (no additions):

- `SwiftUI` — `@Environment`, `NavigationSplitView`-embedded panes, `Button`,
  `Label`, `Menu`, `ScrollView`.
- `Observation` — `@Observable` on `DeveloperPaneDependencies`.
- `CodansCore` — `HookConfig`, `HookSubscription`, `Settings`,
  `ProjectID`, `AtomicFileStore`.
- `CodansKit` — `SkillFileSystem`, `RealSkillFileSystem`, `HomeScopeGuard`.
- `AppKit` — `NSWorkspace`, `NSPasteboard` (production-only, behind
  closures in `DeveloperPaneDependencies` so unit tests never reach them).

No new SPM packages; no Tuist dependency changes.
