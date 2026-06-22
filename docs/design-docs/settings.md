# Design Doc: Settings — Window, Persistence, and Per-Project Preferences

**状态：** 已上线（可见）
**Author:** Gump (with Claude)

## Context and Scope

Settings is one durable subsystem with two faces:

- a standalone macOS **Settings window** (`Window(id: "settings")`, opened with
  `⌘,`) carrying global preferences plus a per-Project subtree;
- a single on-disk document `~/.config/codans/settings.json` owned by one
  writer, `SettingsStore`.

User-facing behavior and acceptance criteria live in
[ui-settings-window.md](../product-specs/ui-settings-window.md). This doc records
the durable invariants and the non-obvious *why* behind the persistence model,
the v3 per-Project schema, and the notification-gating semantics — not the
SwiftUI layout, which is free to change.

The design has three persisted documents under `~/.config/codans/`, each a
single-writer file with a top-level `version` and atomic-rename writes:
`settings.json` (this doc), `catalog.json` (the Project→Worktree→Tab→Pane tree),
and `hooks.json` (event subscriptions). Keeping them as **three single-writer
files** is the load-bearing decision — see "The single-writer invariant".

## Goals and Non-Goals

**Goals**

- One writer, one schema for `settings.json`; no two stores race the file.
- A v3 per-Project schema (`projects[ProjectID]: ProjectSettings`) that is the
  single home for every per-Project preference, with a nested
  `git: GitProjectSettings?` subtree for git-kind-only fields.
