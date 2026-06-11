# Design Doc: Project Settings — Sub-Pane Implementation (Phase 2)

**Status:** Draft
**Author:** Gump
**Date:** 2026-04-25
**Builds on:** [project-settings.md](./project-settings.md) (Phase 1 — schema + rename + scaffolds)

## Context and Scope

Phase 1 (`docs/design-docs/project-settings.md`, shipped via PR #42) reshaped the
Project Settings storage and navigation: `settings.json` v3 absorbed every
per-Project preference, the sidebar grew six kind-conditional sub-rows under each
Project, four sub-panes landed as `Coming in a later release` placeholders, and
the Hooks pane stayed read-only with a "Reveal hooks.json in Finder" escape
hatch. Phase 1 explicitly listed those as Non-Goals to ship the schema work
without sub-pane UX bikeshedding.

Phase 2 fills the user-facing gap. After this work, every per-Project preference
that has a backing field becomes editable from the Settings window, the
worktree lifecycle gets first-class hooks (`setup` / `archive` / `delete` shell
scripts), user-defined scripts run from the Command Palette and a Scripts pane,
environment variables propagate into spawned terminals, and the Hooks pane
edits subscriptions inline instead of pointing at a JSON file. The Phase 2
scope intentionally collapses the sidebar from six sub-rows to three —
`General`, `Scripts`, `Hooks` — so single-field overrides cluster in one pane
and list-heavy surfaces (Scripts, Hooks) keep their own pages.

Reference files (read for this design):

- `apps/mac/codans/App/Features/Settings/Panes/SettingsGeneralView.swift`
  — Form / Section / Picker pattern the new General pane mirrors.
- `apps/mac/codans/App/Features/Settings/Panes/GitHubSettingsView.swift`
  — global GitHub Section structure that the per-Project GitHub Section reuses.
- `apps/mac/codans/App/Features/Settings/Panes/ProjectGeneralSettingsView.swift`
  — Phase 1 General pane that grows substantially in Phase 2.
- `apps/mac/codans/App/Features/Settings/SettingsSection.swift` — sub-pane
  enum that shrinks from 6 to 3 Project cases.
- `apps/mac/codans/App/Features/Settings/SettingsWindowFeature.swift` —
  pane-state composition; `projectsChanged` re-seeds `kind`, the same hook
  retires the now-unreachable Git/GitHub/Env panes.
- `apps/mac/codans/Hooks/HookConfigStore.swift` — `load` / `save` /
  `scheduleSave` / `flush` / `upsertInternal` (the existing internal-namespace
  upsert pattern that user-facing edit reuses).
- `apps/mac/codans/App/Clients/HookConfigClient.swift` — TCA bridge that
  Phase 2 widens with `save` / `upsert` / `delete` closures.
- `apps/mac/codans/Runtime/TerminalEngine.swift` and
  `apps/mac/codans/Runtime/Ghostty/PaneSurface.swift` — the spawn path
  envVars need to ride through.
- `apps/mac/CodansCore/Hooks/HookSubscription.swift` — the 9-case Scope
  enum the inline editor renders a kind-aware picker for.
- `apps/mac/CodansCore/Settings/{ProjectSettings,GitProjectSettings,ScriptDefinition}.swift`
  — schema slots that Phase 2 fills (no version bump).
- `apps/mac/codans/App/Features/CommandPalette/CommandPaletteItem.swift`
  — palette extension point for surfacing user-defined scripts.

Adjacent work:

- The status-bar and tab-bar features that landed in PR #40 / #41 are
  independent of this design. Phase 2 widens the tab-creation API
  (`createTab`) to carry script-spawn metadata (env / cwd / icon /
  tint / initial command) but does not change tab-bar layout or
  catalog wire format.
- The WorktreeHeader gains one new SwiftUI view
  (`HeaderRunScriptSplitButton`) adjacent to the existing
  `HeaderOpenSplitButton`. No other header layout changes.

## Goals and Non-Goals

### Goals

- **G1 — Make every Project preference editable.** Each `ProjectSettings`
  / `GitProjectSettings` field that has a backing slot today gets a control
  in the General pane. Inheritance from the global defaults renders inline
  ("Use global default — <inherited value>") so users see the resolved
  value without opening Settings → General.
- **G2 — Sidebar simplifies to three sub-rows per Project.** Drop the
  six-row layout from Phase 1: General + Scripts + Hooks for both kinds.
  Kind difference becomes Section-level inside General, not row-level in
  the sidebar. No icon, no badge, no label exposes kind.
- **G3 — Worktree lifecycle scripts.** New `GitProjectSettings.setupScript`,
  `archiveScript`, `deleteScript` fields; each is a single shell command
  (no kind / icon) that fires synchronously around the matching worktree
  lifecycle action (`createWorktree` / `setWorktreeArchived(true)` /
  `removeWorktree`). Fail-stop semantics for setup, fail-warn for archive
  and delete. Distinct from the `HookEvent.{worktreeCreated,
  worktreeRemoved}` taxonomy: lifecycle scripts are inline + blocking +
  can abort the lifecycle action; hook subscriptions are async fire-and-
  forget. We keep them separate rather than overload `HookDispatcher`
  with a "block-and-fail-the-event-on-non-zero-exit" mode — see A6.
- **G4 — User-defined Scripts run from anywhere.** `ProjectSettings.scripts`
  becomes a real list of `ScriptDefinition` (kind / name / command /
  optional icon and color). The primary entry point is a
  `HeaderRunScriptSplitButton` in the WorktreeHeader (next to the
  existing Open-in-Editor split button): main click runs the default
  script, dropdown lists every script + a "Manage Scripts…" link to
  Settings. Command Palette and the Scripts pane Run button are
  secondary entry points (power-user / one-off). Each invocation opens
  a fresh tab; tabs are not deduplicated by script id and titles are
  not locked — users can rename or close them like any other tab.
- **G5 — Environment variables propagate into spawned subprocesses.**
  `ProjectSettings.envVars` becomes a key/value editor in General;
  TerminalEngine accepts the resolved env at spawn time and passes it into
  libghostty's per-surface env (or, if libghostty cannot, types `export`
  statements before the user's first command — exec-time fallback).
- **G6 — Hooks pane becomes inline-editable.** The Hooks sub-pane edits
  subscriptions in place: event picker, scope picker (covers all 9 Scope
  cases with kind-aware fallback), command, matchPattern with flags, mode,
  timeout, cwd, env, disabled toggle. Scope of edit is "subscriptions
  bound to the current Project"; saving with a non-project scope removes
  the row from this pane (still visible in Developer pane's global view).

### Non-Goals

- **No new schema version.** The fields G1–G6 need either already exist on
  `ProjectSettings` / `GitProjectSettings` (added but unused in Phase 1)
  or are additive on `GitProjectSettings` (the three lifecycle script
  fields). All pre-existing v3 settings.json files round-trip identically.
- **No global default env vars.** Project-level only. A future `Settings.general`
  surface for global env defaults can layer on top without disturbing
  Phase 2.
- **No worktree-level overrides.** Lifecycle scripts and envVars apply
  uniformly to every worktree under the Project. Per-worktree overrides
  remain out of scope (would need a Catalog-side schema change anyway).
- **No tab-bar quick-launch for scripts.** The WorktreeHeader split-
  button is the primary entry point; Command Palette + the Scripts
  pane's Run button are secondary. A tab-bar `+` submenu or per-tab
  "Run script…" affordance is a separate UX decision deferred to a
  future round.
- **No script chains or dependencies.** Scripts are atomic: the user types
  whatever shell pipeline they want into `command`. No `dependsOn`
  declaration, no Make-like graph.
- **No CI / remote runner.** Scripts run on the user's local machine in the
  current worktree. Pushing scripts to a runner is out of scope.
- **No template variable expansion in env values.** `MY_VAR=$HOME/work`
  stores literally; the spawned shell may or may not expand at use time.
  Touch-code performs zero substitution at storage or spawn time.
- **No password / secret masking on env values.** `settings.json` is
  plaintext on disk; UI masking would be theatre.
- **No sheet-based hook editor.** Hook editing is inline-expandable rows
  in the Hooks pane; no modal sheet.
- **Shortcuts and Updates panes.** Still scaffolds, still not in scope.

## Design

### Overview

Three changes anchor Phase 2:

1. **Sidebar restructure.** `SettingsSection` drops `.projectGit`,
   `.projectGitHub`, `.projectEnv`. Each Project shows three rows under
   its DisclosureGroup: General, Scripts, Hooks. The General pane absorbs
   what used to be three separate panes; kind-conditional rendering moves
   from sidebar (which sub-rows to show) to General (which Sections to
   render).
2. **Spawn-path env injection.** `PaneSurface` and `HierarchyManager.openPane`
   widen to carry an `env: [String: String]`. The hierarchy resolves the
   merged env at spawn time (`SettingsStore.settings.projects[pid].envVars`,
   merged with the process env via "project keys win"), and PaneSurface
   passes it to libghostty's per-surface env when available, falling back
   to typed `export` lines into the PTY before the user's `initialCommand`
   runs. The fallback is exec-time only — if libghostty supports per-
   surface env we never type exports.
3. **Hooks become writable.** `HookConfigClient` grows `save` / `upsert`
   / `delete` closures over the existing `HookConfigStore.scheduleSave`
   pipeline. The Hooks pane uses inline-expandable rows — clicking a row
   exposes the editor; the row collapses on Save / Cancel. Scope is
   picked from a kind-tagged enum picker that switches between a Project /
   Worktree / Tab / Pane ID dropdown and a glob TextField as the user
   selects different scope kinds.

The central trade-off running through Phase 2 is **breadth over polish**.
We could ship 5 separate phases, one per pane, with deeper UX per pane
(animated state-machine for hook validation, autocomplete on env keys,
template-variable hints in script commands). We deliberately keep each
pane simple — Form + Section + native macOS controls — so the whole
batch lands in a single PR and Project Settings stops being a "looks
done but isn't" product surface.

### System Context Diagram

```
┌────────────────── Settings Window ──────────────────┐
│                                                     │
│   SettingsSidebarView                               │
│      ▾ Project A                                    │
│         General      ← combines 5 Sections          │
│         Scripts      ← lifecycle + user list        │
│         Hooks        ← inline-editable rows         │
│                                                     │
│   ProjectGeneralSettingsView                        │
│     · Editor / Shell / Worktree* / GitHub* / Env    │
│     · all writes route to SettingsStore.mutateProject│
│                                                     │
│   ProjectScriptsSettingsView                        │
│     · Lifecycle (git_repo only) — 3 TextEditors     │
│     · User-defined list — kind picker + name + cmd  │
│     · Run buttons → CommandPaletteRouter            │
│                                                     │
│   ProjectHooksSettingsView                          │
│     · merged Global + Project rows (Phase 1)        │
│     · NEW: per-row inline editor + Add Hook button  │
│     · writes via HookConfigClient.upsert / .delete  │
│                                                     │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌──────────── Persistence + Runtime ──────────────────┐
│                                                     │
│   SettingsStore (settings.json v3)                  │
│     projects[pid] = ProjectSettings(                │
│       defaultEditor, worktreesDirectory,            │
│       defaultShell, envVars, scripts,               │
│       git: GitProjectSettings(                      │
│         worktreeBaseRef, copyIgnored*,              │
│         defaultMergeStrategy, postMergeAction,      │
│         githubDisabled,                             │
│         setupScript, archiveScript, deleteScript    │
│       )                                             │
│     )                                               │
│                                                     │
│   HookConfigStore (hooks.json v2)                   │
│     scheduleSave on every upsert / delete           │
│                                                     │
│   HierarchyManager.openPane / createWorktree /      │
│     setWorktreeArchived / removeWorktree            │
│       │                                             │
│       ▼ resolves project envVars + lifecycle script │
│   TerminalEngine.ensureSurface(env: [...])          │
│       │                                             │
│       ▼ libghostty per-surface env  OR              │
│       ▼ typed `export K='V'` lines into PTY (fallback)│
│                                                     │
│   CommandPaletteItems.build(...)                    │
│     adds one item per ScriptDefinition in active    │
│     project; activation routes to runScript effect  │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### Sidebar restructure

`SettingsSection` shrinks the per-Project case set:

```swift
public enum SettingsSection: Hashable, Sendable {
  case general, github, notifications, terminal, developer
  case shortcuts, updates, about
  case projectGeneral(ProjectID)   // grew — now combines 5 Sections
  case projectScripts(ProjectID)   // grew — now editable lifecycle + list
  case projectHooks(ProjectID)     // grew — now inline-editable
}
```

Three cases retire: `.projectGit`, `.projectGitHub`, `.projectEnv`. The
sidebar's `subrows(for:projectID:)` returns the three live cases regardless
of `ProjectKind`. Inside `ProjectGeneralSettingsView`, kind drives
whether the Worktree and GitHub Sections render — clean separation.

`SettingsWindowView`'s detail switch loses three cases (one per retired
sub-pane); their pane-view files (`ProjectGitSettingsView.swift`,
`ProjectGitHubSettingsView.swift`, `ProjectEnvSettingsView.swift`) get
deleted. The `check-rename-residue.sh` deny-list grows to block their
re-introduction.

### General pane — internal structure

`ProjectGeneralSettingsView` is one `Form` with five sibling Sections,
in this fixed order:

```
Section "Editor"
  ┌─ Picker "Default Editor" — bound to projects[pid]?.defaultEditor
  │    tag(nil) = "Use global default — <inheritedEditor>"
  │    tag(.some("vscode")) = "Visual Studio Code"
  │    ... installed editors from EditorRegistry

Section "Default Shell"
  ┌─ Picker "Shell" — bound to projects[pid]?.defaultShell
  │    tag(nil) = "Use global default — <inheritedShell>"
  │    options: /bin/bash, /bin/zsh, /opt/homebrew/bin/fish, ...
  │    populated from EditorRegistry-style ShellRegistry (NEW)

[git_repo only:]
Section "Worktree"
  ┌─ TextField + "Choose…" — projects[pid]?.worktreesDirectory
  │    nil case shows "Use global default — ~/.codans/repos/<name>"
  ├─ TextField "Base ref" — projects[pid]?.git?.worktreeBaseRef
  │    nil case shows placeholder "Use global default — origin/HEAD"
  ├─ Toggle "Copy .gitignore'd files when creating worktree"
  │    bound to git?.copyIgnoredOnWorktreeCreate
  └─ Toggle "Copy untracked files when creating worktree"
       bound to git?.copyUntrackedOnWorktreeCreate

[git_repo only:]
Section "GitHub"
  ┌─ Picker "Merge strategy" — git?.defaultMergeStrategy
  │    tag(nil) = "Use global default — Squash"
  │    tags: Merge / Squash / Rebase
  ├─ Picker "After merging a PR" — git?.postMergeAction
  │    tag(nil) = "Use global default — Ask"
  │    tags: Ask / Archive / Delete
  └─ Toggle "Disable GitHub integration for this Project"
       bound to git?.githubDisabled

Section "Environment"
  ┌─ List of {key: String, value: String} pairs
  │    columnar layout: KEY (TextField) | VALUE (TextField) | ✕ button
  │    rows ordered alphabetically by key on render (no manual reorder)
  ├─ "Add variable" button → appends a blank row, focus on KEY field
  └─ Inline validation: invalid KEY (non-POSIX or duplicate) shows
       red border + accessibility hint, save button disabled per row
```

Optional-field controls share a `OptionalOverridePicker<Value>` helper
(NEW): given a `Binding<Value?>` and an `inheritedValue: Value?`, it
renders the "Use global default — <inherited>" tag and the option list.
Centralising the visual prevents drift across the four override fields.

The Toggle bindings for `copyIgnoredOnWorktreeCreate` /
`copyUntrackedOnWorktreeCreate` use a custom `OptionalToggleBinding` —
nil means inherit, true/false means override. The control is a Picker
with three options ("Use global default — yes" / "Yes" / "No") rather
than a Toggle, matching how supacode-style override visuals work for
boolean overrides.

The Environment Section sorts keys alphabetically on display but stores
in the same `[String: String]` shape on disk; insertion order is not
preserved (Swift dictionaries don't guarantee it anyway). Adding a new
variable inserts a blank row that does not commit until both KEY and
VALUE fields lose focus and pass validation.

### Scripts: data model

The `ScriptDefinition` placeholder Phase 1 reserved (id / name / command)
expands to:

```swift
public struct ScriptDefinition: Equatable, Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  public var kind: ScriptKind
  public var name: String           // user-visible, defaults to kind.defaultName
  public var command: String        // raw shell, runs via $SHELL -c
  public var systemImage: String?   // override (only honored when kind == .custom)
  public var tintColor: ScriptTintColor?  // override (custom-only)
}

public enum ScriptKind: String, Codable, CaseIterable, Sendable {
  case run, test, deploy, lint, format, custom

  // Each kind carries a default name / SF Symbol / tint color when the
  // user does not override.
}

public enum ScriptTintColor: String, Codable, Sendable {
  case green, yellow, red, blue, teal, purple, gray
  // SwiftUI Color resolution lives on the view side via a tiny helper.
}
```

Key design points:

- **Kind drives default visuals.** A user picking `.test` gets the test
  icon and yellow tint without typing anything else; the picker shows
  the kind's default name as a placeholder. `.custom` is the only kind
  where `systemImage` and `tintColor` overrides take effect — for
  predefined kinds the resolver ignores any stored override (matches the
  "kind is the contract" semantics from supacode-style scripts).
- **No `cwd` / `env` per script.** The user encodes any cwd / env tweak
  in `command` itself (`cd packages/foo && NODE_ENV=test npm test`).
  Project-level envVars apply to every script implicitly.
- **No "is enabled" toggle.** A script that exists is runnable. To
  disable, delete it.

`GitProjectSettings` grows three new fields:

```swift
public struct GitProjectSettings {
  // ... existing fields (Phase 1) ...

  /// Shell command run synchronously after a new Worktree is created
  /// at this Project's `worktreesDirectory`. Empty string skips. Failure
  /// (non-zero exit) blocks worktree-create completion and surfaces the
  /// error in the Create Worktree sheet. cwd = the new worktree path.
  public var setupScript: String

  /// Shell command run synchronously before a Worktree is archived.
  /// Empty string skips. Failure logs a warning but does not block
  /// archive — the user already requested the action; the script's
  /// output stays visible for inspection.
  public var archiveScript: String

  /// Shell command run synchronously before a Worktree is removed.
  /// Empty string skips. Failure-warn semantics match `archiveScript`.
  /// cwd = the worktree path (files still on disk).
  public var deleteScript: String
}
```

These are plain `String` (not `ScriptDefinition`) because their role is
fixed — name, icon, color all derive from the lifecycle moment. The
empty-string sentinel encodes "no script" so the Codable shape stays
trivial; `GitProjectSettings.isEffectivelyEmpty` checks all three are
empty.

`Settings.garbageCollect()` already collapses an empty `git` subtree to
nil; the new fields fold into that check (`isEffectivelyEmpty` extended).

### Scripts: pane UI

```
┌─ Project Scripts pane ─────────────────────────────────┐
│                                                        │
│ [git_repo only:]                                       │
│ Worktree Lifecycle                                     │
│   Setup   ┌────────────────────────────────────┐ │
│           │  npm install                        │     │
│           └────────────────────────────────────┘     │
│           Run after a new worktree is created.       │
│                                                      │
│   Archive ┌────────────────────────────────────┐     │
│           │                                     │     │
│           └────────────────────────────────────┘     │
│           Run before archiving a worktree.           │
│                                                      │
│   Delete  ┌────────────────────────────────────┐     │
│           │  ./scripts/save-state.sh            │     │
│           └────────────────────────────────────┘     │
│           Run before removing a worktree (files       │
│           still on disk).                            │
│                                                      │
│ Scripts                                       + Add  │
│  ▶  ⚙ Run     "Dev"   npm run dev          [edit] [✕]│
│  ▶  ⚙ Test    "Test"  npm test              [edit] [✕]│
│  ▶  ✏ Custom  "Tail"  ssh prod 'tail …'    [edit] [✕]│
└──────────────────────────────────────────────────────┘
```

The lifecycle Section shows three labelled `TextEditor` inputs (each
bound to a `Binding<String>` over the `git` subtree). Empty value renders
a placeholder caption explaining what the field does. There is no
"validate by running" button — running a lifecycle script is a side
effect of the lifecycle action.

The Scripts list section uses inline rows. Each row shows kind icon,
name, command preview (single-line, ellipsis-truncated), and three
trailing controls:

- **▶ Run** — fires the same activation as the Command Palette.
- **edit** — toggles the row into expanded form: name, command (multi-
  line), kind picker, and (when kind == .custom) icon picker + color
  picker.
- **✕** — confirms then deletes.

"+ Add" inserts a new row already in expanded form, kind defaulting to
`.run`, name defaulting to `.run.defaultName`, command empty, focus on
the command field.

Sort order of the Scripts list is stored insertion order in the
`[ScriptDefinition]` array — users can manually drag rows to reorder.
ForEach `.onMove` writes the new array back via `SettingsStore.mutateProject`.

### Scripts: execution model

A script run produces a fresh tab every time. The tab:

- spawns in the Worktree active when the user invoked the script
  (HeaderRunScriptSplitButton uses the worktree owning the header;
  Command Palette infers from current selection; Scripts pane infers
  from the project's selected worktree, falling back to the first
  worktree if none is selected)
- title is initialised to `script.name`; user can rename via the tab
  UI like any other tab
- icon is `script.kind.systemImage` (or `script.systemImage` for custom)
- tint is `script.kind.tintColor` (or `script.tintColor` for custom)
- cwd is the worktree path
- env is the resolved Project envVars (same set every pane gets)
- spawn shell is `script.command` (run as `$SHELL -c <command>` inside
  the new pane's PTY; exit leaves the tab open so users can re-read
  output until they close it manually)

Tabs are NOT deduplicated by `ScriptDefinition.id`. Running the same
script twice opens two tabs side-by-side. Rationale: tab-management is
a low-cost user action; the alternative (one-tab-per-script with
locked titles + reconcile-on-boot for orphaned tabs) costs more
machinery than it saves users. If users complain about tab clutter we
can add an opt-in "reuse last tab" Toggle on the script later.

The `HierarchyClient` gains a `runScript` closure:

```
runScript: @MainActor @Sendable (
  _ scriptID: UUID,
  _ projectID: ProjectID,
  _ worktreeID: WorktreeID
) async throws -> Void
```

The live implementation:

1. Reads the `ScriptDefinition` via `SettingsWriter.readSnapshotSync`
   (or returns `.unknownScript` if it's been deleted between user
   click and effect dispatch).
2. Calls `HierarchyManager.createTab(in: worktreeID, ..., name:
   script.name, icon: ..., tint: ..., env: env, cwd: worktreePath,
   command: "<defaultShell> -c '<escaped command>'")`.

`HierarchyManager.createTab` widens to accept icon / tint / env / cwd /
command; the backwards-compatible tab-bar path passes nil for them,
which lets `createTab` carry them forward only to the runtime layer
that knows how to use them. `Tab.name` already stores the title and is
all we need — there is no `lockedTitle` flag, no per-script tab map,
no reconcile-on-boot machinery. No `Catalog` schema change.

### WorktreeHeader Run split-button

`HeaderRunScriptSplitButton.swift` (new) lives next to the existing
`HeaderOpenSplitButton.swift`. It uses SwiftUI's native `Menu(primaryAction:)`
to render a split button: main click = primary action, ▾ click = full
menu. Two states:

```
[scripts available]                  [no scripts]
┌────────────────────────┐           ┌────────────────────┐
│  ▶ Test  ▾              │           │  ▶ Run  ▾          │
└────────────────────────┘           └────────────────────┘
  primary click → run "Test"          primary click → open
  ▾ click → menu of all scripts        Settings → Scripts
                                       ▾ click → same menu
                                         (just a "Manage…" item)
```

State source: `settingsStore.settings.projects[currentProjectID]?.scripts ?? []`.

- **Primary script** = `scripts.first { $0.kind == .run }`, falling back
  to `scripts.first` if no `.run`-kind exists. Label, icon, tint follow
  the chosen primary's `.displayName / .resolvedSystemImage /
  .resolvedTintColor`.
- **Empty list** behaviour: button still renders with label "Run" and
  the play icon, but primary click and every menu item route to "open
  Settings → Scripts pane" (driven by SettingsWindowPresenter and the
  new `.projectScripts(currentProjectID)` selection).
- **Menu contents**: one Button per script (icon + name; running state
  badge if we add it later) + Divider + "Manage Scripts…" Button at
  the end.
- **Activation**: each menu item dispatches the same
  `HierarchyClient.runScript` effect a Command Palette pick would.
  Action route lives in `RootFeature` (parallel to the editor-open
  routes).
- **Visibility**: the button shows on every Worktree header for both
  `git_repo` and `plain_dir` Projects (Scripts have no kind dependency).
  Phase 2 adds it to the WorktreeHeader Toolbar adjacent to the
  Open-in-Editor button — no other header layout changes.

### Environment: model + injection

`ProjectSettings.envVars: [String: String]` lives on disk; the resolved
env at spawn time merges `ProcessInfo.processInfo.environment` (the
codans app's own env) with `projects[pid].envVars`. Project keys
win on collision. The merge happens in a single helper:

```swift
nonisolated func resolvedEnv(
  for projectID: ProjectID,
  in settings: Settings
) -> [String: String] {
  var env = ProcessInfo.processInfo.environment
  for (key, value) in (settings.projects[projectID]?.envVars ?? [:]) {
    env[key] = value
  }
  return env
}
```

The merged map flows through:

- `HierarchyManager.openPane` → `TerminalEngine.ensureSurface(in: …, env:)`
- `HierarchyManager.createTab` (when a Script-spawn tab is created) →
  same path
- `runScript` (Phase 2 new path) → `createTab` with env folded in
- `runWorktreeLifecycleScript` (Phase 2 new path, used by setup /
  archive / delete hooks) → `Process` invocation with `environment` set
  directly (not through TerminalEngine, since lifecycle scripts run
  headless, not in a pane) — see "lifecycle execution" below

`PaneSurface.init` widens to accept `env: [String: String]`. The
implementation tries libghostty's per-surface env config first; if the
ghostty SDK exposed by the codans worktree's vendored ghostty does
not have such a hook, the fallback is to type `export KEY='VALUE'`
lines into the PTY before any `initialCommand`. The fallback uses
single-quote escaping (POSIX-compatible) and prefixes each line with a
single space to leverage `HISTCONTROL=ignorespace` if the user's shell
has it set.

The libghostty support check happens once at `TerminalEngine.bringUp`
(check the SDK symbol availability via `#if canImport` or feature
detection, store the result in a `let supportsPerSurfaceEnv: Bool`).

