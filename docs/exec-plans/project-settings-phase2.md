# ExecPlan: Project Settings Phase 2 — Sub-Pane Implementation

**Status:** Draft
**Author:** Gump
**Date:** 2026-04-25
**Builds on:** [project-settings.md](./project-settings.md) (Phase 1 — schema + rename + scaffolds)

This is a living document. The Progress, Surprises & Discoveries, Decision
Log, and Outcomes & Retrospective sections must be kept up to date as work
proceeds.

## Purpose

After this change, every per-Project preference that has a backing slot
in `settings.json` v3 / `hooks.json` v2 becomes editable from the Settings
window without leaving the app. Opening ⌘, → Project A → General shows a
single Form with five Sections (Editor, Default Shell, Worktree, GitHub,
Environment); the Worktree and GitHub Sections render only when the
Project is git-backed. Project A → Scripts shows three lifecycle TextEditors
(setup / archive / delete, git-only) and a list of user-defined scripts with
inline editing and drag-to-reorder. Project A → Hooks shows the merged
Global+Project subscription list with inline-expandable rows that edit
event / scope / command / matchPattern / mode / timeout / cwd / env /
disabled flags in place. The WorktreeHeader grows a Run split-button next
to "Open in Editor"; main click runs the default script (first `.run`
kind, or first script otherwise), ▾ menu lists every script with a
"Manage Scripts…" footer that jumps to the Scripts pane. Each Run opens a
fresh tab whose title, icon, and tint default to the script's. Worktree
lifecycle actions (`createWorktree` / `setWorktreeArchived(true)` /
`removeWorktree`) wrap their respective `setupScript` /
`archiveScript` / `deleteScript` and surface stdout/stderr in a transient
`LifecycleScriptToast`; setup is fail-stop, archive and delete are
fail-warn. `ProjectSettings.envVars` propagates into spawned terminals
through libghostty's per-surface env hook (or, if libghostty does not
expose one, via a typed `export` line ahead of `initialCommand`).

The sidebar simplifies from six sub-rows per Project (Phase 1) to three —
General, Scripts, Hooks — by retiring `.projectGit` / `.projectGitHub` /
`.projectEnv` `SettingsSection` cases and folding their content into
General Sections. The three scaffold pane files
(`ProjectGitSettingsView.swift` / `ProjectGitHubSettingsView.swift` /
`ProjectEnvSettingsView.swift`) are deleted and their names go into
`scripts/check-rename-residue.sh`'s deny-list to prevent regressions.

No new on-disk schema version: `setupScript` / `archiveScript` /
`deleteScript` are additive on `GitProjectSettings`, and `ScriptDefinition`
expands additively (existing reserved-empty Phase 1 entries decode with
`kind` defaulting to `.run`).

## Progress

- [x] M0 — libghostty per-surface env capability spike — **supported** via `ghostty_surface_config_s.env_vars` (2026-04-25)
- [x] M1 — Schema & types: ScriptKind, ScriptTintColor, ScriptDefinition
       expansion, GitProjectSettings +3 lifecycle script fields (2026-04-25,
       21 tests, full CodansCore suite green)
- [x] M2 — Mid-layer API: HookConfigClient (+upsert/+delete),
       SettingsWriter (+5 closures); HierarchyClient.runScript +
       HierarchyManager.runScript / openPane env arg deferred to M5/M8 per
       Decision Log (2026-04-25, 14 tests)
- [x] M3 — Sidebar restructure: SettingsSection drops 3 cases, retired pane
       files deleted, deny-list grows; existing fallback retained
       (2026-04-25)
- [x] M4 — General pane rewrite (5-Section Form + OptionalOverridePicker
       + ShellRegistry + EnvironmentEditorView) — 28 tests across 5 files
       (2026-04-25)
- [x] M5 — Scripts pane (Lifecycle Section + user-defined list with inline
       edit / drag-to-reorder + Run/edit/delete buttons) — 10 tests across
       4 files (2026-04-25)
- [x] M6 — Hooks pane inline edit (HookEditorRow + ScopePickerView +
       Add Hook button) — ProjectHooksSettingsView rewritten for inline
       editing of every HookSubscription field, ProjectSettingsFeature
       extended with `.upsertHook` / `.deleteHook` actions plus a
       `hookSubscriptions` state field so the editor row can edit the
       full model (HookRow remains a display-only projection); 24 tests
       across 5 files (2026-04-25)
- [ ] M7 — HeaderRunScriptSplitButton (WorktreeHeader, primary script
       entry point)
- [x] M8 — Runtime: env injection through PaneSurface / TerminalEngine —
       PaneSurface widened to take `env` and emit
       `ghostty_surface_config_s.env_vars` + `env_var_count`; TerminalEngine
       and HierarchyManager (openPane / splitPane) forward the map;
       HierarchyClient's live wiring resolves project envVars from the
       captured SettingsStore so every user-flow openPane / splitPane
       inherits Project env (closure shape unchanged so RootFeature/M10
       callsites compile untouched). 9 tests, build green (2026-04-25)
- [x] M9 — Runtime: Worktree lifecycle script execution + LifecycleScriptToast.
       `runWorktreeLifecycleScript` runs `$SHELL -c <command>` on a detached
       Task with cwd = worktree path and env = `resolvedEnv(for:in:)`;
       combined stdout+stderr is captured on a single Pipe. Three wrapper
       variants `createWorktreeWithLifecycle` / `setWorktreeArchivedWithLifecycle`
       / `removeWorktreeWithLifecycle` exist alongside the pre-existing
       lifecycle-free signatures (IPC keeps the originals untouched).
       Setup is fail-stop with catalog rollback (see Decision Log);
       archive and delete are fail-warn. Toast is a TCA `@Reducer` with
       a TestClock-driven 5s auto-dismiss on success; failure stays open
       until the user dismisses. SIGTERM Cancel is wired but no-op
       (deferred Risk R2 mitigation). 18 tests, build green (2026-04-25)
- [x] M10 — Command Palette: `.runProjectScript` Kind + build path
- [x] M11 — Tests sweep: ≥50 net new (actual ≈ 130 across all milestones).
       Build green, rename gate green. 6 pre-existing test failures
       documented in Surprises (autoSeedTabAndPaneIfNeeded reaches
       unimplemented closures; not a Phase 2 regression). (2026-04-25)
- [ ] M12 — Docs, manual QA deferred (no live app session in this run),
       /codex:review pending

## Surprises & Discoveries

### 2026-04-25 — M11: pre-existing RootFeatureTests / WorktreeDetailFeatureTests flake

Six tests fail in the full suite under Swift Testing (`selectionChangedMirrorsActiveTabFromSnapshot`,
`gitViewerOverlayVisibleTracksSelectionAgainstCatalog`, three
`headerOpenEditor*` cases, plus `tabBarActionRoutesViaScope`). All
issues are recorded as `Issue.record(...)` from `unimplemented` test
dependencies — specifically `hierarchyClient.createTab` /
`hierarchyClient.openPane`, which `RootFeature.autoSeedTabAndPaneIfNeeded`
calls on every `selectionChanged` when the target Worktree has empty
tabs. The failing tests don't stub those closures.

`autoSeedTabAndPaneIfNeeded` predates this branch (present on `main`
before Phase 2). The tests were authored before that auto-seed landed
and have been silently recording issues since. Fixing them is out of
scope for Phase 2 — flagged for a follow-up cleanup commit.

The Phase 2 milestones' own test suites (M1 / M2 / M4 / M5 / M6 / M7 /
M8 / M9 / M10) all pass when run individually. `make mac-build` is
green. `bash scripts/check-rename-residue.sh` is clean.

### 2026-04-25 — M9: catalog rollback on setup failure (deviation from design doc)

Design doc §"Worktree lifecycle execution" specified that on setup
failure "the worktree directory is left on disk… but the catalog row
is not added." Implementation deviates: `createWorktreeWithLifecycle`
runs `createWorktree` (catalog append) FIRST so the script can read
the row's path during the spawn, then on failure rolls the catalog
row back via `removeWorktree`. The on-disk directory is still left
for inspection. Rationale: the wrapper takes a `path` argument (caller
already created the directory), and the catalog row is the cheap
artifact to clean up; leaving a stale row would confuse the sidebar
without giving the user an action surface. The Create Worktree UI
flow does NOT use the wrapper variant — it uses the script-only path
through `HierarchyClient.runWorktreeLifecycleScript` because `wt sw`
already created the directory and the catalog row was attached
through `createWorktreeWithGit` before the setup script runs. Setup
failures from that path therefore leave both directory + row in
place; the toast's failure message is the user's signal to clean up.
The wrapper variant exists for future callers (IPC, scripted
provisioning) where the rollback semantics are appropriate.

### 2026-04-25 — M9: toast presents in terminal state, not running state

