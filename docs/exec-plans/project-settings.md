# ExecPlan: Project Settings — Unified Per-Project Preferences

**Status:** Approved — In Progress (2026-04-24)
**Author:** Gump
**Date:** 2026-04-24

This is a living document. The Progress, Surprises & Discoveries, Decision
Log, and Outcomes & Retrospective sections must be kept up to date as work
proceeds.

## Purpose

After this change, opening ⌘, and clicking any Project in the sidebar
shows a kind-appropriate set of sub-panes: a git-backed Project exposes
General / Git & Worktree / GitHub / Scripts / Hooks / Environment, and a
plain-directory Project exposes General / Scripts / Hooks / Environment
— no icon or label tells the user which kind it is; the distinction is
carried only by which panes appear. Editor and worktree-directory
overrides that were previously stored on `catalog.json` now live in
`settings.json` alongside the GitHub overrides, so a user editing a
single JSON file sees every per-Project preference in one place. A hook
subscription with `scope: { kind: "projectID", value: "<pid>" }` fires
for any pane in that Project, including plain-directory Projects that
have no worktrees to anchor a scope against. The three on-disk schemas
(`settings.json` v2→v3, `catalog.json` v1→v2, `hooks.json` v1→v2)
migrate transparently on first launch.

## Progress

- [x] Step 1 — `ProjectKind` enum + `Project.kind` + `HierarchyClient.kind(of:)` (2026-04-24)
- [x] Step 2 — `ProjectSettings` + `GitProjectSettings` types (additive) (2026-04-24)
- [x] Step 3 — `settings.json` v3 codable + v2-fold decoder path (2026-04-24)
- [x] Step 4 — `catalog.json` v2 (Project fields stripped from encoder) (2026-04-24)
- [x] Step 5 — `hooks.json` v2 (new Scope cases + fail-soft Kind) (2026-04-24)
- [x] Step 6 — `SettingsStore.mutateProject` + `HierarchyClient` slim-down + "Open in" rewire (2026-04-25)
- [x] Step 7 — `RepositorySettingsFeature` → `ProjectSettingsFeature` rename + `HookSource.project` (2026-04-25)
- [x] Step 8 — `SettingsWindowFeature` rename + sidebar kind-aware rendering + 4 new `SettingsSection` cases (2026-04-25)
- [x] Step 9 — Pane view file renames + 4 scaffold pane views (2026-04-25)
- [x] Step 10 — CI grep gate for `Repository` rename residue (2026-04-25)
- [x] Step 11 — Doc updates (`architecture.md`, `ui-settings-window.md` amendment, deprecated exec-plan header); manual QA deferred (no running app) (2026-04-25)
- [x] Step 12 — Self-review fixes (migration map shape, EditorFeature read-site) (2026-04-25); codex review deferred (rate limit)
- [ ] Final — push + `gh pr create --base main`

## Surprises & Discoveries

(None yet)

## Decision Log

### 2026-04-24 — Step 3 subsumed Step 6's `mutateRepository → mutateProject` rename

Rationale: `Settings.repositories: [ProjectID: RepositorySettings]` → `Settings.projects:
[ProjectID: ProjectSettings]` forces the `SettingsStore.mutateRepository(_ ... (inout
RepositorySettings) -> Void)` closure type to change (value type is now `ProjectSettings`
and the old `RepositorySettings` struct is deleted in Step 3). Keeping the old method name
alive with a shim translating between two types would be noise. Consequence: Step 6's
scope shrinks to HierarchyClient slim-down + "Open in" dropdown rewire only.

### 2026-04-25 — Step 12 code-reviewer agent round (post self-review)

`agent-skills:code-reviewer` ran after the self-review fixes landed. Findings
acted on in a single follow-up commit:

1. **Blocker — `ProjectGeneralSettingsView` read from the post-drain catalog.**
   The pane's Picker + LabeledContent bound to `project.defaultEditor` /
   `project.worktreesDirectory` on the `Project` struct. After
   `HierarchyManager.drainLegacyOverrides()` runs at startup, both fields are
   guaranteed nil for the rest of the process lifetime; the pane silently showed
   "Use global default" / "—" no matter what the user had saved. Writes already
   routed through `SettingsStore.mutateProject` correctly, so flipping the
   picker persisted, but on next open the UI displayed stale-empty. Fix: add
   `@Environment(SettingsStore.self)` to the view and bind to
   `settingsStore.settings.projects[projectID]?.{defaultEditor, worktreesDirectory}`.
   Catalog `Project` lookup is retained only for identity (name/kind).
2. **Major — `performV1Migration` ignored `catalogOverrides`.** A double-legacy
   user (v1 settings + v1 catalog) would lose per-Project editor / worktree-dir
   overrides on first v3 launch: `drainLegacyOverrides` extracts them, the v1→v3
   migration discards them, and the catalog v2 save then strips the fields.
   Fix: fold the map into `migrated.projects` before calling `performV1Migration`,
   mirroring the Pass 2 union loop in `performV2Migration`.
3. **Major — fail-soft hook decoder test coverage.** Previous test only checked
   "bad entry after good"; the cursor-advance contract needs pinning for
   "bad entry first" and "two consecutive bad entries" cases too. Added two
   `HookConfigCodableTests` cases.
4. **Major — mid-migration crash window in `AppState.init`.** Sequence was:
   drain catalog (debounced save scheduled) → build SettingsStore (synchronous
   atomic v2→v3 commit). A crash between the settings write and the catalog
   debounce flush would leave v3 settings.json on disk without overrides paired
   with a v1 catalog that still carries them, and since settings.json is now
   v3 the migration no longer runs on next launch — the drained map is
   silently dropped. Fix: call `catalogStore.saveNow(manager.catalog)`
   synchronously when `legacyOverrides` is non-empty, before constructing
   SettingsStore.

Nits cleaned up in the same commit: stale doc-comments referencing
`HierarchyClient.setRepositoryDefaultEditor` / `Project.defaultEditor` (3
sites), SettingsWindowFeatureTests method names ending in `…RepositoryPanes`
(renamed to `…ProjectPanes`), `performV2Migration` Pass 1 uses
`collapseEmptyGit()` instead of hand-rolling the isEffectivelyEmpty guard.

Reviewer-deferred suggestions (kept for follow-up): grep-gate trailing-comment
false-positive, deny-list could add `RepositorySettingsView`, `kind` closure
linear scan is fine at realistic project counts. `extra scheduleSave` on
launch from `garbageCollectEditors` is known and accepted.