**Why merge over inheriting only.** If `MY_VAR` exists in the touch-
code app's process env but the user wants their Project's MY_VAR to
override, "merge with project wins" gives them that. If the user instead
wants to clear an inherited var, we don't support that in Phase 2 — they
type `MY_VAR=` (empty value) and most shells treat that as "set to
empty string" (still inherited as exists, just empty). True unsetting
needs `unset` shell syntax; can't be expressed via env map.

### Hooks: pane edit UI

The Hooks pane keeps its existing two-source merged list (Global + Project
rows from Phase 1) and adds:

```
[+ Add Hook]   [Reveal hooks.json in Finder]
```

at the top. Each row from the merged list now becomes a disclosure-style
expandable row. Tapping the row chevron expands the editor inline:

```
▾ ⚙ pane.ready  echo "ready"  scope: anyPane    [Save] [Cancel] [Delete]
   Event           [Picker: pane.created … pane.crashed]
   Scope kind      [Picker: anyPane / paneID / paneLabel / tabID /
                            tabLabel / worktreeID / worktreePathGlob /
                            projectID / projectPathGlob]
   Scope value     [conditional — see below]
   Command         [TextEditor]
   Match pattern   [TextField]   Flags: ☐ caseInsensitive ☐ multiline ☐ dotAll
   Mode            [Picker: fireAndForget / awaitActions]
   Timeout         [Stepper, seconds]
   cwd             [TextField, optional]
   Env             [key/value rows, mini version of General pane]
   ☐ Disabled
```

