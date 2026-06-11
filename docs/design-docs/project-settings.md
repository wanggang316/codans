# Design Doc: Project Settings — Unified Per-Project Preferences

**Status:** Approved
**Author:** Gump
**Date:** 2026-04-24
**Supersedes:** [settings-repositories.md](./settings-repositories.md) — T4's
decisions on vocabulary (`Repository*`), storage split (catalog vs settings),
and hook scoping are explicitly replaced by this doc.

## Context and Scope

T4 (exec-plan `settings-repositories.md`) shipped the per-Project Settings
subtree with two panes (General, Hooks) keyed by `ProjectID`. In doing so it
cemented three decisions that this doc revisits:

1. **Vocabulary.** T4 called the unit a `Repository` (`RepositorySettings`,
   `Settings.repositories`, `SettingsSection.repositoryGeneral`,
   `HierarchyClient.setRepository*`, `RepositorySettingsFeature`). The product
   model has always been `Project` — the two types in it are `git_repo` (git-
   managed) and `plain_dir` (unmanaged folder). Calling the git variant alone
   "repository" and then overloading the name to cover both types is confusing
   and fights the `Project` vocabulary used everywhere else (`Catalog.spaces[].projects[]`,
   `SettingsSection.*(ProjectID)`, `HierarchyManager.findProject*`). The name
   leaks into JSON keys, test names, and the Settings sidebar UI.