### 2026-04-25 — Step 12 self-review uncovered two correctness issues

Codex rate-limited; agent did the review itself. Two issues fixed before the
code-reviewer agent re-run:

1. **Migration dropped catalog-only pids.** `performV2Migration` iterated only
   `legacy.repositories`, so a Project whose v1 catalog carried an editor or
   worktree-dir override but had no GitHub override would lose its override on
   first v3 launch. Fix: changed `catalogOverrides` from a pid-keyed closure to
   a `[ProjectID: ...]` map so the migration can iterate both dimensions
   (intersection loop + union catch-up loop). Added
   `v2FoldsCatalogOnlyPidsIntoProjects` test case pinning the union behaviour.
2. **`EditorFeature.openDefaultInCurrentWorktreeRequested` still read
   `project.defaultEditor` from the catalog snapshot.** Post-Step-4 drain, that
   field is always nil; the ⌘E shortcut would silently ignore the user's
   Project editor override. Fix: rewire through `settingsWriter.readSnapshotSync()`.

### 2026-04-25 — Step 11 manual QA deferred

Step 11 of the plan asked for `make mac-run-app` + a manual walk of the Settings
window with git_repo and plain_dir projects. The agent environment cannot interactively
drive a SwiftUI app, so the run-app walk is deferred to the human. The automated
verification that the agent *can* run — build + full test suite across the three
schemes — is green (Steps 1–9 landed their own suites; Step 10 grep gate is clean).
Doc updates (architecture.md v3 row + ui-settings-window.md amendment note +
settings-repositories.md Superseded-by header) landed in this step.

### 2026-04-25 — Step 6 also rewired per-Project editor reads (not just writes)

Plan described the rewire only for writes (`EditorFeature.setProjectOverride`,
`ProjectOptionsFeature.saveTapped`, `RepositorySettingsFeature`). But several reader sites
still pulled `Project.defaultEditor` / `Project.worktreesDirectory` from the Catalog
snapshot: `EditorHandlers.projectOverride`, `RootFeature.projectOverrideEditorID`,
`GitViewerFeature.openInEditor` fire path, `HeaderOpenSplitButton.projectOverrideID`,
`HierarchySidebarFeature.projectAddWorktreeTapped` + `.projectOptionsTapped`. With v2
catalog encoder no longer writing those fields, a read would return `nil` after the
first drain. Rewired all six sites to read through `SettingsWriter.readSnapshotSync` /
`settings.projects[pid]`. Added `readSnapshotSync` (MainActor-assumed) to SettingsWriter
so reducers can read without an async hop.

### 2026-04-24 — Step 3 fixed two pre-existing flaky tests as a side effect

`SettingsStoreTests.writeFailureLogsButDoesNotMoveFileAside` and
`saveNowCancelsPendingDebouncedWrite` both seeded sentinel editor IDs (`"initial"`,
`"SENTINEL"`) that `Settings.garbageCollectEditors` would wipe on load. The tests passed
under CI's swift-testing `-only-testing` filter because the filter's regex excluded those
individual tests. Running the suite without the filter revealed the breakage. Fix: pass
`knownEditorIDs: [...]` containing the sentinel(s) at each affected `SettingsStore` init so
the normalisation step leaves the test seed intact. Scope limited to those two call sites
— no behavioural change to `garbageCollectEditors`.


## Outcomes & Retrospective

(To be filled at Final completion.)

## Context and Orientation

Related documents:

- Design doc (APPROVED): `docs/design-docs/project-settings.md` — data
  model, schema migrations, Scope extension, alternatives, risks.
  This plan executes the design verbatim; any deviation is logged in
  Decision Log.
- Superseded design: `docs/design-docs/settings-repositories.md` —
  T4's original design. Marked Deprecated at its header.
- Product spec: `docs/product-specs/ui-settings-window.md` — M10–M12
  and the sidebar acceptance criteria. This plan does not change M11/M12
  behavior for git-backed Projects, only reshapes the storage + extends
  sidebar to plain-directory Projects.
- Architecture: `docs/architecture.md` — atomic-rename + 500 ms debounce
  persistence invariants apply to every on-disk write this plan touches.

Key source files (ordered by dependency flow):

- `apps/mac/CodansCore/Project.swift` — `Project` struct. Two fields
  (`defaultEditor`, `worktreesDirectory`) migrate away; `kind` derived
  property added.
- `apps/mac/CodansCore/ProjectKind.swift` — *new*, owns the
  `git_repo` / `plain_dir` enum + `Project.kind` extension.
- `apps/mac/CodansCore/Catalog.swift` — version bump 1→2;
  `garbageCollectEditors` walk retargets to `Settings.projects`.
- `apps/mac/CodansCore/Settings/Settings.swift` — v3 root; renames
  `repositories` → `projects`, decoder accepts v2 and folds into v3.
- `apps/mac/CodansCore/Settings/RepositorySettings.swift` — deleted
  in Step 7 after all call sites moved off it.
- `apps/mac/CodansCore/Settings/ProjectSettings.swift` — *new*,
  the flat struct holding all per-Project prefs; `git` nested.
- `apps/mac/CodansCore/Settings/GitProjectSettings.swift` — *new*,
  the git-kind-only subset.
- `apps/mac/CodansCore/Settings/SettingsMigration.swift` — adds a
  v2→v3 branch that folds catalog overrides via an injected closure.
- `apps/mac/CodansCore/Hooks/HookSubscription.swift` — adds two
  `Scope` cases; Kind decoder becomes fail-soft.
- `apps/mac/CodansCore/Hooks/HookConfig.swift` — version 1→2.
- `apps/mac/codans/Runtime/HierarchyManager.swift` — loses two
  mutators; exposes a migration-time override snapshot.
- `apps/mac/codans/App/Features/Settings/SettingsStore.swift` —
  `mutateRepository` → `mutateProject`; initialisation grows a
  catalog-overrides fold.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — drops two
  closures, adds `kind(of:)`.
- `apps/mac/codans/App/Features/Settings/RepositorySettingsFeature.swift`
  — renamed to `ProjectSettingsFeature.swift`; writes rewire from
  `HierarchyClient` to `SettingsStore`; classifier uses
  `.projectID` / `.projectPathGlob` directly.
- `apps/mac/codans/App/Features/Settings/SettingsWindowFeature.swift`
  — `repositoryPanes` → `projectPanes`; State carries per-pane `kind`.
