# Project Tags + Single-Window — Removing Space and Multi-Window

**Status:** Approved
**Author:** Gump (with Claude)
**Date:** 2026-04-27
**Branch:** `refactor/rm-space`
**Supersedes:** [mw-t4-space-management.md](mw-t4-space-management.md) (Space CRUD surface — to be removed)

## 1. Context and Scope

Two coupled simplifications, landed together because they share one
catalog migration.

**Space → Tag.** The catalog today nests
`Catalog → Space → Project → Worktree → Tab → Pane`. A `Space` is a
**container**: each Project belongs to exactly one Space, and the user
switches between Spaces (⌘K, ⌘1–⌘9) with per-Space selection restoration
(`Space.lastActiveWorktreeID`, `Space.selectedProjectID`,
`CatalogWindow.selectedSpaceID`). We replace the container with
**labels**: a Project carries zero or more `Tag`s (name + color, like
macOS Finder tags); the sidebar shows a flat Project list optionally
filtered by an active Tag set.

**Multi-window → single-window.** The `Catalog.windows: [CatalogWindow]`
array exists in the model and round-trips through `catalog.json`, but in
production code today **nothing reads or writes it** (verified via grep:
the only callers are tests and the decoder default). The UI uses
`WindowGroup`, so users *can* spawn extra main windows from the system
menu, but no in-app surface relies on it, no "New Window" menu item is
exposed, and no window restoration consults `catalog.windows`. We're
formalizing the de-facto state: one main window, plus the existing
Settings satellite (`Window(id: "settings")`).

The two changes interlock: with multi-window gone, the per-window filter
question collapses — Tag filter state moves to the top-level `Catalog`,
removing what would otherwise be the trickiest piece of the new
hierarchy.

In-scope: domain model, persistence, sidebar UX, CLI, migration, removal
of `Space` and `CatalogWindow`. Out-of-scope: smart/saved filters,
tag-on-Worktree, restoring multi-window as a settable preference.

## 2. Goals and Non-Goals

**Goals**

- Replace 5-level hierarchy with 4 levels: `Catalog → Project → Worktree → Tab → Pane`.
- N:N labeling: a Project can carry multiple Tags simultaneously.
- Sidebar filter by Tag (multi-select OR), persisted in the catalog.
- Enforce single main window; Settings remains a separate `Window(id:)`.
- One-shot, lossless migration from existing Spaces to Tags and from
  multi-window catalogs to single-window.
- Remove every `Space` and `CatalogWindow` reference from domain, UI,
  CLI, IPC, and tests.
- Keep `catalog.json` rollback path open for one release (read v2, write v3).

**Non-Goals**

- Multi-window as a user-facing capability (model-level removal is final
  for now; if real demand surfaces later, re-introduction is a separate
  design).
- Tag inheritance / hierarchy (no nested tags).
- Tag-on-Worktree, tag-on-Tab (tags live on Projects only).
- Smart/saved filters or boolean tag expressions beyond OR.
- Open color palette (free-form hex). Fixed 7-color set.
- Restoring "per-Space last-active worktree" — `Project.selectedWorktreeID`
  already covers per-Project recall; the per-Space layer goes away.

## 3. Design Overview

Two trade-offs, both pulling toward simplification.

**Container vs. label.** Spaces gave one-shot context switching with
state memory; Tags give cross-cutting classification with stateless
filtering. We choose Tags because:

- Most users want to mark a Project with multiple traits (`#client-acme`,
  `#urgent`, `#archive-candidate`) — a 1:N container forces false choices.
- The selection-memory machinery on Space (`selectedProjectID`,
  `lastActiveWorktreeID`) duplicates state that already lives on `Project`
  (`selectedWorktreeID`) and `Worktree` (`selectedTabID`). Removing Space
  removes the duplication.
- Sidebar mental model becomes "all my projects, optionally filtered"
  instead of "current space's projects" — closer to Finder, Reminders,
  Notes. Lower onboarding cost.