- A notification policy whose four toggles compose orthogonally and whose
  gating semantics are pinned (they were the original source of "persisted but
  inert" bugs).
- Migrations that land automatically and are recoverable: v1/v2 → v3 in place,
  with the original file preserved aside.

**Non-Goals**

- Per-Worktree overrides. The override hierarchy is global → Project; every
  override field is `Optional` so a future worktree tier is purely additive.
- A per-repo checked-in config file (team-shared config overlaid on global).
  All Project settings live in the user-global `settings.json`.
- A general settings import/export UI; sidebar search.

## The single-writer invariant

A single `SettingsStore` owns the whole `Settings` tree and is the only writer
of `settings.json`. This guards against the failure mode that motivated the
design: **two** `@MainActor` stores writing the same file — an editor store
owning `{version, defaultEditorID, customEditors}` and a notifications store
owning `{version, notifications}` — both decoding through `AtomicFileStore`,
both rewriting the file in full from a narrow schema, so the last writer
silently wipes the other's keys. One store owning the whole tree closes that
class of bug.

The invariant generalizes: **"different writers must not clobber one file" is a
writer-overlap rule, not a centralization mandate.** The correct split is
three single-writer files —
`settings.json` ↔ `SettingsStore`, `catalog.json` ↔ `HierarchyManager` (via its
store), `hooks.json` ↔ the hook config store. Hoisting catalog or hook data
into `settings.json` to satisfy a literal "one file for everything" reading was
rejected (Alternatives A1): it conflates *user preferences* (settings) with
*structural layout* (catalog) and *event subscriptions* (hooks), and forces a
coin-flip on where each new field lives.

## Persistence model (`SettingsStore` + `AtomicFileStore`)

`SettingsStore` is a single `@MainActor @Observable` class holding the whole
`Settings` value and exposing section-scoped mutators — `mutateGeneral`,
`mutateNotifications`, `mutateDeveloper`, `mutateWorktree`, `mutateProject` —
each a read-modify-write over a sub-struct via `inout` that schedules **one
debounced atomic save**. Views and reducers read live state through the store
and write through these mutators; nothing else opens the file.

**File permission invariant — 0600, set once, inside the atomic write.** The
temp file is `open(2)`'d `O_CREAT|O_WRONLY|O_TRUNC, 0o600` and `rename(2)`
preserves the mode, so the final file inherits `0600` with **no follow-up
`chmod`**. A second `chmod` outside the atomic write would open a window where a
reader sees the file at `0644` before the mode lands. Anyone touching
`AtomicFileStore` must preserve this — do not add a post-write `chmod`.

**Reader contract for sibling readers.** Any code reading `settings.json`
outside `SettingsStore` must go through the same versioned-decode-or-migrate
path (`SettingsMigration.load`), never hand-decode the file. The file is
**atomic-rename + top-level `version` + migrate-in-place-with-backup**; a reader
that probes raw JSON will desync the moment a migration runs.

**Garbage collection before save.** `Settings.garbageCollect()` drops
`projects[pid]` entries whose `ProjectSettings.isEffectivelyEmpty` is true and
collapses an effectively-empty `git: GitProjectSettings()` to `nil`, so
`settings.json` never accumulates useless `{}` objects. This is what lets
follow-up waves add per-Project fields without a schema bump (an empty entry
round-trips as absent).

## v3 per-Project schema

The unit of per-Project preference is a **`Project`**, never a "Repository".
The two kinds are `git_repo` (git-managed) and `dir` (a plain folder); the
type that distinguishes them is:

```swift
public nonisolated enum ProjectKind: String, Codable, Hashable, Sendable {
  case gitRepo = "git_repo"
  case dir     = "dir"          // rawValue is "dir", not "plain_dir"
}
extension Project { public var kind: ProjectKind { gitRoot == nil ? .dir : .gitRepo } }
```

`kind` is **derived from `gitRoot`, never persisted** — a second stored field
would drift the moment a user runs `git init` / `rm -rf .git`. The next catalog
refresh flips `kind` for free. The UI reads it via `HierarchyClient.kind(of:)`
so reducers need only a `ProjectID`, not a full `Project` snapshot.

```swift
public nonisolated struct Settings {            // currentVersion = 3
  var version: Int
  var general: GeneralSettings
  var developer: DeveloperSettings
  var worktree: WorktreeSettings
  var projects: [ProjectID: ProjectSettings]
  var notifications: NotificationsSettings
}

public nonisolated struct ProjectSettings: Equatable, Codable, Sendable {
  var defaultEditor: EditorID?         // nil = inherit the global default editor
  var worktreesDirectory: String?      // no-op on `dir`
  var envVars: [String: String]
  var scripts: [ScriptDefinition]
  var git: GitProjectSettings?         // nil for `dir`, or when no git overrides
}
```

Durable schema decisions:

- **Top-level key is `projects` (value `ProjectSettings`), not `repositories`
  (value `RepositorySettings`).** Vocabulary unification: everything else in the
  product model is "Project"; the v2 `Repository*` naming leaked into JSON keys,
  test names, and the sidebar, and fought every other call site.
- **`ProjectID` is encoded as a UUID-string-keyed object.** Decoding is
  **lenient**: the decoder walks `projects` as `[String: ProjectSettings]` and
  drops keys that fail to parse as `ProjectID` (logged, not fatal), so a
  hand-edit or a future ID-format change can't abort the whole load. Same
  policy applies to unparseable keys elsewhere in the file.
- **Single home for per-Project preferences.** Every user-editable per-Project
  field lives on `projects[pid]`; `Project` in `catalog.json` retains only
  identity/structure. The earlier split (editor/worktree-dir on the catalog,
  GitHub overrides on settings) forced two files to own two halves of one
  mental slice — reversed here.
- **Git-only fields nest under `git: GitProjectSettings?`, not a sum type.**
  Nested-`Optional` makes a `git_repo ↔ dir` flip (the user runs `git init` or
  deletes `.git`) a **no-op**: the universal fields stay put and `git` is simply
  present or absent. A sum type (`enum { case git(...), case dir(...) }`) would
  turn that user-triggered transition into a data migration that re-keys JSON
  arms and hand-copies common fields. Rejected (Alternatives A2).
- **Universal fields apply to both kinds.** `defaultEditor` and
  `worktreesDirectory` sit at the top level even though `worktreesDirectory` is
  a no-op for `dir`; carrying it universally keeps the data model uniform and a
  later `git init` upgrade picks it up at no cost.

**Resolving per-Project fields (post-migration invariant).** The `catalog.json`
encoder **does not write** `Project.defaultEditor` / `worktreesDirectory` (both
are permanently `nil` in the snapshot). Every reader MUST resolve those two
fields via `SettingsStore` / `settings.projects[pid]`, **never** off the
`Project` struct — which silently yields `nil`, read by callers as "use global
default". This is the most common drift trap in this subsystem.

## 技术决策 — schema 迁移记录

The schema is **v3** today (`Settings.currentVersion = 3`). The records below
pin the load-bearing *why* behind how the loader still ingests every historical
shape; they are not part of the steady-state read/write path.

The migration entry point in code is **`SettingsMigration.load`** with
`typealias SettingsMigration.CatalogOverrides`
(`= [ProjectID: (defaultEditor:, worktreesDirectory:)]`) in `CodansCore`.
[architecture.md](../architecture.md) narrates the same one-shot fold under the
name **`HierarchyManager.drainLegacyOverrides`** — same mechanism, two names;
the code-side authority is `SettingsMigration`.

- **Three accepted shapes; v3 is the fast path.** `SettingsMigration.load`
  decodes v3 directly (`Settings.init(from:)` is strict v3-only; a no-op,
  idempotent, no disk write) and catches `unsupportedVersion(2)` /
  `unsupportedVersion(1)` to run the legacy folds out-of-band. v1 lifts
  **straight to v3** (it skips v2 entirely — a v1 file never had a `repositories`
  dict). The original file is renamed aside (`settings.json.v1-<ts>` /
  `settings.json.v2-<ts>`) **before** the v3 write lands, so a botched migration
  is always recoverable. The decoder itself stays pure (v3-only); the
  legacy-shape handling and the catalog fold live in `SettingsMigration.load`.
- **v1 carries forward only `defaultEditorID`.** The permissive `LegacyV1Settings`
  decode reads `version` and `defaultEditorID`; missing fields map to defaults,
  not failures. The retired C8 `customEditors` array is ignored on migration
  (C8a). v1 had no notifications section, so nothing maps into
  `NotificationsSettings` from the v1 path.
- **v2 → v3 fold.** Map each `repositories[pid]` value into a `ProjectSettings`
  whose `git` holds the three GitHub fields; then fold the per-Project
  `defaultEditor` / `worktreesDirectory` read from `catalog.json` into the same
  `projects[pid]`. This requires catalog access at settings-load time and so
  runs after `HierarchyManager` has loaded. Vocabulary unification rides on the
  same fold: the v2 `repositories` key (value `RepositorySettings`) becomes
  `projects` (value `ProjectSettings`), retiring the `Repository*` naming that
  had leaked into JSON keys, test names, and the sidebar.
- **Migration crash window (ordering invariant).** Draining the catalog only
  *schedules* a debounced save, while the settings v2→v3 commit is synchronous.
  A crash between them would drop overrides permanently — `settings.json` is
  already v3, so the migration never re-runs. **The catalog must be written
  synchronously first** (`saveNow` before the settings commit) when legacy
  overrides are non-empty: then a crash before the settings write re-runs the
  fold next boot against an already-clean catalog (the two fields read `nil`),
  producing no duplicates.
- **Per-file, not atomic.** Each persisted file migrates independently on its
  own load path, so one file's migration failing can't corrupt the others. An
  unrecognised `version` routes the file aside as `*.broken-<ts>` and starts
  from defaults (the architecture-wide escape hatch).

## Notification gating (`NotificationsSettings`)

`NotificationsSettings` is the `notifications` section of `settings.json`. Its
four delivery toggles are **orthogonal booleans, not a single `level` enum** —
users need crossings the enum can't express (in-app off + system on =
"background only"), and sound / Dock badge are independent dimensions on top.
The durable gating contract, which the notification coordinator (the single
policy chokepoint) enforces:

- **`inAppEnabled`** gates `inbox.append` (the bell unread list, and the Dock
  badge that derives from the inbox's unread count) but is **decoupled from the
  OS-post path** — a system banner can still fire with in-app off.
- **`systemEnabled`** is the **outer guard** on OS posts: false short-circuits
  before mute evaluation, so a disabled-system-banner path never even evaluates
  muting.
- **`soundEnabled`** is passed **per call** as `OSNotifier.post(playSound:)`,
  not stashed as adapter state — a stateful `playSound` property would race when
  a batch of posts straddles a settings flip.
- **`dockBadgeEnabled`** drives the Dock badge. `recomputeDockBadge` clears the
  badge unless **both** `inAppEnabled` and `dockBadgeEnabled` are on, so the
  badge is a strict subset of the inbox surface.

The inbox **is** the only in-app surface; there is no separate transient toast,
so gating it satisfies the "no in-app banner" requirement without building one.
Two distinct mute-style switches are easy to confuse and must stay distinct: a
top-level `enabled` short-circuits the whole pipeline (no inbox append at all),
whereas `mute.enabled` still appends to the inbox but silences OS post + badge +
sound. The full notification pipeline (detector → coordinator → sinks,
roll-up badges, command-finished suppression) is its own subsystem — see
[notifications.md](./notifications.md). This doc owns only the *settings* that
gate it.

## Settings window shell

The window is a standalone `Window(id: "settings")` scene driven by a
`SettingsWindowFeature` reducer over a `NavigationSplitView` (sidebar + detail).
Each pane composes as its own reducer or a direct view; the per-Project subtree
is held keyed by `ProjectID` and pruned when the catalog drops a Project.

Durable shell decisions:

- **Sidebar `selection` is transient, never persisted.** Closing the window
  resets it; reopening defaults to General. Persisting it was rejected as a
  product decision, not a technical one.
- **The sidebar group of Projects, and per-Project sub-rows, are driven by the
  live catalog**, not stored on the window — the catalog is the single source of
  truth for "what exists". `HierarchyClient.kind(of:)` returns `nil` for a gone
  Project; callers treat that as "this pane will be pruned next
  `.projectsChanged`".
- **`SettingsWriter` is the per-Project write seam.** `ProjectSettingsFeature`
  and the worktree-header "Open in" dropdown both write through `SettingsWriter`
  closures (`setProjectDefaultEditor`, `setProjectWorktreesDirectory`,
  `setProjectGitField`, `setProjectEnvVar`, `setProjectScripts`,
  `setProjectLifecycleScript`), whose live implementations chain into
  `SettingsStore.mutateProject(pid) { … }`. Per-Project writes do **not** route
  through `HierarchyClient` / the catalog (the storage-unification core).
- **Per-Project sub-rows are kind-conditional, but kind is never surfaced.** No
  icon, badge, or label distinguishes `git_repo` from `dir`; the only signal is
  which sub-rows / Sections appear. Users infer the distinction implicitly. The
  actual landed sidebar sub-rows under each Project are **General** and
  **Commands** (`SettingsSection.projectGeneral` + `.projectScripts`); the
  General pane renders editor/git-viewer/worktree/GitHub/environment as
  kind-conditional *Sections* internally rather than as separate sidebar rows.

## Lifecycle scripts vs hook subscriptions

Per-Project worktree **lifecycle scripts** (`setup` / `archive` / `delete`
shell commands on `GitProjectSettings`) run **inline and blocking** around the
matching catalog action and can **abort** it: a non-zero `setupScript` blocks
`createWorktree` (the on-disk dir is left, the catalog row is not added);
`archive` / `delete` are fail-warn (the action proceeds, the failure is logged).
This is deliberately distinct from `worktree.*` **hook subscriptions**, which
are async fire-and-forget and cannot block. The two are kept separate rather
than overloading the hook dispatcher with a "block-and-fail-the-event" mode —
the semantics (blocking-and-abortive vs fire-and-forget) are fundamentally
different. Lifecycle scripts run headless via a direct `Process` (cwd = worktree
path, env = the resolved Project env), not through a terminal surface.

## Risks

| Risk | Mitigation |
|---|---|
| A future feature re-opens the `settings.json` shared-file hazard. | `SettingsStore` is the only writer; flag any other `AtomicFileStore` write to `Settings`' URL in review. |
| Reader resolves per-Project `defaultEditor` off the `Project` struct (always nil post-migration) → silent "use global default". | Documented above; resolve via `settings.projects[pid]` only. |
| Mid-migration crash drops catalog overrides. | Synchronous catalog `saveNow` before the settings v2→v3 commit; idempotent re-fold next boot. |
| Catalog/Settings load-order coupling (fold needs catalog loaded first). | Sequenced in bring-up; settings load asserts the catalog is not still loading. |
| `kind` drift (stale `gitRoot` snapshot shows wrong sub-rows). | Re-derived on `.projectsChanged`; acceptable to show wrong rows for one catalog-refresh tick. |

## References

- Product spec: [ui-settings-window.md](../product-specs/ui-settings-window.md)
- Notification pipeline (gated by these settings): [notifications.md](./notifications.md)
- Schema authority: `apps/mac/CodansCore/Settings/{Settings,ProjectSettings,GitProjectSettings,NotificationsSettings,SettingsMigration}.swift`, `apps/mac/CodansCore/ProjectKind.swift`
- Single writer + atomic store: `apps/mac/codans/App/Features/Settings/SettingsStore.swift`
- Per-Project write seam: `SettingsWriter` in `apps/mac/codans/App/Features/Editor/EditorFeature.swift`; `apps/mac/codans/App/Features/Settings/{SettingsSection,ProjectSettingsFeature}.swift`
- On-disk file inventory + versions: [architecture.md](../architecture.md)
