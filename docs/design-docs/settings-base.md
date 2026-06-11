# Design Doc: Settings Window — Shell & Persistence Base (T1)

**Status:** Draft (revised 2026-04-21 per master REVISE round 1 — Q1/Q2/Q3)
**Author:** Gump (agent: feat/settings-shell)
**Date:** 2026-04-21
**Product spec:** [ui-settings-window.md](../product-specs/ui-settings-window.md)

## Context and Scope

codans currently exposes preferences through a single SwiftUI `.sheet`
(`SettingsSheetFeature`/`SettingsSheetView`) presented by `RootFeature` and
limited to the Editors pane. Two separate `@MainActor` stores write to the
same on-disk file `~/.config/codans/settings.json`:

- `SettingsStore` (app target) owns `Settings` (v1, fields: `version`,
  `defaultEditorID`, `customEditors`) — driven by C7/C8 editor work.
- `NotificationSettingsStore` (app target) owns `CodansSettings` (also
  `version: 1`, field: `notifications`) — driven by C6 agent notifications.

Each store decodes the file through `AtomicFileStore`, both reject unknown
versions, and both rewrite the file in full from their narrow schema. The
last writer wins, silently wiping the other's keys. This is the core defect
M13 calls out.

The product spec requires an independent macOS window (not a sheet) with a
sidebar covering six global sections plus a `Repositories` disclosure tree,
and a round of new content (Notifications, Developer, Shortcuts / Updates
placeholders, About, per-Repository panes). T1 delivers the shell plus
General/About plus persistence base; T2/T3/T4 fill Notifications /
Developer / Repository panes in parallel on top of the contracts this
design freezes.

Reference files:

- `apps/mac/codans/App/CodansApp.swift` — scene graph, `AppState` bring-up.
- `apps/mac/codans/App/Features/Root/RootFeature.swift` — owns the old sheet.
- `apps/mac/codans/App/Features/Settings/{SettingsSheetFeature,SettingsSheetView,SettingsEditorSection,SettingsStore}.swift`.
- `apps/mac/codans/App/Clients/EditorClient.swift` — reads `settings.defaultEditorID`, `settings.customEditors`, catalog `Project.defaultEditor`.
- `apps/mac/codans/App/Clients/InboxClient.swift` — reads/writes `NotificationSettingsStore`.
- `apps/mac/codans/Notifications/{NotificationSettingsStore,NotificationCoordinator,C6AppBootstrap}.swift`.
- `apps/mac/CodansCore/Editor/Settings.swift` (v1 `Settings`), `EditorStorageModels.swift` (`CustomEditor`), `Project.swift` (`defaultEditor`, `worktreesDirectory`).

## Goals and Non-Goals

### Goals

- Deliver an independent "Settings" `Window(id: "settings")` scene with `⌘,`
  open/focus semantics (M1, M2, M15, M16).
- Render the double-column shell (sidebar + detail) with the six global
  sections in fixed order, plus the Repositories disclosure tree (M3, M9).
- Implement the General section end-to-end (Appearance placeholder,
  Default editor picker, Built-in / Custom editor lists) by reusing
  `EditorFeature`/`EditorService` (M4).
- Render a shared `ComingSoonPane` for Shortcuts / Updates (M7) and a
  static About pane (M8).
- Unify persistence into a single `Settings` v2 Codable tree, one writer,
  one reader, atomic-rename writes (M13).
- Provide one-shot v1→v2 migration at load time that preserves any
  editor-only, notifications-only, or combined v1 file (M14).
- Publish frozen contracts T2/T3/T4 depend on: `SettingsSection` enum,
  `Settings` v2 shape, `SettingsStore` mutate API,
  `NotificationSettingsReader` protocol, placeholder pane views.
- Keep the macOS `Settings…` menu wired to `⌘,` and keep Esc inert
  (M15, M16).

### Non-Goals

- Notifications / Developer / Repository pane bodies — explicitly owned
  by T2 / T3 / T4.
- A general settings import/export UI (Nice-to-have N2).
- Sidebar search filter (N1).
- Any Appearance theme engine — the control persists but does not repaint.
- CLI install / hook editing / diagnostics implementation — T3 scope.
- Multi-window (non-Settings) refactors.
- Removing or renaming `EditorFeature`, `EditorClient`, `EditorService`,
  `EditorRegistry`, `CustomEditor`, `CommandTemplate` — reused verbatim.
- Any cross-version migration beyond v1→v2 (Out of scope per spec).

## Design

### Overview

T1 replaces the sheet-based settings surface with a standalone
`Window(id: "settings")` scene driven by a new `SettingsWindowFeature`
reducer and a SwiftUI `NavigationSplitView`. Persistence is collapsed onto
a single `Settings` v2 document owned by a single `@MainActor @Observable`
`SettingsStore`. All pane reducers (today: General/About; tomorrow:
Notifications/Developer/Repository) read and mutate through that store,
so no two writers race the file again.