The Scope value control is kind-aware:

- `.anyPane` → no value control (greyed out)
- `.paneID(_)` → Picker over current Project's panes (ProjectID → all
  worktrees → all tabs → all panes; row labels use Worktree branch + Tab
  name + Pane index for disambiguation)
- `.paneLabel(_)` → TextField
- `.tabID(_)` → Picker over current Project's tabs
- `.tabLabel(_)` → TextField
- `.worktreeID(_)` → Picker over current Project's worktrees
- `.worktreePathGlob(_)` → TextField with placeholder `**/feature/*`
- `.projectID(_)` → Picker over all open Projects (defaults to current)
- `.projectPathGlob(_)` → TextField

The Scope kind picker switches the value control without losing user-
typed glob/label content (we keep a transient `[ScopeKind: String]`
buffer in pane state so toggling between `.paneLabel` and `.tabLabel`
doesn't blow away the typed string). ID-based scopes don't share the
buffer because their value comes from a Picker selection, not text.

**Save / Cancel / Delete** apply to that row only. Save validates:

- Event is required.
- Command is required (non-empty after trimming).
- Glob scope, when chosen, is required to be non-empty.
- ID scope, when chosen, must resolve to an existing entity in the
  catalog (the Picker's empty selection counts as invalid; users can
  pick something or switch to a glob/label scope).
- Timeout is in `[0, 600]` seconds (0 = await indefinitely;
  matchPattern requires a `paneOutputMatch` event implicitly).

If validation fails, Save is disabled and the offending field shows
inline error text. Cancel discards local edits and re-collapses the row
to its persisted state. Delete confirms via `confirmationDialog` and
calls `HookConfigClient.delete(subscriptionID)`.

Row visibility follows Phase 1's classification: a saved subscription
whose scope no longer binds to the current Project disappears from
this pane on the next refresh (it's still in `hooks.json`, still in
the Developer pane). The user is told this via a Save-time tooltip
("This hook will move to the Global list").

### HookConfigClient — extended API

```swift
nonisolated struct HookConfigClient: Sendable {
  // existing
  var load: @MainActor @Sendable () async throws -> HookConfig
  var ensureExists: @MainActor @Sendable () async throws -> Void

  // new
  var upsert: @MainActor @Sendable (_ subscription: HookSubscription) async throws -> Void
  var delete: @MainActor @Sendable (_ subscriptionID: UUID) async throws -> Void
}
```

Both new closures wrap `HookConfigStore.scheduleSave` after mutating the
in-memory `HookConfig.subscriptions` array. `upsert` matches
`upsertInternal`'s semantics (replace by id, append if absent). `delete`
no-ops when the id is missing — matches "best-effort delete on a stale
ID" semantics.

The store's `upsertInternal` already reserves the `__codans/internal:`
command namespace for first-party hooks. `upsert` from the user-facing
Hook editor refuses to write a subscription whose `command` starts with
that prefix — that's a UI-level guard, not a model-level one (model
allows any command).

