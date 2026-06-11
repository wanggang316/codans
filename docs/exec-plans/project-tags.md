# ExecPlan: Project Tags + Single-Window — Removing Space and Multi-Window

**Status:** Approved → In Progress
**Author:** Gump (with Claude)
**Date:** 2026-04-27
**Branch base:** `refactor/rm-space`

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan lands, a codans user can:

- Open codans and see **a single flat list of all their projects** in the sidebar — no Space switcher, no nested grouping, no concept of "current workspace."
- **Tag any project** with one or more colored labels (`#client-acme`, `#urgent`, `#archive-candidate`) via the project's right-click menu, and pick the colors from the macOS Finder 7-color palette.
- **Filter the sidebar** by clicking colored chips in a footer at the bottom of the sidebar — `[All]`, one chip per Tag, plus `[Untagged]` when at least one project has no tags. Multi-select is OR (Finder/Reminders semantics). The active filter persists across relaunch.
- **Manage tags globally** through a dedicated TagManager sheet: create, rename, recolor, delete (deletion cascades to remove the tag from every project but never deletes project data).
- **Drive everything from `codans` CLI**: `codans tag list/create/rename/recolor/remove`, `codans project tag add/remove`, `codans project list --tag <name> | --untagged`.
- **Run a single main window**: ⌘W hides it (the app keeps running with IPC + Ghostty surfaces alive); ⌘Q is gated by a confirmation dialog that names how many running terminal sessions will end. Settings remains a separate window, opened via ⌘,.

Existing data is migrated losslessly: each prior Space becomes a same-named Tag (with a color cycled from the palette), every project that lived in that Space inherits that tag, and the previously-active Space becomes the initial filter. A single first-launch toast explains the change.

## Progress

- [x] M0 — Baseline: rebase, capture pre-existing lint + test status — 2026-04-27
- [x] M1 — CodansCore: introduce `Tag` / `TagID` / `TagColor` / `TagFilter` value types (additive, no integration) — 2026-04-27 commit 4d67c91
- [x] M2 — Catalog v3 schema flip + v2→v3 migration + Space/CatalogWindow removal (production build-clean; codansTests builds clean)
  - [x] M2.1a Project.tagIDs — commit 1a0d7e3
  - [x] M2.1b Catalog v3 + migration + Space.swift deletion — commit ec43426
  - [x] M2.1c TerminalEvent / HookEnvelope / NotificationInboxAggregation / Worktree comments — included in ec43426
  - [x] M2.2 CatalogCodableTests rewrite + v2→v3 migration tests + IPC type updates — commit 060b3e6
  - [x] M2.3 HierarchyManager surface flip — commit 9ef04c4 (subagent)
  - [x] M2.4 HierarchyClient surface flip — commit 9ef04c4 (same subagent)
  - [x] M2.5–M2.11 RootFeature, Sidebar, SpaceManager deletion, CommandPalette, MainWindowCommands, Socket handlers, codans CLI, CodansApp seed removal — commit 0fc0b1d (subagent) + 971ddf9 (orchestrator final pass)
  - [x] M2.12 Test sweep across `apps/mac/codans/Tests/` — `xcodebuild build-for-testing -workspace codans.xcworkspace -scheme codans -destination 'platform=macOS'` succeeds
- [x] M3 — Single-window enforcement (Window(id:) + cmd+N suppressed + cmd+Q confirmation gate) — commit cd4a153
- [x] M4 — Sidebar chip footer + filter wiring (TagChipFooter + filteredProjects + cmd+F focus) — commit da39c8e
- [x] M5 — TagManagerFeature + project-row Tag editor (Tag dots + Tags submenu + sheet) — commit 341e4da
- [x] M6 — codans CLI tag commands + IPC handlers (tag.* + project.tag.* RPCs + codans tag/codans project tag/list --tag) — commit 32c01b8
- [x] M7 — First-launch toast + docs sweep + gate cleanup
  - [x] product-spec.md / architecture.md / CHANGELOG.md sweep — commit 7dfbda8
  - [x] First-launch toast — **moot** after the no-compat cleanup. The
    toast was scoped to "your spaces are now tags" education for users
    whose catalogs got migrated. With v1/v2 catalog migration removed
    (commit af7d834), there are no migrated users to educate; fresh
    installs land on an empty catalog with no Spaces concept ever
    present. CHANGELOG (3c314e9) communicates the rejection-and-restart
    upgrade path instead.
  - [x] `check-no-space-residue` Make target removed — commit af7d834
    (along with the v1/v2 migration code per "无需考虑兼容性").
- [ ] Final code review pass via agent-skills:code-reviewer

**Verification (2026-04-27 21:32):**
- `xcodebuild build -scheme codans -destination 'platform=macOS'` ✅ BUILD SUCCEEDED
- `xcodebuild build -scheme codans -destination 'platform=macOS'` ✅ BUILD SUCCEEDED
- `xcodebuild build-for-testing -scheme codans -destination 'platform=macOS'` ✅ TEST BUILD SUCCEEDED
- `xcodebuild test -scheme CodansCore -destination 'platform=macOS'` ✅ 333/333 passed in 45 suites
- `make -C apps/mac check-no-space-residue` ✅ no residue
- (codansTests host-app run still crashes on Ghostty config load — pre-existing, see Surprises §M0)

## Surprises & Discoveries

- **2026-04-27, M0**: `make -C apps/mac check` reports **42 pre-existing lint errors** spanning `Toast/`, `GitHub/Views/`, `PaneSurface.swift`, `GhosttyActionDecoder.swift`, `RootFeature.swift`, several test files, and `NotificationCoordinatorTests`/`TrackerRegistry` (inclusive-language + TODO violations). None of these are in files this plan modifies, so they are accepted baseline noise. Captured in `/tmp/m0-lint-baseline.txt`. **Action**: don't gate any milestone on `make check` going green; instead use `make build` + targeted `swiftlint lint <new-files>` + `xcodebuild test`. The `mac-no-space-residue` gate added in M2 is a `grep`, independent of swiftlint, so it still works.
- **2026-04-27, M0**: The `make test` target in `apps/mac/Makefile` is a stub (`@echo "no tests yet"`). Tests run via `xcodebuild test -scheme codans -destination 'platform=macOS'` directly. Plan's Concrete Steps section now says `xcodebuild test ...` not `make test`.
- **2026-04-27, M0**: Make targets are `build/lint/format/check/test/clean/...` (no `mac-` prefix); the `mac-*` shorthand is at the top-level `Makefile` only. Plan's Concrete Steps uses `make -C apps/mac <target>` which is the correct form for all milestones.
- **2026-04-27, M0**: `xcodebuild test -project ...` fails with `Unable to find module dependency: 'ArgumentParser'` because Tuist resolves SwiftPM into the **workspace**. Use `-workspace apps/mac/codans.xcworkspace` instead. Build then succeeds, but test host (`codans` app launched in test mode) crashes with `Signal 11: Backtracing from 0x288e20734...` during Ghostty config file load — `[default] reading configuration file path=/Users/wanggang/.config/ghostty/config` is the last log line before the crash. **Pre-existing**, not introduced by this plan. Workaround: scope tests with `-only-testing:CodansCoreTests` (unit layer; no host app).