The central trade-off is **schema scope vs. agent parallelism**. Because
T2/T3/T4 start immediately after T1 lands, the v2 schema must be stable
before any pane body ships — otherwise three branches race field renames.
The design therefore freezes the top-level shape, sub-structs for each
section, and the mutate-API surface, even for sections whose UI is still
empty. Field semantics for sections T1 does not render
(`NotificationsSettings`, `DeveloperSettings`) are derived directly from
existing code (C6 `NotificationsSettings` / `MuteSettings`, spec M6
Developer requirements) so the proposals are concrete and defensible
without blocking on T2/T3/T4 implementation detail. `RepositorySettings`
is an explicit exception — it is intentionally empty in T1 (see
"Repository scope" in Data Storage).

The Repository tree is modeled as `[ProjectID: RepositorySettings]` in
settings.json but is **reserved as an empty slot** in T1 — see "Data
Storage / Repository scope". `Project.defaultEditor` and
`Project.worktreesDirectory` stay on the `Catalog` and continue to be
persisted by `CatalogStore`; the Repository General pane (T4) reads and
writes them through `HierarchyManager` / `HierarchyClient`, not
through `SettingsStore`. M13's requirement is "different panes writing
the same settings.json must not clobber each other's keys" — owning
hooks.json (`HookConfigStore`), catalog.json (`CatalogStore`), and
settings.json (`SettingsStore`) as three single-writer files is the
correct responsibility split. Collapsing everything into settings.json
would bloat T1 scope (EditorClient, HierarchyManager worktree
creation, catalog Codable, every `Project(...)` fixture) without
furthering M13.

### System Context Diagram

```
                 ┌──────────────────────────────────────┐
                 │ CodansApp (SwiftUI Scene graph)   │
                 │                                      │
┌─ Menu Bar ─┐   │  WindowGroup "main"                  │
│ Settings…  │──▶│    → ContentView                     │
│  (⌘,)      │   │                                      │
└────────────┘   │  Window "settings"  ◀── openWindow ──┤
                 │    → SettingsWindowView              │
                 │        (NavigationSplitView)         │
                 └──────────────────────────────────────┘
                         │                  ▲
                         │ Action / Binding │  Settings snapshot
                         ▼                  │
                 ┌──────────────────────────────────────┐
                 │ SettingsWindowFeature (TCA reducer)  │
                 │   state: selection, sections,        │
                 │          general (EditorFeature)     │
                 │   delegates: T2/T3/T4 pane reducers  │
                 └──────────────────────────────────────┘
                         │ mutate/read
                         ▼
                 ┌──────────────────────────────────────┐
                 │ SettingsStore (@Observable @MainActor)│
                 │   settings: Settings (v2)            │
                 │   mutate APIs + NotificationSettings │
                 │   Reader adapter                     │
                 └──────────────────────────────────────┘
                         │ AtomicFileStore write/read (debounced 500 ms)
                         ▼
                 ~/.config/codans/settings.json  (v2)
                 ~/.config/codans/settings.json.v1-<ts>  (backup, on migration)
```

Consumers besides the window:

- `EditorClient.live` reads `settings.general.defaultEditorID` /
  `settings.general.customEditors` from `SettingsStore`, and continues
  to read per-Project overrides from the catalog via
  `HierarchyManager.catalog … project.defaultEditor` (unchanged from
  today).
- `NotificationCoordinator` / `InboxClient` consume a
  `NotificationSettingsReader` protocol and mutate via
  `settingsStore.mutateNotifications { $0... }`.

### API Design

#### `SettingsSection` enum (frozen contract — T2/T3/T4 switch on this)

```swift
public enum SettingsSection: Hashable, Sendable {
  // Global sections — order is stable, matches spec M3.
  case general
  case notifications
  case developer
  case shortcuts
  case updates
  case about
  // Repository sections — one pair per open Project.
  case repositoryGeneral(ProjectID)
  case repositoryHooks(ProjectID)
}
```

- `SettingsWindowFeature.State.selection: SettingsSection?` — nil on
  launch, persisted as transient window state (not in `settings.json`),
  reset to `nil` on window close per M16.
- When `selection == nil` and the window becomes visible, the view
  renders `.general` as the effective detail — satisfying "re-open
  defaults to General" without resurrecting a stale Repository selection.
- `SettingsSection.all(for: [ProjectID])` helper returns the flat
  side-bar order for a given project set. T4 does not replace this
  helper; the window view consumes it directly.

#### `Settings` v2 — top-level Codable shape (frozen contract)