### SettingsWriter — extended API

```swift
nonisolated struct SettingsWriter: Sendable {
  // existing closures (Phase 1)
  var readSnapshot, readSnapshotSync, setDefaultEditorID,
      setProjectDefaultEditor, setProjectWorktreesDirectory: ...

  // new in Phase 2
  var setProjectDefaultShell: @Sendable (ProjectID, String?) async -> Void
  var setProjectGitField: @Sendable (ProjectID, GitFieldUpdate) async -> Void
  var setProjectEnvVar: @Sendable (ProjectID, String, String?) async -> Void
    // value=nil means "remove the key"
  var setProjectScripts: @Sendable (ProjectID, [ScriptDefinition]) async -> Void
  var setProjectLifecycleScript: @Sendable (
    ProjectID, WorktreeLifecycle, String
  ) async -> Void

  enum WorktreeLifecycle { case setup, archive, delete }
}
```

`GitFieldUpdate` is a small enum that names which `git.*` field to
mutate — keeps the closure count manageable while still letting tests
assert specific writes:

```swift
enum GitFieldUpdate {
  case worktreeBaseRef(String?)
  case copyIgnoredOnWorktreeCreate(Bool?)
  case copyUntrackedOnWorktreeCreate(Bool?)
  case defaultMergeStrategy(MergeStrategy?)
  case postMergeAction(MergedWorktreeAction?)
  case githubDisabled(Bool)
}
```

