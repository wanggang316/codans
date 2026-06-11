# ExecPlan: Settings Window — Shell & Persistence Base (T1)

**Status:** Completed
**Author:** Gump (agent: feat/settings-shell)
**Date:** 2026-04-21

This is a living document. The Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective sections must be kept up
to date as work proceeds.

## Purpose

After this change a user who runs codans can press `⌘,` (or pick
*Settings…* from the app menu) and see a standalone **Settings** window
with a six-item sidebar (General / Notifications / Developer / Shortcuts
/ Updates / About), a `Repositories` disclosure tree listing their open
projects, and a General pane that lets them change Appearance, pick a
Default editor, and manage Built-in / Custom editor entries. Closing
the main window does not close Settings; closing Settings clears
sidebar selection but preserves draft state; re-opening defaults to
General. Under the hood, `~/.config/codans/settings.json` has a
single writer (`SettingsStore`), exists at schema `version: 2`, and
auto-upgrades any existing v1 file (editor-only, notifications-only,
or combined) on first launch without user intervention — the v1 file
is preserved next to it as `settings.json.v1-<yyyyMMdd-HHmmss>`.

The other three parallel tasks (T2 Notifications, T3 Developer, T4
Repositories) can compile and start their work the moment Step 2 lands,
because Step 2 freezes the contract surfaces (`SettingsSection`,
`NotificationSettingsReader`, four placeholder pane views) without
changing any runtime behaviour.

## Progress

Each step is a single `/commit`. Steps 1–6 are code commits; steps 0
and 7 are environment / QA. Push happens only once, at the end,
before opening the PR against `feature/settings-base`.

- [x] Step 0 — Tuist buildableFolders verification (probes confirmed recursion — no commit)
- [x] Step 1a — Rename v1 Settings → LegacyEditorSettings (prep commit to free namespace)
- [x] Step 1 — Add `CodansCore/Settings/` v2 types + SettingsCodableTests
- [x] Step 2 — Add contract surfaces (enum / protocol / 4 placeholder panes / ComingSoonPane)
- [x] Step 3 — Migration scaffolding (LegacyV1Settings + SettingsMigration + SettingsMigrationTests)
- [x] Step 4 — SettingsStore v2 refactor + C6 coordinator rewire + delete NotificationSettingsStore
- [x] Step 5 — Settings Window scene + SettingsWindowFeature + General / About panes + menu
- [x] Step 6 — Remove SettingsSheet* + reroute showCustomEditorsSettings
- [x] Step 7 — Manual QA (see Outcomes below); style commit to land swift-format pass + lint fix
- [x] Final — test matrix green on four schemes; push + PR pending this last commit

## Surprises & Discoveries

- **Swift filename collision between v1 and v2 `Settings`.** Both structs had
  the public type name `Settings`; the v1 file `CodansCore/Editor/Settings.swift`
  couldn't coexist with a new `CodansCore/Settings/Settings.swift`.
  Compiler error was
  `filename "Settings.swift" used twice`. Resolved by renaming the v1 file
  to `LegacyEditorSettings.swift` + the type to `LegacyEditorSettings` in a
  dedicated prep commit (Step 1a) that preceded Step 1. The legacy name
  lives only until Step 4 deletes it.
- **Tuist `buildableFolders` IS recursive.** Xcode 16's
  `PBXFileSystemSynchronizedRootGroup` does not list individual source
  files in `project.pbxproj`, so the initial grep-based check looked
  like a miss. Empirical probe (add a deliberate compile-error file
  inside the subfolder, build the target, observe the error) confirmed
  recursion works for `CodansCore/`, `codans/App/Features/Settings/Panes/`,
  and `.../Sidebar/`. No `Project.swift` edit required.
- **GhosttyKit.xcframework had never been built in this worktree.** First
  `tuist generate` failed on a ghostty dependency-fetch HTTP 400. Copying
  the matching-fingerprint prebuilt framework from a sibling worktree
  (`feat/mw-gitviewer-shortcuts`) unblocked generation; no Zig build ran.
- **SettingsWindowPresenter could not close over `@Environment(\.openWindow)` directly** because
  `OpenWindowAction` is only valid inside a `View` with that environment. Solved by
  publishing `openSettingsWindowAction: (@MainActor () -> Void)?` on `AppState` from the
  main scene's `.task` block; the presenter's `open` closure captures AppState weakly and
  forwards through that stored action.
- **Toolbar ⌘, + CommandGroup ⌘, conflict.** The old gear-button
  `.keyboardShortcut(",", modifiers: [.command])` competed with the new
  `CommandGroup(replacing: .appSettings)` binding. Removed the
  per-button shortcut in Step 6; CommandGroup owns ⌘, now.

## Decision Log

- **Step 1a prep commit (2026-04-21).** Added an unplanned commit between
  Step 0 and Step 1 to resolve the `Settings` name collision (see
  Surprises). The prep commit renames v1 `Settings` → `LegacyEditorSettings`
  and updates 3 call sites (SettingsStore, EditorFeature, EditorFeatureTests).
  Step 1 proper added v2 Settings afterwards. Step 4 deletes `LegacyEditorSettings`
  as scheduled.
- **Step 6 removed the per-button ⌘, shortcut.** Plan didn't explicitly
  call this out; decision made on the spot because two competing bindings
  to the same chord would be non-deterministic.
- **Co-located `AuthorizationStatusCache` in `CodansCore/Settings/NotificationsSettings.swift`.**
  Plan stage placed it with the v2 NotificationsSettings struct (Step 1) rather than leaving
  it in the deleted `NotificationSettingsStore.swift`. No material difference; note for
  future readers looking for where C6 auth-status persistence lives.
- **Style commit landed after Step 7 instead of during Step 2 / Step 5.**
  `make check` flagged one accessibility-label lint violation + running
  `swift-format` touched 155 files (pure whitespace / line-wrap).
  Co-landed as a single style commit to keep prior feature commits
  diff-narrow.

## Outcomes & Retrospective

**Automated coverage — all green.** Four xcodebuild test schemes ran
locally: `codans`, `CodansCore`, `CodansKit`, `codans`. All four produced
`** TEST SUCCEEDED **`. New test coverage:

- `SettingsCodableTests` — 5 tests (default round-trip, minimal-JSON
  fallback, unparseable-repositories-key drop, unsupported-version
  rejection, UUID-keyed encode invariant).
- `SettingsMigrationTests` — 6 tests (fresh/missing-file, editor-only
  v1, notifications-only v1, combined v1, unsupported version, corrupt
  JSON, v2-passthrough no-backup guard).
- `SettingsStoreTests` (rewritten) — mutators, Appearance round-trip,
  RepositorySettings GC, Reader conformance, migration smoke.
- `SettingsWindowFeatureTests` — selection round-trip, windowClosed
  clears, effectiveSection fallback.
- `RootFeatureTests.headerShowCustomEditorsSettingsInvokesPresenter`
  replaces the deleted settings-sheet presentation test.