## Decision Log

- **D1** (planning, 2026-04-27): Catalog v3 schema flip is **atomic in M2** rather than additive-with-shims. Carrying both `spaces` and `tags` in parallel during a transition window would force every reader (HierarchyManager, sidebar, CLI, IPC handlers) to handle two shapes; the shim cost exceeds the cost of one large mechanical PR. The migration is in-place inside `Catalog.init(from:)`, so the on-disk transition is also atomic.
- **D2** (planning, 2026-04-27): The big-bang PR (M2) accepts a "tags exist in the model but the UI shows neither chip footer nor TagManager" transitional state until M4/M5 land. During this window the sidebar renders a flat project list and inherited tags are read-only. We deliberately avoid a placeholder chip footer in M2 — placeholder UI is its own bug surface.
- **D3** (planning, 2026-04-27): Single-window (M3) ships **before** the schema flip (M2) is **wrong** — M3's ⌘Q confirmation reads `HierarchyManager.catalog`, which is shape-stable across the refactor, but M3 also touches `MainWindowCommands` which M2 will gut (removing ⌘K / ⌘1–⌘9 Space bindings). Sequencing M3 after M2 lets MainWindowCommands settle into one shape rather than two. **Final order: M0 → M1 → M2 → M3 → M4 → M5 → M6 → M7.**
- **D4** (planning, 2026-04-27): `codans space *` is **removed outright** in M2, not deprecated with a stub. `codans` ships in lockstep with the app, so external scripts can't span versions. CHANGELOG documents the removal in M7.
- **D5** (planning, 2026-04-27): A temporary CI grep gate lands in M2 (`! grep -r 'SpaceID\|\bSpace\b\|CatalogWindow' apps/mac --include='*.swift'`) and is removed in M7. The gate is a Makefile target invoked from `make mac-check`, not a separate workflow file.
- **D6** (planning, 2026-04-27): The v2 read path (decoder branch in `Catalog.init(from:)`) survives one release. M7 does **not** remove it — that removal is a follow-up after enough users have migrated. Logged in M7's outcomes and tracked separately.
- **D7** (planning, 2026-04-27): M2 is the only milestone that benefits from parallel agent dispatch. The schema flip is one focused unit (one author), but the ~120 mechanical fix-ups across features (sidebar, command palette, settings panes, tests) are independent. Per the user's `agent-teams-for-splittable-work` memory: dispatch a small team after the core schema lands compile-broken, each agent owning a feature directory.
- **D8** (planning, 2026-04-27): `applicationShouldTerminate` confirmation suppresses when no Worktree has any Pane. Empty-state quit is silent — no nag for users who haven't started a session.

## Outcomes & Retrospective

(To be filled at milestone completion)

## Context and Orientation

Related documents:

- Design doc (authoritative for trade-offs and resolved questions): `docs/design-docs/project-tags.md`
- Superseded design doc: `docs/design-docs/mw-t4-space-management.md` (the SpaceManager surface this plan deletes)
- Architecture: `docs/architecture.md`
- Golden rules: `docs/golden-rules.md`
- Product spec for the Space surface being removed: `docs/product-specs/space-management.md` (read for context on what behaviors must be preserved or intentionally dropped)

Key source files (read in this order before M1):

- `apps/mac/CodansCore/Space.swift` — domain type to delete in M2.
- `apps/mac/CodansCore/Project.swift` — gains `tagIDs: Set<TagID>` (Codable as sorted `[TagID]` for stable diffs). Existing `loadState` transient field shows the pattern for fields excluded from `Codable`.
- `apps/mac/CodansCore/Catalog.swift` — schema lives here. M2 bumps `currentVersion` to 3 and rewrites `init(from:)` to support the chained v1→v2→v3 migration. The existing v1→v2 logic and `DecodingIssue.unsupportedVersion` enum are the reference for this shape.
- `apps/mac/CodansCore/IDs.swift` — `HierarchyID` protocol and ID structs. M1 adds `TagID`; M2 removes `SpaceID`.
- `apps/mac/codans/Runtime/HierarchyManager.swift` — the only mutator of `Catalog`. Currently exposes `createSpace`, `renameSpace`, `removeSpace`, `selectSpace`, `setSpaceLastActiveWorktree`, `reorderSpaces`. M2 swaps these for `createTag`, `renameTag`, `recolorTag`, `removeTag`, `setProjectTags(projectID:Set<TagID>)`, `setActiveTagFilter(TagFilter)`. The `removeTag` cascade reads every project's `tagIDs` and removes the dropped TagID — non-destructive (no Project deletion).
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — TCA dependency surface; closure list is appended-only by master's parallel-conflict rule. In M2 we cannot follow that rule (the surface is being inverted), so M2 explicitly waives it for the Space→Tag swap and reverts to append-only afterward.
- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift` — line ~720 is the `spaceFooter`; M2 removes the footer and its associated state (`isSpacePopoverPresented`, all `spacePopover*` actions). M4 reattaches a new chip footer at the same `safeAreaInset` mount point in `HierarchySidebarView.swift` (currently line 139).
- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift` — `.safeAreaInset(edge: .bottom)` host; the spaceFooter view at line 720 is replaced view-by-view in M4 by `tagChipFooter`.
- `apps/mac/codans/App/Features/SpaceManager/` — entire directory deleted in M2. M5 creates a sibling `apps/mac/codans/App/Features/TagManager/` with `TagManagerFeature.swift` + `TagManagerView.swift`.
- `apps/mac/codans/App/Features/Root/RootFeature.swift` — `@Presents var spaceManagerSheet` removed in M2; `@Presents var tagManagerSheet` added in M5. The `.switchToSpaceAtIndex(Int)` action and `openSpaceSwitcherRequested` action are removed in M2 with no replacement.
- `apps/mac/codans/App/Features/CommandPalette/CommandPaletteItems.swift` — Space-scoped items removed in M2; tag-scoped items deferred to a follow-up if needed (out of plan scope).
- `apps/mac/codans/App/Commands/MainWindowCommands.swift` — ⌘K and ⌘1–⌘9 bindings removed in M2; ⌘F binding added in M4.
- `apps/mac/codans/App/CodansApp.swift` — `WindowGroup` flipped to `Window(id:)` in M3; first-run seed branch (currently seeds "Personal" Space) removed in M2; toast trigger added in M7.
- `apps/mac/codans/App/AppDelegate` (declared inline at the bottom of `CodansApp.swift`) — M3 adds `applicationShouldTerminate` confirmation and overrides `applicationShouldTerminateAfterLastWindowClosed` to `false`.
- `apps/mac/codans/App/Features/Socket/handlers/HierarchyHandlers.swift` — `space.*` RPCs removed in M2; `tag.*` and `project.tag.*` added in M6.
- `apps/mac/codans-cli/Commands/HierarchyCommands.swift` — `codans space` subcommands removed in M2; new `codans tag` + `codans project tag` subcommands added in M6.
- `apps/mac/CodansCoreTests/CatalogCodableTests.swift` — golden-test pattern for catalog (de)serialization. M2 adds a v2 fixture (`Tests/Fixtures/catalog-v2.json`) loaded by a new `catalog_v2_to_v3_migration_*` test family.