Live implementations chain into `SettingsStore.mutateProject(pid) {
$0.git = ($0.git ?? .init()); $0.git!.<field> = newValue }` with
`collapseEmptyGit()` running on save (already wired).

### Command Palette extension

`CommandPaletteItem.Kind` grows one case:

```swift
case runProjectScript(ProjectID, WorktreeID, ScriptDefinition.ID)
```

`CommandPaletteItems.build` consults the active selection's
ProjectID; for that Project it iterates `SettingsWriter.readSnapshotSync()
.projects[pid]?.scripts ?? []` and emits one item per script. Item label
is `script.name`; subtitle is the kind's display name (e.g. "Test",
"Deploy", or "Custom"). When the user activates, RootFeature routes the
`Kind` to the new `HierarchyClient.runScript` closure.

Cross-project scripts are not surfaced — switching to project B and
opening the palette must not show project A's scripts. The active
selection drives the build, which already happens for other Project-
scoped palette items.

### Worktree lifecycle execution

Lifecycle scripts run in three new HierarchyManager paths that wrap
the existing lifecycle methods. Each path:

1. Reads the `git.*Script` field from `Settings.projects[pid].git`.
2. If empty, calls the underlying lifecycle method directly (no
   wrapping).
3. If non-empty, spawns a NSTask-backed `Process`:
   - cwd = worktree path (the new one for setup; the existing one
     for archive / delete).
   - environment = resolvedEnv(for: pid).
   - executableURL = the user's `defaultShell` resolution result.
   - arguments = `["-c", scriptCommand]`.