**Manual UI QA — partially covered.** Ground-truth click-through of the
spec Acceptance Criteria requires a human driver. Items
automation-cannot-cover (⌘, opens an independent window, Repositories
DisclosureGroup renders, Appearance round-trips across relaunch,
sidebar reflects catalog deltas in real time) depend on interactive
launch. The upgrade-compatibility scenario was partially automated via
`SettingsStoreTests.migratesV1EditorFileOnInit`; seed-fixture smoke was
staged in `/tmp/tctest-*` but not click-verified.

**M13 single-writer invariant achieved.** Only `SettingsStore` writes
`~/.config/codans/settings.json` now; `NotificationSettingsStore`
is deleted. Per-Repo catalog data (`Project.defaultEditor`,
`Project.worktreesDirectory`) remains in `catalog.json` per design D1.

**M14 migration verified.** V1 editor-only / notifications-only /
combined fixtures all migrate to v2 via `SettingsMigration.load`;
backup files land as `settings.json.v1-<ts>`. Covered by automated tests.

**Contracts frozen for T2/T3/T4.** `SettingsSection`, `Settings v2`,
`SettingsStore` mutate API, `NotificationSettingsReader`, and the four
placeholder pane views are in place. Downstream waves need only
replace pane view bodies and extend sub-structs — the detail switch
in `SettingsWindowView` is stable.

**Gaps / follow-ups.** Full GUI-driven QA of the spec Acceptance
Criteria was out of scope for this agent session — the user (Gump) or
a T5 review slot should drive an interactive walkthrough before the
Settings window is advertised to end users.

## Context and Orientation

Related documents:

- Product spec: `docs/product-specs/ui-settings-window.md`
- Design doc: `docs/design-docs/settings-base.md` (Approved,
  decisions D1 / D2 / D3)
- Architecture: `docs/architecture.md` — see Persistence + State
  Management sections; the "atomic-rename JSON with top-level
  `version: Int`" invariant governs both `settings.json` and
  `catalog.json`.
- Golden rules: `docs/golden-rules.md` — rules 2 (validate boundaries),
  3 (shared utilities), 8 (small commits) apply.

### Key source files the implementer will touch

Current (to be refactored or deleted):

- `apps/mac/codans/App/Features/Settings/SettingsStore.swift` —
  owner of v1 `Settings` (editor-only). Gets rewritten in Step 4.
- `apps/mac/codans/App/Features/Settings/SettingsSheetFeature.swift` —
  `.sheet`-presented reducer. Deleted in Step 6.
- `apps/mac/codans/App/Features/Settings/SettingsSheetView.swift` —
  Done-button chrome host. Deleted in Step 6.
- `apps/mac/codans/App/Features/Settings/SettingsEditorSection.swift` —
  today's editor UI. Contents lift to
  `Panes/SettingsGeneralView.swift` in Step 5; file deleted in Step 6.
- `apps/mac/codans/Notifications/NotificationSettingsStore.swift` —
  the second writer of `settings.json`. Deleted in Step 4 together
  with its `CodansSettings` / `NotificationsSettings` types (the
  latter is re-introduced in `CodansCore/Settings/` with a superset
  shape in Step 1).
- `apps/mac/codans/Notifications/NotificationCoordinator.swift` —
  reads/mutates settings. Rewired to
  `NotificationSettingsReader` + mutate closure in Step 4.
- `apps/mac/codans/Notifications/C6AppBootstrap.swift` — construction
  site for the coordinator. Signature changes in Step 4.
- `apps/mac/codans/App/Clients/InboxClient.swift` — one
  `muteRule` closure currently calls `NotificationSettingsStore.mutate`.
  Switched to `SettingsStore.mutateNotifications` in Step 4.
- `apps/mac/codans/App/Clients/EditorClient.swift` — reads
  `settings.defaultEditorID` / `settings.customEditors`. Updated to
  `settings.general.*` in Step 4.
- `apps/mac/codans/App/CodansApp.swift` — scene graph. Gains
  `Window(id: "settings")` + `CommandGroup(replacing: .appSettings)`
  in Step 5. Loses `notificationSettingsStore` field in Step 4.
- `apps/mac/codans/App/Features/Root/RootFeature.swift` — loses
  `settingsSheet` in Step 6; delegate `showCustomEditorsSettings`
  rerouted to the new `SettingsWindowPresenter`.
- `apps/mac/CodansCore/Editor/Settings.swift` — v1 `Settings`
  struct. Deleted in Step 4 once nothing references it; replaced by
  `CodansCore/Settings/Settings.swift` from Step 1.
- `apps/mac/Project.swift` — the Tuist project. Inspected in Step 0;
  amended only if buildableFolders turn out to be non-recursive.

New files introduced (paths final):

- `apps/mac/CodansCore/Settings/Settings.swift` — v2 root Codable
- `apps/mac/CodansCore/Settings/GeneralSettings.swift`
- `apps/mac/CodansCore/Settings/NotificationsSettings.swift`
- `apps/mac/CodansCore/Settings/DeveloperSettings.swift`
- `apps/mac/CodansCore/Settings/RepositorySettings.swift` (empty struct)
- `apps/mac/CodansCore/Settings/AppearancePreference.swift`
- `apps/mac/CodansCore/Settings/LegacyV1Settings.swift` (Step 3)
- `apps/mac/CodansCore/Settings/SettingsMigration.swift` (Step 3)
- `apps/mac/codans/App/Features/Settings/SettingsSection.swift`
- `apps/mac/codans/App/Features/Settings/NotificationSettingsReader.swift`
- `apps/mac/codans/App/Features/Settings/SettingsWindowFeature.swift`
- `apps/mac/codans/App/Features/Settings/SettingsWindowView.swift`
- `apps/mac/codans/App/Features/Settings/Sidebar/SettingsSidebarView.swift`
- `apps/mac/codans/App/Features/Settings/Panes/ComingSoonPane.swift`
- `apps/mac/codans/App/Features/Settings/Panes/SettingsGeneralView.swift`
- `apps/mac/codans/App/Features/Settings/Panes/AboutSettingsView.swift`
- `apps/mac/codans/App/Features/Settings/Panes/NotificationsSettingsView.swift`
  *(placeholder; T2 replaces body)*
- `apps/mac/codans/App/Features/Settings/Panes/DeveloperSettingsView.swift`
  *(placeholder; T3 replaces body)*
- `apps/mac/codans/App/Features/Settings/Panes/RepositoryGeneralSettingsView.swift`
  *(placeholder; T4 replaces body)*
- `apps/mac/codans/App/Features/Settings/Panes/RepositoryHooksSettingsView.swift`
  *(placeholder; T4 replaces body)*
- `apps/mac/codans/App/Clients/SettingsWindowPresenter.swift` —
  TCA dependency wrapping `EnvironmentValues.openWindow`