- `apps/mac/codans/App/Features/Settings/SettingsSection.swift` —
  two cases renamed; four new cases added.
- `apps/mac/codans/App/Features/Settings/Sidebar/SettingsSidebarView.swift`
  — DisclosureGroup rows conditional on `kind`; **no visual indicator**
  distinguishes kinds.
- `apps/mac/codans/App/Features/Settings/Panes/*SettingsView.swift`
  — file renames + four new scaffolds.
- `apps/mac/codans/App/Features/Editor/EditorFeature.swift` — the
  existing `.setProjectOverride` action rewires from HierarchyClient
  to SettingsStore.
- `apps/mac/codans/App/Features/Socket/handlers/HookHandlers.swift`
  — exhaustive `switch` over `HookSubscription.Scope` grows two cases.
- `apps/mac/codans/App/Features/Settings/Panes/HookMergeView.swift`
  — the `scopeLabel` helper grows two cases; `HookSource.repository`
  renames to `.project` (tag label stays "Project" user-facing).
- `scripts/check-rename-residue.sh` — *new*, the CI grep gate.
- `apps/mac/Makefile` — adds `check-rename` target.

Terms of art:

- **kind** — the `git_repo` / `plain_dir` classification of a Project.
  Derived from `Project.gitRoot` (nil → plain_dir). Not persisted; not
  rendered anywhere in the UI; only controls which Settings sub-rows
  appear under a Project in the sidebar.
- **fold** — the migration step that reads `Project.defaultEditor` and
  `Project.worktreesDirectory` from a v1 catalog and writes those
  values into the corresponding `projects[pid]` entry of a freshly
  upgraded v3 `settings.json`. Happens once at first launch after the
  upgrade.
- **fail-soft Kind decoder** — a Codable `init(from:)` on
  `HookSubscription.Scope.Kind` that returns `nil` on an unknown raw
  string instead of throwing. The surrounding `HookSubscription`
  decoder catches the typed nil, logs a warning, and signals to the
  outer `[HookSubscription]` decoder to drop that entry. A broken
  Kind no longer corrupts the whole file.
- **scaffold pane** — a `View` with the final frozen signature
  (`struct ProjectGitSettingsView: View { let projectID: ProjectID;
  @Bindable var store: StoreOf<ProjectSettingsFeature>; … }`) whose
  body renders a single `Text("Coming in M…")`. Follow-up waves
  replace the body without touching the window shell.
- **T4** — the Settings-window per-Project subtree work that landed
  on this branch ahead of this plan (`RepositorySettings*` naming,
  `repositoryPanes`, `classifyHooks`). T4's structure stays; its
  names and storage change.

## Plan of Work

The work splits into five narrative milestones. Each step inside a
milestone is a single `/commit`; step-by-step sequencing is enforced
by data dependencies. Two pairs of steps are genuinely parallelisable
— those pairs are flagged under *Parallel execution opportunities*
below; everything else is serial.

### Milestone 1 — Data foundation (additive, no behavior change)

At the end of this milestone, `ProjectKind` exists as a derived
property on `Project`, and the `ProjectSettings` / `GitProjectSettings`
types compile alongside (but do not replace) `RepositorySettings`. No
JSON file changes yet; no UI changes yet. Build stays green.

**Step 1 — `ProjectKind` + `Project.kind` + `HierarchyClient.kind(of:)`.**
Add `apps/mac/CodansCore/ProjectKind.swift` holding the two-case
public enum (`.gitRepo`, `.plainDir`, raw values `"git_repo"` and
`"plain_dir"`). Add an extension on `Project` with
`public var kind: ProjectKind { gitRoot == nil ? .plainDir : .gitRepo }`.
Extend `apps/mac/codans/App/Clients/HierarchyClient.swift` with a
closure `var kind: @MainActor @Sendable (ProjectID) -> ProjectKind?`;
live wiring scans `hierarchyManager.catalog.spaces` for the Project
and maps, returning `nil` on absence. Tests under
`apps/mac/CodansCoreTests/ProjectKindTests.swift` cover the two
derivation branches; `apps/mac/codans/Tests/HierarchyClientTests.swift`
gains a forwarding test. Commit message: `feat(core): add ProjectKind
derivation and HierarchyClient.kind(of:)`.

**Step 2 — `ProjectSettings` + `GitProjectSettings` types (additive).**
Add `apps/mac/CodansCore/Settings/ProjectSettings.swift` with the
struct shape from the design doc: top-level `defaultEditor: EditorID?`,
`worktreesDirectory: String?`, `defaultShell: String?`,
`envVars: [String: String]`, `scripts: [ScriptDefinition]`
(placeholder type — see Interfaces), and `git: GitProjectSettings?`.
Add `apps/mac/CodansCore/Settings/GitProjectSettings.swift` with
`worktreeBaseRef: String?`, `copyIgnoredOnWorktreeCreate: Bool?`,
`copyUntrackedOnWorktreeCreate: Bool?`, `defaultMergeStrategy:
MergeStrategy?`, `postMergeAction: MergedWorktreeAction?`,
`githubDisabled: Bool`. Codable omit-when-default on every Optional
and `githubDisabled: false`. Provide `isEffectivelyEmpty` on both
(outer also clears `git` to nil when inner is empty). Tests under
`apps/mac/CodansCoreTests/Settings/ProjectSettingsCodableTests.swift`:
round-trip empty struct (`{}`), populated git-only, populated
top-level-only, mixed. Also add a placeholder `ScriptDefinition`
struct in `apps/mac/CodansCore/Settings/ScriptDefinition.swift`
with minimal fields (`id: UUID`, `name: String`, `command: String`)
— this reserves the slot; full definition lands in a later wave.
Commit message: `feat(settings): add ProjectSettings and
GitProjectSettings types`.

### Milestone 2 — Schema version bumps with migration

At the end of this milestone, all three JSON files accept both their
current and next versions, writing the new shape on the next save.
In-memory `Settings` holds `projects: [ProjectID: ProjectSettings]`
instead of `repositories: [ProjectID: RepositorySettings]`. No UI or
feature-reducer changes yet — the sub-pane code still compiles
against the old names because those names live in the view tier
(renames happen in Milestone 4).