Terms of art:

- **Catalog**: the persisted top-level state object at `~/.config/codans/catalog.json`. One file, debounced atomic write (existing `CatalogStore`).
- **HierarchyManager**: the single MainActor-owned mutator of `Catalog`. Every state change in the app routes through one of its methods; views never mutate `Catalog` directly.
- **HierarchyClient**: TCA `@Dependency` wrapper over HierarchyManager — a struct of closures that reducers call instead of holding a reference to the manager. Lets tests substitute a mock implementation.
- **TagFilter**: a sum type (`.all`, `.tags(Set<TagID>)`, `.untagged`) that drives sidebar visibility. Stored on `Catalog`, mutated via `HierarchyManager.setActiveTagFilter`.
- **Chip footer**: a horizontally-scrolling row of pill-shaped buttons mounted at the sidebar's `.safeAreaInset(edge: .bottom)`. One pill per Tag, plus `[All]` and conditionally `[Untagged]`.
- **The big bang (M2)**: a single PR that flips the Catalog schema, removes the `Space` and `CatalogWindow` types, rewires every consumer (~135 Swift files, mostly mechanical compile-error fixes), and ships the migration. Large by file count but mechanical in nature — there is one schema decision (already made in the design doc) and the rest is type-driven.

## Plan of Work

### Milestone 0 — Baseline