2. **Storage split (D1).** T4 kept per-Project user preferences
   (`Project.defaultEditor`, `Project.worktreesDirectory`) on `catalog.json`
   and left `Settings.repositories` as "reserved-empty, future GitHub
   overrides only." In practice the split means two files own two halves
   of the same mental-model slice; adding each new preference forces a
   coin-flip on where it goes, and the user experience ("edit a Project
   setting") is implemented by routing through `HierarchyClient` for some
   fields and `SettingsStore` for others.
3. **Hook scope.** Hooks (exec-plan 0003) are the app's own event-subscription
   system — distinct from git hooks. `HookSubscription.Scope` currently has
   seven cases that can bind to panes, tabs, or worktrees, but **none** that
   binds to a Project directly. The T4 classifier therefore can only promote
   a subscription to `HookSource.repository` when its `worktreePathGlob`
   happens to match the project root, or when its `worktreeID` appears in the
   project's worktree list. Plain-dir Projects have a synthetic worktree and
   no concept of multiple worktrees, so user-facing "hook for this project"
   authoring has no precise scope to emit.

Additionally, `ProjectKind` is implicit — callers check `gitRoot != nil`. Some
UI surfaces (notably the Settings sidebar sub-items) need to conditionally
render by kind. That distinction is worth naming rather than spreading
`gitRoot != nil` across call sites.

This doc proposes the minimal set of changes that fixes all four at once,
because the rename, the storage unification, and the hook-scope evolution
cannot cleanly land separately: each touches the JSON schemas and the
reducer surface that the other two rely on.

Reference files (read for this design):

- `apps/mac/CodansCore/Project.swift` — `Project` struct, carries
  `defaultEditor`, `worktreesDirectory`, `gitRoot`. `supportsWorktrees`
  derived property is the implicit kind flag today.
- `apps/mac/CodansCore/Catalog.swift` — v1; `garbageCollectEditors`
  walks `Project.defaultEditor` at load.
- `apps/mac/CodansCore/Settings/Settings.swift` — v2; holds
  `repositories: [ProjectID: RepositorySettings]`, string-keyed JSON.
- `apps/mac/CodansCore/Settings/RepositorySettings.swift` — three fields
  today (`defaultMergeStrategy`, `postMergeAction`, `githubDisabled`).
- `apps/mac/codans/App/Features/Settings/RepositorySettingsFeature.swift`
  — the implemented T4 reducer with `classifyHooks` / `isRepositoryScope`.
- `apps/mac/codans/App/Features/Settings/SettingsWindowFeature.swift`
  — `repositoryPanes: IdentifiedArrayOf<…>` composition.
- `apps/mac/codans/App/Features/Settings/SettingsSection.swift` —
  `.repositoryGeneral(ProjectID)` / `.repositoryHooks(ProjectID)` cases.
- `apps/mac/CodansCore/Hooks/HookSubscription.swift` — `Scope` enum with
  7 cases; Codable uses `{ kind, value }` discriminated form.
- `apps/mac/CodansCore/Hooks/HookConfig.swift` — v1; decoder rejects
  non-v1 files.
- `apps/mac/codans/Hooks/HookDispatcher.swift`,
  `apps/mac/codans/App/Features/Socket/handlers/HookHandlers.swift` —
  exhaustive `switch` on `Scope` — adding cases forces compile-time coverage.

## Goals and Non-Goals

### Goals

- **G1 — Unify vocabulary.** Every `Repository*` / `repositories` identifier
  related to per-Project settings is renamed to `Project*` / `projects`.
  Includes: `RepositorySettings` → `ProjectSettings`, `Settings.repositories`
  → `Settings.projects`, `SettingsSection.repository*` → `.project*`,
  `RepositorySettingsFeature` → `ProjectSettingsFeature`,
  `HierarchyClient.setRepository*` → `setProject*`, `HookSource.repository`
  → `.project`. Test names follow.
- **G2 — Single home for per-Project preferences.** All user-editable
  per-Project fields live on `Settings.projects[ProjectID]` in
  `settings.json`. `Project` in `catalog.json` retains only identity /
  structure (`id`, `name`, `rootPath`, `gitRoot`, `spaceID` positional,
  `worktrees`, `selectedWorktreeID`). `defaultEditor` and
  `worktreesDirectory` move out of `Project` into `ProjectSettings`.
- **G3 — First-class kind.** Introduce `ProjectKind { gitRepo, plainDir }`
  as a derived property on `Project` (from `gitRoot`). Expose it through
  `HierarchyClient` so Settings UI and the sidebar conditionally render
  sub-panes by kind without grepping `gitRoot != nil`.
- **G4 — Settings layout by kind.**
  - `git_repo`: General, **Git & Worktree**, **GitHub**, Scripts, Hooks,
    Environment.
  - `plain_dir`: General, Scripts, Hooks, Environment.
  - Kind itself is **not surfaced in the UI** — no icon, no badge, no
    label distinguishing git_repo from plain_dir in the sidebar. Kind
    drives which sub-rows appear and nothing else. Users infer the
    distinction implicitly from the available panes.
  - The Git-specific payload in `ProjectSettings` is nested under
    `git: GitProjectSettings?`. Present for `gitRepo`, omitted for
    `plainDir`. If a `plainDir` upgrades via `git init`, the app creates
    `git` on first Git pane render.
- **G5 — Project-scoped Hooks.** Add two cases to `HookSubscription.Scope`:
  `.projectID(ProjectID)` and `.projectPathGlob(String)`. Both match a Project
  regardless of its kind — `plain_dir` projects can now subscribe to `pane.*`,
  `tab.*` events scoped to them. The T4 classifier now uses these directly
  instead of deriving project membership from worktree-level scope.
- **G6 — Forward-compatible Scope decoding.** `HookSubscription.Scope.Kind`
  Codable becomes fail-soft on unknown kinds: the subscription is skipped
  with a logged warning, not the whole file. Future scope-taxonomy additions
  do not break pre-update clients' ability to load the file.
- **G7 — Schema migrations land automatically.** `settings.json` v2 → v3,
  `catalog.json` v1 → v2, `hooks.json` v1 → v2. Each decoder accepts both
  the old and the new version, upgrades in-memory, and the next save
  writes the new version. No user action required.

### Non-Goals

- **No in-window hook editing.** Adding / enabling / disabling hooks via
  the Settings window remains out of scope; the Reveal-in-Finder hatch
  stays. Hook authoring still happens through `hooks.json` or `codans hook`.
- **No per-Worktree settings.** Override hierarchy in v1 is global →
  project. A future v2 may introduce worktree-level overrides; the
  `Optional<T>` shape of every override field is chosen so that extension
  is purely additive.
- **No per-repo checked-in config file.** All project settings live in
  the user-global `settings.json`. A dual-location scheme (team-shared
  config committed to the repo, overlaid on top of global settings) is
  not in scope. When team-shared per-repo config becomes a requirement,
  revisit.
- **No new settings payload beyond what T4 already touches + what the
  schema needs to carry.** Scripts, Environment, GitHub Pane beyond the
  existing three fields are scaffolded (panes, sections, types) but their
  field set and UX land in follow-up waves. This doc reserves the slots;
  subsequent design docs fill them.
- **No rewrite of Scope-matching semantics in `HookDispatcher`.** The
  dispatcher today fires by `event` + `disabled` and lets consumers filter
  by scope. The fire-path scope-filtering gap is pre-existing and not
  this doc's concern; adding new scope cases follows the same non-filter
  pattern.
- **No rename of the Settings window scene ID / toolbar / sidebar
  disclosure UI strings.** User-visible strings stay ("General", "Hooks",
  etc.). The rename is code-internal; the one user-visible nudge is the
  sidebar group header which is driven by spec copy, not by the enum
  name.

## Design

### Overview

Three structural moves, one rename, each mechanically small but
coordinated because they share schemas:

1. **Rename** the `Repository*` surface to `Project*` (G1). Mechanical,
   compiler-enforced, no behavior change.
2. **Unify storage** (G2, G4). `Settings.projects[pid]: ProjectSettings`
   absorbs the two catalog fields; `Project` on the catalog loses them.
   `ProjectSettings` is flat for universal fields, with `git: GitProjectSettings?`
   nested for kind-specific fields. Settings window renders sub-panes by
   `ProjectKind`.
3. **Extend Hook scope** (G5, G6). `.projectID` / `.projectPathGlob`
   become first-class; the T4 classifier reads them directly. Decoder
   fail-soft on unknown scope kinds makes future extension cheap.

The central trade-off running through all three is **short-term
disruption for long-term coherence.** The alternative — leaving names
and storage where T4 put them and adding plain-dir support on top — is
tractable, but every subsequent feature would have to explain *why* the
UI says "Project" while the code says "Repository", and *why* adding a
per-Project preference means a coin-flip between two files. T4 deferred
both choices to ship M11/M12 on time; this doc pays down the debt
before we build `git_repo` / `plain_dir` UI branching on top.

### System Context Diagram

```
┌───────────────────────────────────────────────────────────────┐
│ Settings Window Scene                                         │
│                                                               │
│   SettingsSidebarView ── kind = hierarchyClient.kind(of: pid) │
│         │                                                     │
│         │  renders sub-rows conditionally by kind             │
│         ▼                                                     │
│   SettingsSection.projectGeneral(pid) / .projectGit(pid) /    │
│   .projectGitHub(pid) / .projectHooks(pid) / .projectScripts  │
│   / .projectEnv(pid)                                          │
│         │                                                     │
│         ▼                                                     │
│   ProjectSettingsFeature (was RepositorySettingsFeature)      │
│         │                                                     │
│         ├─ reads/writes  Settings.projects[pid]: ProjectSettings
│         │                  via SettingsStore                  │
│         ├─ reads         Catalog (identity, worktrees only)   │
│         │                  via HierarchyClient                │
│         ├─ reads         HookConfig                           │
│         │                  via HookConfigClient               │
│         └─ reveals       hooks.json                           │
│                            via FinderClient                   │
│                                                               │
├── Stores (disk) ──────────────────────────────────────────────┤
│                                                               │
│  ~/.config/codans/settings.json  v3  ◀─ SettingsStore    │
│      { version: 3, projects: { <pid>: ProjectSettings } }    │
│                                                               │
│  ~/.config/codans/catalog.json   v2  ◀─ HierarchyManager │
│      Project { id, name, rootPath, gitRoot, worktrees, ... } │
│      (defaultEditor and worktreesDirectory removed)          │
│                                                               │
│  ~/.config/codans/hooks.json     v2  ◀─ HookConfigStore  │
│      Scope: + .projectID, + .projectPathGlob                 │
│                                                               │
└───────────────────────────────────────────────────────────────┘

Migration on first load:
  v2 settings.json  → read; move repositories[] to projects[];
                      absorb catalog Project.{defaultEditor,
                      worktreesDirectory} into projects[pid];
                      write v3.
  v1 catalog.json   → read; drop Project.{defaultEditor,
                      worktreesDirectory}; write v2.
  v1 hooks.json     → read; no payload change; write v2.
```

### Data Model

#### ProjectKind

```swift
public nonisolated enum ProjectKind: String, Codable, Hashable, Sendable {
  case gitRepo   = "git_repo"
  case plainDir  = "plain_dir"
}

extension Project {
  public var kind: ProjectKind { gitRoot == nil ? .plainDir : .gitRepo }
}
```

Derived, not persisted. Rationale: `gitRoot` is already on disk and is
the source of truth; introducing a second stored field would invite
drift (user runs `git init`, the explicit `kind` becomes stale). The
UI reads `project.kind` through a new `HierarchyClient.kind(of:)`
closure so reducers don't need the full `Project` snapshot.

#### ProjectSettings (replaces RepositorySettings)

```swift
public nonisolated struct ProjectSettings: Equatable, Codable, Sendable {
  // Identity-agnostic; applies to both kinds.
  public var defaultEditor: EditorID?          // moved from Project
  public var worktreesDirectory: String?       // moved from Project
  public var defaultShell: String?             // reserved; future wave
  public var envVars: [String: String]         // reserved; future wave
  public var scripts: [ScriptDefinition]       // reserved; future wave

  // Git-only; nil for plain_dir (or whenever user has no git overrides).
  public var git: GitProjectSettings?

  public var isEffectivelyEmpty: Bool { /* all-nil check */ }
}

public nonisolated struct GitProjectSettings: Equatable, Codable, Sendable {
  public var worktreeBaseRef: String?                 // reserved
  public var copyIgnoredOnWorktreeCreate: Bool?       // reserved
  public var copyUntrackedOnWorktreeCreate: Bool?     // reserved
  public var defaultMergeStrategy: MergeStrategy?     // was on RepositorySettings
  public var postMergeAction: MergedWorktreeAction?   // was on RepositorySettings
  public var githubDisabled: Bool                     // was on RepositorySettings

  public var isEffectivelyEmpty: Bool { /* all-nil + !githubDisabled */ }
}
```

The three existing T4 GitHub fields migrate under `git.*`. The two
fields moving off `Project` (`defaultEditor`, `worktreesDirectory`)
land at the top level of `ProjectSettings` — they apply to both kinds
(a plain_dir project still has a default editor; `worktreesDirectory`
is a no-op for plain_dir but carrying it universally simplifies the
data model, and a future `git init` upgrade picks it up at no extra
cost).

`isEffectivelyEmpty` drives the existing `Settings.garbageCollect` GC
sweep — both the outer struct and the nested `git` keep `{}`
placeholders out of disk. GC semantics: if `git` is itself
effectively-empty, set it to `nil` before checking the outer struct.

#### Settings (v3)

```swift
public nonisolated struct Settings: Equatable, Sendable {
  public static let currentVersion = 3

  public var version: Int
  public var general: GeneralSettings
  public var notifications: NotificationsSettings
  public var developer: DeveloperSettings
  public var projects: [ProjectID: ProjectSettings]      // was `repositories`
}
```

JSON key change: `repositories` → `projects`. ProjectID is encoded as a
UUID-string-keyed object (the pattern Settings v2 already uses).

#### Project (unchanged shape; two fields removed)

```swift
public nonisolated struct Project: Equatable, Sendable, Identifiable {
  public var id: ProjectID
  public var name: String
  public var rootPath: String
  public var gitRoot: String?
  public var worktrees: [Worktree]
  public var selectedWorktreeID: WorktreeID?
  public var loadState: ProjectLoadState        // transient, unchanged
  // REMOVED: defaultEditor, worktreesDirectory
}
```

Derived: `var kind: ProjectKind`, `var supportsWorktrees: Bool` (kept,
still tied to `gitRoot != nil`).

#### HookSubscription.Scope (two new cases)

```swift
public enum Scope: Equatable, Sendable {
  case anyPane
  case paneID(PaneID)
  case paneLabel(String)
  case tabID(TabID)
  case tabLabel(String)
  case worktreeID(WorktreeID)
  case worktreePathGlob(String)
  case projectID(ProjectID)           // NEW
  case projectPathGlob(String)        // NEW; matches project.rootPath
}
```

Codable Kind enum grows two string cases (`projectID`,
`projectPathGlob`). Discriminator format unchanged: `{ kind, value }`.
Decoder behavior changes (see G6): unknown `kind` string no longer
fails the enum — the surrounding `HookSubscription` decoder catches
the typed error, logs a warning, and returns `nil`, which the
containing `[HookSubscription]` decoder treats as an entry to skip.

### API Design

#### ProjectSettingsFeature (renamed from RepositorySettingsFeature)

Shape preserved; fields renamed. Two new actions reserved for the
next-wave sub-panes (Git, GitHub):

```swift
@Reducer
struct ProjectSettingsFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let projectID: ProjectID
    var kind: ProjectKind              // NEW: read once on entry
    var hooksLoad: HooksLoad = .idle
    var lastWriteFailure: String?
    var id: ProjectID { projectID }
  }

  enum Action: Equatable {
    // General
    case setDefaultEditorOverride(EditorID?)
    case setWorktreeBaseDirectory(String?)   // kept; no-op on plain_dir

    // Hooks
    case onHooksAppear
    case hooksLoaded(Result<[HookRow], LoadError>)
    case revealHooksJSONRequested

    // Common
    case writeFailed(String)

    // Reserved for follow-up waves (types elided)
    // case setDefaultMergeStrategy(MergeStrategy?)   // git only
    // case setGitHubDisabled(Bool)                   // git only
    // case setScripts([ScriptDefinition])
    // case setEnvVar(key: String, value: String?)
  }
}
```

Writes go through `SettingsStore.updateProject(pid) { ps in … }`, not
`HierarchyClient` — this is the core storage unification. `SettingsStore`
gains a narrow mutator:

```swift
extension SettingsStore {
  /// Lock-free read-modify-write of a single Project's settings slot.
  /// Creates an empty `ProjectSettings` if missing. Triggers the
  /// existing 500ms debounced atomic save.
  @MainActor
  func updateProject(_ pid: ProjectID, transform: (inout ProjectSettings) -> Void)
}
```

`HierarchyClient.setProjectDefaultEditor` /
`setProjectWorktreeBaseDirectory` (the T4 closures) are **removed** —
their callers route through `ProjectSettingsFeature` instead, whose
effects target `SettingsStore`. `WorktreeHeader`'s "Open in" dropdown,
which wrote via `EditorFeature.setProjectOverride` → HierarchyClient,
also rewires to `SettingsStore.updateProject`.

#### HierarchyClient — slim down, add `kind(of:)`

Remove: `setRepositoryDefaultEditor`, `setRepositoryWorktreeBaseDirectory`
(moved to SettingsStore).

Add:

```swift
var kind: @MainActor @Sendable (_ projectID: ProjectID) -> ProjectKind?
```

Returns `nil` if the Project is gone — caller treats as "pane will be
pruned on next `.projectsChanged`."

Keep: `snapshot()`, `setDefaultEditor(_, for:, in:)` (the two-ID variant
is still used by the worktree header; it remains a pure catalog mutator
for a now-nonexistent field, so it too goes away — see rewiring in
Migration below).

Actually, `setDefaultEditor(_, for:, in:)` becomes dead after the
migration (catalog no longer carries `defaultEditor`). The "Open in"
dropdown rewires to a new `EditorFeature.setProjectOverride` variant
that writes to `SettingsStore` instead. See Component Boundaries.

#### HookConfigClient — unchanged surface

No change. The `load()` / `ensureExists()` split continues. The only
behavioral change is inside `HookConfigStore`: v1 files are auto-upgraded
to v2 on first successful decode + save.

#### Hook classification (simpler)

```swift
nonisolated func classifyHook(
  _ subscription: HookSubscription,
  for project: Project
) -> HookSource {
  switch subscription.scope {
  case .anyPane, .paneID, .paneLabel, .tabID, .tabLabel:
    return .global

  case .projectID(let pid):
    return pid == project.id ? .project : .global

  case .projectPathGlob(let glob):
    return fnmatch(glob, project.rootPath) ? .project : .global

  case .worktreeID(let wtID):
    return project.worktrees.contains { $0.id == wtID } ? .project : .global

  case .worktreePathGlob(let glob):
    // Worktree-path glob is about worktrees; match ONLY worktree paths.
    // Matching the project root here was a T4 workaround for the missing
    // projectID scope. With .projectID now available, keep worktreePathGlob
    // strictly worktree-scoped — users who want project-scope choose
    // .projectPathGlob.
    return project.worktrees.contains { fnmatch(glob, $0.path) }
      ? .project : .global
  }
}
```

`HookSource.repository` is renamed to `.project`. T4's
`isRepositoryScope` helper collapses into this switch; the glob-matching
helper `doesPathMatchGlob` is kept as-is (pulled into its own file
because it's used by three callers: two `fnmatch` sites here + the
existing `HookExecutor` path-match site).

### Data Storage

#### settings.json: v2 → v3

**v2 shape:**

```jsonc
{
  "version": 2,
  "general":     { /* ... */ },
  "notifications": { /* ... */ },
  "developer":   { /* ... */ },
  "repositories": {
    "<project-uuid>": {
      "defaultMergeStrategy": "squash",
      "postMergeAction": "archive",
      "githubDisabled": false
    }
  }
}
```

**v3 shape:**

```jsonc
{
  "version": 3,
  "general":     { /* ... */ },
  "notifications": { /* ... */ },
  "developer":   { /* ... */ },
  "projects": {
    "<project-uuid>": {
      "defaultEditor": "vscode",
      "worktreesDirectory": "/Users/x/worktrees/a",
      "git": {
        "defaultMergeStrategy": "squash",
        "postMergeAction": "archive",
        "githubDisabled": false
      }
    }
  }
}
```

**Migration (v2 → v3).** `Settings.init(from:)` accepts `version` in
`{2, 3}`. On v2:

1. Read `repositories` under its old key; map each value into a
   `ProjectSettings` whose `git` field holds the three GitHub fields
   (all other top-level fields `nil`).
2. Read `catalog.json` in parallel (same load path), gather per-Project
   `defaultEditor` / `worktreesDirectory` values, fold them into the
   corresponding `projects[pid]` entry. This requires the Settings load
   to have catalog access — resolved by doing the v2→v3 fold inside
   `SettingsStore.bringUp()`, which already runs after `HierarchyManager`
   is loaded. The decoder itself stays pure; the fold is a post-decode
   step.
3. Write v3 back to disk on the next scheduled save.

v3 is the steady state; v2 files persist until first save.

#### catalog.json: v1 → v2

**v2 change:** `Project` omits `defaultEditor` and `worktreesDirectory`
CodingKeys. `init(from:)` still reads them `decodeIfPresent` (for v1
input) and carries them into the in-memory `Project` only during the
migration window — the settings-side `bringUp` fold reads them from
there, clears them in `Catalog`, and writes v2.

The decoder accepts `version` in `{1, 2}`. `Project` v1 decoder returns
a struct whose `defaultEditor` / `worktreesDirectory` are `nil` after
the migration has completed; subsequent saves write v2 shape without
those keys.

**`garbageCollectEditors`.** Walks `defaultEditor` on `Project` today.
Moves to walk `Settings.projects[pid].defaultEditor` — the helper
migrates alongside the field, keeping the "once at load" invariant.

#### hooks.json: v1 → v2

**v2 change:** Adds two `Scope.Kind` cases. `HookConfig.currentVersion
= 2`. Decoder accepts `version` in `{1, 2}`. Subscription decoding uses
a fail-soft Kind decoder — unknown-kind entries are dropped and logged.

The dispatcher / handlers / classifier / `HookMergeView` scope-label
helper each grow two `case .projectID` / `case .projectPathGlob`
branches (exhaustive switch, compiler-enforced).

#### Migration choreography

Migration reads span two files and must be ordered:

```
AppState.bringUp() {
  1. hierarchyManager.load()       // reads catalog.json v1 or v2
  2. settingsStore.load()           // reads settings.json v2 or v3;
                                    // if v2, folds catalog overrides
                                    // in, then writes v3 and a cleaned
                                    // v2 catalog
  3. hookConfigStore.load()         // reads hooks.json v1 or v2
                                    // unknown scope kinds drop-with-log
}
```

Each migration is idempotent: re-running against a v3 file is a no-op
and produces no disk write. Failure mode: if the catalog backing file
is corrupt, Settings migration runs as if no catalog overrides existed
— users keep their GitHub preferences, lose nothing durable (the catalog
is rebuilt from disk scanning anyway).

### Component Boundaries

```
apps/mac/
├── CodansCore/
│   ├── Project.swift                          (field removal + kind derivation)
│   ├── Catalog.swift                          (v2 version bump, GC walk move)
│   ├── Settings/
│   │   ├── Settings.swift                     (v3, repositories→projects)
│   │   ├── ProjectSettings.swift              (RENAMED from RepositorySettings.swift)
│   │   └── GitProjectSettings.swift           (NEW)
│   └── Hooks/
│       ├── HookSubscription.swift             (+2 Scope cases, fail-soft Kind)
│       └── HookConfig.swift                   (v2)
│
├── codans/
│   ├── App/Features/Settings/
│   │   ├── SettingsSection.swift              (project* cases)
│   │   ├── ProjectSettingsFeature.swift       (RENAMED; uses SettingsStore for writes)
│   │   ├── SettingsWindowFeature.swift        (projectPanes + kind-aware selection)
│   │   ├── SettingsWindowView.swift           (detail switch re-labelled)
│   │   ├── Sidebar/SettingsSidebarView.swift  (conditional sub-rows by kind)
│   │   └── Panes/
│   │       ├── ProjectGeneralSettingsView.swift  (RENAMED)
│   │       ├── ProjectGitSettingsView.swift      (NEW scaffold)
│   │       ├── ProjectGitHubSettingsView.swift   (NEW scaffold)
│   │       ├── ProjectHooksSettingsView.swift    (RENAMED)
│   │       ├── ProjectScriptsSettingsView.swift  (NEW scaffold)
│   │       ├── ProjectEnvSettingsView.swift      (NEW scaffold)
│   │       └── HookMergeView.swift               (label helper + HookSource rename)
│   ├── App/Clients/
│   │   ├── HierarchyClient.swift              (remove 2 setRepository* closures;
│   │   │                                       add kind(of:))
│   │   └── HookConfigClient.swift             (unchanged)
│   ├── App/Features/Editor/
│   │   └── EditorFeature.swift                (setProjectOverride writes via SettingsStore)
│   └── Runtime/HierarchyManager.swift         (remove worktreesDir/defaultEditor mutators;
│                                               add migrateAwayFromCatalogOverrides helper)
```

Dependency directions:

- `ProjectSettingsFeature` depends on `SettingsStore` (new primary
  writer), `HierarchyClient` (identity + kind + worktree reads),
  `HookConfigClient`, `FinderClient`. No dependency on
  `HierarchyManager`.
- Sidebar depends on `HierarchyClient.kind(of:)` to decide which sub-rows
  to render — resolved per `projectID` at view construction, re-queried
  on `.projectsChanged`.
- Settings window reducer's `.projectsChanged` pruning logic stays as-is
  (T4 already handles removal). The `ensureProjectPane` helper passes
  `kind` into the initial `State`.

Scaffold views (Git, GitHub, Scripts, Env) land as `Text("Coming in
M…")` bodies with their frozen `(projectID:, store:)` signatures, so
follow-up waves can fill bodies without touching the window shell.

## Alternatives Considered

### A1. Rename only; leave storage split intact

Fix G1, defer G2/G4/G5. T4's D1 stays in force; `Project.defaultEditor`
/ `Project.worktreesDirectory` remain on the catalog.

- Pros: smallest diff; zero migration risk; no catalog-json bump.
- Cons: every subsequent per-Project feature (scripts, env vars, git
  overrides) has to decide between catalog vs settings. The rename
  itself would have to name the settings-side slot something like
  `Settings.projects`, while the catalog fields live under
  `catalog.projects[...].defaultEditor` — two `.projects` paths meaning
  different things. Worse ergonomics than before the rename.
- Verdict: rejected. Rename without unification replaces one vocabulary
  problem with two.

### A2. Unify in the other direction — move everything to the catalog

The mirror of the chosen design: push GitHub overrides from
`Settings.repositories` into `Project` on the catalog.

- Pros: honors T4 D1's "catalog owns per-Project data" principle;
  `Settings` shrinks back to global state.
- Cons: (a) `settings.json` has the only secrets-relevant access
  pattern we care about (mode-0600 + atomic rename + debounced write),
  but catalog.json has the same invariants today, so this is a wash.
  (b) Settings panes would need to route every write through
  `HierarchyClient`, re-introducing the "spaceID required, but Settings
  doesn't carry one" friction T4 solved with `findProjectAnySpace`. (c)
  The notion of "this is your preferences file" gets muddier — users
  who hand-edit `settings.json` would be surprised to find editor
  overrides missing from it.
- Verdict: rejected. Settings is the user-preferences file; catalog is
  the structural layout file. Putting user preferences on the catalog
  is the direction that caused the T4 awkwardness in the first place.

### A3. Sum type for ProjectSettings instead of nested `git: GitProjectSettings?`

```swift
enum ProjectSettings: Codable {
  case git(common: CommonSettings, git: GitProjectSettings)
  case plainDir(common: CommonSettings)
}
```

- Pros: Swift-idiomatic; impossible to store Git overrides on a
  plain_dir project (compile-time guarantee).
- Cons: every `git_repo ↔ plain_dir` transition (user runs `git init`
  or deletes `.git`) becomes a data migration — we have to re-key the
  JSON from one enum arm to another, and the unchanged "common" fields
  have to be hand-copied. With nested `Optional`, the transition is
  a no-op. This is a real, user-triggered event (we already detect
  `.git` add/remove on catalog refresh); forcing a data migration there
  is more cost than the compile-time guarantee saves.
- Verdict: rejected.

### A4. Version-bump everything as one atomic migration vs per-file incremental

- Pros of atomic: all three files move together; rollback semantics
  are "downgrade all or none."
- Cons of atomic: any single file's migration failing corrupts the
  other two's upgrade path. Each file's decoder has independent
  correctness boundaries already.
- Verdict: kept per-file, each decoder accepts two versions, each file
  upgrades on next save. Rollback (by editing `version` back down) is
  the user's escape hatch per file.

### A5. Put project-scope logic inside `HookSubscription.Scope.worktreePathGlob`

Skip adding `.projectID` / `.projectPathGlob`. Keep T4's glob-matches-
root-or-worktree-path trick for project membership.

- Pros: no schema bump; no new cases to thread through exhaustive
  switches.
- Cons: plain_dir projects have no worktrees, so the T4 trick relies
  on a synthetic worktree whose path equals the project root. The
  classifier then conflates "worktree scope" and "project scope," and
  users who want "fire `tab.*` events for any pane in this project"
  have to express it via a glob that matches the project root — a
  mental model that degrades once per-worktree scopes start mattering
  (a user wanting "any worktree of this project except worktree X"
  has no clean way to say it). Adding `.projectID` makes the
  distinction explicit.
- Verdict: rejected. Scope taxonomy is cheap to extend when guarded by
  fail-soft decoding; the UX clarity is worth it.

### A6. Unified `ProjectSettingsFeature` vs split by sub-pane

Keep T4's single-reducer-for-all-panes shape vs. one reducer per
sub-pane (General / Git / GitHub / Hooks / Scripts / Env).

- Pros of split: each reducer is small and owns one pane's state; tests
  stay focused.
- Cons of split: six reducers for six panes doubles the boilerplate in
  `SettingsWindowFeature` (six IdentifiedArrays, six pruning branches);
  state that spans panes (e.g., `lastWriteFailure` shared across every
  General write) has to be hoisted somewhere.
- Verdict: kept unified for consistency with T4; revisit if any single
  sub-pane's state grows past ~200 LoC.

## Cross-Cutting Concerns

### Testing strategy

- **Migration correctness** (new):
  - `SettingsStoreMigrationTests.v2_repositoriesFold_preservesGitHubFields` —
    feed a v2 file with `repositories[pid].defaultMergeStrategy` set;
    assert v3 output has `projects[pid].git.defaultMergeStrategy` set,
    and `projects[pid]` top-level fields are empty.
  - `SettingsStoreMigrationTests.v2_catalogOverrides_absorbedAndCleared` —
    feed v2 settings + v1 catalog with `defaultEditor` set on a Project;
    assert v3 output has `projects[pid].defaultEditor`, and v2 catalog
    has the key absent.
  - `SettingsStoreMigrationTests.v3_isNoOp` — feed v3 file, assert no
    disk write scheduled, no state change.
  - `HookConfigStoreTests.v1_upgradesToV2_onSave` — feed v1 file, assert
    in-memory `config.version == 2`, save writes v2.
  - `HookSubscriptionCodableTests.unknownScopeKind_skipsSubscription` —
    JSON with `scope.kind = "futureKind"` decodes as empty
    subscriptions list with a log line.
- **ProjectSettingsFeatureTests** (rename + extension):
  - All existing T4 tests rename `repository*` → `project*`.
  - New: `setDefaultEditorOverride_writesToSettingsStore` (was
    HierarchyClient).
  - New: `classifyHook_projectID_matches_isProject`,
    `_projectPathGlob_matches_isProject`, `_projectID_nonMatch_isGlobal`.
  - New: `kind_plainDir_hidesGitActions` — send `.setDefaultMergeStrategy`
    on a plain_dir state; expect a no-op (or, simpler, don't wire the
    action at all in the plain_dir path — tested at the sidebar render
    level).
- **SettingsWindowFeatureTests**: `selecting_projectGit_onPlainDir_fallsBackToGeneral`
  — verifies the conditional sidebar can't steer selection to a pane the
  current kind doesn't expose (defense-in-depth vs. stale state where a
  project flipped from `gitRepo` to `plainDir` while Settings was open).