- `apps/mac/CodansCoreTests/SettingsCodableTests.swift`
- `apps/mac/CodansCoreTests/SettingsMigrationTests.swift`
- `apps/mac/codans/Tests/SettingsWindowFeatureTests.swift`

### Terms of art

- **Global section** / **Repository section** — sidebar row categories,
  defined in the product spec Vocabulary.
- **Contract surface** — a Swift file that T2/T3/T4 will import but
  not modify. The four placeholder pane views and the
  `SettingsSection` / `NotificationSettingsReader` declarations are the
  contract surfaces this plan freezes; downstream agents replace only
  the `body` of a placeholder view or fill the empty sub-structs with
  their section-specific fields.
- **Legacy v1 file** — `settings.json` written before this work, whose
  top-level `version` is `1` and which may populate any of
  `defaultEditorID`, `customEditors`, `notifications` (disjoint or
  combined, because today two stores race-write it).
- **Contract-freeze step** — Steps 1, 2, 3 above. These commits add
  new files without changing any runtime behaviour, so T2/T3/T4 can
  branch off `feat/settings-shell@<after-step-2>` immediately.
- **Tuist `buildableFolders`** — a property in `apps/mac/Project.swift`
  that lists the folders a target compiles. Observed behaviour is
  recursive — `CodansCore/Editor/` and `CodansCore/Notifications/`
  compile today without being listed, implied by the single
  `"CodansCore"` entry. Step 0 verifies this empirically before
  relying on it for Step 1.

## Plan of Work

The plan is ordered as three phases: **(A) Contract freeze** (Steps
0–3) — no runtime effect, purely adds new files so T2/T3/T4 can start
compiling. **(B) Unified persistence** (Step 4) — switches the settings
file over to v2 and collapses the two writers into one, rewired in a
single atomic commit per master instruction #3. **(C) Window surface
and cleanup** (Steps 5–7) — the actual user-visible Settings window
comes last, so failures during (A)(B) cannot land a half-wired UI.

Slicing rationale: "contract first" is more important here than the
usual vertical-slice heuristic, because the other three agent branches
are waiting for the contract. The vertical slice (`⌘,` opens the
window) cannot start until the persistence layer it talks to is
stable (Step 4), so Steps 5–6 follow Step 4 naturally.

### Phase A — Contract freeze

#### Step 0: Verify Tuist buildableFolders recursion

Before creating `CodansCore/Settings/`, run `make -C apps/mac
generate` against a temporary probe file to confirm Tuist auto-picks
up new subfolders under `CodansCore/` without editing
`apps/mac/Project.swift`.

Rationale: the `CodansCore` target lists
`buildableFolders: ["CodansCore", "CodansCore/Hooks"]` yet the
`CodansCore/Editor/` and `CodansCore/Notifications/` subfolders
clearly compile today — so recursion is the presumed behaviour, but
unverified. If the probe shows the new subfolder is NOT picked up,
edit `apps/mac/Project.swift` to add `"CodansCore/Settings"` to
the target's buildableFolders and commit that edit as Step 0; Step 1
then lands on a known-good Tuist config. If the probe shows recursion
works, discard the probe file and proceed with no commit for Step 0.

Exact procedure:

1. `touch apps/mac/CodansCore/Settings/_probe.swift` with content
   `// probe`.
2. Run `make -C apps/mac generate`.
3. Open the generated project: check whether
   `codans.xcodeproj/project.pbxproj` contains `_probe.swift` as
   a member of the `CodansCore` group sources.
   `grep -q _probe.swift apps/mac/codans.xcodeproj/project.pbxproj
   && echo RECURSES || echo NEEDS-EXPLICIT-ENTRY`.
4. Delete the probe file.
5. If result was `NEEDS-EXPLICIT-ENTRY`, edit `Project.swift`'s
   `CodansCore` target to append `"CodansCore/Settings"` to
   `buildableFolders`; re-run generate; commit with
   `chore(mac): declare CodansCore/Settings as a buildable folder`.
   Otherwise skip the commit.

Same probe applies under `codans/App/Features/Settings/Panes/`
and `Sidebar/` — the `codans` app target lists
`"codans/App"` plus a handful of explicit subfolders. If the
probe shows recursion works, no further action. If it requires
explicit entries, add `"codans/App/Features/Settings/Panes"` and
`"codans/App/Features/Settings/Sidebar"` to the app target's
buildableFolders in the same Step 0 commit.

#### Step 1: Add `CodansCore/Settings/` v2 Codable types

Create six files under `apps/mac/CodansCore/Settings/` that
together define the v2 schema. No runtime wiring changes in this step.

- `AppearancePreference.swift` — enum with cases `.system`, `.light`,
  `.dark`; `Codable` via rawValue `String`; `Sendable`.
- `GeneralSettings.swift` — struct with `appearance: AppearancePreference
  = .system`, `defaultEditorID: EditorID? = nil`, `customEditors:
  [CustomEditor] = []`. `Codable`, `Equatable`, `Sendable`. Custom
  init with defaults so `try? container.decode(GeneralSettings.self)`
  with empty JSON yields a valid default.
- `NotificationsSettings.swift` — **superset** of the current
  `CodansSettings.notifications` shape. Fields: `mute: MuteSettings
  = .defaults`, `authStatus: AuthorizationStatusCache = .notDetermined`,
  `neverPrompt: Bool = false`, `notNowUntil: Date? = nil`,
  `inAppEnabled: Bool = true`, `systemEnabled: Bool = true`,
  `soundEnabled: Bool = true`, `dockBadgeEnabled: Bool = true`.
  All new fields default to safe values so a decode of a legacy object
  with only the original four keys still succeeds. Reuses `MuteSettings`
  and `AuthorizationStatusCache` from
  `apps/mac/CodansCore/Notifications/MuteSettings.swift` and
  `apps/mac/codans/Notifications/NotificationSettingsStore.swift`
  — the latter enum is copied into this file (same cases) because it
  currently lives in the app target and Step 4 will delete the old
  file; co-locating it with `NotificationsSettings` in
  `CodansCore/Settings/` is the natural home.
- `DeveloperSettings.swift` — struct with
  `cli: DeveloperCLISettings = .init()` where `DeveloperCLISettings`
  is a nested struct holding `lastInstallAttemptAt: Date? = nil`.
- `RepositorySettings.swift` — `public struct RepositorySettings:
  Equatable, Codable, Sendable { public init() {} }`. No fields.
  Doc-comment notes that T4+ fills this.