Design doc described the toast as showing a running spinner during
script execution. The implementation presents the toast only after
the script's terminal state (success / failure) is known; the
`.running` exit state still exists on the feature for completeness
but no current callsite passes through it. Rationale: the wrapper
variants and the script-only path both run synchronously from the
caller's perspective (`async let result = await client.…`), and
the catalog mutation needs to be observable before the toast
finishes anyway. Showing a transient running spinner would require
threading the toast presentation through a separate request before
the await resumes, which is racy with TCA's effect ordering. The
.running state remains for a future SIGTERM-capable iteration where
the toast holds open through cancellation (Risk R2 mitigation).

### 2026-04-25 — M6: hooksLoaded payload widened to carry the full subscription model

`HooksLoad.loaded` keeps `[HookRow]` as a display-only projection
(callers like the Developer pane still want the trimmed shape). The
M6 editor needs the underlying `HookSubscription` to seed
`HookEditorRow.Draft`, so the load action now returns a
`HooksLoadPayload` carrying both the rows and the raw subscriptions,
and `ProjectSettingsFeature.State` parks the latter on a new
`hookSubscriptions` field. Existing `ProjectSettingsFeatureTests`
updated to assert the new field on every successful load. The
`HierarchyManager.hookSubscriptions` shortcut I considered first does
not exist — keeping the read path through the reducer matches the
rest of the pane's tested write paths.

### 2026-04-25 — M4: SwiftUI MainActor inference forces nonisolated annotations on pure helpers

`OptionalOverridePicker.inheritRowText`, `TriStateOverrideToggle.inheritLabel`,
`EnvVarValidator`, and `ProjectGeneralSettingsView.visibleSections(for:)`
are all pure deterministic functions with no mutable state. Because they
sit inside SwiftUI `View` structs (or alongside one in the same file),
the project's strict-concurrency settings infer MainActor isolation on
them, which then forces every test to be `@MainActor`. Adding
`nonisolated` to each is the right fix — it documents that the helpers
are pure and lets test files stay `struct` (no actor ceremony).

### 2026-04-25 — M4: WriteRoutes extraction to dodge SwiftUI binding-test friction

The original draft of `ProjectGeneralSettingsView` inlined the
SettingsWriter calls inside each `Binding(set:)`. Tests that wanted to
assert "control X writes through closure Y" would have had to
instantiate the SwiftUI view, surface the private bindings, and exercise
them — heavy and brittle. Extracted the routing fan-out into a
`WriteRoutes` struct on the view. Tests construct `WriteRoutes` directly
with a stubbed `SettingsWriter.testValue` and verify each route in
isolation, mirroring `ProjectOptionsFeatureTests`' shape.

### 2026-04-25 — M10: CommandPaletteItems.build reads SettingsWriter via @Dependency

`CommandPaletteFeature.swift` is owned by other in-flight branches
(M6/M8), so the M10 build path could not change `appeared`'s payload to
plumb `Settings`. Instead the static `CommandPaletteItems.build`
function reads `@Dependency(SettingsWriter.self)` directly inside the
new `projectScriptItems(...)` helper. `swift-dependencies`' docs sanction
local `@Dependency` use inside helper functions, so the production path
runs through the same writer the rest of the app already uses without
forcing CommandPaletteFeature's signature to grow. Existing
`CommandPaletteItemsTests` cases that build with an active project now
wrap their calls in `withDependencies { ... readSnapshotSync = { Settings() } }`
to silence the unimplemented testValue.

## Decision Log

### 2026-04-25 — M5: lifecycle TextEditor commits on focus loss, not every keystroke

The plan asked for "debounced binding or onChange / onSubmit" to avoid
write-on-every-keystroke. TextEditor has no native commit-on-blur, so
`ProjectScriptsSettingsView` carries a private `LifecycleEditor`
wrapper that owns a local `@State draft` and writes through
`SettingsWriter.setProjectLifecycleScript` only when the field's
`@FocusState` flips to false. Upstream changes while the field is
unfocused adopt into `draft` so the displayed value tracks persisted
state. The wrapper is in the same file (private) since no other view
needs it.

### 2026-04-25 — M5: tint helper duplicated rather than promoted

The plan permitted duplicating `HeaderRunScriptSplitButton.color(for:)`
into `ScriptDefinitionRow` so neither file's helper has to be made
module-public. Took that path — both call sites carry an identical
five-line switch keyed by `ScriptTintColor`. Promotion stays available
if a third caller appears.

### 2026-04-25 — M5: ProjectScriptsSettingsView uses `List`, not `Form`

`.onMove` requires a List-shaped container; mixing it inside a
`.formStyle(.grouped) Form` does not work cleanly on macOS 14. The
pane uses `List { ... } .listStyle(.inset)` with two `Section`
children to keep the visual rhythm matching `Form`-styled panes while
allowing drag-to-reorder. Form-vs-List is purely a SwiftUI container
choice; the binding fan-out shape is unchanged.

### 2026-04-25 — M2: scope `createTab` widening down

The design doc proposed widening `HierarchyManager.createTab` to accept
`name / icon / tint / env / cwd / command`. On reading the runtime path
the simpler shape is:

- `createTab` keeps its current signature (only `name`).
- `openPane` gains an `env: [String: String] = [:]` arg.
- A new `HierarchyManager.runScript(_:in:)` composes `createTab` +
  `openPane(env:initialCommand:)` for the script-spawn flow.