- **Golden-file migration tests**: check-in a v2 `settings.json` +
  v1 `catalog.json` fixture under `apps/mac/codans/Tests/Fixtures/`
  and assert round-trip through bringUp produces a byte-stable v3 output
  plus expected v2 catalog.

### Error handling

- Scope decoding fail-soft: a logged warning + dropped subscription, not
  a file-load failure. Matches the existing `Settings.swift` policy on
  unparseable ProjectID keys.
- `SettingsStore.updateProject` on an unknown pid: creates the slot.
  `ProjectSettingsFeature`'s guard is the `.projectsChanged` pruning —
  it removes stale pane state before a write can target a ghost pid.
- Migration partial failure: if `SettingsStore.load()` succeeds but the
  parallel catalog read fails, Settings v3 is produced with any already-
  folded-in catalog values (possibly zero). The catalog gets rebuilt
  on its own path. No data is lost; user sees the overrides they had
  at time of last successful catalog save.

### Security / privacy

- No new secret material. Same on-disk invariants (mode 0600, atomic
  rename, debounced write) apply to `settings.json` v3.
- `projectPathGlob` introduces user-authored regex/glob patterns that
  match filesystem paths — same threat surface as the existing
  `worktreePathGlob`. Malicious glob (catastrophic backtracking) could
  slow hook classification; mitigate by reusing the existing
  `NSRegularExpression`-backed path with a 5ms evaluation timeout guard
  (pre-existing, verified in `HookExecutor`).