- `Settings.swift` — v2 root:

  ```swift
  public struct Settings: Equatable, Codable, Sendable {
    public static let currentVersion = 2
    public var version: Int
    public var general: GeneralSettings
    public var notifications: NotificationsSettings
    public var developer: DeveloperSettings
    public var repositories: [ProjectID: RepositorySettings]

    public static let `default` = Settings(...)
    public static func defaultURL(home: URL = ...) -> URL    // = ~/.config/codans/settings.json
  }

  extension Settings {
    public enum DecodingIssue: Error, Equatable { case unsupportedVersion(Int) }
  }

  extension Settings /* Codable */ {
    // init(from:) rejects version != 2 with DecodingIssue.unsupportedVersion;
    // each sub-struct decodeIfPresent'd with fallback to its default.
    //
    // `repositories` decoded as [String: RepositorySettings] first, then
    // each key attempted as ProjectID; unparseable keys skipped with an
    // os.Logger warning. Keys that resolve to empty RepositorySettings
    // (encoded as {}) are retained by decode but GC'd on next encode via
    // a helper `Settings.garbageCollect()` called inside SettingsStore
    // before each save (Step 4).
  }
  ```

  `ProjectID` comes from `apps/mac/CodansCore/IDs.swift` and
  already derives `Codable` from its UUID `RawValue` — no custom
  coding.

Tests — create `apps/mac/CodansCoreTests/SettingsCodableTests.swift`:

- Round-trip `Settings.default` through encode→decode; assert equality.
- Encode `Settings.default` to canonical JSON (sorted keys, pretty),
  assert it matches the snapshot from design doc "Data Storage".
- Decode a minimal `{"version":2}` JSON; assert each sub-tree defaults
  are applied.
- Decode a JSON with `repositories` containing an unparseable key
  (`"not-a-uuid"`); assert the key is dropped and the rest of the tree
  loads.
- Attempt to decode `{"version":99}`; assert `DecodingIssue.unsupportedVersion(99)`.

Commit message: `feat(core): add Settings v2 Codable types`.

**Verification for Step 1.** Run at `apps/mac/`:

```
make generate
xcodebuild -workspace codans.xcworkspace -scheme CodansCoreTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
```

Expect: `** TEST SUCCEEDED **` with `SettingsCodableTests` showing
5 tests passed. No other test targets are touched; they remain green.

#### Step 2: Add contract surfaces (enum / protocol / placeholders / ComingSoonPane)

Seven new files, all self-contained, all in the app target. None are
wired into the existing runtime — they exist so T2/T3/T4 can
`import`-and-switch against them.

1. `apps/mac/codans/App/Features/Settings/SettingsSection.swift`:

   ```swift
   public enum SettingsSection: Hashable, Sendable {
     case general, notifications, developer, shortcuts, updates, about
     case repositoryGeneral(ProjectID)
     case repositoryHooks(ProjectID)

     public static let globals: [SettingsSection] =
       [.general, .notifications, .developer, .shortcuts, .updates, .about]
   }
   ```

   The `globals` static is the canonical iteration order (spec M3).
   `repositoryGeneral / repositoryHooks` carry the Project they bind
   to; views reconstruct the sidebar repository rows from
   `HierarchyManager.catalog`.

2. `apps/mac/codans/App/Features/Settings/NotificationSettingsReader.swift`:

   ```swift
   @MainActor
   protocol NotificationSettingsReader: AnyObject {
     var mute: MuteSettings { get }
     var authStatus: AuthorizationStatusCache { get }
     var neverPrompt: Bool { get }
     var notNowUntil: Date? { get }
     var inAppEnabled: Bool { get }
     var systemEnabled: Bool { get }
     var soundEnabled: Bool { get }
     var dockBadgeEnabled: Bool { get }
   }
   ```

   No conformances yet. Step 4 adds the `SettingsStore` conformance.

3. `apps/mac/codans/App/Features/Settings/Panes/ComingSoonPane.swift`:

   ```swift
   struct ComingSoonPane: View {
     let title: String
     var body: some View {
       VStack(spacing: 8) {
         Text(title).font(.title3.bold())
         Text("Coming in a later release.").foregroundStyle(.secondary)
       }
       .frame(maxWidth: .infinity, maxHeight: .infinity)
     }
   }
   ```

4. `Panes/NotificationsSettingsView.swift` — `struct NotificationsSettingsView: View { var body: some View { Text("TODO: supplied by T2") } }`.
5. `Panes/DeveloperSettingsView.swift` — `TODO: supplied by T3`.
6. `Panes/RepositoryGeneralSettingsView.swift` —
   takes `let projectID: ProjectID`; body `Text("TODO: supplied by T4 for \(projectID)")`.
7. `Panes/RepositoryHooksSettingsView.swift` — same shape,
   `Text("TODO: supplied by T4 for \(projectID)")`.

Each placeholder view includes `#Preview { ... }` rendering its body
so Xcode previews remain green.

No test file added in this step — the contract surfaces have no
behaviour to test beyond "they compile". The existing test suites
must still be green.

Commit message: `feat(settings): freeze contract surfaces for T2/T3/T4`.

**Verification for Step 2.** Run at `apps/mac/`:

```
make generate
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug build -destination 'platform=macOS' | xcbeautify
```

Expect `** BUILD SUCCEEDED **`. Also run the lint:

```
make lint
```

Expect no new lint findings on the added files (SwiftLint's rules
about implicit-return etc. apply).

#### Step 3: Migration scaffolding

Two new files and one test file. Still no runtime wiring.

- `apps/mac/CodansCore/Settings/LegacyV1Settings.swift`:

  ```swift
  /// Permissive Codable for legacy settings.json. Every field is
  /// optional because the two historical writers (editor store and
  /// notifications store) each populated a disjoint subset.
  struct LegacyV1Settings: Decodable {
    let version: Int?
    let defaultEditorID: EditorID?
    let customEditors: [CustomEditor]?
    let notifications: LegacyNotificationsSettings?

    struct LegacyNotificationsSettings: Decodable {
      let mute: MuteSettings?
      let authStatus: AuthorizationStatusCache?
      let neverPrompt: Bool?
      let notNowUntil: Date?
    }
  }
  ```

- `apps/mac/CodansCore/Settings/SettingsMigration.swift`:

  ```swift
  enum SettingsMigration {
    enum LoadOutcome: Equatable {
      case fresh                                           // file missing
      case v2(Settings)                                    // already current
      case migratedFromV1(Settings, backupURL: URL)        // rename v1 → v1-<ts>
      case unsupported(Int, backupURL: URL)                // move aside → broken-<ts>
      case corrupt(backupURL: URL)                         // decode error → broken-<ts>
    }

    static func load(from url: URL, clock: () -> Date = Date.init) throws -> LoadOutcome

    static func migrate(_ legacy: LegacyV1Settings) -> Settings    // pure helper
  }
  ```

  `migrate` applies the mapping described in design-doc Data Storage
  (§Migration algorithm step 3). `load` wraps `AtomicFileStore.read`
  with the v2-first / legacy-fallback / rename-aside sequence.