Why: Tab does not store icon/tint today, the tab-bar does not render
icons, and the script's env/cwd are pane-level (not tab-level) data.
Widening `createTab` for arguments that do not flow into Tab is YAGNI
under CLAUDE.md ("Don't add features not in the plan / future-proof
APIs"). If a future revision teaches the tab-bar to render per-tab
icons, `createTab` can grow then.

Plan section update: M2 task 4 ("createTab widening") replaced with
"add `runScript(_:in:)` to HierarchyManager"; task 1 ("openPane gains
env arg") moves from M8 to M2 since both M5 (Scripts pane Run) and M9
(lifecycle execution) consume it.

### 2026-04-25 — M8: env C-string ownership lives on PaneSurface; HierarchyClient closure shape unchanged

PaneSurface holds onto every `strdup`'d `(key, value)` pair plus the
backing `UnsafeMutableBufferPointer<ghostty_env_var_s>` for its full
lifetime, freeing both in `isolated deinit`. libghostty does not document
whether `ghostty_surface_new` copies the env_vars buffer, so we
conservatively assume it does not and mirror the existing
`workingDirectoryCString` lifecycle. Empty env map renders
`env_vars = nil, env_var_count = 0` (no allocations).

The plan asked to widen `HierarchyClient.openPane` /  `splitPane`
closures with an `env` parameter. Closures cannot have default arguments
in Swift, so growing the arity would force every callsite (including
RootFeature.swift, owned by parallel M10 work that we cannot touch) to
update. Instead the live wiring keeps the closure shape unchanged and
resolves the project's envVars internally via the captured SettingsStore
(weak capture, mirroring the runScript closure). Result: existing
callers (TabBar / SplitViewport / CreateWorktree / IPC openPane /
RootFeature) auto-inherit Project envVars without any signature change;
runScript still passes the resolved env explicitly through
`manager.openPane(..., env:)`.

### 2026-04-25 — M0: libghostty per-surface env supported

The vendored ghostty SDK exposes per-surface env via
`ghostty_surface_config_s.env_vars: ghostty_env_var_s*` plus
`env_var_count: size_t`
(`apps/mac/.build/ghostty/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h:444-481`).
`ghostty_env_var_s` carries `const char* key` / `const char* value`. M8
will populate this array directly when constructing the surface config;
the typed-export fallback designed in the design doc is not needed for
production. PaneSurface currently uses
`ghostty_surface_config_new()` (line 71) and we extend the existing
config with `env_vars` / `env_var_count` before handing it to ghostty.

Risk R1's mitigation framing ("if libghostty cannot, types `export`
statements …") is dropped from M8's scope. The Environment Section
caption no longer needs the `HISTCONTROL=ignorespace` warning. The
spike confirms the design's preferred path is live.

## Outcomes & Retrospective

(To be filled at milestone completion.)

## Context and Orientation

Related documents:

- Design doc (this plan implements): [docs/design-docs/project-settings-phase2.md](../design-docs/project-settings-phase2.md)
- Phase 1 design doc (still authoritative for schema + rename invariants): [docs/design-docs/project-settings.md](../design-docs/project-settings.md)
- Phase 1 ExecPlan (already completed): [docs/exec-plans/project-settings.md](./project-settings.md)
- Architecture: [docs/architecture.md](../architecture.md)

Key source files (read before touching):

- `apps/mac/CodansCore/Settings/ProjectSettings.swift` — per-Project
  fields. `envVars` and `scripts` are reserved-empty and grow real
  bindings in M4 / M5.
- `apps/mac/CodansCore/Settings/GitProjectSettings.swift` — git-only
  override fields. M1 adds `setupScript` / `archiveScript` / `deleteScript`
  (additive Codable, no schema bump).
- `apps/mac/CodansCore/Settings/ScriptDefinition.swift` — Phase 1
  placeholder (`id` / `name` / `command`). M1 expands to
  `(id, kind, name, command, systemImage?, tintColor?)`.
- `apps/mac/CodansCore/Hooks/HookSubscription.swift` — 9-case Scope
  enum the Hooks pane edits inline.
- `apps/mac/codans/App/Features/Settings/SettingsSection.swift` —
  pane enum. M3 drops `.projectGit` / `.projectGitHub` / `.projectEnv`.
- `apps/mac/codans/App/Features/Settings/SettingsWindowFeature.swift`
  — pane composition. M3 prunes the retired-pane subrows mapping;
  `projectsChanged` already falls back to General when kind hides the
  selection (Phase 1 fix; cite the existing behaviour in M3 commit).
- `apps/mac/codans/App/Features/Settings/Panes/ProjectGeneralSettingsView.swift`
  — Phase 1's minimal pane. M4 rewrites this as a 5-Section Form.
- `apps/mac/codans/App/Features/Settings/Panes/{ProjectGitSettingsView,ProjectGitHubSettingsView,ProjectEnvSettingsView}.swift`
  — three scaffolds deleted in M3 once their content lives in General.
- `apps/mac/codans/App/Features/Settings/Panes/ProjectScriptsSettingsView.swift`
  — placeholder. M5 fills.
- `apps/mac/codans/App/Features/Settings/Panes/ProjectHooksSettingsView.swift`
  — Phase 1 read-only. M6 makes it editable.
- `apps/mac/codans/App/Clients/HookConfigClient.swift` — TCA bridge
  for `hooks.json`. M2 adds `upsert` / `delete` closures over the existing
  `HookConfigStore.scheduleSave` pipeline.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — manager bridge.
  M2 adds `runScript`. M9 wires `createWorktree` / `setWorktreeArchived` /
  `removeWorktree` through `runWorktreeLifecycleScript`.
- `apps/mac/codans/App/Features/Editor/EditorFeature.swift` — defines
  `SettingsWriter` today. M2 adds `setProjectDefaultShell` /
  `setProjectGitField` / `setProjectEnvVar` / `setProjectScripts` /
  `setProjectLifecycleScript`.
- `apps/mac/codans/Runtime/TerminalEngine.swift` and
  `apps/mac/codans/Runtime/Ghostty/PaneSurface.swift` — spawn path.
  M8 widens `ensureSurface` and `PaneSurface.init` to carry `env: [String:
  String]`. M0 (the libghostty spike) determines whether per-surface env
  is supported or whether the typed-export fallback is mandatory.
- `apps/mac/codans/Runtime/HierarchyManager.swift` — orchestrator for
  spawn + lifecycle. M2 widens `createTab`; M8 wires env into spawn paths;
  M9 adds `runWorktreeLifecycleScript(_:for:)` and wraps the three
  lifecycle methods.
- `apps/mac/codans/App/Features/CommandPalette/CommandPaletteItem.swift`
  / `CommandPaletteItems.swift` — palette entries. M10 adds
  `.runProjectScript(ProjectID, WorktreeID, ScriptDefinition.ID)` Kind and
  the build path that iterates the active Project's scripts.
- `apps/mac/codans/App/Features/WorktreeHeader/HeaderOpenSplitButton.swift`
  — pattern HeaderRunScriptSplitButton mirrors. M7 adds the new view
  next to the existing one in the same toolbar slot.
- `scripts/check-rename-residue.sh` — CI rename gate. M3 grows the
  deny-list with the three retired pane class names.

Terms used in this plan:

- **Sub-pane**: a `SettingsSection` case + matching pane view file. Phase 1
  split per-Project fields across six sub-panes; Phase 2 collapses to three.
- **Inheritance / override**: a `Project`-scoped optional that, when nil,
  reads from the global default (`Settings.general.*` or
  `Settings.github.*`). The override controls render "Use global default —
  <inheritedValue>" inline so users see the resolved value without jumping
  panes.
- **Lifecycle script**: one of `setupScript` / `archiveScript` /
  `deleteScript` on `GitProjectSettings`. Distinct from `HookEvent.worktree*`
  hooks (which fire async / fire-and-forget) — lifecycle scripts run
  inline, block the lifecycle action on non-zero exit (setup) or warn
  (archive / delete), and surface output in `LifecycleScriptToast`.
- **User-defined script** / **ScriptDefinition**: a stored `(id, kind,
  name, command, systemImage?, tintColor?)` entry under
  `ProjectSettings.scripts`. Runs as `$SHELL -c <command>` in a fresh tab
  via `HierarchyClient.runScript`.
- **Spawn-path env injection**: the route by which `ProjectSettings.envVars`
  reaches the running shell. Preferred path: libghostty per-surface env.
  Fallback: a typed `export A='1' B='2' …` line into the PTY before the
  user's `initialCommand`.

Orientation paragraph for cross-area work: per-Project state lives on
`SettingsStore.settings.projects[pid]`. Reads from views go through
`@Environment(SettingsStore.self)` (Phase 1's code-reviewer fix); writes
go through `SettingsWriter` closures, which mutate via
`SettingsStore.mutateProject(pid)` and call `scheduleSave` / `flush` on
the underlying `AtomicFileStore`. `HierarchyClient` is the only bridge
to the runtime side; it owns `createWorktree` / `setWorktreeArchived` /
`removeWorktree` (which M9 wraps with lifecycle execution) and `createTab`
/ `runScript` (which M8 / M5 / M7 dispatch into).

## Plan of Work

The work splits into milestones grouped by dependency layer. Within each
milestone, tasks land as sequential commits unless flagged "parallel".
M4–M7 are the largest blocks and are flagged for Agent-team
parallelisation since they share no data files.

### Milestone 0: libghostty per-surface env capability spike (R1 verification)

The whole env-injection design hinges on whether libghostty exposes a
per-surface env hook. Before any view code is written we run a small
spike: read the vendored ghostty SDK header surface
(`apps/mac/.build/ghostty` / `vendor/ghostty/...`) for any
`ghostty_surface_*_env*` symbol or config field that lets us seed the
new pty's env at surface creation. If yes, M8 uses it directly. If no,
M8 carries the typed-export fallback from the start and we drop "the
preferred path" framing.

At the end of M0 the Decision Log records which path M8 takes. If the
result is "fallback only", we also add an "envInjectionMode" footnote to
the Environment Section caption per Risk R1's mitigation.

Acceptance: a written entry in this plan's Decision Log titled
"M0 — libghostty per-surface env: <supported|unsupported>", citing the
SDK symbol or its absence.

### Milestone 1: Schema & types (additive, no schema bump)

Goal: every model field Phase 2's UX writes to exists on disk and
round-trips Codable.

Tasks:

1. **`apps/mac/CodansCore/Settings/ScriptKind.swift`** (NEW): define
   `enum ScriptKind: String, Codable, CaseIterable, Sendable { case run,
   test, deploy, lint, format, custom }`. Add static helpers
   `defaultName(for:)`, `defaultSystemImage(for:)`, `defaultTintColor(for:)`
   returning per-kind values. Keep symbol/colour resolution inline; SwiftUI
   `Color` / SF Symbols don't import here, so the helpers return raw
   `String` (SF Symbol name) / `ScriptTintColor` (next task) — view-side
   resolves to `Image` / `Color`.
2. **`apps/mac/CodansCore/Settings/ScriptTintColor.swift`** (NEW):
   define `enum ScriptTintColor: String, Codable, Sendable { case green,
   yellow, red, blue, teal, purple, gray }`. The SwiftUI `Color`
   resolution helper lives view-side in M5.
3. **`apps/mac/CodansCore/Settings/ScriptDefinition.swift`** (EXPAND):
   add `kind: ScriptKind`, `systemImage: String?`, `tintColor:
   ScriptTintColor?` while preserving existing `id` / `name` / `command`.
   Codable: `kind` decodes with default `.run` when absent so any reserved-
   empty Phase 1 settings round-trip. Add computed properties:
   `displayName` (returns `name` if non-empty else `kind.defaultName`),
   `resolvedSystemImage` (returns `systemImage` only when `kind == .custom`,
   otherwise `kind.defaultSystemImage`), `resolvedTintColor` (same custom-
   only override semantics).
4. **`apps/mac/CodansCore/Settings/GitProjectSettings.swift`** (EXPAND):
   add `setupScript: String`, `archiveScript: String`, `deleteScript:
   String`, default empty. Codable: `decodeIfPresent` with default `""`.
   Extend `isEffectivelyEmpty` so an all-fields-empty `git` subtree still
   collapses to nil through the existing `Settings.garbageCollect()` path.
5. **`apps/mac/CodansCore/Settings/ProjectSettings.swift`** (no field
   changes, but add `normalizeScriptIDs() mutating` per Risk R5: walks
   `scripts`, replaces any duplicate `id` with a fresh UUID, returns the
   list of replaced IDs for logging). Wire into the `Settings` `decode`
   path so loads always normalize.

Tests in this milestone (CodansCoreTests):

- `ScriptDefinitionCodableTests.swift`: round-trips for every `ScriptKind`
  case; predefined kinds ignore `systemImage` / `tintColor` via
  `resolvedSystemImage` / `resolvedTintColor` (raw stored value preserved
  but resolver returns kind default); `.custom` honours both overrides.
- `GitProjectSettingsCodableTests.swift`: a v3 `settings.json` payload
  without `setupScript` / `archiveScript` / `deleteScript` decodes with
  empty strings; a payload with them round-trips identically; an
  all-empty `git` subtree collapses to nil through `garbageCollect()`.
- `ProjectSettingsScriptIDNormalisationTests.swift`: a payload with two
  `ScriptDefinition` entries sharing the same `id` decodes, but
  `normalizeScriptIDs()` replaces one and logs the replacement (assert via
  the swap-store handler).

### Milestone 2: Mid-layer API (clients, writer, store)

Goal: every UI write site has a closure to call. No view code yet.

Tasks:

1. **`apps/mac/codans/App/Clients/HookConfigClient.swift`** (EXPAND):
   add `var upsert: @MainActor @Sendable (HookSubscription) async throws
   -> Void` and `var delete: @MainActor @Sendable (UUID) async throws ->
   Void`. Live impls call into `HookConfigStore.upsert(_:)` /
   `HookConfigStore.remove(id:)` (add these on the store: `upsert` mutates
   in-place by id-match-or-append and calls `scheduleSave`; `remove` is
   no-op when id is absent). The user-facing `upsert` rejects subscriptions
   whose `command` starts with the `__codans/internal:` prefix and
   throws a typed `WriteRefused.internalNamespace` so the UI can surface
   the message.
2. **`apps/mac/codans/App/Features/Editor/EditorFeature.swift`**
   (`SettingsWriter` extension): add five closures.
   - `setProjectDefaultShell: @Sendable (ProjectID, String?) async ->
     Void` — nil clears the override.
   - `setProjectGitField: @Sendable (ProjectID, GitFieldUpdate) async ->
     Void` — `GitFieldUpdate` enum named in design doc lists every
     mutable git field. Live impl folds into
     `SettingsStore.mutateProject(pid)`, ensures `git = git ?? .init()`
     before mutation, runs the existing `collapseEmptyGit()` post-mutation.
   - `setProjectEnvVar: @Sendable (ProjectID, String, String?) async ->
     Void` — `nil` value removes the key.
   - `setProjectScripts: @Sendable (ProjectID, [ScriptDefinition]) async
     -> Void` — full replace; reorder writes route here.
   - `setProjectLifecycleScript: @Sendable (ProjectID,
     SettingsWriter.WorktreeLifecycle, String) async -> Void` —
     `WorktreeLifecycle = .setup | .archive | .delete`.

   The `.testValue` / `.previewValue` initializers grow no-op stubs.
3. **`apps/mac/codans/App/Clients/HierarchyClient.swift`** (EXPAND):
   add `var runScript: @MainActor @Sendable (UUID, ProjectID, WorktreeID)
   async throws -> Void`. Live impl inside `HierarchyManager`: looks up the
   `ScriptDefinition` via `SettingsWriter.readSnapshotSync()`, throws
   `RunScriptError.unknownScript` if missing, otherwise calls
   `createTab(...)` with the resolved metadata.
4. **`apps/mac/codans/Runtime/HierarchyManager.swift`** (EXPAND
   `createTab`): widen the signature to accept `name: String?`, `icon:
   String?`, `tint: ScriptTintColor?`, `env: [String: String]`,
   `cwd: URL?`, `command: String?` (all optional / defaulted-empty).
   Existing tab-bar `+` callsite passes nil/empty for all new args (no
   behaviour change for them). The script-spawn callsite from M5 / M7
   carries the resolved metadata.
5. **`apps/mac/codans/Runtime/HierarchyManager.swift`** (NEW
   helper): `nonisolated func resolvedEnv(for projectID: ProjectID,
   in settings: Settings) -> [String: String]` — exact body from the
   design doc Section "Environment: model + injection". Pure function;
   takes a `Settings` snapshot; merges process env with project envVars
   ("project keys win"). Lives at the manager level so M8 / M9 can both
   call it.

Tests in this milestone (mac/codans/Tests):

- `HookConfigClientTests.swift`: `upsert` of a fresh subscription appends;
  upsert of an existing id replaces; `delete` of a present id removes;
  `delete` of a missing id no-ops; upsert of a `__codans/internal:`
  command throws `WriteRefused.internalNamespace`.
- `SettingsWriterPhase2Tests.swift`: each of the five new closures on a
  `SettingsStore` test instance writes the expected `Settings` mutation
  and persists through `flush()`. `setProjectGitField(.githubDisabled
  (true))` flips the bool; `setProjectEnvVar(pid, "MY_VAR", nil)` removes
  the key; `setProjectScripts(pid, [])` clears the list.
- `HierarchyManagerCreateTabBackcompatTests.swift`: existing tab-bar `+`
  path through `createTab` with all-default new args produces the same
  `Tab` struct as before this widening (regression guard).

### Milestone 3: Sidebar restructure & retire scaffolds

Goal: the sidebar shows three sub-rows per Project; the three retired
pane files are deleted; the rename-residue gate prevents re-introduction.
This milestone lands early (before M4) so the General pane rewrite in M4
does not have to coexist with the dead Git/GitHub/Env panes.

Tasks:

1. **`apps/mac/codans/App/Features/Settings/SettingsSection.swift`**
   (DROP 3 cases): remove `.projectGit(ProjectID)`, `.projectGitHub(ProjectID)`,
   `.projectEnv(ProjectID)` from the enum. Update `subrows(for:projectID:)`
   to return only `[.projectGeneral, .projectScripts, .projectHooks]`
   regardless of `ProjectKind` (Phase 2 takes the kind difference inside
   General, not at the sidebar). Update `projectID` extractor to drop the
   removed cases.
2. **`apps/mac/codans/App/Features/Settings/SettingsWindowView.swift`**
   detail switch: drop the three `.projectGit` / `.projectGitHub` /
   `.projectEnv` cases. The remaining three Project cases stay.
3. **DELETE** `apps/mac/codans/App/Features/Settings/Panes/ProjectGitSettingsView.swift`,
   `apps/mac/codans/App/Features/Settings/Panes/ProjectGitHubSettingsView.swift`,
   `apps/mac/codans/App/Features/Settings/Panes/ProjectEnvSettingsView.swift`.
4. **DELETE** their tests under
   `apps/mac/codans/Tests/ProjectSettingsScaffoldTests.swift` (or
   wherever Phase 1 anchored "scaffold" coverage; the file is small).
5. **`scripts/check-rename-residue.sh`** (DENY-LIST GROW): add
   `ProjectGitSettingsView`, `ProjectGitHubSettingsView`,
   `ProjectEnvSettingsView` to the deny pattern list with a short
   "// Retired in Project Settings Phase 2" comment.
6. **`apps/mac/codans/App/Features/Settings/SettingsWindowFeature.swift`**:
   verify `projectsChanged` already falls back to `.projectGeneral(pid)`
   when `subrows(for:)` no longer contains the current selection (Phase 1
   fix). Add a regression test for the reverse direction: a Project
   already on `.projectGeneral` keeps that selection across a kind flip
   from `git_repo` to `plain_dir`.
7. **`apps/mac/codans/App/Features/Settings/SettingsWindowFeature.swift`**
   pane composition: drop the `IdentifiedArrayOf` references to
   `.projectGit(...)` / `.projectGitHub(...)` / `.projectEnv(...)` if any
   (likely none — the pane state is keyed by `ProjectID`, not section).

Tests in this milestone:

- `SettingsSectionPhase2Tests.swift` (UPDATE existing): assert
  `SettingsSection.subrows(for: .gitRepo, projectID: pid)` returns
  `[.projectGeneral(pid), .projectScripts(pid), .projectHooks(pid)]`.
  Same for `.plainDir`. The retired cases no longer compile (compile-
  time guard).
- `SettingsWindowFeatureKindFlipTests.swift` (UPDATE existing
  `projectsChangedFallsBackToGeneralWhenKindHidesCurrentSelection`):
  current test covers `.projectGit → .projectGeneral` on flip. Add a
  symmetrical test for `.plainDir → .gitRepo` flip keeping
  `.projectGeneral` (no spurious bounce).
- Run `bash scripts/check-rename-residue.sh` and confirm clean exit.

### Milestone 4: General pane rewrite (5-Section Form)

Goal: opening Project A → General shows one Form with five Sections,
kind-conditional rendering, OptionalOverridePicker shared across all
nil-override fields. **Parallelisable with M5 / M6 / M7** — different
files, no shared state.

Tasks:

1. **`apps/mac/CodansCore/Settings/ShellRegistry.swift`** (NEW):
   `struct ShellRegistry` with a static `installed: [String]` that probes
   `/etc/shells` for paths whose binaries exist on disk. Mirrors
   `EditorRegistry`. Tests stub via a `ShellRegistry.Provider` protocol so
   we don't read the real filesystem in tests.
2. **`apps/mac/codans/App/Features/Settings/Panes/OptionalOverridePicker.swift`**
   (NEW): generic SwiftUI view
   `OptionalOverridePicker<Value: Hashable>(title: String, selection:
   Binding<Value?>, inheritedValue: Value?, options: [(value: Value, label:
   String)], inheritedLabel: (Value?) -> String)`. Renders a Picker whose
   `tag(nil)` row label is `"Use global default — \(inheritedLabel
   (inheritedValue))"`. M4 instantiates it for `defaultEditor`,
   `defaultShell`, `worktreeBaseRef`, `defaultMergeStrategy`, `postMergeAction`.
3. **`apps/mac/codans/App/Features/Settings/Panes/OptionalToggleBinding.swift`**
   (NEW helper): a tiny adapter so the `copyIgnoredOnWorktreeCreate` /
   `copyUntrackedOnWorktreeCreate` Picker (three options: "Use global
   default — yes" / "Yes" / "No") can express the three states without a
   custom view. Implementation: a Picker over `enum TriState { case
   inherit, yes, no }` with `Binding` adapters in / out of `Bool?`.
4. **`apps/mac/codans/App/Features/Settings/Panes/EnvironmentEditorView.swift`**
   (NEW): the key/value table. Reads `projects[pid]?.envVars`; renders
   a column-aligned list of `(key, value, ✕ button)` rows sorted alphabetically
   by key on display. "Add variable" appends a blank row whose KEY field
   takes focus. Validation: KEY rejects non-POSIX (`[A-Za-z_][A-Za-z0-9_]*`)
   and duplicate keys; VALUE rejects strings containing `\n` or `\r`
   (Risk R3). Errors render inline with a red border + accessibility hint.
   Writes route through `SettingsWriter.setProjectEnvVar(pid, key,
   newValue)`; deletes route through `setProjectEnvVar(pid, key, nil)`.
5. **`apps/mac/codans/App/Features/Settings/Panes/ProjectGeneralSettingsView.swift`**
   (REWRITE): one `Form` with five sibling `Section`s in the order from the
   design doc (Editor, Default Shell, Worktree, GitHub, Environment).
   Worktree and GitHub render only when `projectKind == .gitRepo`.
   - Editor Section: `OptionalOverridePicker<EditorID>` with
     `inheritedValue = settingsStore.settings.general.defaultEditorID`.
   - Default Shell Section: `OptionalOverridePicker<String>` with
     `inheritedValue = settingsStore.settings.general.defaultShell`,
     options from `ShellRegistry.installed`.
   - Worktree Section: TextField + "Choose…" for `worktreesDirectory`
     (matches Phase 1's `ProjectOptions` flow); TextField for
     `git.worktreeBaseRef`; two `TriState` Pickers for `copyIgnored*` /
     `copyUntracked*`.
   - GitHub Section: two `OptionalOverridePicker`s for
     `defaultMergeStrategy` / `postMergeAction`; one Toggle for
     `githubDisabled`.
   - Environment Section: embed `EnvironmentEditorView`.
   View reads `@Environment(SettingsStore.self)` for live state (Phase 1
   pattern). Bindings write through `SettingsWriter` closures.
6. **`apps/mac/codans/App/Features/Settings/ProjectSettingsFeature.swift`**:
   no reducer changes for M4 (writes go through `SettingsWriter` closures,
   not through this feature's actions). Drop any `.projectGit*` /
   `.projectGitHub*` / `.projectEnv*` action cases that Phase 1 reserved
   for the retired sub-panes.

Tests in this milestone:

- `OptionalOverridePickerTests.swift`: `tag(nil)` selection writes nil
  through the binding; tag(.some(value)) writes the value; the inherited
  label string composes correctly when `inheritedValue == nil` (renders
  `"Use global default — \(noneFallback)"`).
- `ProjectGeneralSettingsViewKindRenderTests.swift`: render the view on a
  `.plainDir` Project and assert the SwiftUI hierarchy has no Worktree /
  GitHub Sections (use `XCTAssertViewContains` shim from
  `CodansTestSupport`); render on `.gitRepo` and assert all five.
- `EnvironmentEditorValidationTests.swift`: a non-POSIX KEY shows the
  inline error and does not invoke `setProjectEnvVar`; a value with `\n`
  rejects with the "no newlines in env values" message; duplicate KEY
  refuses to commit; deleting a row calls `setProjectEnvVar(pid, key,
  nil)`.
- `ProjectGeneralSettingsViewWriteRoutingTests.swift`: each control's
  binding routes to the correct `SettingsWriter` closure with the right
  arguments.

### Milestone 5: Scripts pane (lifecycle + user-defined list)

Goal: opening Project A → Scripts shows three lifecycle TextEditors (git-
only) and a user-defined list with inline edit / drag-to-reorder.
**Parallelisable with M4 / M6 / M7**.

Tasks:

1. **`apps/mac/codans/App/Features/Settings/Panes/ScriptDefinitionRow.swift`**
   (NEW): SwiftUI view for a single script row. Collapsed form shows kind
   icon (resolved via `script.resolvedSystemImage` + `resolvedTintColor`
   → SwiftUI `Image` / `Color`), name, command preview, and three
   trailing buttons (▶ Run, edit pencil, ✕ delete). Expanded form shows:
   - Name TextField
   - Command TextEditor (multi-line)
   - Kind Picker (every `ScriptKind` case)
   - When `kind == .custom`: SF Symbol picker (a small grid of common
     run/test/deploy/lint/format icons + a free-form TextField for any
     SF Symbol name) and a `ScriptTintColor` Picker.
   - Save / Cancel buttons (Save calls
     `SettingsWriter.setProjectScripts(pid, updatedArray)`).
2. **`apps/mac/codans/App/Features/Settings/Panes/ProjectScriptsSettingsView.swift`**
   (REWRITE): `Form` with two Sections.
   - Lifecycle Section (rendered only when `kind == .gitRepo`): three
     labelled TextEditors bound to `git.setupScript` / `git.archiveScript`
     / `git.deleteScript` through
     `SettingsWriter.setProjectLifecycleScript`.
   - Scripts Section: `ForEach(scripts)` of `ScriptDefinitionRow` with
     `.onMove` writing the reordered array back via
     `setProjectScripts`. "+ Add" prepends a new row already in expanded
     form, kind defaulting to `.run`, name empty, command empty.
3. **Run-button activation**: each row's ▶ Run button dispatches
   `HierarchyClient.runScript(scriptID, projectID, currentWorktreeID)`.
   `currentWorktreeID` comes from `state.lastFocusedWorktreeID` on the
   `ProjectSettingsFeature` (carry that on the feature state — populate
   from the parent `SettingsWindowFeature` whenever it knows, fall back
   to `project.worktrees.first` if the user has not focused one).
4. **Delete confirmation**: ✕ button shows a `.confirmationDialog`
   ("Delete script "<name>"?") before calling `setProjectScripts(pid,
   currentArrayWithRowRemoved)`.

Tests in this milestone:

- `ScriptDefinitionRowExpansionTests.swift`: clicking edit reveals all
  fields; switching kind to non-`.custom` hides the icon / colour pickers
  but preserves any typed `systemImage` / `tintColor` in
  `ScriptDefinition` so a flip back to `.custom` restores them.
- `ProjectScriptsSettingsViewLifecycleTests.swift`: lifecycle Section
  hidden on `.plainDir`; visible on `.gitRepo`; typing into the setup
  TextEditor calls `setProjectLifecycleScript(pid, .setup, newValue)`.
- `ProjectScriptsSettingsViewReorderTests.swift`: dragging row 0 to row 2
  invokes `setProjectScripts(pid, [s2, s1, s0])` (or whatever the
  `.onMove` semantics produce).
- `ProjectScriptsSettingsViewRunButtonTests.swift`: ▶ Run dispatches
  `HierarchyClient.runScript(scriptID, projectID, worktreeID)` with the
  expected arguments.

### Milestone 6: Hooks pane inline edit

Goal: opening Project A → Hooks shows the merged Global+Project list with
inline-expandable rows that edit every HookSubscription field.
**Parallelisable with M4 / M5 / M7**.

Tasks:

1. **`apps/mac/codans/App/Features/Settings/Panes/ScopePickerView.swift`**
   (NEW): kind-aware scope picker. Top-level Picker chooses one of nine
   `Scope.Kind`s. Below, a conditional value control:
   - `.anyPane` — none.
   - `.paneID` / `.tabID` / `.worktreeID` / `.projectID` — Picker over the
     relevant catalog entities (current Project's children for pane / tab
     / worktree; all open Projects for projectID; defaults to current).
     Catalog comes from `HierarchyClient.children(...)` calls; M2's
     `runScript` doesn't add new catalog reads, but ScopePickerView does.
   - `.paneLabel` / `.tabLabel` — TextField.
   - `.worktreePathGlob` / `.projectPathGlob` — TextField with placeholder
     `**/feature/*` / `**/repos/*`.
   Uses an internal `[ScopeKind: String]` buffer so toggling between
   text-valued kinds preserves user input.
2. **`apps/mac/codans/App/Features/Settings/Panes/HookEditorRow.swift`**
   (NEW): the expandable row from the design doc Section "Hooks: pane
   edit UI". Edit fields: event Picker, ScopePickerView, command
   TextEditor, matchPattern TextField + three flag toggles, mode Picker
   (`fireAndForget` / `awaitActions`), timeout Stepper (0 … 600 seconds),
   cwd TextField (optional), env list (a tiny EnvironmentEditorView
   variant — keep that view's table generic enough for both general
   envVars and per-hook env), `disabled` Toggle. Save validates per
   design doc; failure keeps row expanded with red-flagged fields.
3. **`apps/mac/codans/App/Features/Settings/Panes/ProjectHooksSettingsView.swift`**
   (REWRITE): replace the read-only list with a `ForEach` of
   `HookEditorRow`. Add a "+ Add Hook" button at the top that inserts a
   new row already expanded with the scope pre-selected to
   `.projectID(currentProjectID)`. Save routes through
   `HookConfigClient.upsert`; Delete (per-row) routes through
   `HookConfigClient.delete`. Saving with a non-project scope shows a
   tooltip ("This hook will move to the Global list") on Save and the
   row disappears from this pane on next refresh.
4. **`apps/mac/codans/App/Features/Settings/ProjectSettingsFeature.swift`**:
   add reducer actions for hook upsert / delete dispatched from
   `HookEditorRow`. Effects call into `HookConfigClient.upsert` /
   `delete` and surface failure as inline error text on the row.
5. **EnvironmentEditorView genericisation**: extract M4's
   `EnvironmentEditorView` into a parameterised view that takes
   `Binding<[String: String]>` plus a write-through callback so both the
   Project envVars editor (M4) and per-hook env editor (M6) share the
   same code. (This task may belong to M4 if M6 lands first; the
   parallelisation rule "different files, no shared state" requires
   care here — schedule the genericisation in M4 and have M6 import.)

Tests in this milestone:

- `ScopePickerViewKindSwitchTests.swift`: toggling between `.paneLabel`
  and `.tabLabel` preserves the typed string in the buffer; toggling to
  `.paneID` reads from the buffer is a no-op (buffer ignored).
- `HookEditorRowSaveValidationTests.swift`: empty event blocks Save;
  empty command blocks Save; ID-scope without a Picker selection blocks
  Save; valid combinations route to `HookConfigClient.upsert` with the
  right `HookSubscription` payload.
- `HookEditorRowDeleteRouteTests.swift`: Delete shows the confirmation,
  then dispatches `HookConfigClient.delete(subscriptionID)`.
- `ProjectHooksSettingsViewAddHookTests.swift`: + Add inserts a new row
  with `scope == .projectID(currentProjectID)`; cancelling discards.

### Milestone 7: HeaderRunScriptSplitButton (WorktreeHeader)

Goal: every Worktree header shows a Run split button next to the existing
"Open in Editor" split button. **Parallelisable with M4 / M5 / M6**.

Tasks:

1. **`apps/mac/codans/App/Features/WorktreeHeader/HeaderRunScriptSplitButton.swift`**
   (NEW): SwiftUI view using `Menu(primaryAction:)`. State source:
   `@Environment(SettingsStore.self) settings.projects[currentProjectID]?.scripts`.
   - Primary action: `scripts.first { $0.kind == .run }` ??
     `scripts.first`. Calls `HierarchyClient.runScript(...)` for that
     script. Empty list: routes to "open Settings → Scripts pane" via
     `SettingsWindowPresenter` + `.projectScripts(currentProjectID)`.
   - Menu items: one per script (label = `displayName`, icon =
     `resolvedSystemImage`, tint = `resolvedTintColor`); Divider; "Manage
     Scripts…" footer that opens Settings → Scripts.
   - Label / icon / tint of the button itself reflects the primary
     script's resolved values (or "Run" + play.fill + accent if empty).
2. **`apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderView.swift`**
   (or equivalent host of `HeaderOpenSplitButton`): place
   `HeaderRunScriptSplitButton` immediately after the Open button in
   the toolbar layout. No other layout changes.
3. **RootFeature route**: add an action handler that maps the button's
   activation to `HierarchyClient.runScript`. Existing `OpenInEditor`
   activation lives nearby; mirror its shape.

Tests in this milestone:

- `HeaderRunScriptSplitButtonStateTests.swift`: empty `scripts` array →
  primary action routes to "open Scripts pane"; non-empty array picks
  the first `.run` kind; falls back to `scripts.first` when no `.run`
  exists; menu lists every script + Manage Scripts trailer.
- `HeaderRunScriptSplitButtonResolutionTests.swift`: primary script's
  label, icon, tint match `.resolvedSystemImage` / `.resolvedTintColor`
  — `.custom` script honours overrides; predefined kinds ignore stored
  override values per the resolver semantics.

### Milestone 8: Runtime — env injection through PaneSurface

Goal: `ProjectSettings.envVars` reaches the running shell. Path
determined by M0's spike result.

Tasks:

1. **`apps/mac/codans/Runtime/Ghostty/PaneSurface.swift`**: widen
   `init(...)` to accept `env: [String: String]` (default empty). If
   M0 said per-surface env is supported: pass `env` into the libghostty
   surface config at creation. If not: store on the surface; after the
   pty signals ready and before any `initialCommand` runs, write
   `" export A='1' B='2' …\n"` (single line, leading space for
   `HISTCONTROL=ignorespace`, single-quote escaping, ends with the
   user's intended `initialCommand` if any).
2. **`apps/mac/codans/Runtime/TerminalEngine.swift`**: widen
   `ensureSurface(...)` to forward `env: [String: String]`. The
   `bringUp` path performs the M0 capability check once and stores
   `let supportsPerSurfaceEnv: Bool` for `PaneSurface` to read.
3. **`apps/mac/codans/Runtime/HierarchyManager.swift`**:
   `openPane` resolves env via `resolvedEnv(for: projectID, in:
   settings)` (M2 helper) and forwards into `ensureSurface`. The
   `createTab` widening from M2 already carries `env`; the script-spawn
   path from M5 / M7 calls `createTab(..., env: resolvedEnv(...))`.

Tests in this milestone (live + integration):

- `PaneSurfaceEnvInjectionTests.swift` (unit, fallback path): given
  `supportsPerSurfaceEnv == false`, the pty receives the expected typed-
  export prefix line. Use a `MockPTYWrite` shim that captures bytes.
- `HierarchyManagerResolvedEnvTests.swift`: `resolvedEnv` merges process
  env with project envVars correctly; a process-env key collides with a
  project key and the project value wins; an empty project envVars map
  returns process env unchanged.
- Smoke test (live, gated behind `#if INTEGRATION`): spawn a pane with
  `env = ["MY_VAR": "hello"]` and assert that `printenv MY_VAR` returns
  `hello`. May be skipped on CI if libghostty isn't available there;
  document in the test file.

### Milestone 9: Runtime — Worktree lifecycle execution

Goal: `createWorktree` / `setWorktreeArchived(true)` / `removeWorktree`
each runs the relevant lifecycle script and surfaces output in
`LifecycleScriptToast`. Setup is fail-stop, archive and delete are
fail-warn.

Tasks:

1. **`apps/mac/codans/Runtime/HierarchyManager.swift`** (NEW
   helper): `func runWorktreeLifecycleScript(_ phase:
   SettingsWriter.WorktreeLifecycle, for worktreeID: WorktreeID) async
   throws -> LifecycleScriptResult`. Reads `git.<phase>Script` from
   the project's settings; empty string returns `.skipped`. Otherwise
   spawns a `Process` with `executableURL = userDefaultShell`,
   `arguments = ["-c", scriptCommand]`, `environment = resolvedEnv(...)`,
   `currentDirectoryURL = worktreePath`. Captures combined stdout+stderr
   into a buffered `String`. Returns `.success(stdout: String)` or
   `.failure(exitCode: Int32, stdout: String)`.
2. **`apps/mac/codans/Runtime/HierarchyManager.swift`**: wrap each
   of the three lifecycle methods to call
   `runWorktreeLifecycleScript(.setup / .archive / .delete, for:
   worktreeID)`. Setup: a `.failure(...)` aborts catalog row creation
   (worktree directory left on disk; cf design doc Security note). Archive
   / delete: a `.failure(...)` logs a warning and proceeds. Output
   posts to `LifecycleScriptToast` regardless.
3. **`apps/mac/codans/App/Features/Toast/LifecycleScriptToast.swift`**
   (NEW): a transient SwiftUI sheet anchored on the main window. Shows
   phase + worktree name + scrollable stdout. Auto-dismisses 5s after
   success; stays open on failure until the user dismisses; Cancel button
   on the sheet sends SIGTERM to the running process.
4. **`apps/mac/codans/App/Features/Toast/LifecycleScriptToastFeature.swift`**
   (NEW TCA reducer): tracks `(isPresented, phase, worktreeID, output,
   exitState)`. Effects subscribe to a `LifecycleScriptStream`
   `AsyncSequence` that the manager publishes on. RootFeature integrates
   per the toolbar / window-bus pattern used by other transient sheets.

Tests in this milestone:

- `WorktreeLifecycleSkipTests.swift`: empty `setupScript` skips invocation
  and `createWorktree` proceeds normally.
- `WorktreeLifecycleFailStopTests.swift`: a non-empty `setupScript` that
  exits non-zero blocks `createWorktree` from registering the catalog
  row; the toast shows the failure output.
- `WorktreeLifecycleFailWarnTests.swift`: a non-zero `archiveScript` /
  `deleteScript` logs a warning but the lifecycle action still
  completes; the toast remains visible until dismissed.
- `WorktreeLifecycleEnvTests.swift`: the spawned process's environment
  contains the resolved Project envVars merged with process env.
- `WorktreeLifecycleCwdTests.swift`: setup runs with cwd = new worktree
  path; archive / delete with cwd = existing worktree path.

### Milestone 10: Command Palette — runProjectScript

Goal: opening the Command Palette from inside Project A surfaces one
item per `ProjectSettings.scripts` entry. Activating runs through
`HierarchyClient.runScript`.

Tasks:

1. **`apps/mac/codans/App/Features/CommandPalette/CommandPaletteItem.swift`**:
   add `case runProjectScript(ProjectID, WorktreeID, ScriptDefinition.ID)`
   to `Kind`. Item label = `script.displayName`; subtitle = kind's
   display string ("Test", "Deploy", or "Custom"); icon = resolved system
   image; tint = resolved tint colour.
2. **`apps/mac/codans/App/Features/CommandPalette/CommandPaletteItems.swift`**:
   in `build(...)`, when an active Project is in scope, iterate
   `settings.projects[pid]?.scripts ?? []` and emit one
   `runProjectScript` item per entry. Cross-project scripts are not
   surfaced — the active selection drives the build.
3. **RootFeature route**: handle `Kind.runProjectScript` by dispatching
   `HierarchyClient.runScript(...)`.

Tests in this milestone:

- `CommandPaletteRunScriptBuildTests.swift`: with an active Project
  carrying three scripts, the palette items list contains exactly three
  `.runProjectScript` items in array-stored order; switching active
  Project surfaces the new Project's scripts and not the previous one's.
- `CommandPaletteRunScriptActivationTests.swift`: activating a
  `runProjectScript` item dispatches `HierarchyClient.runScript(...)`
  with the matching `(scriptID, projectID, worktreeID)`.

### Milestone 11: Tests sweep + ≥ 50 net new

Goal: every changed surface has coverage. Most tests land alongside
their milestone; M11 is the final sweep that fills gaps and aligns
naming.

Sweep checklist:

- M1 schema tests in CodansCoreTests (≥ 6).
- M2 client / writer tests in mac/codans/Tests (≥ 8).
- M3 sidebar restructure tests (≥ 3).
- M4 General pane tests (≥ 8).
- M5 Scripts pane tests (≥ 6).
- M6 Hooks editor tests (≥ 6).
- M7 HeaderRunScriptSplitButton tests (≥ 4).
- M8 env injection tests (≥ 4).
- M9 lifecycle execution tests (≥ 6).
- M10 Command Palette tests (≥ 2).

Cross-cutting integration test (NEW):
`Phase2RoundTripTests.swift` — open Settings → Project A → General → set
envVars + edit shell + edit scripts; switch to Hooks → add a hook → save;
reopen Settings; assert every value persisted by reading
`SettingsStore.settings` via the store directly.

Total target: ≥ 50 net new tests. M11 audits the count and adds extras
(e.g. malformed payload guards mirroring HookConfig's pattern from
Phase 1) as needed to hit the floor.

### Milestone 12: Docs, rename gate, manual QA, codex review, push + PR

Tasks:

1. **`docs/architecture.md`**: amend the `settings.json` description with
   `setupScript` / `archiveScript` / `deleteScript` (additive) and the
   `envVars` editor + spawn-path injection note. Version stays v3.
2. **`docs/product-specs/ui-settings-window.md`**: amend the Acceptance
   Criteria to cover the 5-Section General pane, the Scripts pane
   (Lifecycle + User-defined sections), the inline-editable Hooks pane,
   and the WorktreeHeader Run split-button.
3. **Manual QA pass**:
   - Start `make mac-run-app`, open Settings, click Project A.
   - Verify three sub-rows (General / Scripts / Hooks) under each Project.
   - Verify General pane Sections render conditionally on
     `gitRepo` vs `plainDir`.
   - Edit Editor / Shell / Worktree base ref / GitHub strategy / a couple
     of envVars; verify writes persist after Quit & Restart.
   - Add a `.run` and a `.test` script, drag to reorder, click Run from
     the WorktreeHeader split-button, verify a fresh tab opens with
     the right name / icon / tint.
   - Edit a hook inline: change scope from `.anyPane` to
     `.projectID(current)`, add a `matchPattern`; verify the row
     persists; reload Settings; row reflects the saved value.
   - Add a `setupScript = "echo SETUP"`; create a Worktree; verify the
     `LifecycleScriptToast` shows "SETUP" and auto-dismisses.
   - Add a `setupScript` that `exit 1`s; verify the toast stays open
     and the catalog row is not added.
   - Verify a `ProjectSettings.envVars["MY_VAR"] = "hello"` produces
     `printenv MY_VAR` → `hello` in a freshly-spawned pane.
4. **`scripts/check-rename-residue.sh`**: run; expect clean exit.
5. **`/codex:review`** on the branch in background mode; address findings
   in follow-up commits before merging. The Phase 1 review surfaced four
   issues — expect a similar bar on Phase 2.
6. **Push + `gh pr create --base main`** with the design doc + this
   ExecPlan referenced in the PR body.

## Concrete Steps

Run from the repository root unless otherwise specified.

```bash
# Always operate from the worktree root
cd /Users/wanggang/.prowl/repos/codans/feature/worktree-settings

# Confirm branch
git status
git log --oneline -5

# Generate the Xcode project (after Tuist target / source-list edits)
make mac-generate

# Build (per-milestone; expect warnings clean)
make mac-build

# Lint
make mac-lint

# Test runs (target: every milestone leaves the suite green)
make mac-test         # full suite
# Or, per-milestone targeted runs:
xcodebuild test \
  -workspace apps/mac/codans.xcworkspace \
  -scheme CodansCore \
  -only-testing:CodansCoreTests/ScriptDefinitionCodableTests \
  | xcbeautify

# Rename-residue gate
bash scripts/check-rename-residue.sh

# Commit cadence: one commit per task in this plan, with a message that
# names the file/area changed and the milestone.
git add -p
git commit -m "feat(settings): M1 — expand ScriptDefinition (+kind, +icon, +tint)"
```

Codex review:

```bash
# Background review — let it run while we proceed
/codex:review --background
# Check status
/codex:status
# Address findings in a follow-up commit per finding
git commit -m "fix(settings): address Codex review P1/P2 findings"
```

PR creation (final step):

```bash
git push -u origin feature/project-settings-phase2
gh pr create --base main \
  --title "Project Settings Phase 2 — sub-pane implementation" \
  --body-file - <<'EOF'
## Summary

Phase 2 of the Project Settings work (builds on PR #42). Fills the four
scaffold sub-panes from Phase 1 and makes the Hooks pane editable,
collapsing the sidebar to three sub-rows (General / Scripts / Hooks).

- Design doc: docs/design-docs/project-settings-phase2.md
- Exec plan: docs/exec-plans/project-settings-phase2.md

## Test plan
- [ ] make mac-build, make mac-lint, make mac-test
- [ ] bash scripts/check-rename-residue.sh
- [ ] Manual QA pass (Settings → Project → all three sub-panes)
- [ ] Codex review run; findings addressed in follow-up commits
EOF
```

## Validation and Acceptance

The branch is ready to merge when every item below is verifiable:

1. `make mac-build` succeeds with no new warnings.
2. `make mac-test` reports ≥ 50 net new tests passing relative to Phase 1
   baseline.
3. `bash scripts/check-rename-residue.sh` exits 0; the deny-list contains
   `ProjectGitSettingsView`, `ProjectGitHubSettingsView`,
   `ProjectEnvSettingsView`.
4. Opening Settings → any Project shows exactly three sub-rows (General,
   Scripts, Hooks) regardless of `ProjectKind`.
5. The General pane on a `.gitRepo` Project renders five Sections in
   order: Editor, Default Shell, Worktree, GitHub, Environment. On a
   `.plainDir` Project the Worktree and GitHub Sections do not render.
6. Setting `setupScript = "echo HELLO"` and creating a Worktree opens
   the `LifecycleScriptToast` showing `HELLO`; the toast auto-dismisses
   after 5s. Setting `setupScript = "exit 1"` keeps the toast open and
   the new worktree directory does not appear in the catalog.
7. Running a script from the WorktreeHeader Run split-button opens a
   fresh tab whose title is the script's `displayName`, icon is
   `resolvedSystemImage`, and tint is `resolvedTintColor`. Re-running
   opens a second tab side-by-side (no dedup).
8. A `ProjectSettings.envVars["MY_VAR"] = "hello"` value reaches a
   freshly-spawned pane: `printenv MY_VAR` prints `hello`. The path used
   (libghostty per-surface env vs typed-export fallback) is recorded in
   the Decision Log per M0.
9. Editing a hook inline: changing event / scope / command / matchPattern
   / mode / timeout / cwd / env / disabled persists through
   `HookConfigClient.upsert`; deleting routes through `delete`; saving
   with a non-project scope removes the row from this pane on the next
   refresh (Developer pane still shows it).
10. The Codex review on the merged PR has no unaddressed P1 or P2 issues.

## Idempotence and Recovery

Most tasks in this plan are file edits + tuist regen + test runs; rerunning
them is safe. Notes on the few non-idempotent steps:

- **Schema additive fields (M1)**: adding `setupScript` /
  `archiveScript` / `deleteScript` is additive Codable; old v3 files
  decode unchanged. If the work is interrupted between adding the field
  and updating tests, the build still passes (defaults are empty).
- **Pane file deletes (M3)**: deleting `ProjectGitSettingsView.swift`
  etc. is reversible from git history. The rename-gate addition is also
  reversible.
- **Codex review fixes**: each follow-up commit is independently
  revertable; the review log lives at `~/.claude/plugins/data/codex-
  openai-codex/state/.../jobs/<job-id>.log` for re-reading.
- **Lifecycle script execution failures (M9)**: a partial worktree
  directory left on disk after a failed setup is documented as the user-
  facing recovery path ("rerun Add Worktree → pick Existing"). The
  catalog row is not registered, so there is no internal cleanup.
- **`make mac-generate`**: regenerates the Xcode workspace from Tuist
  manifests; idempotent. Safe to rerun whenever you add/move files in
  the source list.

If a milestone must be split across sessions, the Progress section above
is the source of truth — update timestamps and split items into "done"
and "remaining" before pausing.

## Artifacts and Notes

(Populated during execution. Sample snippets that prove milestone
acceptance, codex review findings, and any non-trivial diffs go here.)

## Interfaces and Dependencies

End-state types and signatures the implementation must produce.

In `apps/mac/CodansCore/Settings/ScriptKind.swift`:

```swift
public enum ScriptKind: String, Codable, CaseIterable, Sendable {
  case run, test, deploy, lint, format, custom
}

extension ScriptKind {
  public var defaultName: String { ... }
  public var defaultSystemImage: String { ... }
  public var defaultTintColor: ScriptTintColor { ... }
}
```

In `apps/mac/CodansCore/Settings/ScriptTintColor.swift`:

```swift
public enum ScriptTintColor: String, Codable, Sendable {
  case green, yellow, red, blue, teal, purple, gray
}
```

In `apps/mac/CodansCore/Settings/ScriptDefinition.swift`:

```swift
public struct ScriptDefinition:
  Equatable, Codable, Sendable, Identifiable, Hashable
{
  public var id: UUID
  public var kind: ScriptKind
  public var name: String
  public var command: String
  public var systemImage: String?
  public var tintColor: ScriptTintColor?

  public var displayName: String { name.isEmpty ? kind.defaultName : name }
  public var resolvedSystemImage: String {
    kind == .custom ? (systemImage ?? kind.defaultSystemImage) : kind.defaultSystemImage
  }
  public var resolvedTintColor: ScriptTintColor {
    kind == .custom ? (tintColor ?? kind.defaultTintColor) : kind.defaultTintColor
  }
}
```

In `apps/mac/CodansCore/Settings/GitProjectSettings.swift` (additive):

```swift
public struct GitProjectSettings { ...
  public var setupScript: String   // empty means skip
  public var archiveScript: String
  public var deleteScript: String
}
```

In `apps/mac/codans/App/Clients/HookConfigClient.swift` (extends
existing struct):

```swift
nonisolated struct HookConfigClient: Sendable {
  // existing
  var load: @MainActor @Sendable () async throws -> HookConfig
  var ensureExists: @MainActor @Sendable () async throws -> Void
  // new
  var upsert: @MainActor @Sendable (HookSubscription) async throws -> Void
  var delete: @MainActor @Sendable (UUID) async throws -> Void
}

enum HookConfigClient.WriteRefused: Error, Equatable {
  case internalNamespace
}
```

In `apps/mac/codans/App/Features/Editor/EditorFeature.swift`
(`SettingsWriter` extension):

```swift
nonisolated struct SettingsWriter: Sendable { ...
  // new in Phase 2
  var setProjectDefaultShell: @Sendable (ProjectID, String?) async -> Void
  var setProjectGitField: @Sendable (ProjectID, GitFieldUpdate) async -> Void
  var setProjectEnvVar: @Sendable (ProjectID, String, String?) async -> Void
  var setProjectScripts: @Sendable (ProjectID, [ScriptDefinition]) async -> Void
  var setProjectLifecycleScript: @Sendable (
    ProjectID, WorktreeLifecycle, String
  ) async -> Void

  enum WorktreeLifecycle: Sendable { case setup, archive, delete }

  enum GitFieldUpdate: Sendable {
    case worktreeBaseRef(String?)
    case copyIgnoredOnWorktreeCreate(Bool?)
    case copyUntrackedOnWorktreeCreate(Bool?)
    case defaultMergeStrategy(MergeStrategy?)
    case postMergeAction(MergedWorktreeAction?)
    case githubDisabled(Bool)
  }
}
```

In `apps/mac/codans/App/Clients/HierarchyClient.swift`:

```swift
nonisolated struct HierarchyClient: Sendable { ...
  var runScript: @MainActor @Sendable (
    _ scriptID: UUID,
    _ projectID: ProjectID,
    _ worktreeID: WorktreeID
  ) async throws -> Void
}

enum HierarchyClient.RunScriptError: Error, Equatable {
  case unknownScript(UUID)
  case missingWorktree(WorktreeID)
}
```

In `apps/mac/codans/Runtime/HierarchyManager.swift`:

```swift
extension HierarchyManager {
  nonisolated func resolvedEnv(
    for projectID: ProjectID, in settings: Settings
  ) -> [String: String] { ... }

  func runWorktreeLifecycleScript(
    _ phase: SettingsWriter.WorktreeLifecycle,
    for worktreeID: WorktreeID
  ) async throws -> LifecycleScriptResult
}

enum LifecycleScriptResult: Sendable {
  case skipped
  case success(stdout: String)
  case failure(exitCode: Int32, stdout: String)
}

// createTab widens (existing call sites pass nil for new args):
func createTab(
  in worktreeID: WorktreeID,
  ...,
  name: String? = nil,
  icon: String? = nil,
  tint: ScriptTintColor? = nil,
  env: [String: String] = [:],
  cwd: URL? = nil,
  command: String? = nil
) async throws -> Tab.ID
```

In `apps/mac/codans/Runtime/Ghostty/PaneSurface.swift`:

```swift
final class PaneSurface { ...
  init(
    ...,
    env: [String: String] = [:]
  ) { ... }
}
```

In `apps/mac/codans/App/Features/CommandPalette/CommandPaletteItem.swift`:

```swift
extension CommandPaletteItem.Kind {
  case runProjectScript(ProjectID, WorktreeID, ScriptDefinition.ID)
}
```

In `apps/mac/codans/App/Features/Settings/Panes/`:

```swift
struct OptionalOverridePicker<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value?
  let inheritedValue: Value?
  let options: [(value: Value, label: String)]
  let inheritedLabel: (Value?) -> String
}

struct EnvironmentEditorView: View { ... }
struct ScriptDefinitionRow: View { ... }
struct HookEditorRow: View { ... }
struct ScopePickerView: View { ... }
```

In `apps/mac/codans/App/Features/WorktreeHeader/HeaderRunScriptSplitButton.swift`:

```swift
struct HeaderRunScriptSplitButton: View {
  let projectID: ProjectID
  let worktreeID: WorktreeID
  // body uses Menu(primaryAction:) { ... } label: { ... }
}
```

In `apps/mac/codans/App/Features/Toast/LifecycleScriptToast.swift`:

```swift
struct LifecycleScriptToast: View {
  let phase: SettingsWriter.WorktreeLifecycle
  let worktreeID: WorktreeID
  let stream: AsyncStream<String>   // stdout chunks
  let onCancel: () -> Void
}
```