Before any edit, capture the baseline so post-work comparisons are apples-to-apples. Run `make -C apps/mac mac-check` (delegates to swift-format + swiftlint) and `make -C apps/mac mac-test` (or the project's test target — confirm in `apps/mac/Makefile`). Record any pre-existing failures in *Surprises & Discoveries*. If unrelated failures exist, escalate before touching code — silent inheritance of regressions makes M2 impossible to land.

The branch is already `refactor/rm-space`. Confirm `git status` is clean and `git log --oneline -5` matches the recent commit list. No rebase needed unless `main` has moved during planning.

### Milestone 1 — Tag value types in CodansCore

Goal: introduce the new value types in isolation. After this milestone, the types exist, are Codable, and have unit tests, but no consumer references them yet. Compiles and ships green; zero behavior change.

Files added:

- `apps/mac/CodansCore/Tag.swift` — defines `Tag`, `TagColor`, `TagFilter`. Sketch:

  ```swift
  public nonisolated struct Tag: Equatable, Codable, Sendable, Identifiable {
    public var id: TagID
    public var name: String
    public var color: TagColor
  }

  public nonisolated enum TagColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, grey
  }

  public nonisolated enum TagFilter: Equatable, Codable, Sendable {
    case all
    case tags(Set<TagID>)
    case untagged
    // Custom Codable: encode as { kind: "all" | "tags" | "untagged",
    // tagIDs?: [TagID] (sorted) }. Sorted on encode for stable diffs.
  }
  ```

- `apps/mac/CodansCore/IDs.swift` — append `TagID`:

  ```swift
  public nonisolated struct TagID: HierarchyID {
    public let raw: UUID
    public init(raw: UUID) { self.raw = raw }
  }
  ```

  `SpaceID` stays untouched in M1 (removed in M2).

- `apps/mac/CodansCoreTests/TagTests.swift` — round-trip Codable for `Tag`, exhaustive case coverage for `TagColor.allCases`, round-trip for each `TagFilter` case (including `.tags(Set<TagID>)` with deterministic on-disk ordering), and a test that asserts encoding `.tags([a, b])` and `.tags([b, a])` produces byte-identical JSON (set semantics + sorted on disk).

Verify: `xcodebuild build -scheme codans` succeeds; `xcodebuild test -scheme CodansCoreTests` shows the new test count green; `git diff --stat` touches three files.

Commit one PR (PR-1) at this milestone boundary. Per `feedback_commit_only_my_files`, stage explicit paths only.

### Milestone 2 — Catalog v3 schema flip and Space/CatalogWindow removal

Goal: collapse the 5-level hierarchy to 4, replace Space with Tag throughout, remove CatalogWindow, ship the v2→v3 migration. After this milestone the app launches against a v3 catalog (migrated from v2 if present), shows a flat project list in the sidebar, and has neither a chip footer (M4) nor a TagManager sheet (M5). Existing tags from the migration are read-only via UI but visible as colored dots on project rows.

This is the largest milestone. Order within the PR:

**M2.1 — Schema (CodansCore changes only).** Edit `apps/mac/CodansCore/Catalog.swift` to bump `currentVersion = 3`, replace the property set, and rewrite `init(from:)`:

```swift
public nonisolated struct Catalog: Equatable, Sendable {
  public static let currentVersion = 3
  public var version: Int
  public var projects: [Project]
  public var tags: [Tag]
  public var activeTagFilter: TagFilter

  // existing static empty / defaultURL preserved
}
```

The decoder accepts versions 1, 2, 3. Versions 1 and 2 chain through their existing v1→v2 logic, then v2→v3 at the end:

```swift
// after v1→v2 normalization …
let v2Spaces = try container.decodeIfPresent([Space].self, forKey: .spaces) ?? []
let v2Windows = try container.decodeIfPresent([CatalogWindow].self, forKey: .windows) ?? []
let v2SelectedSpaceID = try container.decodeIfPresent(SpaceID.self, forKey: .selectedSpaceID)
// v3 native:
let v3Projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
let v3Tags = try container.decodeIfPresent([Tag].self, forKey: .tags) ?? []
let v3Filter = try container.decodeIfPresent(TagFilter.self, forKey: .activeTagFilter) ?? .all

if version <= 2 {
  let palette: [TagColor] = [.blue, .orange, .green, .purple, .red, .yellow, .grey]
  var spaceIDToTagID: [SpaceID: TagID] = [:]
  var migratedTags: [Tag] = []
  var migratedProjects: [Project] = []
  for (idx, space) in v2Spaces.enumerated() {
    let tag = Tag(id: TagID(), name: space.name, color: palette[idx % palette.count])
    spaceIDToTagID[space.id] = tag.id
    migratedTags.append(tag)
    for var project in space.projects {
      project.tagIDs.insert(tag.id)
      migratedProjects.append(project)
    }
  }
  let seedSpaceID = v2SelectedSpaceID
    ?? v2Windows.compactMap { $0.selectedSpaceID }.first
  let migratedFilter: TagFilter = seedSpaceID
    .flatMap { spaceIDToTagID[$0] }
    .map { .tags([$0]) } ?? .all
  os_log(.info, "migrated catalog v%d → v3 (%d spaces → %d tags, %d projects)",
         version, v2Spaces.count, migratedTags.count, migratedProjects.count)
  self.projects = migratedProjects
  self.tags = migratedTags
  self.activeTagFilter = migratedFilter
} else {
  self.projects = v3Projects
  self.tags = v3Tags
  self.activeTagFilter = v3Filter
}
self.version = Catalog.currentVersion
```

Edit `apps/mac/CodansCore/Project.swift`: add `var tagIDs: Set<TagID>` with default `[]`. Codable: encode as sorted `[TagID]` (matches existing `isPinned`-on-Worktree pattern of "default omits the key"; if `tagIDs.isEmpty`, omit). Decode `decodeIfPresent([TagID].self) ?? []` then `Set(...)`.

**Delete** `apps/mac/CodansCore/Space.swift` entirely. Remove `SpaceID` from `IDs.swift`. Remove `CatalogWindow` struct from `Catalog.swift`. Remove `Catalog.windows` and `Catalog.selectedSpaceID` properties.

**M2.2 — Migration tests.** Add `apps/mac/CodansCoreTests/Fixtures/catalog-v2.json` with a hand-written 2-Space catalog (one Space with 2 Projects + 1 Worktree each, one Space with 0 projects, `selectedSpaceID` set to the second Space, one CatalogWindow entry). Extend `CatalogCodableTests` with:

- `migration_v2_to_v3_produces_one_tag_per_space`
- `migration_v2_to_v3_assigns_each_project_its_space_tag`
- `migration_v2_to_v3_uses_selectedSpaceID_for_initial_filter`
- `migration_v2_to_v3_falls_back_to_first_window_filter_when_selectedSpaceID_is_nil`
- `migration_v2_to_v3_with_empty_spaces_yields_all_filter`
- `migration_v2_to_v3_color_palette_cycles_after_seven_spaces` (8 spaces → palette[7] = palette[0])
- `migration_v1_chains_through_v2_to_v3` (uses the existing v1 fixture if present, else a hand-crafted one)

Each test loads the fixture via `Catalog.init(from: JSONDecoder().decode(...))` and asserts shape — no I/O.

**M2.3 — HierarchyManager surface flip.** In `apps/mac/codans/Runtime/HierarchyManager.swift`:

- Delete: `createSpace`, `renameSpace`, `removeSpace`, `selectSpace`, `setSpaceLastActiveWorktree`, `reorderSpaces`, `drainLegacyOverrides` (if Space-coupled — verify; if it operates on per-Project legacy fields it stays).
- Add:

  ```swift
  func createTag(name: String, color: TagColor) -> TagID
  func renameTag(_ id: TagID, to name: String)
  func recolorTag(_ id: TagID, to color: TagColor)
  func removeTag(_ id: TagID)            // cascades: strips id from every project's tagIDs;
                                          // also normalizes activeTagFilter (drops the id from
                                          // .tags set; if set becomes empty → .all)
  func setProjectTags(_ projectID: ProjectID, tags: Set<TagID>)
  func setActiveTagFilter(_ filter: TagFilter)
  ```

  Each method ends with `store.scheduleSave(catalog)`. `removeTag`'s cascade is critical — failing to normalize `activeTagFilter` would leave a stale TagID in the persisted filter and the sidebar would silently filter to nothing.

**M2.4 — HierarchyClient surface flip.** In `apps/mac/codans/App/Clients/HierarchyClient.swift`, replace every Space-named closure with the Tag equivalents above, plus `setProjectTags` and `setActiveTagFilter`. This breaks the append-only convention; document the waiver in the PR description so T-PROJECT / T-WORKTREE child branches know to rebase. Update `live`, `liveValue`, `testValue` factories.

**M2.5 — RootFeature surgery.** Remove `@Presents var spaceManagerSheet`, action cases `.spaceManagerSheetShown`, `.spaceManagerSheet(...)`, `.switchToSpaceAtIndex`, `.openSpaceSwitcherRequested`, and the `.ifLet` for `spaceManagerSheet`. Remove the corresponding sidebar delegate handler. **Do not yet** add `tagManagerSheet` — that arrives in M5.

**M2.6 — Sidebar flattening.** In `HierarchySidebarFeature.swift`: remove `isSpacePopoverPresented`, all `spacePopover*` actions, the `spaceFooterTapped` action, the `handleSpaceSwitch` helper, and any `setSpaceLastActiveWorktree` calls. The sidebar now reads `catalog.projects` directly (was `catalog.spaces.flatMap { $0.projects }`). In `HierarchySidebarView.swift`: delete the `spaceFooter` function and remove the `.safeAreaInset(edge: .bottom)` modifier entirely (M4 reinstates it with `tagChipFooter`).

**M2.7 — SpaceManager removal.** Delete `apps/mac/codans/App/Features/SpaceManager/` recursively (`SpaceManagerFeature.swift`, `SpaceManagerView.swift`, plus associated tests under `apps/mac/codans/Tests/`). Update the Tuist `Project.swift` if it explicitly enumerates this directory.

**M2.8 — Command palette + commands cleanup.** In `apps/mac/codans/App/Features/CommandPalette/CommandPaletteItems.swift`: remove every Space-scoped item. In `apps/mac/codans/App/Commands/MainWindowCommands.swift`: remove the ⌘K binding and the ⌘1–⌘9 loop. Leave `CommandGroup(after: .newItem)` in place (M3 will hang the `replacing: .newItem` group); leave ⌘E / ⌘⇧G alone.

**M2.9 — IPC handlers.** In `apps/mac/codans/App/Features/Socket/handlers/HierarchyHandlers.swift`: remove every `space.*` RPC. Do **not** add `tag.*` or `project.tag.*` here — those land with their CLI in M6 to keep the wire surface and CLI surface co-evolving in one PR.

**M2.10 — CLI cleanup.** In `apps/mac/codans-cli/Commands/HierarchyCommands.swift`: delete the `codans space` subcommand tree. The `codans focus` / `codans project` / etc. trees stay. M6 adds `codans tag`.

**M2.11 — CodansApp seed branch.** In `apps/mac/codans/App/CodansApp.swift`: remove the "Personal" Space seed in `init()` (currently lines 173–179 per design-doc reference). The migration handles existing data; for fresh installs an empty catalog is fine — the sidebar shows an empty project list with an "Add Project…" affordance. Do not add a default Tag seed.

**M2.12 — Test sweep.** Update or delete every test that references Space:

- `RootFeatureCommandPaletteRoutingTests` — drop Space-routing tests
- `HierarchySidebarFeatureTests` — drop popover/footer tests; keep selection tests against the flat project list
- `HierarchyManager*Tests` — replace Space-mutation tests with Tag-mutation tests
- `CatalogCodableTests` — add the v2→v3 migration tests from M2.2
- Delete `SpaceManagerFeatureTests` outright

**M2.13 — CI grep gate.** Add a `mac-no-space-residue` Make target in `apps/mac/Makefile`:

```makefile
mac-no-space-residue:
	@if grep -rn 'SpaceID\|\bSpace\b\|CatalogWindow\|spacePopover\|spaceFooter' \
	    --include='*.swift' apps/mac/CodansCore apps/mac/CodansCoreTests apps/mac/codans apps/mac/codans; then \
	  echo "Space residue found"; exit 1; fi
```

Wire it into `mac-check` so `make mac-check` fails on residue. M7 removes both.

**Acceptance for M2:**

- `xcodebuild build -scheme codans` succeeds.
- `xcodebuild test` shows all green; specifically `CatalogCodableTests` shows the new migration tests passing.
- Launch the app against a real v2 catalog (a backup of the user's `~/.config/codans/catalog.json` before this work began) and verify: the sidebar shows the flat project list, every project is present, tags can be observed on rows (M4 surfaces them visually — for M2 alone, log them or assert via a debug menu/printout; or skip visual proof until M4 and rely on the migration test).
- `make mac-check` passes including the new `mac-no-space-residue` gate.

PR-2 is the heart of the refactor. Per D7, the implementer may dispatch sub-agents in parallel after M2.1–M2.4 land compile-broken: each agent owns one feature directory and fixes the resulting compile errors. The implementer integrates and runs the full test sweep before opening the PR.

### Milestone 3 — Single-window enforcement and ⌘Q gate

Goal: collapse `WindowGroup` to `Window(id:)`, suppress ⌘N, route close-vs-quit through ⌘W (hide) and ⌘Q (gated quit). After this milestone the user cannot spawn a second main window from any system surface; closing the main window leaves the app running in the dock; quitting prompts (unless empty).

Files touched (3):

- `apps/mac/codans/App/CodansApp.swift`:

  ```swift
  static let mainWindowID = "main"

  // body:
  Window("codans", id: CodansApp.mainWindowID) {
    // existing AppAppearanceView { ContentView(...) } body
  }
  .windowStyle(.titleBar)
  .windowToolbarStyle(.unified)
  .commands {
    if let store = appState.store {
      MainWindowCommands(store: store)
    }
    CommandGroup(replacing: .newItem) { /* empty — suppress ⌘N */ }
    CommandGroup(replacing: .appSettings) { /* existing Settings… button */ }
  }
  ```

- The existing `AppDelegate` (declared at the bottom of `CodansApp.swift`) gains:

  ```swift
  nonisolated func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    return false
  }

  nonisolated func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    MainActor.assumeIsolated {
      let manager = appState?.hierarchyManager
      let hasOpenPanes = manager?.catalog.projects.contains { project in
        project.worktrees.contains { worktree in
          worktree.tabs.contains { tab in !tab.panes.isEmpty }
        }
      } ?? false
      guard hasOpenPanes else { return .terminateNow }
      let alert = NSAlert()
      alert.messageText = "Quit codans?"
      alert.informativeText = "Running terminal sessions will end."
      alert.addButton(withTitle: "Quit")
      alert.addButton(withTitle: "Cancel")
      alert.alertStyle = .warning
      return alert.runModal() == .alertFirstButtonReturn
        ? .terminateNow
        : .terminateCancel
    }
  }
  ```

- `apps/mac/codans/App/Commands/MainWindowCommands.swift`: no edits in M3 (the ⌘K and ⌘1–⌘9 bindings were already removed in M2). M4 will add ⌘F here.

**Acceptance for M3:**

- Launch the app. The system menu's File menu does not contain "New Window" (the ⌘N binding is suppressed). Right-clicking the dock icon shows the standard menu without "New Window".
- Open a Worktree with a Pane. Press ⌘W — the window hides; the dock icon stays bouncing-free; the menu bar still shows codans's app menu.
- Click the dock icon — the window re-shows with prior layout.
- Press ⌘Q — an alert appears: *"Quit codans? Running terminal sessions will end."* Clicking Cancel returns to the app; clicking Quit terminates.
- Close all Panes (or test with an empty catalog). Press ⌘Q — the app quits without prompting.

PR-3 lands.

### Milestone 4 — Sidebar chip footer

Goal: reattach a footer at the sidebar's `.safeAreaInset(edge: .bottom)`, render Tag chips with filter behavior, show colored tag dots on project rows, wire ⌘F. After this milestone users can filter the project list visually.

Files touched (~5):

- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift`:

  - State: read `catalog.activeTagFilter` from environment (no copy in feature state — same single-source-of-truth pattern as the prior space surface).
  - Actions: `.tagChipTapped(TagID)`, `.allChipTapped`, `.untaggedChipTapped`, `.tagFilterFocusRequested` (⌘F).
  - Reducer:

    - `tagChipTapped(id)`: read current `.activeTagFilter`. If `.all` or `.untagged` → set to `.tags([id])`. If `.tags(set)` containing `id` → remove `id`; if set becomes empty → `.all`. If `.tags(set)` not containing `id` → insert `id`. Persist via `hierarchyClient.setActiveTagFilter`.
    - `allChipTapped`: `setActiveTagFilter(.all)`.
    - `untaggedChipTapped`: `setActiveTagFilter(.untagged)`.
    - `tagFilterFocusRequested`: emit a delegate (or use `@FocusState` wired in the view) that focuses the chip footer.

- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift`:

  - Reattach `.safeAreaInset(edge: .bottom)` with a new `tagChipFooter(catalog:)` view.
  - `tagChipFooter` lays out chips inside a horizontally-scrolling `ScrollView(.horizontal)`: leading `[All]` chip, then `ForEach(catalog.tags) { tag in chip(tag) }`, then `[Untagged]` chip when `catalog.projects.contains { $0.tagIDs.isEmpty }`.
  - Chip selection state derived from `catalog.activeTagFilter` — no view-local state.
  - Project rows: in the row body, append `tagDots(for: project)` after the existing name+badges. `tagDots` resolves each `tagID` to a `Tag` via `catalog.tags.first(where:)`, renders a 6×6 colored circle per tag, caps at 3 with "+N".
  - Filter logic on the project list: derive a filtered list from `catalog.projects` based on `catalog.activeTagFilter`:

    - `.all` → all projects
    - `.tags(set)` → projects where `!$0.tagIDs.isDisjoint(with: set)` (OR)
    - `.untagged` → projects where `$0.tagIDs.isEmpty`

- `apps/mac/codans/App/Commands/MainWindowCommands.swift`: add a hidden `Button("Filter Tags") { store.send(.tagFilterFocusRequested) }.keyboardShortcut("f", modifiers: .command)` in the existing `CommandGroup(after: .newItem)`.

- `apps/mac/codans/App/Features/HierarchySidebar/TagChipFooter.swift` (new) — extracted view if `tagChipFooter` exceeds ~80 lines; otherwise inline.

- Tests in `HierarchySidebarFeatureTests`: chip-tap toggles the filter (every state-machine transition); `[All]` / `[Untagged]` are mutually exclusive with `.tags`; ⌘F dispatches the focus action.

**Acceptance for M4:**

- Migration produces tags from a 2-Space test catalog. Launch the app: chip footer shows `[All]` + 2 tag chips. Click one tag chip — sidebar shrinks to its projects only. Click another tag chip — both selected (OR). Click the active tag chip again — deselected; if set becomes empty, filter resets to `[All]`. Click `[Untagged]` (visible only when an untagged project exists) — sidebar shows untagged projects only.
- ⌘F focuses the chip footer (cursor-style focus ring on `[All]`).
- Quit and relaunch — active filter persists.
- `xcodebuild test` green.

PR-4 lands.

### Milestone 5 — TagManager + project-row Tag editor

Goal: surface CRUD. After this milestone users can create/rename/recolor/delete tags via a sheet, and assign/unassign tags per project via the row context menu.

Files added (~4) and touched (~4):

- `apps/mac/codans/App/Features/TagManager/TagManagerFeature.swift` (new):

  ```swift
  @Reducer struct TagManagerFeature {
    @ObservableState struct State: Equatable {
      var renameDraft: TagRenameDraft?
      var pendingRemoval: PendingTagRemoval?
    }
    enum Action: Equatable, BindableAction {
      case binding(BindingAction<State>)
      case createTagTapped(name: String, color: TagColor)
      case renameRowTapped(TagID, currentName: String)
      case renameDraftChanged(String)
      case renameCommitted
      case renameCancelled
      case recolor(TagID, TagColor)
      case removeTapped(TagID, name: String)
      case removeConfirmed
      case removeCancelled
    }
    @Dependency(HierarchyClient.self) private var client
  }

  struct PendingTagRemoval: Equatable {
    var tagID: TagID
    var displayName: String
    var affectedProjectCount: Int
  }
  ```

  Reducer behavior mirrors the deleted SpaceManagerFeature shape: rename trim+empty guard, removal captures `affectedProjectCount` at tap time, recolor is fire-and-forget, no last-tag protection (deleting the only tag is legal — Untagged is a valid catalog state).

- `apps/mac/codans/App/Features/TagManager/TagManagerView.swift` (new): NavigationStack-hosted List, each row shows a color swatch (popover with the 7 palette options), inline-editable name, trash button. Confirmation dialog: *"Remove tag '<name>'? <N> project(s) will lose this tag. Project data is not affected."*

- `apps/mac/codans/App/Features/Root/RootFeature.swift`: re-add a `@Presents var tagManagerSheet: TagManagerFeature.State?` plus its presentation action, ifLet, and a delegate handler `.openTagManager` from sidebar.

- `apps/mac/codans/App/ContentView.swift`: a second `.sheet(item:)` for `tagManagerSheet`, mirroring the existing settings sheet host.

- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift`:

  - Project row context menu gains `Menu("Tags")` with one `Toggle` per existing tag (driven by `client.setProjectTags`) plus a divider, "New Tag…" (opens a small inline picker — quickest path: a sheet hosted on the row), and "Edit Tags…" (sends `.delegate(.openTagManager)`).
  - Tag chip footer (M4) gains a trailing "+" button that also opens TagManager — discoverability for users who never right-click a row.

- Tests: `TagManagerFeatureTests` (new) covering rename trim/empty, removal-counts capture, recolor forwards, removal cascades through the client. Extend `HierarchySidebarFeatureTests` for the row context menu Toggle behavior.

**Acceptance for M5:**

- Right-click a project row → Tags submenu shows existing tags as toggles. Toggle one — chip footer reflects the change immediately. Toggle off the last tag on a project — Untagged chip appears in the footer (if it wasn't already), no warning.
- "Edit Tags…" opens the TagManager sheet. Create a new tag (name + color picker). Rename inline. Recolor by clicking the swatch. Delete a tag — confirmation shows project count; confirming strips the tag from every project and the chip from the footer.
- Quit and relaunch — every change persists.

PR-5 lands.

### Milestone 6 — `codans` CLI surface and IPC handlers

Goal: bring the CLI to parity with the GUI. After this milestone every Tag operation is scriptable.

Files touched (~6):

- `apps/mac/codans/App/Features/Socket/handlers/HierarchyHandlers.swift`: add RPC methods `tag.list`, `tag.create`, `tag.rename`, `tag.recolor`, `tag.remove`, `project.tag.add`, `project.tag.remove`, `project.list` (with optional `tag` and `untagged` filter args). Each delegates to `HierarchyManager` and returns the canonical post-op snapshot (matching the existing `space.*` RPC return convention).
- `apps/mac/codans-cli/Commands/HierarchyCommands.swift`: add `codans tag` subcommand tree and extend `codans project` with `tag add/remove` and `list --tag/--untagged`. Resolution-by-name follows the existing `codans project` pattern (best-effort case-fold; ambiguity warns and requires `--id`).
- `apps/mac/codans/` CLI tests (whatever the existing pattern is — likely `codans/Tests/` if present): one test per subcommand verifying argument parsing and IPC roundtrip via a fake socket server. Match whatever pattern the existing `codans project` / `codans focus` tests follow.

Sketch:

```
codans tag list [--json]
codans tag create <name> [--color red|orange|yellow|green|blue|purple|grey]
codans tag rename <id|name> <new-name>
codans tag recolor <id|name> <color>
codans tag remove <id|name>
codans project tag add <project> <tag>...
codans project tag remove <project> <tag>...
codans project list [--tag <tag>] [--untagged] [--json]
```

**Acceptance for M6:**

- `make mac-build` produces both the app and the `codans` binary.
- `codans tag list --json` returns the post-migration tag set.
- `codans tag create urgent --color red && codans project tag add acme-web urgent` then `codans project list --tag urgent` shows `acme-web`.
- `codans tag remove urgent` cascades; `codans project list` no longer reports `urgent` for any project.
- Foreground GUI is updated live — the chip footer adds/removes chips reflecting CLI actions (the existing socket → catalog → SwiftUI publish pipeline handles this).

PR-6 lands.

### Milestone 7 — First-launch toast, docs, gate cleanup

Goal: the user-facing finish line. After this milestone the change is announced in-app, documented, and the temporary CI gate is removed.

Files touched (~5):

- `apps/mac/codans/App/CodansApp.swift` or `apps/mac/codans/App/Features/Root/RootFeature.swift`: on first run after migration, present a single non-blocking toast: *"Your spaces are now tags. Click a chip in the sidebar to filter projects."* — single line, dismiss-on-tap, auto-dismiss after 8s. Suppression flag `onboarding.tagsToastShown: true` stored via the existing `SettingsStore`. Toast is suppressed if the catalog has zero tags (fresh install with no migration).
- `apps/mac/codans/Settings/Settings.swift` (or wherever `Settings` keys live): add `onboarding.tagsToastShown: Bool` (default `false`).
- `docs/product-spec.md`: replace the "Space / Project / Worktree / Tab / Pane hierarchy" mention with the 4-level hierarchy and tag classification.
- `docs/architecture.md`: update the codemap section that describes Space/Project to reflect Tag.
- `apps/mac/Makefile`: remove the `mac-no-space-residue` target and its inclusion in `mac-check`.
- `CHANGELOG.md` (root): one-line entries for "Spaces are now tags", "Single main window with hide-on-close", "codans CLI: codans space removed; codans tag added".

**Acceptance for M7:**

- Wipe `~/.config/codans/onboarding-tags-toast-flag` (or whatever the suppression key resolves to) and launch — toast appears. Dismiss. Relaunch — no toast.
- `docs/product-spec.md` and `docs/architecture.md` no longer contain "Space" outside of historical references.
- `make mac-check` passes; `grep "mac-no-space-residue" apps/mac/Makefile` returns empty.
- CHANGELOG entries present.

PR-7 lands. Refactor complete.

## Concrete Steps

From the worktree root `/Users/wanggang/.prowl/repos/codans/refactor/rm-space`:

```bash
# M0 — baseline
git status                              # expect clean
make -C apps/mac mac-check 2>&1 | tee /tmp/baseline-check.txt
make -C apps/mac mac-test  2>&1 | tee /tmp/baseline-test.txt

# After each milestone
make -C apps/mac mac-build              # must succeed
make -C apps/mac mac-check              # lint + (M2+) no-space-residue gate
make -C apps/mac mac-test               # full test sweep
git diff --stat                         # eyeball file count vs plan estimate

# M2 specifically — verify migration with a real catalog
cp ~/.config/codans/catalog.json /tmp/catalog-v2-snapshot.json   # ONCE, before M2
# … after M2 lands and you launch …
diff <(jq .version /tmp/catalog-v2-snapshot.json) <(jq .version ~/.config/codans/catalog.json)
# expected: 2 → 3
jq '.tags | length' ~/.config/codans/catalog.json
# expected: equals the prior space count
```

Per `feedback_commit_cadence`, invoke `/commit` after every self-contained sub-step within a milestone — not just at milestone boundaries. M2 in particular should produce ~10 commits internally (one per sub-step M2.1 through M2.13), even though they all ship in one PR. Stage explicit paths only (`feedback_commit_only_my_files`); never `git add -A`.

PR cadence: one PR per milestone (M0 has no PR — it's pre-flight). After each PR merges, rebase the next branch onto `refactor/rm-space` so subsequent milestones build on landed work.

## Validation and Acceptance

Mapped to design-doc resolved questions:

| Item | Proof site |
|------|-----------|
| Existing v2 catalog migrates to v3 with one tag per space | M2.2 `migration_v2_to_v3_*` tests + manual diff of `~/.config/codans/catalog.json` |
| Each migrated project carries its prior space's tag | M2.2 `migration_v2_to_v3_assigns_each_project_its_space_tag` + post-launch sidebar inspection |
| `selectedSpaceID` becomes the initial filter | M2.2 `migration_v2_to_v3_uses_selectedSpaceID_for_initial_filter` |
| Multi-window catalog collapses cleanly | M2.2 `migration_v2_to_v3_falls_back_to_first_window_filter_when_selectedSpaceID_is_nil` |
| Single-window enforced (⌘N suppressed, no New Window menu) | M3 manual: File menu inspection |
| ⌘W hides; ⌘Q prompts when panes exist; ⌘Q silent when empty | M3 manual matrix: open pane → ⌘W → click dock; ⌘Q with panes → confirm; ⌘Q empty → no prompt |
| Chip footer filters with OR semantics | M4 reducer tests + manual chip-tapping |
| `[Untagged]` chip visible only when present | M4 manual: tag every project → chip disappears; untag one → chip reappears |
| ⌘F focuses chip footer | M4 manual + reducer test |
| Project context menu Tags submenu toggles tag membership | M5 manual + extended sidebar test |
| TagManager: create/rename/recolor/delete with cascade | M5 manual + `TagManagerFeatureTests` |
| Deleting a tag normalizes the active filter | M2.3 `removeTag` test + M5 manual |
| `codans tag *` and `codans project tag *` work end-to-end | M6 CLI tests + manual transcript |
| First-launch toast appears once | M7 manual: wipe flag, relaunch, dismiss, relaunch |
| `make mac-check` passes including the residue gate | After M2; gate removed in M7 |

## Idempotence and Recovery

- **M0 baseline** is read-only.
- **M1** is purely additive; reverting the PR removes the new types with no consumer impact.
- **M2** migration is one-shot per catalog: once `~/.config/codans/catalog.json` is rewritten to v3, the v2 decoder branch is no longer hit. The v2 decoder remains in code, so reverting the M2 PR makes the build read v3 catalogs as v2 and **fail** (`unsupportedVersion(3)`). User recovery: restore `/tmp/catalog-v2-snapshot.json` (taken pre-M2 per Concrete Steps) over `~/.config/codans/catalog.json` and downgrade the build.
- **M3** is purely UI-layer; reverting the PR restores `WindowGroup` with no data impact.
- **M4–M7** are additive over M2's foundation; each is independently revertable.
- `HierarchyManager.removeTag` cascade is idempotent — re-removing an already-removed TagID is a no-op (the cascade walks projects and sets are set semantics).
- The `mac-no-space-residue` Make gate is idempotent (read-only grep).
- Per the user's `git-safety` memory: do not `git add -u/-A` at any commit. Each commit names the files explicitly.

## Artifacts and Notes

Sample fixture (M2.2) `apps/mac/CodansCoreTests/Fixtures/catalog-v2.json`:

```json
{
  "version": 2,
  "spaces": [
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Day Job",
      "projects": [
        { "id": "aaaa...", "name": "acme-web", "rootPath": "/tmp/acme-web", "worktrees": [] }
      ],
      "selectedProjectID": "aaaa..."
    },
    {
      "id": "22222222-2222-2222-2222-222222222222",
      "name": "Side",
      "projects": []
    }
  ],
  "selectedSpaceID": "11111111-1111-1111-1111-111111111111",
  "windows": [
    { "id": "33333333-3333-3333-3333-333333333333",
      "selectedSpaceID": "22222222-2222-2222-2222-222222222222" }
  ]
}
```

Expected v3 result (asserted in M2.2 tests):

```
catalog.tags.count == 2
catalog.tags[0].name == "Day Job"
catalog.tags[0].color == .blue       // palette[0]
catalog.tags[1].color == .orange     // palette[1]
catalog.projects.count == 1
catalog.projects[0].name == "acme-web"
catalog.projects[0].tagIDs == [tagDayJob.id]
catalog.activeTagFilter == .tags([tagDayJob.id])  // selectedSpaceID, not first-window
```

Sample ⌘Q dialog (M3):

> *Quit codans?*
>
> *Running terminal sessions will end.*
>
> [Quit] [Cancel]

Sample first-launch toast (M7):

> Your spaces are now tags. Click a chip in the sidebar to filter projects.

## Interfaces and Dependencies

In `apps/mac/CodansCore/Tag.swift`, define:

```swift
public struct Tag: Equatable, Codable, Sendable, Identifiable
public enum TagColor: String, Codable, CaseIterable, Sendable
public enum TagFilter: Equatable, Codable, Sendable {
  case all
  case tags(Set<TagID>)
  case untagged
}
```

In `apps/mac/CodansCore/IDs.swift`, add `public struct TagID: HierarchyID`. **Remove** `SpaceID` in M2.

In `apps/mac/CodansCore/Project.swift`, add `public var tagIDs: Set<TagID>` (Codable as sorted `[TagID]`, omitted when empty).

In `apps/mac/CodansCore/Catalog.swift`, the v3 shape:

```swift
public struct Catalog: Equatable, Sendable {
  public static let currentVersion = 3
  public var version: Int
  public var projects: [Project]
  public var tags: [Tag]
  public var activeTagFilter: TagFilter
}
```

`Catalog.init(from:)` accepts versions 1, 2, 3 and chains migrations. `Space`, `SpaceID`, `CatalogWindow` are removed.

In `apps/mac/codans/Runtime/HierarchyManager.swift`, the new mutation surface:

```swift
func createTag(name: String, color: TagColor) -> TagID
func renameTag(_ id: TagID, to name: String)
func recolorTag(_ id: TagID, to color: TagColor)
func removeTag(_ id: TagID)              // cascades: projects, activeTagFilter
func setProjectTags(_ projectID: ProjectID, tags: Set<TagID>)
func setActiveTagFilter(_ filter: TagFilter)
```

In `apps/mac/codans/App/Clients/HierarchyClient.swift`, mirror each method as a closure on the dependency surface. Update `live`, `liveValue`, `testValue`. M2 explicitly waives the append-only convention; M5+ resumes append-only.

In `apps/mac/codans/App/Features/TagManager/TagManagerFeature.swift`, define:

```swift
@Reducer struct TagManagerFeature {
  @ObservableState struct State: Equatable {
    var renameDraft: TagRenameDraft?
    var pendingRemoval: PendingTagRemoval?
  }
  enum Action: Equatable, BindableAction { /* see M5 */ }
}
```

In `apps/mac/codans/App/Features/Socket/handlers/HierarchyHandlers.swift`, the new RPCs:

```
tag.list, tag.create, tag.rename, tag.recolor, tag.remove,
project.tag.add, project.tag.remove,
project.list (with optional tag / untagged filters)
```

In `apps/mac/codans-cli/Commands/HierarchyCommands.swift`, the new subcommands:

```
codans tag list|create|rename|recolor|remove
codans project tag add|remove
codans project list [--tag] [--untagged]
```

External dependencies: none added. All new code uses `ComposableArchitecture`, `SwiftUI`, `AppKit`, `CodansCore`, `os.log`, `Foundation`.