- `apps/mac/CodansCoreTests/SettingsMigrationTests.swift` — five
  tests, one per design-doc fixture:

  1. `migratesEditorOnlyV1` — seeds `{"version":1,"defaultEditorID":"vscode","customEditors":[...]}`,
     asserts `.migratedFromV1`, `general.defaultEditorID == "vscode"`,
     `general.customEditors` preserved, `notifications` at defaults,
     backup file exists with `.v1-` prefix.
  2. `migratesNotificationsOnlyV1` — seeds
     `{"version":1,"notifications":{"mute":{...},"authStatus":"denied"}}`,
     asserts notification fields carry over, `general` at defaults,
     `notifications.dockBadgeEnabled` reflects `mute.badgeEnabled`.
  3. `migratesCombinedV1` — seeds the union file; both sub-trees
     carry over.
  4. `backsUpUnsupportedVersion` — seeds `{"version":99}`, asserts
     `.unsupported(99, ...)`, backup file exists with `.broken-` prefix.
  5. `backsUpCorruptJSON` — seeds the file with `{` (not parseable),
     asserts `.corrupt(...)` and the backup.

Commit message: `feat(core): add v1→v2 settings migration (scaffolding)`.

**Verification for Step 3.** Run `make generate` + the
`CodansCoreTests` scheme; expect 5 new tests passed + all prior
Codable tests still passing.

### Phase B — Unified persistence

#### Step 4: SettingsStore v2 refactor + C6 coordinator rewire + delete `NotificationSettingsStore`

This is the largest step in the plan. It is intentionally atomic —
splitting it further leaves the repo in a state where
`NotificationSettingsStore` rejects v2 (`version == 2` fails its
`unsupportedVersion` gate) and races `SettingsStore` for the file.
Per master instruction #3, the refactor and the deletion land together.

Files modified / deleted (full list, so the implementer can budget):

Modified:
- `apps/mac/codans/App/Features/Settings/SettingsStore.swift` — full rewrite.
- `apps/mac/codans/App/Clients/EditorClient.swift` — switch to
  `settings.general.defaultEditorID` / `settings.general.customEditors`.
- `apps/mac/codans/App/Clients/InboxClient.swift` — `muteRule`
  routes through `settingsStore.mutateNotifications { $0.mute.mutedRuleIDs.insert(...) }`.
- `apps/mac/codans/Notifications/NotificationCoordinator.swift` —
  init takes `reader: any NotificationSettingsReader` + `mutate: @MainActor @Sendable (inout NotificationsSettings) -> Void`
  instead of the concrete `NotificationSettingsStore`. Internally
  replace `settings.settings.notifications.<X>` reads with `reader.<X>`,
  and `settings.mutate { $0.notifications... }` calls with
  `mutate { $0... }`.
- `apps/mac/codans/Notifications/C6AppBootstrap.swift` —
  parameters switch from `settingsStore: NotificationSettingsStore?`
  to `settings: SettingsStore`. Pass `settings` to
  `NotificationCoordinator`'s reader+mutate parameters.
  `flushPendingWrites()` calls `settings.flush()`.
- `apps/mac/codans/App/CodansApp.swift` —
  `AppState.notificationSettingsStore` field removed;
  `InboxClient.live(inbox: …, settings: settingsStore)`;
  `flushAllPersistedState()` flushes `settingsStore` once;
  `startNotifications` passes `settingsStore` into
  `C6AppBootstrap.start(settings: settingsStore, …)`.
- `apps/mac/codans/App/Features/Settings/SettingsStore.swift` owns
  `Settings` v2 directly and calls `SettingsMigration.load` in its
  initialiser; exposes the full mutate API from design-doc §API;
  conforms to `NotificationSettingsReader`.

Deleted:
- `apps/mac/codans/Notifications/NotificationSettingsStore.swift`
  (file — everything the app used lives now on `SettingsStore` +
  `NotificationSettingsReader`).
- `apps/mac/CodansCore/Editor/Settings.swift` (v1 Settings struct).
  `CustomEditor` / `CommandTemplate` / `EditorID` stay in
  `EditorStorageModels.swift` / `EditorValidators.swift` — those
  files are unchanged.

Tests:
- `apps/mac/codans/Tests/SettingsStoreTests.swift` — rewritten.
  Cover: each mutate API schedules a save; `flush` writes-through;
  `saveNow` skips the debounce; corrupt file on disk backed aside;
  writes produce canonical pretty-printed JSON; empty RepositorySettings
  entries GC on save.
- `apps/mac/codans/Tests/NotificationsTests/NotificationSettingsStoreTests.swift` —
  **deleted** (its subject class is gone).
- `apps/mac/codans/Tests/NotificationsTests/C6AppBootstrapTests.swift` —
  updated assertions. One new test: `coordinatorReceivesReaderWiredToSettingsStore`
  — mutates `settingsStore.mutateNotifications { $0.mute.mutedRuleIDs.insert("r") }`,
  asserts `bootstrap.coordinator`'s reader reports the update.
- `apps/mac/codans/Tests/NotificationsTests/NotificationCoordinatorTests.swift` —
  fixtures switch from a fake `NotificationSettingsStore` to a
  hand-rolled `FakeSettingsReader` (class implementing the protocol)
  plus a `MutateRecorder` closure. No coordinator logic under test
  actually changes.
- `apps/mac/codans/Tests/NotificationsTests/InboxClientLiveTests.swift` —
  wires `InboxClient.live` with a `SettingsStore()` fixture rather
  than `NotificationSettingsStore()`.
- `apps/mac/codans/Tests/NotificationsTests/C6EndToEndTests.swift` —
  end-to-end helper that used to construct `NotificationSettingsStore`
  now constructs `SettingsStore`; no behavioural change expected.

Implementation notes:
- `SettingsStore` keeps its existing debounce pattern (`pendingSaveTask`,
  `debounceWindow`); the migration runs once in `init` and writes the
  migrated tree through `saveNow()` before returning, so the first
  mutate does not race the backup rename.
- `mutateRepository` auto-inserts a default `RepositorySettings()` on
  first access; `scheduleSave()` runs `Settings.garbageCollect()`
  against the snapshot it's about to write to drop empty entries.
- `NotificationSettingsReader` conformance on `SettingsStore` is a
  small extension with eight computed properties reading
  `settings.notifications.*`. Reads are `@MainActor` — the protocol
  is declared `@MainActor` so consumers must hop on, matching today.
- The old `CodansSettings.DecodingIssue.unsupportedVersion` path
  in `NotificationSettingsStore` is gone — migration moves this
  responsibility to `SettingsMigration.load` (Step 3).

Commit message: `refactor(settings): unify settings.json on v2 with NotificationSettingsReader`.

**Verification for Step 4.** Run at `apps/mac/`:

```
make generate
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace codans.xcworkspace -scheme CodansCoreTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
```

Expect: both schemes `** TEST SUCCEEDED **`. Particularly check that
`NotificationCoordinatorTests`, `InboxClientLiveTests`,
`C6AppBootstrapTests`, `C6EndToEndTests`, `SettingsStoreTests` all
pass.

Manual smoke: `make -C apps/mac run-app`, verify the Header bell
popover still renders (nothing user-facing should have changed yet).