**Step 3 — `settings.json` v3 with v2-fold decoder.** Edit
`apps/mac/CodansCore/Settings/Settings.swift`: bump
`currentVersion` to 3; rename the field and coding key
`repositories` to `projects`; change the value type to
`[ProjectID: ProjectSettings]`; keep the string-keyed JSON dict
form. The decoder accepts `version ∈ {2, 3}`; on v2, it reads
`repositories` under its old key and maps each
`RepositorySettings` value into a `ProjectSettings` whose `git`
field holds the three existing GitHub fields and whose other
top-level fields are all nil/empty. `garbageCollect()` walks
`projects` and also clears `git` to nil when `git.isEffectivelyEmpty`.
`garbageCollectEditors(knownIDs:)` walks
`projects.values.compactMap(\.defaultEditor)` instead of
`general.defaultEditorID`; the general-side walk stays. Extend
`SettingsMigration.load` with a new branch
`.migratedFromV2(Settings, backupURL: URL)` alongside the existing
v1→v2 branch. The v2→v3 branch takes an injected closure
`catalogOverrides: (ProjectID) -> (defaultEditor: EditorID?,
worktreesDirectory: String?)?` and folds the returned values into
`projects[pid]` top-level fields. `SettingsStore.init` gains a
`catalogOverridesSnapshot` parameter it forwards to migration; the
parameter is `nil` when called outside `bringUp` (tests). Tests
under `apps/mac/CodansCoreTests/Settings/SettingsMigrationV2ToV3Tests.swift`:
fresh v3 file round-trips; v2 file with one `repositories[pid]`
entry produces v3 with matching `projects[pid].git.*`; v2 file
plus catalog-overrides closure produces v3 with the two top-level
fields set; v3 file is a no-op (no disk write scheduled); Scope
key unknown on a v3 subscription still loads (covered in Step 5,
not here). Commit message: `feat(settings): migrate settings.json
to v3 with projects dict`.

**Step 4 — `catalog.json` v2 stripping two Project fields.** Edit
`apps/mac/CodansCore/Catalog.swift` to bump
`currentVersion` to 2; decoder accepts `version ∈ {1, 2}`. Edit
`apps/mac/CodansCore/Project.swift`: keep
`defaultEditor: EditorID?` and `worktreesDirectory: String?` as
stored fields (so pending in-memory reads from Milestone 3 still
work), but remove both from `CodingKeys` for encoding — they're
read on decode (`decodeIfPresent` on v1 input) and never written.
`Catalog.garbageCollectEditors(knownIDs:)` is retired: its
responsibility moves to `Settings.garbageCollectEditors`, so delete
the catalog-side method and its call site in `CatalogStore`. Then
edit `apps/mac/codans/Runtime/HierarchyManager.swift` to add a
one-shot accessor `func drainLegacyOverrides() -> [ProjectID:
(defaultEditor: EditorID?, worktreesDirectory: String?)]` that
snapshots every Project's two fields, then clears them in-memory
(so the next save persists v2 catalog without the fields). Call
sequence: `bringUp` invokes `drainLegacyOverrides` *before*
`SettingsStore.init(catalogOverridesSnapshot:)` runs so the closure
sees the non-empty snapshot. After `SettingsStore.init` returns,
`bringUp` calls `hierarchyManager.scheduleSave()` to commit the v2
catalog. Tests: `CatalogCodableTests.v1Input_roundTripsAsV2`;
`HierarchyManagerTests.drainLegacyOverrides_returnsAllAndClears`;
end-to-end `SettingsCatalogMigrationIntegrationTests` seeding a v1
catalog + v2 settings.json, asserting a post-bringUp v3
settings.json contains the overrides and the catalog contains none.
Commit message: `feat(catalog): migrate catalog.json to v2 by
stripping per-Project preference fields`.