4. Reads the process's combined stdout+stderr into a buffered string;
   shows it in a transient `LifecycleScriptToast` UI element (a small
   sheet that auto-dismisses on success after 5s, stays open on
   non-zero exit until the user dismisses).
5. For `setupScript`: a non-zero exit blocks the create from
   completing — the worktree directory is left on disk (rollback would
   be expensive and surprising), but the catalog row is not added.
   For `archiveScript` / `deleteScript`: a non-zero exit logs a warning
   and the lifecycle action proceeds. Failure does not roll back.
6. The toast UI is part of the main window, not the Settings window —
   lifecycle actions originate from the main window (Add Worktree
   sheet, Archive / Remove buttons), so the script output belongs
   there.

This is intentionally NOT routed through TerminalEngine / PaneSurface:
lifecycle scripts are headless, do not need a PTY, and would otherwise
require ad-hoc tab management for one-shot processes. A direct
`Process` invocation keeps the code path simple.

### Component boundaries

```
apps/mac/
├── CodansCore/
│   ├── Settings/
│   │   ├── ProjectSettings.swift            (no schema change; new
│   │   │                                     `envVars` editor binding helpers)
│   │   ├── GitProjectSettings.swift         (+3 fields: setupScript,
│   │   │                                     archiveScript, deleteScript)
│   │   ├── ScriptDefinition.swift           (expand from placeholder)
│   │   └── ScriptKind.swift                 (NEW)
│   └── (no Hooks model changes)
├── codans/
│   ├── App/Features/Settings/
│   │   ├── SettingsSection.swift            (drop 3 cases, drop 3 sub-row helpers)
│   │   ├── ProjectSettingsFeature.swift     (+ envVars / scripts / hook actions)
│   │   ├── SettingsWindowFeature.swift      (drop kind→subrow mapping for retired panes)
│   │   ├── SettingsWindowView.swift         (drop 3 cases from detail switch)
│   │   └── Panes/
│   │       ├── ProjectGeneralSettingsView.swift   (5-Section rewrite)
│   │       ├── ProjectScriptsSettingsView.swift   (NEW — replaces scaffold)
│   │       ├── ProjectHooksSettingsView.swift     (inline-edit rewrite)
│   │       ├── HookEditorRow.swift                (NEW — expandable row)
│   │       ├── ScopePickerView.swift              (NEW — kind-aware scope picker)
│   │       ├── ScriptDefinitionRow.swift          (NEW — script list row)
│   │       ├── EnvironmentEditorView.swift        (NEW — k/v table)
│   │       ├── OptionalOverridePicker.swift       (NEW — shared override visual)
│   │       └── (DELETE: ProjectGitSettingsView.swift,
│   │                   ProjectGitHubSettingsView.swift,
│   │                   ProjectEnvSettingsView.swift)
│   ├── App/Features/Editor/EditorFeature.swift    (SettingsWriter expanded)
│   ├── App/Clients/
│   │   ├── HookConfigClient.swift                 (+upsert/+delete)
│   │   └── HierarchyClient.swift                  (+runScript)
│   ├── App/Features/CommandPalette/
│   │   ├── CommandPaletteItem.swift               (+runProjectScript Kind)
│   │   └── CommandPaletteItems.swift              (build path consults scripts)
│   ├── App/Features/WorktreeHeader/
│   │   └── HeaderRunScriptSplitButton.swift       (NEW — primary Script entry)
│   ├── Runtime/
│   │   ├── TerminalEngine.swift                   (env passed through to surfaces)
│   │   ├── HierarchyManager.swift                 (createTab widens for env / locked
│   │   │                                            title / icon / tint;
│   │   │                                            +runWorktreeLifecycleScript)
│   │   └── Ghostty/PaneSurface.swift              (env arg + ghostty hookup)
│   └── Tests/
│       ├── (extensive new coverage — see Cross-Cutting)
└── scripts/check-rename-residue.sh               (deny-list grows by 3)
```

Dependency directions:

- `ProjectSettingsFeature` depends on `SettingsWriter` and the new
  `HookConfigClient` closures; no direct `SettingsStore` reference.
- View files (`ProjectGeneralSettingsView` and friends) read live state
  via `@Environment(SettingsStore.self)` for the per-Project entry,
  exactly the Phase 1 fix from the code-reviewer round (so the General
  pane reflects user writes immediately, not the stale post-drain
  catalog snapshot).
- `Process`-based lifecycle execution lives on HierarchyManager because
  it's already the orchestrator for `createWorktree` / `setWorktreeArchived`
  / `removeWorktree`. The new `runWorktreeLifecycleScript(_:for:)` runs
  inline within those methods.
- Command Palette extension imports from `CodansCore` for
  `ScriptDefinition`; the `runProjectScript` activation route lives in
  RootFeature alongside other palette routes.

## Alternatives Considered

### A1. Keep Phase 1's six sub-rows; just fill the four scaffolds

Original Phase 1 plan: each pane stays separate. Phase 2 fills bodies
without changing the sidebar.

- Pros: less code churn (no SettingsSection enum cases retire);
  Phase 1 invariants stay frozen; users who learned the layout don't
  re-learn.
- Cons: (a) sidebar with 6 sub-rows under each Project gets cluttered
  fast as users add Projects; (b) "GitHub" with 3 fields, "Environment"
  with one editor — each pane wastes vertical space relative to its
  content density; (c) inheritance comparison (Project default vs.
  global default) needs cross-pane jumping; (d) supacode-style "one
  pane per Project" pattern has been validated as ergonomic; deviating
  for arbitrary symmetry costs the user.
- Verdict: rejected. The 6-row layout was a Phase 1 placeholder structure
  to defer UX choices, not a final answer. Phase 2 makes the choice.

### A2. Use a single `OptionalToggleRow` for all booleans (true/false/inherit)

Render `copyIgnoredOnWorktreeCreate` as a three-state Toggle alternative:
"On" / "Off" / "Use global default", possibly via SwiftUI's `Picker`
over an `enum {.on, .off, .inherit}`.

- Pros: visually compact; matches macOS Settings `Picker` patterns.
- Cons: a "three-state Toggle" is not a native pattern users recognise;
  Toggle gives clearer "is this enabled" affordance; the picker we
  already use for `defaultMergeStrategy` etc. encodes inheritance fine.
- Verdict: kept the Picker approach. The inheritance UX is consistent
  across Optional Bool / Optional Enum / Optional String fields:
  Picker with a `.use-global` tag.

### A3. Where does the primary Script entry point live?