### Observability

- `Logger(subsystem: "com.gumpw.codans.persistence", category: "settings")`
  gets two new log sites: migration v2→v3 (info), unparseable project
  key (warning, existing).
- `Logger(subsystem: "com.gumpw.codans.hooks", category: "config")` gets
  the unknown-scope-kind warning site.
- Settings window: no change.

### Rollback

- **Downgrade settings.json v3 → v2.** User edits `"version": 3` →
  `"version": 2`, renames `projects` → `repositories`, moves
  `git.defaultMergeStrategy` etc. back to the top. Custom fields
  (defaultEditor, worktreesDirectory) are dropped by the v2 decoder —
  data loss for those two fields, but the v2 app writes them back to
  catalog.json on first save. Asymmetric: downgrade preserves user
  intent for GitHub, loses it for editor/worktree-dir.
- **Downgrade catalog.json v2 → v1.** No payload change — v1 parses
  v2 output because removed fields are `decodeIfPresent` on v1's
  decoder. Trivial rollback.
- **Downgrade hooks.json v2 → v1.** User must also strip any
  subscription whose `scope.kind` is `projectID` / `projectPathGlob`.
  v1 decoder rejects them.
- **No feature flag.** The migration is the feature; guarding it
  behind a flag would mean carrying two code paths for the lifetime of
  the flag. Instead, gate risk with golden-file migration tests and
  ship both versions of the decoder in the same binary — the app can
  still open v2 settings / v1 catalog / v1 hooks files indefinitely.