**Multi-window vs. single-window.** Multi-window costs us a
per-window-state surface (`CatalogWindow`, `selectedSpaceID`,
implicitly per-window `activeTagFilter` if we'd kept it) and has *no*
production callers today. The user's mental model of codans is "the
project terminal," not "a workspace I open multiple of." We collapse to
single-window because:

- The cost (cross-window sync, divergent filters, "which window owns the
  Ghostty surface" edge cases) is paid for a feature nobody uses.
- Tag filter at top-level `Catalog` is one less layer of indirection
  than tag-filter-per-window.
- Settings remains a separate `Window(id:)`, so the satellite-window
  pattern still exists where it earns its keep.

What the user gives up: ⌘1–⌘9 / ⌘K Space jump muscle memory; per-Space
"resume where I was" recall; spawning a second main window via
File → New Window (which was never wired anyway). We accept all three;
see *Alternatives* §4 for the rejected hybrid models.

### 3.1 System Context Diagram

```
                      ┌───────────────────────────┐
   ⌘F / chip tap ───→ │ HierarchySidebarFeature   │
                      │  (filter chip bar +       │
                      │   flat project list)      │
                      └─────────────┬─────────────┘
                                    │ tagFilterChanged / tagAddedToProject
                                    ▼
                      ┌───────────────────────────┐
   codans tag ────────────│  HierarchyManager (+Tag)  │
   codans project tag     │  catalog mutations,       │
                      │  debounced save           │
                      └─────────────┬─────────────┘
                                    │
                                    ▼
                          catalog.json (v3)
                          { tags:[…],
                            projects:[…],
                            activeTagFilter:… }
                          // no windows array; one main Window(id:)
                          // + Settings Window(id:) at the App scene level
```

### 3.2 Data Model

```
// New
struct TagID: HierarchyID                      // UUID, like other IDs

struct Tag: Codable, Equatable, Sendable {
  var id: TagID
  var name: String                              // unique by display, not by ID
  var color: TagColor                           // enum: red/orange/yellow/green/blue/purple/grey
}

// Modified
struct Project {
  // … existing fields …
  var tagIDs: Set<TagID>                        // NEW; Codable as sorted array for stable diffs
}

enum TagFilter: Codable, Equatable {
  case all                                      // no filter (default)
  case tags(Set<TagID>)                         // OR semantics; empty set == .all
  case untagged                                 // virtual: projects with tagIDs.isEmpty
}

// Modified
struct Catalog {
  static let currentVersion = 3
  var version: Int
  var projects: [Project]                       // promoted from Space.projects
  var tags: [Tag]                               // NEW
  var activeTagFilter: TagFilter                // NEW; top-level (single-window)
  // REMOVED: spaces, selectedSpaceID, windows
}

// REMOVED: Space, SpaceID, CatalogWindow
```

`TagID` is opaque and immutable per Tag. `name` is the display string and
mutable; the sidebar de-duplicates by case-folded name when warning the
user, but the persistence layer never enforces uniqueness on name (matches
Finder, which also allows duplicate-name tags across users).

`tagIDs` is a `Set<TagID>` in-memory and a sorted `[TagID]` on disk —
order is irrelevant semantically, sorting keeps `git diff` on
`catalog.json` deterministic.

`TagFilter` is intentionally a sum type rather than `Set<TagID>?` so
"untagged" stays first-class without a magic sentinel.

### 3.3 Migration (v2 → v3)

One-shot, performed inside `Catalog.init(from:)` when `version == 2`:

```
// Spaces → Tags + Projects pulled to top level
var spaceIDToTagID: [SpaceID: TagID] = [:]
for (idx, space) in v2.spaces.enumerated() {
  let tag = Tag(name: space.name, color: palette[idx % 7])
  spaceIDToTagID[space.id] = tag.id
  v3.tags.append(tag)
  for var project in space.projects {
    project.tagIDs.insert(tag.id)
    v3.projects.append(project)
  }
}

// Windows → top-level filter
//   Use the Catalog's selectedSpaceID as the seed filter; if absent, fall
//   back to the first window's selectedSpaceID; otherwise no filter.
//   Multi-window catalogs effectively merge — only one filter survives.
let seedSpaceID = v2.selectedSpaceID
  ?? v2.windows.compactMap { $0.selectedSpaceID }.first
v3.activeTagFilter = seedSpaceID
  .flatMap { spaceIDToTagID[$0] }
  .map { .tags([$0]) } ?? .all

// Dropped: Space.lastActiveWorktreeID, Space.selectedProjectID,
//          CatalogWindow (the entire array)
```

Trade-off — **destructive vs. preserved**: two intentional drops.

1. `Space.lastActiveWorktreeID` is not re-hosted on Tag. A Tag has no
   "current state" semantics; recreating it would re-introduce the very
   container behavior we're removing. Per-Project `selectedWorktreeID`
   already restores the most recently used Worktree on Project focus.
2. Multi-window catalogs collapse to a single filter. In practice the
   `windows` array is never populated by production code (verified via
   grep), so real-world data has 0 windows — the merge is a no-op. The
   migration handles the populated case for safety, picking the first
   non-nil `selectedSpaceID` deterministically.

v1 catalogs go through their existing v1→v2 path first (current code),
then v2→v3. We do **not** add a direct v1→v3 path — chaining keeps the
migrations independently testable.

**Rollback**: writes are v3-only, but the v2 decoder remains for one
release. Downgrading from a v3 build to a v2 build will fail-loud
(`unsupportedVersion(3)`); we accept this — the user's escape hatch is
restoring `~/.config/codans/catalog.json` from Time Machine.

### 3.4 Sidebar UX

```
┌─────────────────────────────────────────────┐
│  ▼ acme-web   ●●                            │
│      main                                    │
│      feat/login                              │
│  ▼ marketing-site  ●                         │
│      main                                    │
│  ▶ infra-tools                               │
│                                              │
├─────────────────────────────────────────────┤
│ [All] [● client-acme] [● urgent] [Untagged] │ ← chip footer
└─────────────────────────────────────────────┘
```

- **Chip footer** lives at the bottom of the sidebar, taking over the
  exact slot the current `spaceFooter` occupies (mounted via
  `.safeAreaInset(edge: .bottom)` in `HierarchySidebarView`). Renders
  one chip per Tag plus implicit `[All]` and `[Untagged]`. Clicking a
  chip toggles its membership in `Catalog.activeTagFilter`. `[All]`
  clears the filter; `[Untagged]` is exclusive (selecting it deselects
  all Tag chips). Footer scrolls horizontally when chips overflow the
  sidebar width.
- **Why bottom, not top**: matches macOS sidebar convention (System
  Settings, Mail mailbox filter row); preserves discoverability for
  users who already look at the bottom of the sidebar for
  scope/context controls; keeps the top edge clean so the first
  Project row sits flush against the title bar's unified material.
- **Project rows** show colored dots after the name — one per assigned
  Tag, capped at 3 with "+N" overflow.
- **No Space row, no popover, no manage-spaces sheet.** The whole
  `SpaceManager` feature directory is deleted; `spaceFooter` is
  replaced in place by the new chip footer view.
- **Project context menu** gains "Tags…" → submenu with checkbox per Tag
  + "New Tag…" + "Edit Tags…" (opens TagManager sheet).
- **TagManager sheet** (new, replaces SpaceManager sheet): create /
  rename / recolor / delete. Deleting a Tag removes it from every
  Project's `tagIDs`; this is a non-destructive cascade (no Project
  data lost). Confirmation dialog shows "N projects will lose this tag".

### 3.5 Component Boundaries

| Component | Owns | Does Not Own |
|---|---|---|
| `CodansCore.Tag` / `TagID` / `TagFilter` | Pure value types, Codable | Persistence, UI |
| `CodansCore.Catalog` (v3) | Schema, migration | Mutation policy |
| `HierarchyManager` | Tag CRUD, `setProjectTags`, `setActiveTagFilter` | Sidebar state |
| `HierarchyClient` | Closure surface for the manager | TCA reducer logic |
| `HierarchySidebarFeature` | Chip bar state, filter dispatch, project rows | Tag CRUD UI |
| `TagManagerFeature` (new) | CRUD sheet, rename/recolor/delete | Filter state |
| `codans` CLI | `codans tag`, `codans project tag` | Domain validation (delegated to manager via IPC) |

`HierarchyClient` gains: `createTag`, `renameTag`, `recolorTag`,
`removeTag`, `setProjectTags(projectID, Set<TagID>)`,
`setActiveTagFilter(TagFilter)`. All `*Space` closures and the
`*Window` closures (currently absent in production but stubbed in
tests) are removed.

### 3.6 IPC / Socket Handlers

`apps/mac/codans/App/Features/Socket/handlers/HierarchyHandlers.swift`
loses its `space.*` RPCs and gains `tag.*` and `project.tag.*`. Schema
versioning on the wire is implicit (codans app and `codans` CLI ship as a
unit), so no protocol negotiation needed.

### 3.7 CLI Surface

```
codans tag list
codans tag create <name> [--color red|orange|yellow|green|blue|purple|grey]
codans tag rename <id|name> <new-name>
codans tag recolor <id|name> <color>
codans tag remove  <id|name>

codans project tag add    <project-id|name> <tag-id|name>...
codans project tag remove <project-id|name> <tag-id|name>...
codans project list [--tag <id|name>] [--untagged]
```

Resolution by `name` is best-effort (first match, case-fold);
ambiguous names emit a warning and require `--id`. Symmetric with
existing `codans project` resolution behavior.

### 3.8 Single-Window Enforcement

Three concrete changes in `CodansApp.swift`:

```swift
// Was: WindowGroup { … }
// Now:
Window("codans", id: CodansApp.mainWindowID) { … }
```

- `WindowGroup` allows the user to spawn multiple instances via the
  system menu (File → New Window if exposed, or via dock right-click).
  `Window(id:)` is single-instance: re-activating brings the existing
  one to front instead of creating a new one. Settings is already a
  `Window(id:)`; this change makes the main scene symmetric.

- `.commands { CommandGroup(replacing: .newItem) {} }` removes the
  default ⌘N "New Window" menu item that `WindowGroup` synthesizes.
  Without this, the menu still shows (and ⌘N still fires) but the
  binding becomes a no-op, which is worse UX than removing it entirely.

- Dock icon click and `open -a codans` from Terminal both route
  through `NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)`;
  the default behavior with `Window(id:)` is to re-show the existing
  window, which is what we want. No code addition needed.

**Close vs. quit semantics** (settles OQ-4):

- **⌘W** closes (hides) the main window. The app stays running with its
  IPC stack, Ghostty surfaces, and notification observer alive.
  Re-clicking the dock icon re-shows the window. This is the standard
  "long-lived background app" pattern — codans hosts terminal
  sessions, and a stray ⌘W must not kill them.
- **⌘Q** quits, gated by a confirmation dialog. `AppDelegate` overrides
  `applicationShouldTerminate(_:)`: present an `NSAlert`
  ("Quit codans? Running terminal sessions will end.") with
  *Quit* / *Cancel*; return `.terminateNow` on confirm,
  `.terminateCancel` on cancel. The alert is suppressed when no
  Worktree has open Panes (clean exit, no work to lose) — matches the
  spirit of the prompt without nagging on empty state.
- `applicationShouldTerminateAfterLastWindowClosed` returns `false`
  so closing the main window doesn't trigger a quit attempt at all.

Settings is unaffected (`Window(id: "settings")`), and remains
spawnable from ⌘, / the App menu. Closing the Settings window does not
prompt; quitting from within Settings still routes through the
`applicationShouldTerminate` confirmation.

Trade-off — **enforce vs. permit**: we could keep `WindowGroup` and
simply not write any state per window. Rejected — `WindowGroup` exposes
the multi-window capability in the system menu and via AppleScript; if
we don't intend to support it, leaving the surface available creates
support load ("I had two windows open and they got out of sync"). One
explicit `Window(id:)` declaration is clearer than implicit non-support.

### 3.9 Keyboard Shortcuts

- **Removed**: ⌘K (space switcher), ⌘1–⌘9 (jump to space), ⌘N (new window).
- **Added**: ⌘F focuses the chip footer (Tag filter); typing filters
  chips in-place, Return commits selection. `Esc` clears filter to
  `.all`.
- ⌘1–⌘9 deliberately left **unbound** — no automatic re-purpose. Frees
  the slot for a future "switch to Nth project" if requested.

## 4. Alternatives Considered

### 4.1 Hybrid: keep Spaces, add Tags as a secondary axis

Trade-off: zero data loss, gentle migration, multi-tag support layered
on top. Rejected — keeps the 5-level hierarchy and all its complexity
(`worktreeID(forPane:)` four-loop, per-Space selection memory) and adds
a new orthogonal axis users have to understand. Net cognitive load goes
up, not down. The user's stated intent ("移除 space") is incompatible.

### 4.2 Replace Space with Folder (still 1:N container, just renamed)

Trade-off: minimal code churn, retains selection memory. Rejected — does
not address the core limitation (a Project belongs to exactly one Folder)
and keeps the 5-level hierarchy intact. Pure renaming with no semantic
gain.

### 4.3 Tags with free-form hex color

Trade-off: maximum flexibility. Rejected — color picker UI is heavier
than the feature warrants; macOS users already recognize the 7-color
Finder palette; constrained palette gives consistent contrast against
the sidebar background without a per-color contrast check. If demand for
custom colors emerges later, `TagColor` can grow a `.custom(hex: String)`
case without breaking v3.

### 4.4 Tag stored as `[String]` on Project (no Tag entity)

Trade-off: simplest possible model. Rejected — rename becomes O(N
projects), color is impossible without a side-table, and the CLI can't
distinguish ID from name when both are strings. The Tag entity costs
one struct and pays back immediately.

### 4.5 Keep multi-window, scope filter per-window

Trade-off: preserves the latent multi-window capability for users who
might want it later; lets two windows show different filtered views
side-by-side. Rejected — the multi-window surface has zero production
callers today and adds a `CatalogWindow` array, per-window filter
serialization, and "which window owns the Ghostty surface" edge cases
for a hypothetical use case. Reintroducing multi-window later, if
demand emerges, is a clean future change (add `windows: [CatalogWindow]`
back to v4 with `activeTagFilter` per window). Keeping the optionality
costs more than removing it.

### 4.6 Repurpose ⌘1–⌘9 to "filter by Tag N"

Trade-off: preserves muscle memory. Rejected for now — Tag-as-filter is
multi-select; binding 1–9 to single-select toggles fights the model.
Leaving the slots free is the lowest-regret choice; revisit if users
ask.

## 5. Cross-Cutting Concerns

### 5.1 Migration safety

- Migration is performed in `Catalog.init(from:)`, the only entry point
  for catalog deserialization. No second copy of the logic.
- A `CatalogCodableTests` golden test loads a hand-written v2 fixture
  and asserts the resulting v3 has the expected `tags` / `projects` /
  `windows[*].activeTagFilter`. Guards against drift.
- The v2 fixture is committed to `Tests/Fixtures/catalog-v2.json` so
  future schema changes can run it through the chain.
- One-time `os_log` line per migration (`"migrated catalog v2 → v3 with N spaces → N tags"`) for support.

### 5.2 Backward compatibility (CLI, IPC)

- `codans space *` subcommands print a friendly deprecation error pointing
  at `codans tag` for one release, then disappear. The error message
  includes the equivalent `codans tag` invocation when one exists.
- IPC `space.*` RPCs are removed outright — there is no out-of-process
  consumer other than `codans` (shipped in lockstep).
- Multi-window CLI: there is no `codans window` command today, so nothing
  to deprecate. If `codans focus` ever grew a `--window <id>` flag, it
  would be removed; current `codans focus` operates on whatever window
  hosts the resolved Pane, which still works under single-window.

### 5.3 Testing

- Unit: `TagTests`, `CatalogV3MigrationTests`, `HierarchyManagerTagTests`.
- Reducer: `HierarchySidebarFeatureTests` for chip bar + filter,
  `TagManagerFeatureTests` for CRUD.
- Integration: round-trip catalog v2 → v3 → v3 with Tag CRUD ops.
- Manual: every product-spec AC mapped 1:1 in the exec plan.

### 5.4 Observability

- The migration emits a single `os_log` line; success path is silent
  thereafter.
- Tag CRUD ops do not log (parity with Project CRUD today).

### 5.5 Performance

- `Project.tagIDs: Set<TagID>` is O(1) lookup for filter pass.
- Sidebar filter is a single linear scan over `catalog.projects` per
  filter change; with realistic project counts (<200) this is sub-ms.
- No new indexes, no new caches.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Users with deep Space muscle memory bounce off the new model | Migration preserves Space names verbatim as Tag names; first-launch toast: "Your spaces are now tags. Click a chip to filter." Single dismissible message, no settings flag. |
| Power users miss ⌘1–⌘9 jump | Documented in CHANGELOG; if real demand surfaces, future PR can bind 1–9 to "toggle filter to Nth tag (single-select)". Leaving the slots unbound for now is reversible. |
| Migration corrupts a catalog | Catalog write is atomic (existing `CatalogStore` writes to temp + rename); migration runs in-memory before the first save. Worst case the user sees an unmigrated v2 catalog after a failed launch — they can roll back to the previous build. We commit the migration logic with the v2 fixture test before any UI work. |
| Tag rename loses CLI references | `TagID` is the canonical handle; `codans` accepts `name` only as a convenience and warns on ambiguity. Scripts written against IDs are stable across renames. |
| Removing Space breaks downstream code we missed | The 135-file Space scope is enumerated in the exec plan; CI grep gate (`! grep -r 'SpaceID\\|\\bSpace\\b' apps/mac --include='*.swift'`) blocks merge until clean. Gate dropped after the refactor lands. |
| User has multiple main windows open at upgrade time | The new build won't read `catalog.windows`; on first launch only one window is created (`Window(id:)`). Any visual "second window" the user had open simply doesn't reappear after restart. No data loss — Tab/Pane state is owned by Worktree, not by Window. |
| AppleScript or external tooling depends on multi-window | None known. If discovered post-ship, the path is to expose a single window-id stable handle rather than re-introduce the `WindowGroup`. |

## 7. Resolved Questions

- **OQ-1** (Tag onboarding): toast on first launch after migration, single
  line, dismissible. Wording: *"Your spaces are now tags. Click a chip in
  the sidebar to filter projects."* Shown once; suppression flag stored
  in `settings.json` (`onboarding.tagsToastShown: true`).
- **OQ-2** (Untagged chip visibility): rendered only when at least one
  Project has `tagIDs.isEmpty`. Reduces chip-bar clutter for users who
  consistently tag everything.
- **OQ-3** (last-tag removal warning): no warning. Tags are optional;
  Untagged is a valid state.
- **OQ-4** (close vs. quit): ⌘W hides the main window (app stays alive);
  ⌘Q is gated by a confirmation `NSAlert` (suppressed when no Worktree
  has open Panes). `applicationShouldTerminateAfterLastWindowClosed`
  returns `false`. See §3.8 for the implementation sketch.

No open questions block implementation.