Three candidate locations for the most-discoverable Run button:

- **(a)** Command Palette only — power-user shortcut, no visible button.
- **(b)** WorktreeHeader split-button — visible at the top of every
  worktree, main click runs the default script, ▾ opens the full list
  + Manage Scripts entry.
- **(c)** Tab-bar `+` menu — submenu of the new-tab affordance.

Verdict: chose **(b)**. Reasons: (a) hides scripts from users who do
not know the palette exists; (c) overloads the tab-bar's trailing
accessory layout (which the tab-bar / status-bar PR just shipped) and
makes scripts feel like "create a new tab from a template" rather
than "run my project's script". WorktreeHeader is the natural visual
home — adjacent to "Open in Editor", scoped to the worktree the user
is looking at, no layout disruption. Command Palette and the Scripts
pane Run button stay as secondary entry points (they were free to
keep).

### A4. Per-script `cwd` + `env` fields on `ScriptDefinition`

Let users specify a script's working directory (relative to worktree
root) and per-script env overrides.

- Pros: matches the maximum flexibility of an analogous `package.json`
  scripts entry; no need to write `cd packages/foo && …` in `command`.
- Cons: every script-edit gets two more fields the user usually doesn't
  need; the `command` string already supports inline `cd` and `KEY=VAL
  cmd` prefixes natively in shell; the persisted shape grows for value
  most users won't set; testing surface widens.
- Verdict: rejected. Per-Project envVars is enough for the common case
  (Project-wide vars); rare per-script needs use shell prefixes in
  `command`. If user feedback says otherwise we can revisit.

### A5. Hook editing in a modal sheet rather than inline

Open a presented `.sheet` for each hook edit instead of expanding the
row.

- Pros: more vertical room for the editor; clearer "I am editing this
  hook" mental model; allows bigger Command TextEditor.
- Cons: an extra modal hop; users editing several hooks in a row
  open/close sheets repeatedly; inline expand is consistent with how
  the Settings window's Section disclosures work elsewhere; sheet
  presentation and TCA `@Presents` plumbing add complexity.
- Verdict: rejected. Inline expand keeps the user inside the Hooks
  pane.

### A6. Lifecycle scripts run in a real terminal pane (TerminalEngine)

Rather than a headless `Process`, spawn a transient pane just like
`runScript` does, so users see a familiar terminal.

- Pros: shared infrastructure (TerminalEngine env injection / surface
  setup is reused); user can interact with prompts (e.g. `read -p`).
- Cons: lifecycle moments don't have a host tab — the worktree might
  not even be selected yet (setup runs before the worktree shows up
  in the sidebar; archive runs while the user is on a different
  worktree). Spawning a transient tab disrupts the workspace; closing
  it on success raises tab-management questions; opening a sheet
  containing a tab is even worse.
- Verdict: rejected for v1. A direct `Process` with a small
  `LifecycleScriptToast` UI is purpose-fit. If users complain the
  transient toast doesn't show enough output, revisit.

### A7. Scope picker as 9 separate sections instead of a kind picker

Render every scope kind as its own row with an exclusive radio group;
only the user-selected row's value control is editable.

- Pros: every scope kind is visible at once; no need to discover the
  kind picker.
- Cons: the editor takes ~9× the vertical space; users have to scroll
  past 8 kinds they don't want to find the one they do; visually
  overwhelming.
- Verdict: rejected. A single Picker plus conditional value control is
  the right balance.

### A8. Reuse one tab per ScriptDefinition.id (with locked title) vs. fresh tab every Run

Considered: track `[ScriptDefinition.ID: TabID]` per Project; rerunning
a script closes the previous tab and opens a new one; the tab title is
locked so users cannot accidentally break the script→tab mapping by
renaming.

- Pros (one-tab-per-script): no tab clutter when a user runs the same
  script repeatedly; tabs always identifiable by name; matches
  IDE-style "test runner" affordance.
- Cons: requires a new `Tab.lockedTitle: Bool` Codable field; requires
  reconcile-on-boot logic to unlock orphaned tabs whose script was
  deleted; users who genuinely want two parallel runs (e.g. of `npm
  test` against two branches) can't get them; tab-management is a
  cheap user action (⌘W); we are inventing a special-case for tabs
  that does not match how any other tab in codans behaves.
- Verdict: rejected. Every Run opens a fresh tab. Title is the
  initial `script.name` but freely renameable like any other tab; no
  `lockedTitle` field, no per-script tab map, no reconcile path. If
  user feedback says clutter is real we can add an opt-in
  "reuse last tab" Toggle to `ScriptDefinition` later — additive,
  no migration.

## Cross-Cutting Concerns

### Testing strategy

Per pane, target ≥ 6 tests; total Phase 2 net new ≈ 50.

- **General pane**: each Section's binding round-trip — Picker
  selecting `.use-global` returns `defaultEditor == nil`; selecting a
  specific value writes to settings.json; Toggle three-state behaves
  same way.
- **Environment editor**: KEY validation (POSIX rule reject), VALUE
  accepts arbitrary string, duplicate KEY refused, blank row never
  commits, delete row + add same KEY round-trips.
- **Scripts data**: ScriptDefinition Codable round-trip across all
  6 ScriptKind cases; predefined kind ignores `systemImage` /
  `tintColor` overrides; custom kind respects them; manual reorder
  via `.onMove` writes back the new array.
- **Scripts execution**: `runScript` opens a tab with locked title;
  re-running same `script.id` closes previous tab; deleted script
  invocation gets `.unknownScript` error; tab close removes from
  per-script tab map.
- **Lifecycle scripts**: empty `setupScript` skips invocation; non-empty
  `setupScript` blocks worktree create on non-zero exit; non-empty
  `archiveScript` warns but proceeds on non-zero exit; cwd is the
  expected path; env is the resolved Project envVars.
- **Hook editor**: scope kind switch preserves text in glob/label
  buffer; ID-scope picker requires non-empty selection to save; save
  routes to `HookConfigClient.upsert`; delete confirms then routes;
  saving with non-project scope removes row from this pane.
- **Schema additivity**: a v3 settings.json without the new
  `setupScript` / `archiveScript` / `deleteScript` keys decodes
  without error and round-trips identically.
- **Env injection (live)**: TerminalEngine integration test that asserts
  spawned pane has `MY_VAR=hello` in its env — at minimum a smoke test
  invoking `printenv` and reading the output via a terminal handler.

### Error handling

- Hook edit save: validation errors keep the row expanded and red-flag
  fields; never silently drops user input.
- Lifecycle script execution failure: the toast keeps the pane open
  with stdout+stderr until the user dismisses; the underlying lifecycle
  action either rolls back (setup) or proceeds with a logged warning
  (archive / delete).
- Script tab creation failure (e.g. ghostty engine returns nil): show a
  one-shot alert "Could not start script — see Console for details";
  clear the per-script tab map entry so the next attempt is clean.