### Documentation

- Update `docs/architecture.md` to note `settings.json` v3 and the
  moved-field list.
- Update `docs/product-specs/ui-settings-window.md` sidebar copy:
  sub-rows listed per kind (add per-kind acceptance criteria for
  M11/M12 and new M17–M20 slots for Git / GitHub / Scripts / Env panes
  — body copy filled by follow-up specs).
- Mark `docs/design-docs/settings-repositories.md` **Deprecated by
  project-settings.md** at the top.

## Risks

- **R1: Catalog / Settings load ordering coupling.** The v2→v3 fold
  requires `HierarchyManager.load()` to have completed before
  `SettingsStore.load()`. Today they're sequenced in `bringUp()`;
  reordering them would silently drop the catalog overrides.
  **Mitigation:** assert in `SettingsStore.bringUp()` that the
  provided `HierarchyManager` has `loadState != .loading` before
  folding; add a golden-file test that fails if the order is
  reversed.
- **R2: Mid-migration crash loses catalog overrides.** Between
  `SettingsStore` writing v3 and `HierarchyManager` writing v2 catalog,
  a crash leaves both files inconsistent: v3 settings have the folded
  values, but v1 catalog still has them too. Both apps would read the
  values twice.
  **Mitigation:** make the catalog write happen first, settings
  write second. If the catalog write wins and the settings write
  crashes, next boot re-runs the fold on the now-clean catalog (which
  has `nil` for the two fields), producing no duplicates. Tested via a
  `simulateCrashAfterCatalogWrite` golden-file test.
