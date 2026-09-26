# Design Doc: Settings — Window, Persistence, and Per-Project Preferences

**状态：** 已上线（可见）
**Author:** Gump (with Claude)

## Context and Scope

Settings is one durable subsystem with two faces:

- a standalone macOS **Settings window** (`Window(id: "settings")`, opened with
  `⌘,`) carrying global preferences plus a per-Project subtree;
- a single on-disk document `~/.config/codans/settings.json` owned by one
  writer, `SettingsStore`.

This doc records
the durable invariants and the non-obvious *why* behind the persistence model,
the v3 per-Project schema, and the notification-gating semantics — not the
SwiftUI layout, which is free to change.

The implemented settings and catalog stores use separate versioned documents
under `~/.config/codans/`: `settings.json` (this doc) and `catalog.json` (the
Project→Worktree→Tab→Pane tree), each with atomic-rename writes. A separate
`hooks.json` for event subscriptions is **planned, not implemented**; see
[lifecycle-hooks.md](./lifecycle-hooks.md). This is not an exhaustive inventory
of persisted files — see [architecture.md](../architecture.md). Keeping each
file owned by one writer is the load-bearing decision below.

## Goals and Non-Goals

**Goals**

- One writer, one schema for `settings.json`; no two stores race the file.
- A v3 per-Project schema (`projects[ProjectID]: ProjectSettings`) that is the
  single home for every per-Project preference, with a nested
  `git: GitProjectSettings?` subtree for git-kind-only fields.
- A notification policy whose four toggles compose orthogonally and whose
  gating semantics are explicit.
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
of `settings.json`. This prevents **two** `@MainActor` stores writing the same file — an editor store
owning `{version, defaultEditorID, customEditors}` and a notifications store
owning `{version, notifications}` — both decoding through `AtomicFileStore`,
both rewriting the file in full from a narrow schema, so the last writer
silently wipes the other's keys. One store owning the whole tree closes that
class of bug.

The invariant generalizes: **"different writers must not clobber one file" is a
writer-overlap rule, not a centralization mandate.** The correct split is
separate single-writer files —
`settings.json` ↔ `SettingsStore`, `catalog.json` ↔ `HierarchyManager` (via its
store), and, if lifecycle hooks are implemented, `hooks.json` ↔ its planned
hook config store. Hoisting catalog or hook data
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
`settings.json` never accumulates useless `{}` objects. An empty entry
round-trips as absent; additive optional fields use their decoding defaults.

## v3 per-Project schema

The unit of per-Project preference is a **`Project`**, never a "Repository".
`ProjectKind` is derived from the catalog in this order: `remoteHost != nil`
means `server`; `isWorkspace` means `workspace`; otherwise `gitRoot != nil`
means `git_repo`, and the remainder are `dir`. The kind itself is not encoded.
A local directory can become a Git project when catalog reconciliation finds
its repository; a workspace remains a workspace even when its root contains
Git metadata. See [Workspace](workspace.md) for member-repository ownership.