**Step 5 — `hooks.json` v2 with new Scope cases + fail-soft Kind.**
Edit `apps/mac/CodansCore/Hooks/HookSubscription.swift`: add
`case projectID(ProjectID)` and `case projectPathGlob(String)` to
`Scope`; add `projectID` and `projectPathGlob` to the private
`Kind` enum. Replace `Kind`'s synthesised Codable with a manual
`init(from:)` that returns `nil` (by throwing a sentinel error the
outer decoder catches) on an unrecognised raw string, and a manual
`encode(to:)` (symmetric). The `HookSubscription` decoder wraps
the Scope decode in a `do/catch`; on sentinel error, it logs a
warning via the existing `Logger(subsystem: "com.gumpw.codans.hooks",
category: "config")` and re-throws as a typed
`DecodingError.valueNotFound` that the outer `[HookSubscription]`
decode can skip-with-log. `HookConfig.swift` bumps
`currentVersion` to 2; decoder accepts 1 or 2. Exhaustive switches
at three consumer sites grow two cases: (a)
`apps/mac/codans/App/Features/Socket/handlers/HookHandlers.swift`
`hook.list` paneID filter — both new cases return `false` (they
don't match a paneID); (b)
`apps/mac/codans/App/Features/Settings/Panes/HookMergeView.swift`
`scopeLabel(_:)` — both new cases return their kind name as a
label; (c) `apps/mac/codans/App/Features/Settings/RepositorySettingsFeature.swift`
`isRepositoryScope` — `.projectID` matches `== project.id`;
`.projectPathGlob` matches by glob against `project.rootPath`.
Tests: `HookSubscriptionCodableTests.projectIDRoundTrip`,
`projectPathGlobRoundTrip`, `unknownKind_dropsSubscriptionWithLog`;
`HookConfigCodableTests.v1InputRoundTripsAsV2`. Commit message:
`feat(hooks): add projectID and projectPathGlob scope cases with
fail-soft decoder`.

### Milestone 3 — Writer rewire

At the end of this milestone, every per-Project settings write goes
through `SettingsStore`. `HierarchyClient` is read-only for
per-Project preferences. The main-window WorktreeHeader "Open in"
dropdown writes through the same pipe as the Settings pane.

**Step 6 — `SettingsStore.mutateProject` + HierarchyClient slim-down
+ "Open in" rewire.** Rename `SettingsStore.mutateRepository(_:_:)`
to `mutateProject(_:_:)` with the new
`(inout ProjectSettings) -> Void` closure type. The garbage
collector before save drops `projects[pid]` entries whose outer
struct is effectively empty (including clearing an empty `git`
child first). Remove
`HierarchyClient.setRepositoryDefaultEditor`,
`setRepositoryWorktreeBaseDirectory` closures and their live
bridges; remove `HierarchyManager.setWorktreesDirectory`,
`setDefaultEditorAnySpace`, and the `findProjectAnySpace` helper
— they become dead code once `EditorFeature.setProjectOverride`
and `ProjectSettingsFeature` (next step) route to SettingsStore.
Edit `apps/mac/codans/App/Features/Editor/EditorFeature.swift`
`.setProjectOverride(projectID:, spaceID:, editorID:)` to close
over `SettingsStore` (injected via `@Dependency` — add a
`SettingsStoreClient` wrapper if direct injection causes MainActor
friction). The `spaceID` parameter stays in the action signature
(callers still supply it) but is ignored by the reducer since
`SettingsStore.mutateProject` keys by `ProjectID` alone —
deprecation path, removed when we later pass through a WorktreeHeader
follow-up. Tests: `SettingsStoreTests.mutateProject_createsAndGCsEmpty`;
`EditorFeatureTests.setProjectOverride_writesToSettingsStore`. Any
test that referenced the removed HierarchyClient closures gets
updated or deleted. Commit message: `refactor(settings): route
per-Project writes through SettingsStore.mutateProject`.

### Milestone 4 — Feature + UI rename and sub-pane scaffolds

At the end of this milestone, the entire Settings code surface uses
`Project` vocabulary, sidebar conditional-renders sub-rows by kind,
and four scaffold panes are wired into the detail switch. The
user-visible text is unchanged except for the one implicit change:
plain_dir projects now have a Hooks sub-row (previously they had
one too, but it was General-plus-Hooks for every project regardless
of kind). Parallel execution from here on.

**Step 7 — `RepositorySettingsFeature` → `ProjectSettingsFeature`.**
Rename
`apps/mac/codans/App/Features/Settings/RepositorySettingsFeature.swift`
to `ProjectSettingsFeature.swift` (git mv). Rename the type; rename
`HooksLoad` payload `.loaded([HookRow])` stays but the `HookSource`
enum in `HookMergeView.swift` renames `.repository` to `.project`
(tagLabel "Repository" becomes "Project"). Replace the two write
actions: `setDefaultEditorOverride(EditorID?)` now dispatches
`.run` effect calling `settingsStore.mutateProject(pid) { $0.defaultEditor = id }`;
`setWorktreeBaseDirectory(String?)` dispatches
`$0.worktreesDirectory = path`. Both still emit `writeFailed(…)`
on throw (reachable when persistence is disabled). Add
`State.kind: ProjectKind` initialised via the new
`HierarchyClient.kind(of:)` closure in
`SettingsWindowFeature.ensureProjectPane`. Rewrite `classifyHooks`
to use `.projectID` / `.projectPathGlob` directly; tighten
`worktreePathGlob` to match only worktree paths (not rootPath).
Rename the tests file to `ProjectSettingsFeatureTests.swift` and
update every `repository`/`Repository` token; the `isRepositoryScope`
helper renames to `isProjectScope`. Delete
`apps/mac/CodansCore/Settings/RepositorySettings.swift` — call
sites are gone. Commit message: `refactor(settings): rename
RepositorySettingsFeature to ProjectSettingsFeature and switch writes
to SettingsStore`.

**Step 8 — `SettingsWindowFeature` rename + sidebar kind-awareness
+ `SettingsSection` case expansion.** Edit
`apps/mac/codans/App/Features/Settings/SettingsWindowFeature.swift`:
rename `repositoryPanes` → `projectPanes` (and its action
`.repositoryPanes` → `.projectPanes`); `.forEach` keypath and
`ensureRepositoryPane` follow. `ensureProjectPane` takes a
`HierarchyClient.kind` lookup to seed `State.kind` on insertion.
Edit
`apps/mac/codans/App/Features/Settings/SettingsSection.swift`:
rename `.repositoryGeneral(ProjectID)` → `.projectGeneral`,
`.repositoryHooks` → `.projectHooks`; add
`.projectGit(ProjectID)`, `.projectGitHub(ProjectID)`,
`.projectScripts(ProjectID)`, `.projectEnv(ProjectID)`. Edit
`apps/mac/codans/App/Features/Settings/Sidebar/SettingsSidebarView.swift`
so the DisclosureGroup row-builder consults
`HierarchyClient.kind(of: pid)` via a view-scoped
`@Environment(\.hierarchyClient)` or a direct `HierarchyManager`
environment read: when `.gitRepo`, render six sub-rows (General,
Git & Worktree, GitHub, Scripts, Hooks, Environment); when
`.plainDir`, render four (General, Scripts, Hooks, Environment).
**No kind icon, no kind label** — sub-rows alone carry the signal.
Tests: `SettingsWindowFeatureTests.projectPanes_ensure_seedsKind`,
`projectPanes_kindFlip_updatesState` (catalog edit that flips
`gitRoot` toggles the pane's kind on next `.projectsChanged`);
`SettingsSidebarSnapshotTests.plainDirRendersFourRows` (or a feature-
level assertion if snapshot tests aren't set up); `selecting_projectGit_onPlainDir_fallsBackToGeneral`
(defense vs. a race where selection points to a pane a flipped kind
no longer exposes). Commit message: `refactor(settings): rename
window state to projectPanes and add kind-aware sidebar`.

**Step 9 — Pane view file renames + four scaffold panes + detail
switch update.** Rename
`RepositoryGeneralSettingsView.swift` → `ProjectGeneralSettingsView.swift`
and the `struct RepositoryGeneralSettingsView` → `ProjectGeneralSettingsView`.
Rename `RepositoryHooksSettingsView.swift` → `ProjectHooksSettingsView.swift`.
Add four new files under
`apps/mac/codans/App/Features/Settings/Panes/`:
`ProjectGitSettingsView.swift`, `ProjectGitHubSettingsView.swift`,
`ProjectScriptsSettingsView.swift`, `ProjectEnvSettingsView.swift`.
Each has the frozen signature
`struct ProjectXSettingsView: View { let projectID: ProjectID;
@Bindable var store: StoreOf<ProjectSettingsFeature>; var body:
some View { Text("Coming in M<N>…") … } }` with the M-number placeholder
filled from the ui-settings-window.md spec section that owns that pane
(Git → M17, GitHub → M18, Scripts → M19, Env → M20; these M numbers
are added to the spec in Step 11). Edit
`apps/mac/codans/App/Features/Settings/SettingsWindowView.swift`
detail switch: rename the two existing cases and add four new ones,
each following the existing `store.scope(state:, action:)` fallback-
to-`EmptyView` pattern. No tests for the scaffold views themselves —
they render one Text. Commit message: `refactor(settings): rename
Repository pane views to Project, add four scaffold panes`.

### Milestone 5 — Guardrails + verification + review

**Step 10 — CI grep gate for `Repository` rename residue.** Add
`scripts/check-rename-residue.sh` that runs from the repo root and
greps `apps/mac/` Swift files for `\b[Rr]epository\b`, excluding
an allowlist (`apps/mac/Makefile` target bodies that speak about
git repos, `docs/**` entirely, `apps/mac/codans/App/Features/GitViewer/**`
which wraps legitimate Git-repo-the-concept APIs, and comment
lines explicitly tagged `// renamed from Repository*`). Non-zero
exit on any hit. Add `apps/mac/Makefile` target `check-rename:` that
runs the script; wire it into `apps/mac/Makefile` `check:` aggregate
after `make lint`. Update `.github/workflows/*.yml` if present (spot
check — CI plumbing may be absent; this project doesn't have a
`.github/workflows/` currently, so no workflow edit). Commit message:
`chore(ci): add grep gate preventing Repository rename residue`.

**Step 11 — Manual QA walk + doc updates.** Manual walk with
`make mac-run-app`, seeded repositories: (a) one git-backed Project;
(b) one plain-directory Project; (c) a git Project that has been
`rm -rf .git`'d while the app is open (to exercise kind flip). Walk
each Settings sub-row for each kind; exercise Reveal hooks.json;
exercise editor override + worktree-directory override writes on a
git Project; confirm no regressions on GitHub merge strategy
(landed by T4). Update
`docs/architecture.md` persistence section with the new version
numbers. Update `docs/product-specs/ui-settings-window.md`: add M17
(Git & Worktree pane), M18 (GitHub pane — promote existing mergeStrategy
content into its own section), M19 (Scripts pane scaffold), M20
(Environment pane scaffold); add Acceptance Criteria notes that
sub-rows render conditionally by kind and that no visual indicator
exposes kind. Mark
`docs/exec-plans/settings-repositories.md` **Status: Superseded by
project-settings.md** at its header. If any QA step surfaces a bug,
file it under *Surprises & Discoveries* and open a sub-step 11a/11b
with the fix (additional commit). Commit message: `docs(settings):
update architecture.md, ui-settings-window.md, and deprecate
settings-repositories exec-plan`.

**Step 12 — `/codex:review` + fix findings.** Invoke `/codex:review`
on the branch. Triage findings into: (a) land-as-is-fix (apply + new
commit); (b) record-as-known-limitation (add to Decision Log with
rationale); (c) outside-scope (capture as a follow-up issue). Do
not amend earlier commits. The final commit in this step groups
review fixes under a single `fix(settings): address review findings`
or, if findings span areas, one commit per fix with the specific
scope noted. If no findings require code changes, skip this commit
and note the clean review in *Outcomes & Retrospective*.

### Parallel execution opportunities

The plan sequences steps serially by default — each step's verification
runs to completion before the next starts. Two pairs are genuinely
safe to execute in parallel via Agent teams because their file
intersections are empty:

- **Pair A** (after Milestone 2 completes): Step 7 can start once
  Steps 5 and 6 are both green. Steps 8 and 9 can then run in parallel
  — Step 8 touches window/sidebar/section files; Step 9 touches pane-
  view files. Neither modifies the other's surface.
- **Pair B** (after Milestone 4 completes): Step 10 (CI gate) and
  Step 11 (docs + manual QA) touch non-overlapping paths (script vs
  markdown docs).

Not safe to parallelise:

- Steps 1 and 5 both edit Hook-related files (`HierarchyClient`
  gains `kind(of:)` in Step 1; Step 5 touches hook-classification
  switches that consume kind indirectly via Project snapshots).
  Sequential.
- Step 2 and Step 4 both touch `Project.swift` (Step 2 adds no
  Project-file edit, but Step 4 removes its CodingKeys for two
  fields). Safer serial.
- Steps inside the same milestone share data-model dependencies and
  must sequence strictly.

For Agent-team execution: one lead agent drives Milestones 1–3
serially. When Milestone 4 begins, the lead spawns two sub-agents
for Steps 8 and 9 with explicit file-ownership statements
("Step 8 owns all files in Features/Settings/ except Panes/*",
"Step 9 owns Panes/* and SettingsWindowView.swift detail switch
additions"), collects their two commits, then runs Milestone 5
with Steps 10 and 11 in parallel under the same pattern.

## Concrete Steps

Working directory for all commands: repo root (`/Users/wanggang/.prowl/repos/codans/feature/worktree-settings`).

### Generate Tuist project

```
make mac-generate
```

Expected tail: `Project generated at …`. Run after any step that adds
or removes Swift files (Steps 1, 2, 5, 9, 10). Idempotent.

### Build sanity

```
cd apps/mac
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug build -destination 'platform=macOS' | xcbeautify
```

Expected: `** BUILD SUCCEEDED **`.

### Per-step test invocation

```
cd apps/mac
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug test \
  -only-testing:codansTests/<TestSuite> \
  -destination 'platform=macOS' | xcbeautify
```

Substitute the step's `<TestSuite>` — each step's commit message
lists the tests that must be green.

### Full-matrix test before Final

```
cd apps/mac
xcodebuild -workspace codans.xcworkspace -scheme codans \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace codans.xcworkspace -scheme CodansCoreTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
xcodebuild -workspace codans.xcworkspace -scheme tcTests \
  -configuration Debug test -destination 'platform=macOS' | xcbeautify
```

Each ends with `** TEST SUCCEEDED **`.

### CI grep gate

```
./scripts/check-rename-residue.sh
```

Expected: empty stdout, exit 0. Non-empty stdout + exit 1 indicates a
missed rename; grep output names the offending file:line.

### Format + lint

```
cd apps/mac
make format
make lint
make check-rename
```

`swift-format` idempotent; `swiftlint` emits no new violations;
`check-rename` passes.

### Run app for manual QA (Step 11)

```
make mac-run-app
```

### Invoke codex review (Step 12)

Invoke the slash command `/codex:review` in the main conversation
(not inside a subagent). Wait for findings; triage per Step 12 policy.

### Final push + PR

```
git push -u origin feature/worktree-settings
gh pr create --base main \
  --title "feat(settings): unify Project settings (rename + schema bumps + kind-aware UI)" \
  --body-file .git/pr-body.md
```

The PR body file is drafted at Final time from the design-doc summary
+ Outcomes & Retrospective content. Target branch `main`; no
intermediate feature branch required — this plan lands on
`feature/worktree-settings` directly because T4's earlier work has
already merged into that branch and the PR is cumulative.

## Validation and Acceptance

**Schema migrations round-trip.** With a v2 `settings.json`
containing `repositories[pid]={"defaultMergeStrategy":"squash"}` and
a v1 `catalog.json` whose Project has
`defaultEditor="vscode"`, `worktreesDirectory="/Users/x/wt/a"`:
launching the app produces a v3 `settings.json` with
`projects[pid]={"defaultEditor":"vscode","worktreesDirectory":"/Users/x/wt/a","git":{"defaultMergeStrategy":"squash"}}`
and a v2 `catalog.json` whose Project lacks the two fields. Asserted
by `SettingsCatalogMigrationIntegrationTests` (new, Step 4) and by
manual QA's "restart with seeded-v1 home-dir" sub-step.

**Hook scope — projectID.** Seed `hooks.json` with one subscription
`scope: { kind: "projectID", value: "<project-A-uuid>" }`. Open
Settings → Project A → Hooks; the row tags as Project. Switch to
Project B; the row tags as Global. Observable in the sidebar row
labels after `.task` fires.

**Hook scope — fail-soft.** Seed `hooks.json` with one subscription
whose `scope.kind` is `"futureKind"`. App launches without error; the
broken subscription is absent from `hook.list` RPC output; a warning
line `"Dropping subscription with unknown scope kind: futureKind"`
appears in `log stream --predicate 'subsystem == "com.gumpw.codans.hooks"'`.

**Kind-aware sidebar — git Project.** Open Settings and expand a
git-backed Project. Observable: six sub-rows (General, Git & Worktree,
GitHub, Scripts, Hooks, Environment). No icon differentiates the
Project from a plain_dir one.

**Kind-aware sidebar — plain_dir Project.** Same, but expanding a
plain_dir Project shows four sub-rows (General, Scripts, Hooks,
Environment). Git & Worktree and GitHub are absent.

**Kind flip mid-session.** Open Settings on a git Project → General
sub-row. In terminal, `rm -rf <project-root>/.git`. The sidebar's
sub-row set collapses to four on the next catalog refresh; if the
user was in Git & Worktree when the flip happened, selection falls
back to General (the `projectsChanged` reducer branch covers this).

**Writer unification.** The main-window WorktreeHeader "Open in"
dropdown selecting a concrete editor writes
`projects[pid].defaultEditor` in `settings.json` (not catalog.json).
Observable by tail-following both files during the click.

**Rename gate.** `./scripts/check-rename-residue.sh` exits 0 after
Step 10. Reverting the rename in any single file (e.g., changing
`projectPanes` back to `repositoryPanes` in
`SettingsWindowFeature.swift`) makes it exit 1 with that file:line
printed.

**Test matrix.** `xcodebuild test` across all three schemes ends
`** TEST SUCCEEDED **`. New test counts approximately:
`ProjectKindTests` +2, `ProjectSettingsCodableTests` +4,
`SettingsMigrationV2ToV3Tests` +5, `CatalogCodableTests` +2 (extend),
`HookSubscriptionCodableTests` +3, `HookConfigCodableTests` +1,
`SettingsStoreTests` +2 (extend), `EditorFeatureTests` +1 (extend),
`SettingsCatalogMigrationIntegrationTests` +3, `ProjectSettingsFeatureTests`
(renamed + extended) net +4, `SettingsWindowFeatureTests` +3 (extend).
Net new passes ≥ 30.

## Idempotence and Recovery

Every step is implemented by editing or adding files — all
idempotent under git. If verification fails mid-step, the recovery
path is `git reset --hard HEAD~1` to drop that step's commit (only
unpushed commits are affected). Do **not** `git commit --amend` per
the project CLAUDE.md invariant; re-stage the fix and create a new
commit.

The migration write paths (Steps 3, 4, 5) each produce a backup
sibling file on the old-version path (`settings.json.v2-<ts>`,
`catalog.json.v1-<ts>`, `hooks.json.v1-<ts>`) before overwriting the
canonical URL. If a post-migration launch reveals a regression,
rolling back the app binary and restoring the sibling backup returns
the user to the pre-migration state. These backup files are
preserved indefinitely; a follow-up maintenance task can prune them
after N successful launches.

Mid-migration crash: Milestone 2 steps commit to disk with
atomic-rename semantics (AtomicFileStore). A crash between Catalog
v2 save and Settings v3 save (Step 3/4 ordering) leaves:
- catalog.json: v2 (fields stripped)
- settings.json: v2 still on disk (next launch migrates)
- sibling backup settings.json.v2-<ts> present
A second launch re-runs migration against the v2 settings +
now-empty-fields v2 catalog; the fold sees zero overrides but v2
settings' `repositories[pid].git.*` still promote correctly. The
user loses the two-field overrides (editor, worktree-dir) only if
the app never had a chance to write them into v3. Acceptable risk —
no silent data corruption, only non-persistence of a convenience
override that the user can re-set in Settings.

Rename residue (Step 10 gate) is idempotent: the script re-runs
identically and either passes or prints the same file:line offenders.

## Artifacts and Notes

### Expected `settings.json` after manual QA on a git Project

```jsonc
{
  "version": 3,
  "general":     { /* unchanged */ },
  "notifications": { /* unchanged */ },
  "developer":   { /* unchanged */ },
  "projects": {
    "<project-A-uuid>": {
      "defaultEditor": "vscode",
      "worktreesDirectory": "/Users/x/worktrees/a",
      "git": {
        "defaultMergeStrategy": "squash"
      }
    }
  }
}
```

Missing top-level fields (`defaultShell`, `envVars`, `scripts`) are
absent; missing `git.*` fields are absent (omit-when-default).

### Expected `catalog.json` after migration

```jsonc
{
  "version": 2,
  "spaces": [
    {
      "id": "...",
      "projects": [
        { "id": "...", "name": "A", "rootPath": "/Users/x/dev/a",
          "gitRoot": "/Users/x/dev/a",
          "worktrees": [ /* ... */ ] }
      ]
    }
  ]
}
```

No `defaultEditor`, no `worktreesDirectory`.

### Expected `hooks.json` with a projectID subscription

```jsonc
{
  "version": 2,
  "recursionWindowMs": 250,
  "subscriptions": [
    {
      "id": "...",
      "event": "pane.ready",
      "command": "echo hello",
      "scope": { "kind": "projectID", "value": "<project-A-uuid>" }
    }
  ]
}
```

### Sample `check-rename-residue.sh` (full content lives in Step 10)

```sh
#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-apps/mac}"
HITS=$(grep -rnIE '\b[Rr]epository\b' "$ROOT" \
  --include='*.swift' \
  | grep -vFf scripts/rename-allowlist.txt || true)
if [[ -n "$HITS" ]]; then
  echo "Repository rename residue found:" >&2
  echo "$HITS" >&2
  exit 1
fi
```

`scripts/rename-allowlist.txt` contains the small set of legitimate
git-repo-the-concept references (GitViewer module, commit-message
builders). The allowlist is a list of substrings; grep `-vFf` drops
matching lines.

## Interfaces and Dependencies

In `apps/mac/CodansCore/ProjectKind.swift`:

    public nonisolated enum ProjectKind: String, Codable, Hashable, Sendable {
      case gitRepo  = "git_repo"
      case plainDir = "plain_dir"
    }

    extension Project {
      public var kind: ProjectKind { gitRoot == nil ? .plainDir : .gitRepo }
    }

In `apps/mac/codans/App/Clients/HierarchyClient.swift`:

    var kind: @MainActor @Sendable (_ projectID: ProjectID) -> ProjectKind?

In `apps/mac/CodansCore/Settings/ProjectSettings.swift`:

    public nonisolated struct ProjectSettings: Equatable, Codable, Sendable {
      public var defaultEditor: EditorID?
      public var worktreesDirectory: String?
      public var defaultShell: String?
      public var envVars: [String: String]
      public var scripts: [ScriptDefinition]
      public var git: GitProjectSettings?
      public var isEffectivelyEmpty: Bool { /* … */ }
    }

In `apps/mac/CodansCore/Settings/GitProjectSettings.swift`:

    public nonisolated struct GitProjectSettings: Equatable, Codable, Sendable {
      public var worktreeBaseRef: String?
      public var copyIgnoredOnWorktreeCreate: Bool?
      public var copyUntrackedOnWorktreeCreate: Bool?
      public var defaultMergeStrategy: MergeStrategy?
      public var postMergeAction: MergedWorktreeAction?
      public var githubDisabled: Bool
      public var isEffectivelyEmpty: Bool { /* … */ }
    }

In `apps/mac/CodansCore/Settings/ScriptDefinition.swift` (placeholder):

    public nonisolated struct ScriptDefinition: Equatable, Codable, Sendable, Identifiable {
      public var id: UUID
      public var name: String
      public var command: String
    }

In `apps/mac/CodansCore/Settings/Settings.swift`:

    public var version: Int                                   // now 3
    public var projects: [ProjectID: ProjectSettings]         // was `repositories`
    public static let currentVersion = 3

In `apps/mac/CodansCore/Settings/SettingsMigration.swift`:

    public enum LoadOutcome: Equatable {
      case fresh
      case v3(Settings)                                       // was `v2`
      case migratedFromV1(Settings, backupURL: URL)
      case migratedFromV2(Settings, backupURL: URL)           // NEW
      case unsupported(Int, backupURL: URL)
      case corrupt(backupURL: URL)
      case migrationBackupFailed(description: String)
    }

    public static func load(
      from url: URL,
      fileManager: FileManager = .default,
      clock: @Sendable () -> Date = { Date() },
      catalogOverrides: @Sendable (ProjectID) -> (
        defaultEditor: EditorID?, worktreesDirectory: String?
      )? = { _ in nil }
    ) throws -> LoadOutcome

In `apps/mac/codans/Runtime/HierarchyManager.swift`:

    func drainLegacyOverrides() -> [ProjectID: (defaultEditor: EditorID?, worktreesDirectory: String?)]
    // removed: setWorktreesDirectory, setDefaultEditorAnySpace, findProjectAnySpace

In `apps/mac/codans/App/Features/Settings/SettingsStore.swift`:

    func mutateProject(_ pid: ProjectID, _ transform: (inout ProjectSettings) -> Void)
    // removed: mutateRepository

In `apps/mac/CodansCore/Hooks/HookSubscription.swift`:

    public enum Scope: Equatable, Sendable {
      case anyPane
      case paneID(PaneID)
      case paneLabel(String)
      case tabID(TabID)
      case tabLabel(String)
      case worktreeID(WorktreeID)
      case worktreePathGlob(String)
      case projectID(ProjectID)          // NEW
      case projectPathGlob(String)       // NEW
    }

    // Scope.Kind decoder becomes manual-and-fail-soft on unknown raw.

In `apps/mac/CodansCore/Hooks/HookConfig.swift`:

    public static let currentVersion = 2
    // decoder accepts version ∈ {1, 2}

In `apps/mac/codans/App/Features/Settings/SettingsSection.swift`:

    public enum SettingsSection: Hashable, Sendable {
      case general, github, notifications, terminal, developer
      case shortcuts, updates, about
      case projectGeneral(ProjectID)         // renamed
      case projectGit(ProjectID)             // NEW
      case projectGitHub(ProjectID)          // NEW
      case projectScripts(ProjectID)         // NEW
      case projectHooks(ProjectID)           // renamed
      case projectEnv(ProjectID)             // NEW
    }

In `apps/mac/codans/App/Features/Settings/ProjectSettingsFeature.swift`:

    @Reducer
    struct ProjectSettingsFeature {
      @ObservableState
      struct State: Equatable, Identifiable {
        let projectID: ProjectID
        var kind: ProjectKind                 // NEW
        var hooksLoad: HooksLoad = .idle
        var lastWriteFailure: String?
        // …
      }
      // Actions unchanged in shape; effects now close over SettingsStore.
    }

In `apps/mac/codans/App/Features/Settings/Panes/HookMergeView.swift`:

    public enum HookSource: Hashable, Sendable { case global, project }
    // `.repository` removed; tag label becomes "Project".

External libraries: no new SPM dependencies. Tuist `buildableFolders`
already cover the directories that gain new files (`CodansCore/Settings/`,
`CodansCore/Hooks/`, `codans/App/Features/Settings/Panes/`). No
Tuist edits required.