```swift
public struct Settings: Equatable, Codable, Sendable {
  public static let currentVersion = 2
  public var version: Int                        // hard-coded to 2
  public var general: GeneralSettings            // Appearance + editors
  public var notifications: NotificationsSettings
  public var developer: DeveloperSettings
  public var repositories: [ProjectID: RepositorySettings]
}
```

Sub-structs (fields chosen now to unblock T2/T3/T4; populated/extended
only by their respective owners):

- `GeneralSettings`
  - `appearance: AppearancePreference` (enum `.system / .light / .dark`,
    default `.system`) — controls Appearance radio (M4.1; preview only).
  - `defaultEditorID: EditorID?` — global editor default (migrated from
    v1 `Settings.defaultEditorID`).
  - `customEditors: [CustomEditor]` — migrated from v1 `Settings.customEditors`.
- `NotificationsSettings` — superset of the existing C6 type:
  - `mute: MuteSettings` (already in `CodansCore/Notifications/MuteSettings.swift`).
  - `authStatus: AuthorizationStatusCache` (existing).
  - `neverPrompt: Bool`, `notNowUntil: Date?` (existing).
  - Plus three UI-owned toggles for M5 (inactive in T1; set by T2):
    `inAppEnabled: Bool`, `systemEnabled: Bool`, `soundEnabled: Bool`,
    `dockBadgeEnabled: Bool`. The last one is a rename over
    `mute.badgeEnabled` — see Migration.
- `DeveloperSettings` — empty struct in T1 with a
  `cli: DeveloperCLISettings` placeholder `{ lastInstallAttemptAt: Date? }`,
  reserved so T3 can extend without shape churn.
- `RepositorySettings` — **reserved-empty in T1**: no fields declared,
  no optionals added. T4 (or a future wave) is free to add fields
  without a schema version bump because an empty `{}` object decodes
  cleanly into `RepositorySettings()` and re-encodes identically. Per-
  Repo user data that does exist today (default-editor override,
  worktree base directory) stays on `Project` in `catalog.json` and is
  reached via `HierarchyManager`. `hookOverrides` is deliberately *not*
  added now: its shape (`[HookID: Bool]`? `[HookID: HookOverride]`?) is
  unknowable without T4's design, and adding a reserved map of a
  to-be-decided element type commits us to migration later. The clean
  choice is to omit it entirely.

All sub-structs get `init` defaults so reading a minimally-populated
settings.json yields a working tree.

#### `SettingsStore` — unified mutate API (frozen contract)

```swift
@MainActor @Observable
final class SettingsStore {
  private(set) var settings: Settings

  // Atomic top-level replace (tests / migration only).
  func replaceAll(_ new: Settings)

  // Section-scoped mutators. Each schedules a 500 ms debounced save.
  func mutateGeneral(_ transform: (inout GeneralSettings) -> Void)
  func mutateNotifications(_ transform: (inout NotificationsSettings) -> Void)
  func mutateDeveloper(_ transform: (inout DeveloperSettings) -> Void)
  func mutateRepository(
    _ projectID: ProjectID,
    _ transform: (inout RepositorySettings) -> Void
  )
  // Convenience, reused by existing editor code.
  func setDefaultEditorID(_ id: EditorID?)
  @discardableResult func addCustomEditor(_ editor: CustomEditor) -> Result<Void, EditorTemplateError>
  @discardableResult func updateCustomEditor(id: EditorID, _ transform: (inout CustomEditor) -> Void) -> Bool
  @discardableResult func removeCustomEditor(id: EditorID) -> Bool
  // Appearance convenience (M4.1).
  func setAppearance(_ appearance: AppearancePreference)

  // Persistence controls (already present).
  func saveNow() throws
  func flush()
}
```

Contract rules:
- Each mutator reads-modifies-writes `settings.<sub>` via `inout` so
  partial trees stay in sync.
- Every mutator schedules a single debounced save — the same 500 ms
  pattern used today.
- `mutateRepository` creates a default `RepositorySettings()` on first
  access so pane code never worries about "is this project in the map".
- Because `RepositorySettings` is empty in T1, the store GCs any map
  entry that encodes to `{}` on the next save, keeping settings.json
  free of useless empty objects.
- Per-Project *catalog* preferences (`defaultEditorID` override,
  `worktreeBaseDirectoryPath`) are **not** on `SettingsStore`. T4 writes
  them through `HierarchyClient.setDefaultEditor` (already exists) and
  a new `HierarchyClient.setWorktreeBaseDirectory` (T4 adds), which
  persist through `CatalogStore`. This keeps the catalog as the single
  source of truth for per-Project metadata.

#### `NotificationSettingsReader` protocol (T2 + coordinator contract)

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

- `SettingsStore` conforms directly via computed properties that read
  `settings.notifications.*`.
- `NotificationCoordinator` and `InboxClient.live` take a
  `NotificationSettingsReader` where they currently take
  `NotificationSettingsStore`.