```swift
public nonisolated struct Settings {            // currentVersion = 3
  var version: Int
  var general: GeneralSettings
  var developer: DeveloperSettings
  var worktree: WorktreeSettings
  var projects: [ProjectID: ProjectSettings]
  var notifications: NotificationsSettings
  var agents: AgentSettings
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
- **Preference and catalog ownership.** Editor, environment, script, and Git
  overrides live on `settings.projects[pid]`. Project display name, icon, color,
  memberships, and hierarchy structure live on `Project` in `catalog.json`;
  their controls write through `HierarchyManager`. The Settings window does
  not imply that every value it displays belongs in `settings.json`.
- **Git-only fields nest under `git: GitProjectSettings?`, not a sum type.**
  Nested-`Optional` makes a `git_repo ↔ dir` flip (the user runs `git init` or
  deletes `.git`) a **no-op**: the universal fields stay put and `git` is simply
  present or absent. A sum type (`enum { case git(...), case dir(...) }`) would
  turn that user-triggered transition into a data migration that re-keys JSON
  arms and hand-copies common fields. Rejected (Alternatives A2).
- **Universal preference fields.** `defaultEditor` and
  `worktreesDirectory` sit at the top level even though `worktreesDirectory` is
  a no-op for `dir`; carrying it universally keeps the data model uniform and a
  later `git init` upgrade picks it up at no cost.

**Resolving per-Project fields.** `defaultEditor` and `worktreesDirectory`
are fields of `ProjectSettings`, not `Project`. Readers resolve them through
`SettingsStore` / `settings.projects[pid]`; the catalog owns identity and
structure.

## Schema migration

`Settings.currentVersion` is 3. `SettingsMigration.load` owns versioned
settings decoding and migration; `SettingsStore` owns the resulting live value.

- **v3:** decode directly without rewriting the file.
- **v1 → v3:** read `version` and `defaultEditorID` through the permissive
  `LegacyV1Settings` decoder. Missing fields use defaults; `customEditors` is
  ignored. Notification settings use defaults.
- **v2 → v3:** convert `repositories[pid]` to `projects[pid]`, nesting the
  GitHub overrides under `ProjectSettings.git`.
- **Optional catalog overrides:** the loader accepts
  `SettingsMigration.CatalogOverrides`, a map of per-Project editor and
  worktrees-directory values, for the v1/v2 migration paths. `SettingsStore`
  also accepts this map to seed a fresh file. Application bootstrap constructs
  `SettingsStore()` without this argument, so it does not transfer overrides
  from `catalog.json`. There is no cross-file migration transaction.

For v1/v2, the migration writes the v3 value to a sibling temporary file,
renames the original to `settings.json.v1-<ts>` or `settings.json.v2-<ts>`, then
renames the temporary file to the canonical URL. If the final rename fails,
it attempts to restore the original. A migration or backup failure puts
`SettingsStore` in an in-memory-only mode: saves are disabled to avoid
replacing the preserved source with defaults.

Unsupported versions and corrupt files are moved to `settings.json.broken-<ts>`
before defaults are used. A failure to preserve that source also disables
persistence. Source data must remain recoverable until the destination has
been persisted; clearing catalog fields before saving settings cannot provide
that guarantee.

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
- **`systemEnabled`** gates the OS-post path, independently of inbox delivery.
  The coordinator also requires authorized system notifications; it does not
  request authorization when processing a candidate.
- **`soundEnabled`** is passed **per call** as `OSNotifier.post(playSound:)`,
  not stashed as adapter state — a stateful `playSound` property would race when
  a batch of posts straddles a settings flip.
- **`dockBadgeEnabled`** drives the Dock badge. `recomputeDockBadge` clears the
  badge unless **both** `inAppEnabled` and `dockBadgeEnabled` are on, so the
  badge is a strict subset of the inbox surface.

The inbox **is** the only in-app surface; there is no separate transient toast,
so gating it satisfies the "no in-app banner" requirement without building one.
The schema has no top-level `enabled` or `mute.enabled` switch. `mute`
contains `mutedRuleIDs` and `mutedPaneIDs`; the Settings UI reports their
counts. Runtime Pane muting uses the `notifications:muted` label and drops
candidates in the detector before any delivery path. The stored mute sets
are not consulted by the detector or coordinator.

`statusBarBellEnabled`, `projectBellEnabled`, `worktreeBellEnabled`, and
`tabBellEnabled` control indicator visibility without changing inbox collection.
The full notification pipeline (detector → coordinator → sinks,
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
  resets it; reopening defaults to General so each Settings session starts
  from the global preferences.
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
- **Kind-specific content.** Project sidebar sub-rows are **General** and
  **Commands**. General, Editor, and Environment sections apply to every kind.
  Git projects and Servers also expose Worktree, GitHub, and Lifecycle sections;
  Workspaces instead expose their member Projects. Default icons reflect the
  Project kind and can be replaced by user-selected symbols, emoji, or images.

## General defaults and agent launch preferences

`general.defaultGitViewerID` defaults to `"built-in"`, including when the JSON
key is missing or null. This value opens the app-owned diff window and is not
an installed-editor registry entry. Registry cleanup preserves `"built-in"`
and resets unknown external Git viewer IDs to it. Editor overrides continue
to use `nil` for inheritance. See [Git Diff Viewer](git-diff-viewer.md).

`quitConfirmation = auto` prompts only for busy live Panes: foreground
commands, terminal progress, or agents in `working` / `blocked` state.
`always` and `never` override that decision; `quitAction` independently chooses
keep-running or snapshot behavior.

`projects[pid].git.launchAgentProfileOnWorktreeCreate` remembers the Create
Worktree sheet's agent selection. A missing, removed, or disabled profile
resolves to None. The chosen profile launches after setup and catalog
registration; a launch failure does not undo worktree creation. CLI creation
uses the profile explicitly requested by that command, not this remembered
sheet preference.

## Developer pane

Two sections use `DeveloperPaneDependencies` (`@Environment`): the `codans`
CLI symlink (`CLIInstallerClient`, privileged) and **Agent skills**. App version
information belongs to the About pane.

Both sections render through `InstallTargetRow`: the target's mark (24pt,
`AgentLogoView` — brand SVG for Claude Code / Codex, an SF Symbol for the
shared folder; the CLI row has none), its name, the path it lands at, a
status dot (green linked, grey absent, orange needs attention, no text),
and an Install / Uninstall button. A link to another build is offered
Install again in both sections; there is no separate Reinstall. Agent
skills ends with a Reveal in Finder button for the bundled skill; the CLI
card's status wording lives in button tooltips rather than a caption.

Agent skills is opt-in per agent. `SkillInstallModel` wraps the same
`SkillInstaller` (`CodansKit/Skills`) that `codans skill` uses, over the
bundle's `Resources/skills` (embedded from the repo's `skills/` at build
time); it offers every bundled skill × every target (Claude Code
`~/.claude/skills`, Codex `~/.codex/skills`, Shared `~/.agents/skills`)
whether or not the agent's folder exists, and each row is a symlink the
user creates (Install) or removes (Uninstall). A link to another build is
offered Install again; anything that is not a Codans skill link keeps a
disabled Install with a tooltip — the pane never replaces it (the CLI's
`--force` is the only way, deliberately). Nothing is linked automatically,
on launch or on update: an existing link keeps pointing at the bundle
path, so an app update updates the skill without the app doing anything.

## Lifecycle scripts vs hook subscriptions

Per-Project `GitProjectSettings` holds `createScript`, `archiveScript`, and
`deleteScript`. Their execution depends on the entry point:

- **Local sidebar creation:** `createScript` runs as the setup phase inside
  `GitWorktreeClient.createWorktreeStream`, in the new worktree, before the
  stream emits `finished` and the sidebar adds the catalog row. It runs via
  `/bin/bash -lc` with progress output in the pending row. A spawn failure or
  non-zero exit adds a progress message and still completes creation; it does
  not roll back the worktree. Stream cancellation terminates the tracked child.
- **Remote sidebar creation:** plain SSH `git worktree add`; this path does
  not execute `createScript`.
- **Sidebar archive/delete:** the reducer stops running project scripts, opens
  an Archive/Delete tab through `runWorktreeLifecycleScript`, and waits for its
  pane to finish before changing the catalog or removing the worktree. A
  non-zero script exit does not abort that action. The helper closes the script
  tab on successful exit.
- **CLI/RPC creation:** `HierarchyHandlers.createWorktree` materializes a
  missing local Git worktree through the shared creation pipeline when a branch
  is supplied. Effective copy/fetch preferences and `createScript` apply. An
  existing path is registered without setup; remote and plain-directory paths
  remain catalog-only. Workspace projects use the separate workspace API.
- **Direct removal:** `removeWorktree` changes the catalog without lifecycle
  scripts. `removeWorktreeWithGit`, including removal from the archived-worktree
  list, also does not run the delete script.

These scripts are distinct from the planned asynchronous `worktree.*` hook
subscriptions. Hook subscriptions and their dispatcher are not implemented;
see [lifecycle-hooks.md](./lifecycle-hooks.md). The worktree entry points and
creation phases are documented in [worktree.md](./worktree.md).

## Risks

| Risk | Mitigation |
|---|---|
| A future feature re-opens the `settings.json` shared-file hazard. | `SettingsStore` is the only writer; flag any other `AtomicFileStore` write to `Settings`' URL in review. |
| Reader bypasses per-Project preferences. | Resolve editor and worktrees-directory values via `settings.projects[pid]`. |
| Migration failure leaves the original settings at risk of overwrite. | Preserve the source/backup and disable persistence on migration or backup failure. |
| Catalog-only overrides are expected to appear in settings. | Bootstrap does not supply `catalogOverrides`; the loader parameter is not an automatic catalog migration. |
| `kind` drift (stale `gitRoot` snapshot shows wrong sub-rows). | Re-derived on `.projectsChanged`; acceptable to show wrong rows for one catalog-refresh tick. |

## References

- Notification pipeline (gated by these settings): [notifications.md](./notifications.md)
- Schema authority: `apps/mac/CodansCore/Settings/{Settings,ProjectSettings,GitProjectSettings,NotificationsSettings,SettingsMigration}.swift`, `apps/mac/CodansCore/ProjectKind.swift`
- Single writer + atomic store: `apps/mac/codans/App/Features/Settings/SettingsStore.swift`
- Per-Project write seam: `SettingsWriter` in `apps/mac/codans/App/Features/Editor/EditorFeature.swift`; `apps/mac/codans/App/Features/Settings/{SettingsSection,ProjectSettingsFeature}.swift`
- On-disk file inventory + versions: [architecture.md](../architecture.md)