### Phase C — Window surface and cleanup

#### Step 5: Settings Window scene + `SettingsWindowFeature` + General / About panes + menu command

The step that actually makes the Settings window visible.

Files added:
- `apps/mac/codans/App/Features/Settings/SettingsWindowFeature.swift` —
  `@Reducer` with the shape described in design-doc §SettingsWindowFeature.
  Scopes `general` to `EditorFeature` so the General pane can reuse
  the existing reducer. `selectionChanged` and `windowClosed` are the
  only bespoke actions. No child-feature placeholders are wired yet
  (T2/T3/T4 add those).
- `apps/mac/codans/App/Features/Settings/SettingsWindowView.swift` —
  root `NavigationSplitView`; sidebar column is `SettingsSidebarView`;
  detail column is the switch over `effectiveSection` (design-doc
  §`SettingsWindowView` detail switch). Minimum frame sizes:
  `minWidth: 750, minHeight: 500` with the sidebar column's
  `navigationSplitViewColumnWidth(min: 220, ideal: 240)`.
- `apps/mac/codans/App/Features/Settings/Sidebar/SettingsSidebarView.swift` —
  renders the six global rows in fixed order, then a `Section("Repositories")`
  containing a sorted `DisclosureGroup` per open Project (pulled from
  `HierarchyManager.catalog` via `@Environment(HierarchyManager.self)`).
  Each disclosure contains two rows (`General`, `Hooks`) yielding
  `.repositoryGeneral(projectID)` / `.repositoryHooks(projectID)` on
  selection. Disclosure state is local `@State` keyed by `ProjectID`
  so it survives window close (per M16, draft state is preserved).
- `apps/mac/codans/App/Features/Settings/Panes/SettingsGeneralView.swift` —
  three sections stacked vertically: Appearance (Picker with D3 caption
  "Preview — themes will ship in a later release."), Default editor
  (picker lifted from `SettingsEditorSection.swift`), Built-in / Custom
  editors lists (lifted from same file, including the `AddCustomEditorSheet`
  subview). The view is driven by `store.scope(state: \.general, action: \.general)`.
- `apps/mac/codans/App/Features/Settings/Panes/AboutSettingsView.swift` —
  reads `Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")`
  (fallback `CFBundleName`), `CFBundleShortVersionString`,
  `CFBundleVersion`, `NSHumanReadableCopyright`. Missing keys omit
  the corresponding line (no constant fallback, per D2). Website
  placeholder link as inactive `Text`.
- `apps/mac/codans/App/Clients/SettingsWindowPresenter.swift` —
  new TCA dependency. `struct SettingsWindowPresenter: Sendable { var open: @MainActor @Sendable () -> Void }`.
  `liveValue` `fatalError`s; actual value injected in Step 5 via
  `.withDependencies { $0.settingsWindowPresenter = .init(open: { openWindow(id: "settings") }) }`
  at `CodansApp.body` — mirrors the `EditorClient` wiring pattern.
  `Root Feature`'s delegate rerouting in Step 6 relies on this client
  existing.
- `apps/mac/codans/Tests/SettingsWindowFeatureTests.swift` — tests
  (a) selecting `.notifications` updates `state.selection`;
  (b) `windowClosed` resets `state.selection` to nil; (c) after
  `windowClosed` the effective section is `.general` on re-render
  (view-level test via `ViewStore.publisher`).

Files modified:
- `apps/mac/codans/App/CodansApp.swift` — `body` gains a
  `Window("Settings", id: "settings") { ... }` scene and
  `CommandGroup(replacing: .appSettings) { Button("Settings…") {
   openWindow(id: "settings") } .keyboardShortcut(",", modifiers: .command) }`
  inside `.commands`. `AppState` gains a `settingsWindowStore: StoreOf<SettingsWindowFeature>?`
  property (built during `bringUp()`) and an injected
  `SettingsWindowPresenter` via dependency overrides.
- `apps/mac/Configurations/mac-Info.plist` — add `NSHumanReadableCopyright`
  key if missing (value: `© 2026 Gump`). Check the existing plist
  first; if the key is already present, leave it.

`RootFeature` is still reachable via the sheet path at the end of
Step 5 — the sheet plumbing isn't removed yet (Step 6). This means
the user can reach the Custom editors UI two ways during the Step 5
window (header button → settings sheet; menu → settings window).
Tolerated because the sheet still works and no tests regress.

Commit message: `feat(settings): add Settings window scene, General and About panes`.

**Verification for Step 5.** Build + test:

```
make generate
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
```

Manual:

1. `make -C apps/mac run-app`.
2. Press `⌘,` — expect the new window to appear with sidebar + General
   pane (Appearance picker, Default editor picker, editor lists).
3. Press `⌘,` again — expect focus, not a second window.
4. Close the main window — expect Settings remains open.
5. Click each sidebar row — Notifications / Developer show the
   `Text("TODO: …")` placeholder; Shortcuts / Updates show the
   shared `ComingSoonPane`; About shows app name + version + build
   number + copyright (if plist has it).
6. Add a project via the main window; switch to Settings — the new
   Repository disclosure row appears; expand shows General/Hooks; each
   routes to the placeholder view for that projectID.
7. Close the Settings window, reopen with `⌘,` — the detail pane
   defaults to General (selection cleared per M16).

#### Step 6: Remove `SettingsSheet*` + reroute `showCustomEditorsSettings`

Cleanup — the sheet path disappears now that the window covers every
use case.

Files deleted:
- `apps/mac/codans/App/Features/Settings/SettingsSheetFeature.swift`
- `apps/mac/codans/App/Features/Settings/SettingsSheetView.swift`
- `apps/mac/codans/App/Features/Settings/SettingsEditorSection.swift`

Files modified:
- `apps/mac/codans/App/Features/Root/RootFeature.swift` —
  remove `@Presents var settingsSheet`, `case settingsSheetShown`,
  `case settingsSheet(PresentationAction<…>)`, and the corresponding
  reducer branches (`case .settingsSheetShown`, `case .settingsSheet(...)`).
  The delegate case `worktreeHeader(.delegate(.showCustomEditorsSettings))`
  changes from `.send(.settingsSheetShown)` to:

  ```swift
  @Dependency(SettingsWindowPresenter.self) var settingsWindowPresenter
  // ...
  return .run { _ in await MainActor.run { settingsWindowPresenter.open() } }
  ```

  (the `@Dependency` declaration at the top of the struct).
  Drop the `.ifLet(\.$settingsSheet, action: \.settingsSheet) { SettingsSheetFeature() }` from the body.
- `apps/mac/codans/Tests/RootFeatureTests.swift` — delete any
  `settingsSheet` presentation assertions; add one test
  `showCustomEditorsSettingsOpensSettingsWindow` that overrides
  `settingsWindowPresenter` with a recorder and asserts the `.open()`
  closure fires when the delegate action is dispatched.

Commit message: `refactor(settings): retire Settings sheet path`.