- **R3: Hook scope addition breaks CLI (`codans hook install`).** The CLI
  validates scope JSON against the shared Codable model. An older `codans`
  binary writing v1 scope to a v2-capable app is fine (additive).
  A newer `codans` binary writing v2 scope to an older app reads as
  "unknown kind" and gets dropped with a warning — data loss.
  **Mitigation:** `codans --version` → app-version handshake on `codans hook
  install`. If `codans` knows it's writing `projectID` / `projectPathGlob`
  and the running app predates v2, refuse with a clear error
  pointing to the app upgrade. Ship the `codans` version bump in the same
  PR as the app change.
- **R4: Plain_dir kind drift.** `ProjectKind` is derived from `gitRoot
  != nil`. If a running app's cached `Project` snapshot has a stale
  `gitRoot`, Settings shows the wrong sub-rows. The catalog refresh
  (file-system watch on `.git/HEAD`) already handles the common case
  (`git init` / `rm -rf .git`). Edge case: user clones a repo over
  an existing plain_dir that's tracked in the app.
  **Mitigation:** re-derive `kind` on `.projectsChanged` in
  `SettingsWindowFeature` and propagate to the pane state. Acceptable
  to show wrong rows for one catalog-refresh tick.
- **R5: Rename scope missed in user-facing strings.** Sidebar copy,
  error messages, log messages may still say "Repository" somewhere.
  **Mitigation:** grep gate in CI (`! grep -rnIE '(^|[^a-zA-Z])[Rr]epository' apps/mac/ --include='*.swift'`)
  with an explicit allowlist file for the small number of
  Repository-the-Git-concept references (e.g., commit messages,
  PR titles, external API wrappers). Add during Step 1 of the
  exec plan.

## Open Questions

None as of this Draft. Assumptions listed in the chat alongside this
doc (project-settings.md is a new file superseding the old one;
three-schema bump is coordinated; ProjectKind is derived; rename is
cascading; no local `.codans.json` variant) have been confirmed
verbally. Anything that surfaces during planning or implementation
goes here with the next Amendments section.