- Writes from inside coordinator (auth status cache, neverPrompt, notNowUntil)
  flow through `settingsStore.mutateNotifications { ... }`.
  The coordinator is passed the `SettingsStore` for writes or, in tests,
  a fake that implements the same reader protocol + a paired mutate
  closure. T1 chooses "pass both reader and a `MutateClosure`" rather
  than widening the protocol so the reader surface stays read-only for
  views that only render.

#### `SettingsWindowFeature` — reducer shape

```swift
@Reducer
struct SettingsWindowFeature {
  @ObservableState struct State: Equatable {
    var selection: SettingsSection?       // nil ⇒ render .general in view
    var general: EditorFeature.State = .init()
    // T2/T3/T4 add child states here behind a Wave-1-introduced
    // `TODOPaneFeature.State` placeholder keyed by SettingsSection.
  }
  enum Action: Equatable {
    case selectionChanged(SettingsSection?)
    case general(EditorFeature.Action)
    case windowClosed           // drops selection, per M16
  }
}
```

The window also reads the live project list from `HierarchyClient.snapshot()`
to build the sidebar rows; the reducer only stores selection, not the
project list. This mirrors how `RootFeature.State.selection` works today
— the catalog is the single source of truth for "what exists".

#### `SettingsWindowView` — detail switch (frozen contract)

```swift
switch effectiveSection {
case .general:
  SettingsGeneralView(store: /* .general scope */)
case .notifications:
  NotificationsSettingsView()          // placeholder; body replaced by T2
case .developer:
  DeveloperSettingsView()              // placeholder; body replaced by T3
case .shortcuts, .updates:
  ComingSoonPane(title: ...)
case .about:
  AboutSettingsView()
case .repositoryGeneral(let pid):
  RepositoryGeneralSettingsView(projectID: pid)   // placeholder; T4
case .repositoryHooks(let pid):
  RepositoryHooksSettingsView(projectID: pid)     // placeholder; T4
}
```

Placeholder view files are committed in T1 as `struct ... { var body: some View { Text("TODO: supplied by T?") } }`
so the switch compiles and previews are safe. T2/T3/T4 replace only the
view body, never the switch case.

#### General pane composition (T1 implementation)

`SettingsGeneralView` owns three vertically stacked sections:

1. **Appearance.** A `Picker` bound to `settings.general.appearance`
   (System / Light / Dark), written via `SettingsStore.setAppearance(_:)`.
   Immediately under the picker a caption reads:

   > Preview — themes will ship in a later release.

   Styled `.font(.caption)` + `.foregroundStyle(.secondary)` per the
   app's existing caption pattern (see `SettingsEditorSection.swift`).
   The picker stays fully enabled; writes land in settings.json and
   survive relaunch. No alert, no disabled state.
2. **Default editor.** Reuses `EditorFeature.State.globalDefault` +
   `.setGlobalDefault(_:)`, lifted from the current
   `SettingsEditorSection.swift`.
3. **Built-in editors list** + **Custom editors list.** Lifted
   verbatim from `SettingsEditorSection.swift` into
   `SettingsGeneralView`. The Add-editor sheet keeps its current
   `@State`-local draft (M16 note: unsubmitted draft is *not*
   preserved across close).

#### About pane composition (T1 implementation)

`AboutSettingsView` reads app metadata from `Bundle.main` rather than
hard-coding strings, so localisation / rebranding happens in one place:

- Title / display name: `Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? "CFBundleName"`.
- Short version + build: `CFBundleShortVersionString` + `CFBundleVersion`
  (already surfaced by `AppState.bundleVersion()`).
- Copyright: `Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String`.
  If the key is missing — Info.plist is the single source of truth — the
  line is omitted rather than substituted with a constant, so the absence
  is obvious in Xcode when setting up a new build config.
- Website link is a placeholder `Text` (spec M8 says "官网占位链接");
  no real URL is hard-coded.

### Data Storage

One file, one schema, `~/.config/codans/settings.json`:

```jsonc
{
  "version": 2,
  "general": {
    "appearance": "system",
    "defaultEditorID": "vscode",
    "customEditors": [/* ... */]
  },
  "notifications": {
    "mute": { "enabled": true, "badgeEnabled": true, "...": "..." },
    "authStatus": "authorized",
    "neverPrompt": false,
    "notNowUntil": null,
    "inAppEnabled": true,
    "systemEnabled": true,
    "soundEnabled": true,
    "dockBadgeEnabled": true
  },
  "developer": { "cli": { "lastInstallAttemptAt": null } },
  "repositories": {}          // reserved-empty slot; see Repository scope below
}
```

Atomic-rename write via `AtomicFileStore`, 500 ms debounce, synchronous
`flush()` on `applicationWillTerminate`. Pretty-printed + sorted keys so
the file is diff-friendly.

#### File permission invariant