**Verification for Step 6.** Full test:

```
make generate
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
```

Manual: launch the app, open the Header Open-in popover,
click "+ Custom editors…" — expect the Settings window to open (or
gain focus) on the General pane's Custom editors list. The sheet
should no longer appear.

#### Step 7: Manual QA pass over spec Acceptance Criteria (T1 slice)

No code changes unless a regression is found. Walk the subset of
`docs/product-specs/ui-settings-window.md §Acceptance Criteria` that
this plan is responsible for and record outcomes in this plan's
`Outcomes & Retrospective` section:

1. **Window lifecycle** — all four bullets (open on ⌘,, focus on
   repeat, survives main-window close, reopens on General).
2. **Sidebar and navigation** — empty-Repositories state,
   two-Project ordering, project-added updates the sidebar, project
   removed with selection falls back to General.
3. **General (T1 slice only)** — historical `defaultEditorID` and
   custom editors visible after upgrade; Appearance round-trip across
   close/reopen.
4. **Notifications** — placeholder text visible (T2 scope otherwise).
5. **Developer** — placeholder visible (T3 scope otherwise).
6. **Shortcuts / Updates** — `ComingSoonPane` rendered.
7. **About** — display name + version + build + copyright (if plist
   has the key).
8. **Repository General / Hooks** — placeholder visible (T4 scope).
9. **Persistence & consistency** — manual: change Appearance to Dark,
   change Default editor, close window, quit app, relaunch; both
   persist. Change `~/.config/codans/settings.json` directly
   (mute rule), relaunch; change reflected.
10. **Upgrade compatibility** — seed a v1 editor-only file + a v1
    notifications-only file + a combined file in three clean home
    directories (via `HOME=/tmp/tctest-x`); launch each; verify
    settings visible in window, backup file present, `settings.json`
    now at `version: 2`.
11. **Placeholder sections** — selection persists across switches,
    does not cause empty-state flicker.

If every bullet passes, mark the step complete. If any bullet fails,
file it under `Surprises & Discoveries` with a reproduction, open a
sub-step (Step 7a, 7b, …) for the fix, and commit the fix with a
`fix(settings): …` message.

Commit in Step 7 is only created if a QA finding required a fix.
Otherwise the plan moves straight to Final.

## Concrete Steps

Working directory for all commands: `apps/mac/`
(repository: `/Users/wanggang/.worktree/repos/codans/feat/settings-shell`).

### Generate Tuist project

```
make generate
```

Expected tail: `Project generated at …`, no errors.

### Build the app (sanity check)

```
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug build -destination 'platform=macOS' | xcbeautify
```

Expected: `** BUILD SUCCEEDED **`.

### Run the full test matrix

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

Expected: each scheme ends with `** TEST SUCCEEDED **`.

### Lint + format

```
make check
```

Expected: swift-format idempotent, swiftlint zero new violations.

### Run the app for manual QA

```
make run-app
```

### Seed a legacy settings file for upgrade QA

```
mkdir -p /tmp/tctest-editor/.config/codans
cat > /tmp/tctest-editor/.config/codans/settings.json <<'JSON'
{"version":1,"defaultEditorID":"vscode","customEditors":[]}
JSON
HOME=/tmp/tctest-editor make run-app
# Quit the app, then:
ls /tmp/tctest-editor/.config/codans/
# Expect: settings.json (v2 on disk), settings.json.v1-<ts>
jq .version /tmp/tctest-editor/.config/codans/settings.json
# Expect: 2
```

Repeat for `/tmp/tctest-notifications/` and `/tmp/tctest-combined/`
with the other two legacy payloads.

### Commit, push, open PR (Final)

```
# After Step 6 + Step 7 are complete and everything is green.
git push -u origin feat/settings-shell
gh pr create --base feature/settings-base --title "feat(settings): window shell + unified persistence (T1)" \
  --body-file - <<'EOF'
## Summary

- Deliver the Settings window shell (⌘,-opened independent window with
  NavigationSplitView sidebar) covering General + About + ComingSoonPane
  for Shortcuts/Updates.
- Collapse two racing writers on `settings.json` into one v2 store with
  `SettingsStore` + `NotificationSettingsReader`.
- Add v1→v2 migration (editor-only / notifications-only / combined).
- Freeze contract surfaces (`SettingsSection`, 4 placeholder pane views,
  mutate API) for T2/T3/T4.

## Design & Plan

- Design doc: `docs/design-docs/settings-base.md`
- Exec plan: `docs/exec-plans/settings-base.md`

## Test plan

- [x] `xcodebuild test` across codans / CodansCoreTests / CodansKitTests / tcTests
- [x] Manual QA walk of spec Acceptance Criteria (T1 slice) — see
      ExecPlan §Outcomes
- [x] Upgrade QA in three clean `HOME` directories (editor-only /
      notifications-only / combined v1 files)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
```

## Validation and Acceptance

System-level acceptance is phrased as user-observable behaviour. A
test-script version is given where mechanical.

**Open/focus the Settings window.** User presses `⌘,` with the main
window active. Observable result: a second window titled "Settings"
appears at ≥ 750 × 500 pt with a sidebar listing General /
Notifications / Developer / Shortcuts / Updates / About. Pressing
`⌘,` again does NOT create a third window — the existing Settings
window gains key focus.

**Close + reopen preserves draft, resets selection.** User opens
Settings, scrolls to Notifications, then closes the window. User
presses `⌘,`. Observable result: detail pane renders **General**,
not Notifications.

**General round-trip across restart.** User changes Appearance to
Dark, closes Settings, quits the app, relaunches, and opens Settings.
Observable result: Appearance shows Dark.

**Upgrade compatibility.** The three seed fixtures in Concrete Steps
above yield a migrated `settings.json` with `version: 2` and an
adjacent `settings.json.v1-<ts>` backup. Verified by `jq` + `ls`.

**Persistence atomicity across panes.** User changes `in-app
notifications` on via direct edit to the v2 file (simulating T2
wiring once landed), then changes Default editor in the General pane;
closes the Settings window; relaunches the app. Observable result:
both changes persist simultaneously — the write Settings produces
does not clobber the notifications toggle. (This property is what
M13 requires; it is an invariant of the single-writer design.)

**Test matrix green.** Running all four `xcodebuild test` schemes
listed in Concrete Steps ends with `** TEST SUCCEEDED **`. The new
`SettingsCodableTests` contributes 5 passes, `SettingsMigrationTests`
contributes 5 passes, `SettingsWindowFeatureTests` contributes 3
passes. `NotificationSettingsStoreTests` is no longer in the tree.

**T2/T3/T4 compile smoke.** Checkout a throwaway branch from the tip
of `feat/settings-shell` (after Step 6), replace the body of
`NotificationsSettingsView.swift` with any non-empty `VStack`, run
`xcodebuild build` — expect success. This is the contract-compile
check T2/T3/T4 will run on their side; it proves the placeholder
files integrate cleanly.