- Env editor invalid input: per-row inline error; never blocks Save on
  other valid rows.

### Security / privacy

- No new external input surfaces. Hook commands and Script commands run
  with the same privileges the codans app has. The user authored
  the strings; we run them. No sandboxing change.
- Environment values may contain secrets (API tokens, passwords). The
  values land in plaintext `settings.json` (mode 0600 already, same as
  the rest of the file). UI does not mask. We document this in the
  Environment Section's footer caption: "Values are stored in plain
  text in settings.json. Do not paste credentials you wouldn't keep in
  a config file."
- Lifecycle scripts run before the catalog records the worktree. A
  malicious / broken `setupScript` cannot corrupt codans state —
  worst case the worktree directory exists on disk but is not in the
  catalog. Recovery: user runs Add Worktree again, picks Existing
  Worktree path.

### Observability

- Each new write site logs through the existing `com.gumpw.codans.persistence`
  / `com.gumpw.codans.hooks` Loggers.
- Lifecycle script invocations log a single line at start (event,
  worktreeID, script length) and a single line at end (exit code,
  elapsed). stdout/stderr go to the toast, not the system log
  (privacy: scripts may print user data).
- Script tab creation logs through `com.gumpw.codans.runtime` /
  `category: "scripts"` (NEW category).

### Migration

- No JSON schema bump. Adding `setupScript` / `archiveScript` /
  `deleteScript` to `GitProjectSettings` is additive (Codable
  `decodeIfPresent`); empty defaults round-trip as omitted.
- `ScriptDefinition` schema expands additively from Phase 1's
  `(id, name, command)`. Old Phase 1 entries (none on disk yet — the
  field was reserved-empty) decode with kind defaulting to `.run` and
  optional fields nil. (Phase 1 testing confirmed no production
  settings.json has script entries.)
- No `Catalog` schema change — Script tabs use the same `Tab.name`
  field every other tab uses; no `lockedTitle` flag added.
- The retired sub-pane SettingsSection cases mean any saved sidebar
  selection state in user data referencing them resets to General
  on first launch under Phase 2. Selection state is session-only
  per Phase 1's design, so no persistent cleanup needed.

### Documentation

- `docs/architecture.md`: Settings.json description gains the lifecycle-
  script + envVars notes, but version stays v3.
- `docs/product-specs/ui-settings-window.md`: Acceptance Criteria
  amended with the new General pane sections and the editable Hooks
  row, plus the Scripts pane Lifecycle + User-defined sections.
- This design doc supersedes nothing; it amends Phase 1's "Non-Goals"
  list (the four scaffolds and read-only Hooks).

## Risks

- **R1: libghostty per-surface env not supported.** The fallback (typed
  `export` lines into PTY) works but pollutes shell history and adds a
  visible `$ export…` flash before the user's first command. Mitigation:
  prefix each line with a leading space (relies on `HISTCONTROL=ignorespace`
  in user's bashrc/zshrc) and use a single `export A='1' B='2' …` line
  instead of one-per-var to compress the flash. Document in the
  Environment Section caption: "If you see export lines printed at pane
  startup, your shell does not have `HISTCONTROL=ignorespace`."
  Add a setting: `Settings.developer.envInjectionMode = {ghostty, exportLines}`
  is a stretch goal; not in initial scope.
- **R2: lifecycle script blocks UI on long-running setup.** A user
  setting `setupScript = "git lfs fetch --all"` could take minutes,
  during which the Add Worktree sheet is non-interactive. Mitigation:
  the `LifecycleScriptToast` has a Cancel button that sends `SIGTERM`
  to the process; if the user truly wants async setup, they encode it
  as `(git lfs fetch --all &) >/dev/null 2>&1` and accept the worktree
  creation succeeds before the fetch finishes.
- **R3: malformed env values break libghostty / shell.** Specifically
  newline-containing values, since most shells refuse multi-line env
  vars. Mitigation: the env editor rejects values containing `\n` /
  `\r` with an inline error. Single-line values pass through as-is.
- **R4: hook edit race — user mid-edit while another writer mutates
  hooks.json.** The Developer pane (where global hooks land) and the
  Project Hooks pane both eventually write through `HookConfigClient.upsert`.
  If user A is mid-edit on a row, user B (somehow) saves a different
  row's edit, the in-memory state drifts from disk. Mitigation:
  `HookConfigStore.scheduleSave` is single-writer / `@MainActor`, and
  every `upsert` re-reads the in-memory `HookConfig` before mutation.
  No real race in single-process codans; cross-process editing
  (user opens hooks.json in vim while Settings is open) is detected
  by the file-watch reload path that exists today.
- **R5: scripts with overlapping `.id`s after manual user-edits to
  settings.json.** Settings.json is hand-editable; a user duplicating a
  script's id would break the per-script-id tab map. Mitigation: at
  load time, `ProjectSettings.normalizeScriptIDs()` runs once and
  generates a fresh UUID for any duplicate `id` it encounters; logs a
  warning per replacement.
- **R6: `defaultShell` resolution fails (binary missing).** Project
  resolves the override before spawning, but the binary may not exist
  on disk — old setting persisting after an uninstall. Mitigation:
  `defaultShell` Picker shows only currently-installed shells; saving
  a value not in the list is rejected. At spawn time, missing-binary
  is caught and logged; the spawn falls back to `/bin/zsh` (macOS
  default) and shows a one-shot toast "Project shell not found, using
  /bin/zsh".
- **R7: Script tab pile-up under heavy iteration.** A user repeatedly
  running the same script (`▶ Test` ten times in a row) ends up with
  ten "Test" tabs side-by-side. Mitigation: ⌘W closes the active tab
  in one keystroke; "Close other tabs" in the tab-bar context menu
  closes a whole worktree's debris in one shot; we accept this as
  user-controlled cost rather than building one-tab-per-script with
  locked titles. If feedback says it actually bites, the additive
  fix is a per-script "reuse last tab" Toggle.

## Open Questions

None at Draft time. All decisions confirmed inline:

- Sidebar collapses to 3 sub-rows ✓
- General combines 5 Sections ✓
- Lifecycle scripts blocking, fail-stop on setup, fail-warn on archive/delete ✓
- Lifecycle scripts stay separate from `HookEvent.worktree*` (different
  semantics: blocking vs fire-and-forget) ✓
- ScriptDefinition without per-script cwd / env ✓
- Scripts run in fresh tabs every invocation; no dedup, no locked title ✓
- WorktreeHeader split-button is the primary entry point; Command
  Palette + Scripts-pane Run button are secondary ✓
- envVars override merges with process env, project keys win ✓
- envVars injected via libghostty per-surface env (fallback: typed export) ✓
- Hook editor inline-expand ✓
- Hook scope picker is kind-aware ✓
- No new schema version ✓

Anything that surfaces during planning or implementation goes into an
Amendments section here.