`settings.json` must be `0600`. The bit is set **inside**
`AtomicFileStore.writeAndFsync` where the temp file is `open(2)`'d with
`O_CREAT|O_WRONLY|O_TRUNC, 0o600` (existing behavior) — `rename(2)`
preserves the mode, so the final file inherits `0600` without a
follow-up `chmod`. `SettingsStore` deliberately does *not* apply its own
`chmod` on top; doing so outside the atomic write introduces a tiny
window during which a reader could see the file at `0644` before the
`chmod` lands. Anyone changing `AtomicFileStore` must preserve this
invariant.

#### Repository scope — what lives where

- `Project.defaultEditor: EditorID?` — stays on `Project` (catalog.json).
  Written by `HierarchyManager.setDefaultEditor` (existing), surfaced
  by T4's Repository General pane via `HierarchyClient.setDefaultEditor`.
- `Project.worktreesDirectory: String?` — stays on `Project`
  (catalog.json). T4 adds `HierarchyClient.setWorktreeBaseDirectory`
  and surfaces it. T1 does **not** change `Project`, the `Catalog`
  shape, or `HierarchyClient`.
- `Settings.repositories: [ProjectID: RepositorySettings]` — reserved
  for future per-Repo settings that do *not* belong on the catalog
  (e.g. "last time I opened the Hooks pane" or user-visible
  overrides that should not round-trip through `codans catalog import`).
  Empty `RepositorySettings` in T1; T4+ may add fields without
  breaking compatibility.

#### `ProjectID` wire format

- Settings side: `ProjectID` is the map key in `repositories` and the
  associated value on `SettingsSection.repositoryGeneral(_)` /
  `.repositoryHooks(_)`.
- Wire form: **the same RawValue string Catalog uses today** (UUID).
  We declare this explicitly so a field renamed on the catalog side
  cannot silently break settings decoding. The Swift types
  (`ProjectID`) already derive Codable from the UUID-backed base
  identifier (`CodansCore/IDs.swift`); the settings Codable
  reuses that derivation, no bespoke converter.
- **Lenient decode of unknown keys.** The decoder walks the
  `repositories` dictionary as `[String: RepositorySettings]` first,
  then filters keys that fail to parse as `ProjectID`. Invalid keys are
  dropped with a log line rather than aborting the decode. This makes
  the file tolerant of hand-edits and of a future ProjectID format
  change.
- **Orphan GC is out of scope for T1.** If a Project is removed from
  the catalog, its `repositories[projectID]` entry (when eventually
  populated) is not auto-purged. Spec Open Question #3 ("Repository
  条目的垃圾回收") flags this — T1 leaves it as future work.

#### Migration — v1 → v2 (M14)

V1 is "unversioned-or-version-1-with-at-most-one-of-two-schemas" because
today's two writers both declared `version: 1` but populated disjoint
subsets of top-level keys:

- `SettingsStore` (editor): `{version:1, defaultEditorID, customEditors}`.
- `NotificationSettingsStore`: `{version:1, notifications: {...}}`.

The union file `{version:1, defaultEditorID, customEditors, notifications}`
is also legal when the two stores happened to write non-overlapping fields.

Migration algorithm (executed exactly once on first v2 load; only
`settings.json` is touched — `catalog.json` / `hooks.json` are out of
scope):

1. Attempt v2 decode. If it succeeds, return.
2. Else attempt **v1 shape** decode: a permissive `LegacyV1Settings`
   Codable that reads optional `defaultEditorID`, `customEditors`,
   `notifications`, plus the `version` header (only `== 1` accepted).
3. If the legacy shape matches, map fields into a fresh `Settings.default`:
   - `general.defaultEditorID = legacy.defaultEditorID`
   - `general.customEditors = legacy.customEditors ?? []`
   - `general.appearance = .system` (new default).
   - `notifications.mute = legacy.notifications?.mute ?? .defaults`
   - `notifications.authStatus = legacy.notifications?.authStatus ?? .notDetermined`
   - `notifications.neverPrompt = legacy.notifications?.neverPrompt ?? false`
   - `notifications.notNowUntil = legacy.notifications?.notNowUntil`
   - `notifications.dockBadgeEnabled = legacy.notifications?.mute.badgeEnabled ?? true`
     (v1 `mute.badgeEnabled` is the closest analog; T2 may split
     semantics later without another migration because `mute.badgeEnabled`
     still exists alongside).
   - `notifications.inAppEnabled / systemEnabled / soundEnabled = true`
     (no analog in v1 — true preserves existing behavior where banners
     and sound were always emitted when authorised and non-muted).
   - `developer = .default`.
   - `repositories = [:]` (reserved-empty; no data to carry).