## Idempotence and Recovery

Each step is implemented by adding new files and/or editing existing
files — both are inherently idempotent under git. If a step lands
partially (e.g., test failures after Step 4), the recovery path is
to `git reset --hard HEAD~1` to drop the step's commit, diagnose the
failure, and re-attempt. Do **not** `--amend` — per project
CLAUDE.md: "Agent and human both reason better over narrow diffs.
Create NEW commits rather than amending."

Step 4's migration path is designed to be idempotent at the user
level too: a user who runs the migrated app, then downgrades and
re-upgrades, will re-read the v2 file and skip the migration branch
entirely. The v1 backup is not touched on a second load.

If the Tuist `buildableFolders` verification in Step 0 lands in the
wrong state (recursion assumed but actually not working), the symptom
in Step 1 is a missing-symbol compile error on `Settings` v2. Recovery:
add the explicit `"CodansCore/Settings"` entry to
`apps/mac/Project.swift`, re-run `make generate`, retry the build.
That recovery commit should land **before** the Step 1 commit on the
history, so amend the order by `git rebase -i` only if no subsequent
commit has been pushed yet — otherwise drop a follow-up fix commit.

If migration corrupts a test fixture during development, delete the
contents of the scratch `HOME` (`rm -rf /tmp/tctest-*`) and re-seed.
Production-grade recovery is a user concern and is addressed by the
`settings.json.v1-<ts>` / `settings.json.broken-<ts>` backup files
— the user can copy either back over `settings.json` after reverting
the app version.

No destructive commands in this plan (no `git reset --hard` into
shared history, no force-push to remote). The only remote interaction
is the single `git push -u origin feat/settings-shell` at the Final
step, after every local gate has passed.

## Artifacts and Notes

### Example migrated JSON (Step 4 output)

    {
      "developer": { "cli": { "lastInstallAttemptAt": null } },
      "general": {
        "appearance": "system",
        "customEditors": [],
        "defaultEditorID": "vscode"
      },
      "notifications": {
        "authStatus": "notDetermined",
        "dockBadgeEnabled": true,
        "inAppEnabled": true,
        "mute": {
          "badgeEnabled": true,
          "enabled": true,
          "mutedPanelIDs": [],
          "mutedRuleIDs": [],
          "redactBodies": false,
          "surfaceIdle": false
        },
        "neverPrompt": false,
        "notNowUntil": null,
        "soundEnabled": true,
        "systemEnabled": true
      },
      "repositories": {},
      "version": 2
    }

### Example backup filename

    ~/.config/codans/settings.json.v1-20260421-121503

## Interfaces and Dependencies

The following types and signatures must exist at the end of the plan.
T2/T3/T4 depend on these verbatim.

In `apps/mac/CodansCore/Settings/Settings.swift`:

    public struct Settings: Equatable, Codable, Sendable {
      public static let currentVersion: Int        // = 2
      public var version: Int
      public var general: GeneralSettings
      public var notifications: NotificationsSettings
      public var developer: DeveloperSettings
      public var repositories: [ProjectID: RepositorySettings]
      public static let `default`: Settings
      public static func defaultURL(home: URL) -> URL
      public enum DecodingIssue: Error, Equatable {
        case unsupportedVersion(Int)
      }
    }

In the same module, `GeneralSettings`, `NotificationsSettings`,
`DeveloperSettings`, `RepositorySettings`, and `AppearancePreference`
as specified in Step 1.

In `apps/mac/codans/App/Features/Settings/SettingsSection.swift`:

    public enum SettingsSection: Hashable, Sendable {
      case general, notifications, developer, shortcuts, updates, about
      case repositoryGeneral(ProjectID)
      case repositoryHooks(ProjectID)
      public static let globals: [SettingsSection]
    }

In `apps/mac/codans/App/Features/Settings/NotificationSettingsReader.swift`:

    @MainActor
    protocol NotificationSettingsReader: AnyObject {
      var mute: MuteSettings { get }
      var authStatus: AuthorizationStatusCache { get }
      var neverPrompt: Bool { get }
      var notNowUntil: Date? { get }
      var inAppEnabled: Bool { get }
      var systemEnabled: Bool { get }
      var soundEnabled: Bool { get }
      var dockBadgeEnabled: Bool { get }
    }

In `apps/mac/codans/App/Features/Settings/SettingsStore.swift`:

    @MainActor @Observable
    final class SettingsStore: NotificationSettingsReader {
      private(set) var settings: Settings

      init(fileURL: URL = Settings.defaultURL(), debounceWindow: Duration = .milliseconds(500))

      // Mutators (all schedule a debounced save)
      func mutateGeneral(_ transform: (inout GeneralSettings) -> Void)
      func mutateNotifications(_ transform: (inout NotificationsSettings) -> Void)
      func mutateDeveloper(_ transform: (inout DeveloperSettings) -> Void)
      func mutateRepository(_ projectID: ProjectID,
                            _ transform: (inout RepositorySettings) -> Void)

      // Convenience (delegate to mutateGeneral)
      func setDefaultEditorID(_ id: EditorID?)
      func setAppearance(_ appearance: AppearancePreference)
      @discardableResult func addCustomEditor(_ editor: CustomEditor)
        -> Result<Void, EditorTemplateError>
      @discardableResult func updateCustomEditor(id: EditorID,
                                                 _ transform: (inout CustomEditor) -> Void) -> Bool
      @discardableResult func removeCustomEditor(id: EditorID) -> Bool

      // Persistence
      func replaceAll(_ new: Settings)
      func saveNow() throws
      func flush()
    }

In `apps/mac/codans/App/Features/Settings/SettingsWindowFeature.swift`:

    @Reducer
    struct SettingsWindowFeature {
      @ObservableState struct State: Equatable {
        var selection: SettingsSection?
        var general: EditorFeature.State
      }
      enum Action: Equatable {
        case selectionChanged(SettingsSection?)
        case general(EditorFeature.Action)
        case windowClosed
      }
    }

In `apps/mac/codans/App/Clients/SettingsWindowPresenter.swift`:

    struct SettingsWindowPresenter: Sendable, DependencyKey {
      var open: @MainActor @Sendable () -> Void
      static let liveValue: SettingsWindowPresenter    // fatalError-backed stub
      static let testValue: SettingsWindowPresenter    // unimplemented stub
    }
    extension DependencyValues { var settingsWindowPresenter: SettingsWindowPresenter { get set } }

External libraries used (no new dependencies):

- `ComposableArchitecture` (existing) — `@Reducer`, `@ObservableState`,
  `@Presents`, `.withDependencies`.
- `SwiftUI` — `Window(id:)`, `NavigationSplitView`, `DisclosureGroup`,
  `@Environment(\.openWindow)`, `CommandGroup(replacing: .appSettings)`.
- `Observation` (`@Observable`) — unchanged usage.

No new SPM packages, no Tuist dependency changes.