4. Rename the v1 file aside as
   `settings.json.v1-<yyyyMMdd-HHmmss>` using the existing
   `filesystemSafeTimestamp()`. The rename happens regardless of which
   legacy keys were present — so users know a migration ran.
5. Write the resulting v2 tree via the normal `saveNow()` path.
6. If **version is unknown (neither 2 nor legacy-parsable)**, continue
   the architecture-wide behavior: back the file up to
   `settings.json.broken-<ts>` (existing) and start from defaults.
   (Spec M14 calls for the same "backup + new file" escape hatch for
   unrecognised versions.)

No catalog or hooks file is touched. `Project.defaultEditor` and
`Project.worktreesDirectory` stay where they are; reads continue to
route through `HierarchyClient`.

#### Storage of transient UI state

The window's `selection` is *not* persisted. Spec M16 explicitly requires
"closing the window clears selection; reopen defaults to General".
`State.selection` lives only in the reducer and resets to `nil` on the
`windowClosed` action.

Custom-editor dialog draft state (Add editor sheet) is `@State` inside
the view, also not persisted — consistent with existing
`SettingsEditorSection.swift`.

### Component Boundaries

Modules and their directions:

```
apps/mac/
├── CodansCore/                (zero internal deps)
│   └── Settings/                 (new subfolder)
│       ├── Settings.swift        (v2 root)
│       ├── GeneralSettings.swift
│       ├── NotificationsSettings.swift  (extends existing C6 shape)
│       ├── DeveloperSettings.swift
│       └── RepositorySettings.swift
│   └── Editor/                   (unchanged — EditorID / CustomEditor / CommandTemplate / EditorValidators)
│
└── codans/App/Features/Settings/
    ├── SettingsStore.swift              (moved in from Settings/, owns v2)
    ├── SettingsWindowFeature.swift      (new reducer)
    ├── SettingsWindowView.swift         (new NavigationSplitView root)
    ├── Panes/
    │   ├── SettingsGeneralView.swift    (wraps EditorFeature + Appearance)
    │   ├── AboutSettingsView.swift      (M8)
    │   ├── ComingSoonPane.swift         (M7)
    │   ├── NotificationsSettingsView.swift   (placeholder; T2 replaces body)
    │   ├── DeveloperSettingsView.swift        (placeholder; T3 replaces body)
    │   ├── RepositoryGeneralSettingsView.swift (placeholder; T4 replaces body)
    │   └── RepositoryHooksSettingsView.swift   (placeholder; T4 replaces body)
    └── Sidebar/
        └── SettingsSidebarView.swift
```

- `Settings` v2 Codable lives in `CodansCore/Settings/` so the CLI
  (`codans`) can decode in future (spec M6 Developer "Copy app version"
  and beyond). Placement is a mild expansion of the existing
  `CodansCore/Editor/Settings.swift` convention. Tuist
  `buildableFolders` recurses, so no `Project.swift` edit is required.
- `SettingsStore` lives in the app target; it references the core
  model directly.
- `NotificationSettingsReader` protocol is defined in the app target
  alongside the coordinator (it references app-target types like
  `SettingsStore`, so lives here).

Dependencies:
- `CodansCore/Settings` depends on `CodansCore` core types
  (`ProjectID`, `EditorID`, `CustomEditor`, `MuteSettings`).
- App target depends on `CodansCore` — unchanged.
- `RootFeature` loses its `settingsSheet` state and effects; the
  sheet-based delegate action from `WorktreeHeaderFeature`
  (`showCustomEditorsSettings`) is rerouted to an
  `OpenWindowAction`-style effect that opens `settings` via
  `EnvironmentValues.openWindow`. Concrete wiring: a new
  `SettingsWindowPresenter` client (TCA dependency) whose
  `.live` closes over `@Environment(\.openWindow)` obtained inside
  `CodansApp.body` and injected via `.withDependencies`.

Legacy code removed:
- `SettingsSheetFeature`, `SettingsSheetView`, `SettingsEditorSection`
  (logic folded into `SettingsGeneralView`).
- `NotificationSettingsStore` entirely. `CodansSettings` /
  `NotificationsSettings` v1 types moved: the v1 `NotificationsSettings`
  shape is kept for the legacy-decode path (LegacyV1Settings) but
  not as the in-memory model.

### Persistence lifecycle integration

`AppState.bringUp()`:

- Constructs one `SettingsStore()`.
- The store's initializer handles v1→v2 migration (see Data Storage).
- `AppState.notificationSettingsStore` is removed; dependents consume
  the new `SettingsStore` through `NotificationSettingsReader` /
  `SettingsStore` mutate closures.
- `flushAllPersistedState()` calls only `settingsStore.flush()` for
  the settings file; `inboxStore.saveNow()` + `notificationBootstrap`
  survive unchanged because they write different files.

`CodansApp.body`:

```swift
Window("Settings", id: "settings") {
  if let store = appState.settingsWindowStore {
    SettingsWindowView(store: store, ...)
  }
}
.commands {
  CommandGroup(replacing: .appSettings) {
    Button("Settings…") { openWindow(id: "settings") }
      .keyboardShortcut(",", modifiers: .command)
  }
  // Existing MainWindowCommands preserved.
}
```

`appState.settingsWindowStore` is a single long-lived
`StoreOf<SettingsWindowFeature>` built during `bringUp()`, so M16's
"draft state persists across close/reopen" is satisfied without
extra plumbing.

## Alternatives Considered

### A1. Move per-Project fields from `Project` (catalog.json) into `Settings.repositories`

Hoist `Project.defaultEditor` and `Project.worktreesDirectory` into
`Settings.repositories[projectID]` and remove them from `Project`, with
a v1→v2 co-migration that walks the catalog and populates the settings
map.

- Pros: "one settings file for all user preferences", which reads as a
  literal interpretation of M13.
- Cons: (1) T1 scope balloons — EditorClient, `HierarchyClient.setDefaultEditor`,
  worktree-creation code in `HierarchyManager`, every `Project(...)`
  fixture in tests, and the catalog's own Codable all have to move in
  lockstep; (2) `ProjectID` is a random UUID generated at catalog
  `addProject` time, so removing a Project and re-adding it loses the
  per-Repo override — this is a real UX regression that settings-side
  storage does not fix (it is spec Open Question #3 and is not solvable
  by rehousing the field); (3) it conflates "user preferences" with
  "project metadata" — hooks live in `hooks.json`, catalog structure
  lives in `catalog.json`, settings live in `settings.json`; that
  three-way split is the intended responsibility boundary and M13's
  real intent is "no two writers touch one file", not "one file for
  everything".
- Verdict: rejected. M13 is a *writer-overlap* invariant, not a
  centralization mandate. Keep per-Project fields on the catalog.

### A2. Per-section files under `~/.config/codans/` (e.g. `settings/general.json`)

- Pros: writers do not share a file so the keys-overwrite bug becomes
  structurally impossible.
- Cons: three+ files to upgrade and back up; `applicationWillTerminate`
  has to flush N stores; product spec M14 explicitly describes
  "the (single) settings.json" history; existing persistence invariants
  ("atomic-rename JSON with top-level `version`") target single files.
- Verdict: rejected — over-solves the problem and increases migration
  surface.

### A3. Keep the sheet, move panes into a TabView within it

Cheaper shell, but violates M1 ("独立窗口") and M16 ("一边调整设置
一边观察主窗口") in letter and spirit. Rejected by the product spec.

### A4. Persist sidebar `selection` across app restarts

- Pros: less cognitive cost when a user was mid-edit in a Repository
  pane and relaunches.
- Cons: spec M16 explicitly requires "reopen defaults to General";
  violating it needs a spec change, not a design choice.
- Verdict: rejected — it is a product decision, not a technical one.

### A5. Separate `SettingsWindowFeature` into per-section reducers for T2/T3/T4 to own

We scope `SettingsWindowFeature` to the shell only; each pane is its
own `@Reducer` composed at the window level. This is already the chosen
shape (see "Component Boundaries"); listed here to capture the trade-off
versus a monolithic window reducer: per-pane reducers trade a bit of
Scope wiring for the ability for T2/T3/T4 to land pane-local reducers
without colliding.

## Cross-Cutting Concerns

### Security / Privacy

- Settings file remains `0600`-private under `~/.config/codans/`
  (existing `AtomicFileStore` policy).
- No new secrets stored. Appearance, editor IDs, per-Project paths are
  all user-visible.
- Migration backup `settings.json.v1-<ts>` inherits the `0600` mode
  from the original inode (rename preserves permissions).

### Observability

- Reuse `os.Logger(subsystem: "com.gumpw.codans.persistence", category: "settings")`.
- Add one additional category `category: "migration"` for v1→v2
  migration traces: whether the load saw v2 / v1 / unknown, which legacy
  keys were carried forward, the backup filename. Enough to debug a
  user report without reading the settings file.

### Testing strategy

- `SettingsStoreTests`: rewrite around v2. Add explicit cases for
  (a) v1 editor-only file migrates, (b) v1 notifications-only file
  migrates, (c) combined v1 file migrates, (d) unknown version
  backs up + defaults, (e) each mutate API debounces + schedules a
  save, (f) empty `RepositorySettings` entry is GCed on next save,
  (g) unparseable `repositories` key is dropped with a log line and
  the rest of the file still decodes.
- `NotificationSettingsStoreTests`: deleted or redirected to a new
  `NotificationSettingsReaderTests` that drives the reader from a
  hand-rolled `SettingsStore`.
- `C6AppBootstrapTests`: extend to assert the coordinator is
  constructed with a `NotificationSettingsReader` + mutate closure,
  and that mutations round-trip through `SettingsStore.settings`.
- `RootFeatureTests`: drop the `settingsSheet` presentation
  assertions; add one test that `worktreeHeader(.delegate(.showCustomEditorsSettings))`
  now invokes the `SettingsWindowPresenter` open effect.
- `EditorFeatureTests`: unchanged with respect to `project.defaultEditor`
  — the catalog still owns the field. Only tests that previously
  reached into `NotificationSettingsStore` need updating.
- Manual verification: walk spec Acceptance Criteria in the T1 slice —
  open/focus, sidebar empty-project list, General round-trips after
  restart, upgrade from hand-authored v1 fixtures, Shortcuts / Updates
  placeholder, About contents, Repositories empty state.

### Rollback

- If the migration corrupts state, user lands on defaults; the v1 file
  is preserved verbatim as `settings.json.v1-<ts>`. Manual rollback is
  "copy the backup back over settings.json after reverting the app".
- The change is not landed in a feature flag because the shell is
  in-window; there is no "old sheet" path behind it to keep. The cost
  of a flag is doubled UI maintenance during T2/T3/T4 — worse than
  a clean cutover.

## Risks

- **R1: Migration misreads a partial v1 file and corrupts settings.**
  Mitigation: decode v2 first (unchanged-file case), fall back to a
  permissive `LegacyV1Settings` whose fields are all optional, and only
  treat missing fields as "default value" rather than "failure". Back
  the original aside before the first write of v2 so the original is
  always recoverable. Unit tests cover the three known v1 shapes.
- **R2: Parallel T2/T3/T4 wave breaks the frozen contracts.**
  Mitigation: the contracts live in their own files (`SettingsSection.swift`,
  `Settings.swift` sub-structs, `SettingsStore.swift`, `NotificationSettingsReader.swift`)
  and land in the first T1 PR. T2/T3/T4 pane branches edit the pane
  view bodies only; the detail switch is frozen. Any contract change
  is a co-ordinated master-mediated revision.
- **R3: Scope creep back into `Project` / `Catalog`.**
  Mitigation: `Project.defaultEditor` / `Project.worktreesDirectory`
  stay on the catalog. T1 does not open the catalog Codable, does not
  touch `HierarchyManager`, and does not rewrite the `Project(...)`
  fixtures. Alternative A1 (hoist into settings.json) was considered
  and rejected; see Alternatives Considered.
- **R4: `openWindow(id: "settings")` re-creates a new store each time.**
  Mitigation: store construction is driven by `AppState`, not by the
  SwiftUI scene body. The scene view reads a weak reference; re-opens
  find the existing store alive and focus the window rather than
  rebuilding. Verified via Xcode debug scene graph in exec-plan
  verification.
- **R5: Notifications coordinator relies on write-through to reach
  `settings.notifications.authStatus`.**
  Mitigation: coordinator now takes both the reader and a mutate
  closure; pass `settingsStore.mutateNotifications` directly. A
  `C6AppBootstrapTests` test asserts that a mutation on the closure
  is visible to the reader within the same test run.
- **R6: Escaping the "settings.json" shared-file hazard re-opens it
  via a future feature.**
  Mitigation: keep `SettingsStore` the only writer. A code-review
  rule (and, later, a `make mac-inspect-dependencies` check) flags
  any other `AtomicFileStore.write(..., to: Settings.defaultURL())`
  call site.

## Open Questions

All Q1–Q3 resolved by master review. See "Decisions" below.

### Decisions

- **D1 (Q1 resolved — master REVISE round 1):** Per-Project preferences
  stay on `Project` in `catalog.json`. `Settings.repositories` is kept
  as a reserved top-level slot but `RepositorySettings` is empty in T1.
  T4's Repository General pane reads and writes `defaultEditor` /
  `worktreesDirectory` through `HierarchyClient`. T1 does **not** alter
  `Project`, the `Catalog`, or `HierarchyManager`. M13 is satisfied by
  the three-writer-three-file split
  (`settings.json` ↔ `SettingsStore`, `catalog.json` ↔ `CatalogStore`,
  `hooks.json` ↔ `HookConfigStore`), not by centralising all data on
  one file.
- **D2 (Q2 resolved):** About pane reads from `Info.plist` via
  `Bundle.main.object(forInfoDictionaryKey:)`. Canonical keys:
  `CFBundleDisplayName` (fallback `CFBundleName`), `CFBundleShortVersionString`,
  `CFBundleVersion`, `NSHumanReadableCopyright`. No in-code constants.
- **D3 (Q3 resolved):** Appearance picker stays enabled; caption below
  reads "Preview — themes will ship in a later release." — plain
  `.caption` / `.secondary` style, no dialog, no disabled state. User
  can still select a value and it persists across relaunch.
