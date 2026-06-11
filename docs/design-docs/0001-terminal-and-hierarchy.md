# Design Doc: Terminal Engine and Five-Level Hierarchy (C1 + C2)

**Status:** Approved
**Author:** Gump (with Claude)
**Date:** 2026-04-19
**Approved:** 2026-04-19 by Gump

## Context and Scope

codans orchestrates terminals around a five-level hierarchy (Space → Project → Worktree → Tab → Pane). Two capabilities from [product-spec.md](../product-spec.md) form the foundation on which every other capability is built:

- **C1 — Terminal engine.** libghostty-based multi-pane rendering and Pane lifecycle management.
- **C2 — Five-level hierarchy.** The data model, persistence, and navigation surface for Spaces, Projects, Worktrees, Tabs, and Panes, including split layouts inside a Tab.

They are coupled: every Pane is both a libghostty surface (C1) and a leaf in the hierarchy (C2). A Tab owns a split tree of Panes; a Worktree owns Tabs; a Project owns Worktrees; a Space groups Projects. Designing them together — rather than in isolation — is the only way to pin down ownership of Pane identity, who allocates / frees libghostty surfaces, and where split geometry lives.

Repository state at the time of this design:

- Bootstrap is complete (exec-plan [0001](../exec-plans/0001-bootstrap-monorepo.md)). Tuist targets `CodansCore`, `CodansIPC`, `codans`, `codans` exist; `codans/{App,Runtime,Hooks,Git}` are empty subfolders.
- `GhosttyKit.xcframework` is temporarily deferred (DEC-8). The Pane rendering design assumes it is present when this plan implements; the bootstrap plan will re-enable it.
- Hybrid state management and IPC conventions are fixed by [architecture.md](../architecture.md). This design conforms to those invariants and does not relitigate them.

This document is the source of truth for how Pane lifecycle, the hierarchy tree, split layouts, and their persistence are structured. It does **not** specify C3 (Hooks), C4 (CLI), C6 (notifications), C7 (git viewer), or C8 (editor integration) — it defines only the events and commands those capabilities will consume.

## Goals and Non-Goals

**Goals**

- Define the domain model (types, identifiers, relationships) for Space / Project / Worktree / Tab / Pane so that every later capability binds to stable names.
- Define the libghostty integration boundary: who owns `ghostty_app_t`, who owns `ghostty_surface_t`, how Pane lifetime maps to surface lifetime.
- Specify split layouts inside a Tab (`SplitTree<PaneID>`): operations, invariants, persistence shape.
- Specify persistence (`catalog.json`, schema version, write path, read path, pruning rules).
- Specify the in-app command/event surface between `Runtime` (C1) and the hierarchy (C2), and between the hierarchy and the TCA app shell.
- Meet the Non-Functional Requirements in product-spec: cold start < 1s, Pane/Tab switch < 16ms, idle CPU ≈ 0%, Pane crash isolation, state durability.
- Leave clearly defined seams for C3 / C4 / C6 / C7 / C8 so they can be added without reshaping C1+C2.

**Non-Goals**

- Defining hook semantics, hook handler execution model, or agent-detection heuristics (C3 / C6).
- Defining CLI subcommand shape or IPC wire types (C4 — the IPC surface for C2 is defined here only abstractly as method namespaces; exact payloads belong to the CLI design doc).
- Defining the git diff/history viewer UI or data model (C7).
- Defining external editor dispatch (C8).
- Multi-window semantics beyond "Window ↔ Space is 1:1" (see Alternatives).
- Remote / SSH / dev-container support (out of scope for v1 per product-spec).
- Package manager integration (out of scope per product-spec).

## Design

### Overview

The design is organised around three ideas:

1. **The hierarchy is a tree of value types with stable UUIDs; mutations go through a single `@Observable` manager.** Space, Project, Worktree, Tab, and Pane are plain Codable structs with `id: UUID`. All structural mutation (insert Worktree, move Tab, split Pane) flows through `HierarchyManager` — an `@Observable` class in `codans/Runtime`. The manager is the single writer; UI and features read via bindings.

2. **The Runtime owns libghostty. Everything else reads or commands it.** `GhosttyRuntime` wraps the process-global `ghostty_app_t`. Each Pane owns a `PaneSurface` wrapping one `ghostty_surface_t`. Pane lifecycle (create / ready / output / idle / exit) is emitted as an `AsyncStream<TerminalEvent>`. The TCA app shell subscribes to events and translates them to actions; it never mutates surfaces directly. This hybrid boundary matches supacode's proven pattern (`TerminalClient` bridging TCA ↔ `@Observable`) and [architecture.md § State Management](../architecture.md).

3. **Split layouts are a separate data structure from the hierarchy, owned by the Tab.** `SplitTree<PaneID>` is a recursive value type (leaf or split) that stores only Pane IDs — never surface objects. View composition resolves each leaf ID to its Pane and the Pane's surface at render time. This is a direct adaptation of supaterm's `SplitTree<ViewType: NSView & Identifiable>` with the generic pinned to `PaneID` so that split state is Codable and persistable.

**Why this shape.** The central trade-off is where mutable Pane state lives. Three options were considered (see Alternatives). Concentrating high-frequency surface state behind `@Observable` inside Runtime, and routing structural mutations through a TCA-facing command surface, avoids two failure modes: (a) routing every libghostty byte through a TCA reducer — Effect allocation and value-type diffs at multi-kHz rates — which supacode hit and split out; (b) making the entire app `@Observable` — loses the unidirectional flow TCA provides for feature code. Both reference projects (supacode explicitly, supaterm implicitly) ended at the same split; we adopt it deliberately rather than rediscovering it.

**Why SplitTree stores only IDs.** Persistence demands it: split geometry must survive app restart, and a live `ghostty_surface_t` pointer cannot. Decoupling also means split operations (grow/shrink, focus navigation, swap panes) are pure value-type transformations — trivially unit-testable without any ghostty bring-up.

### System Context Diagram

```
                ┌──────────────────────────────────────────────┐
                │              macOS window (Space)            │
                │  ┌────────────────────────────────────────┐  │
                │  │  Sidebar: Projects / Worktrees (TCA)   │  │
                │  ├────────────────────────────────────────┤  │
                │  │  Tab bar + SplitTree viewport          │  │
                │  │  ┌──────────┐  ┌──────────┐            │  │
                │  │  │  Pane   │  │  Pane   │   …        │  │
                │  │  │ (GhostV) │  │ (GhostV) │            │  │
                │  │  └────┬─────┘  └────┬─────┘            │  │
                │  └───────┼─────────────┼──────────────────┘  │
                └──────────┼─────────────┼─────────────────────┘
                           │             │
                           │ render/input│
                           ▼             ▼
        ┌─────────────────────────────────────────────────┐
        │  codans/Runtime  (C1)   @Observable         │
        │                                                 │
        │   GhosttyRuntime  ── owns ──▶  ghostty_app_t    │
        │      │                                          │
        │      └─ PaneSurface[paneID] ─▶ ghostty_surface_t
        │                                                 │
        │   HierarchyManager  (C2)   @Observable          │
        │      └─ Space/Project/Worktree/Tab/Pane tree   │
        │      └─ SplitTree<PaneID> per Tab              │
        │                                                 │
        │   AsyncStream<TerminalEvent> ─────────────────▶ (to Hooks C3, TCA app shell)
        │                                                 │
        │   CatalogStore ─▶ ~/.config/codans/         │
        │                   ├── catalog.json   (tree)     │
        │                   └── settings.json  (prefs)    │
        └─────────────────────────────────────────────────┘
                           ▲
                           │ IPC (Unix socket, JSON-RPC)
                           │
                ┌─────────────────────┐
                │  codans  (C4, separate) │
                └─────────────────────┘
```

External boundaries touched by C1+C2:

- **libghostty (via GhosttyKit XCFramework)** — in-process C API. Single direction of trust (we trust ghostty's escape sequence handling, throughput, and crash boundaries).
- **File system** — `~/.config/codans/catalog.json` (written atomic-rename). For non-git Projects and worktree directories, we also read the user's chosen directories under their home or explicit paths.
- **`git` CLI via `Process`** — read-only discovery of branches and worktrees for Project/Worktree CRUD. No write operations (commit/merge/etc. are explicitly out of scope per product-spec; `git worktree add` is a write but is a structural operation, see Component Boundaries).

### API Design

Three surfaces: (i) the Swift command surface between TCA features and Runtime (`HierarchyClient`, `TerminalClient`); (ii) the event stream Runtime publishes; (iii) the IPC method *namespaces* that C4 will bind to (exact payloads deferred to the CLI design doc). All operate on UUIDs.

#### Command surface (TCA → Runtime)

Two clients, paralleling supacode's pattern. These are dependency-injected into TCA features; they do not expose Runtime internals. `HierarchyClient` covers structural mutations; `TerminalClient` covers Pane input and focus.

Key `HierarchyClient` commands (sketch — exact enum in implementation):

- Space: `createSpace(name)`, `renameSpace(id, name)`, `removeSpace(id)`, `selectSpace(id)`
- Project: `addProject(spaceID, path, gitRoot)`, `removeProject(id)`, `setDefaultEditor(projectID, editor)`
- Worktree: `createWorktree(projectID, branch, location?)`, `removeWorktree(id, keepDirectory: Bool)`, `selectWorktree(id)`
- Tab: `createTab(worktreeID, name?)`, `renameTab(id, name)`, `closeTab(id)`, `selectTab(worktreeID, tabID)`
- Pane: `openPanel(tabID)` (creates both hierarchy leaf and surface), `splitPanel(anchor: PaneID, direction)`, `closePanel(id)`, `focusPanel(id)`, `swapPanels(a, b)`, `resizeSplit(at: SplitPath, ratio)`, `zoomPanel(id)` / `unzoom(tabID)`

Key `TerminalClient` commands:

- `sendInput(paneID, text)`, `sendKey(paneID, key)` — text injection for cross-pane messaging (`codans send`, `codans broadcast`)
- `setFocus(paneID)` — keyboard focus (distinct from hierarchy "selected pane" — kept together in practice but separated here for clarity)
- `scroll(paneID, lines)`, `clearScrollback(paneID)` — surface controls

Both clients are `@MainActor @Sendable` function structs, like supacode's `TerminalClient`.

#### Event stream (Runtime → subscribers)

One `AsyncStream<TerminalEvent>`. Events are coarse-grained — they are the taxonomy later consumed by C3 (Hooks) and C6 (notifications) without modification:

- `paneCreated(paneID, tabID)`
- `paneReady(paneID)` — surface is live and has emitted its first byte or cleared its initial prompt (heuristic pinned in implementation)
- `paneOutput(paneID, bytes)` — throttled / batched; see Cross-Cutting § Performance
- `paneIdle(paneID, duration)` — fired once per transition into idle
- `paneExited(paneID, code, signal)`
- `paneCrashed(paneID, reason)` — libghostty surface teardown or Zig-side fault
- `tabActivated(tabID)`
- `worktreeActivated(worktreeID)`
- `hierarchyMutated(path)` — a coarse "something changed in the tree at this path" used by persistence and by TCA for UI refresh

`paneOutput` is the highest-frequency event. It is **not** consumed by TCA reducers; only `Runtime.PanelState` (another `@Observable`) stores scrollback. The stream carries the event so `Hooks` can subscribe for output-match handlers (C3), but TCA does not.

#### IPC namespaces (for C4)

The CLI design doc (a sibling design doc) will pin exact payloads. C1+C2 commit only to the method *namespaces* and to the fact that every operation resolves to a `HierarchyClient` / `TerminalClient` call:

- `hierarchy.*` — Space/Project/Worktree/Tab CRUD, selection, listing
- `terminal.*` — Pane open/close/split/focus/send/broadcast
- `system.get_context` — returns the Pane UUID associated with the calling process (via `CODANS_PANE_ID` env var); used so `codans` run inside a Pane knows its own identity

### Data Storage

All persistent state lives in `~/.config/codans/`:

| File | Owner | Schema version |
|---|---|---|
| `catalog.json` | `HierarchyManager` | `version: Int` at top level |
| `settings.json` | settings feature (not C1+C2) | `version: Int` at top level |

`catalog.json` is the full hierarchy tree, serialized as plain Codable structs. Sketch:

```
Catalog {
  version: 1
  windows: [Window]         // one per macOS window; window ↔ Space is 1:1
  spaces: [Space]           // all spaces, regardless of window assignment
  selectedSpaceID: UUID?
}

Space {
  id: UUID
  name: String
  projects: [Project]
  selectedProjectID: UUID?
}

Project {
  id: UUID
  name: String
  rootPath: String
  gitRoot: String?          // nil for non-git Projects; Worktree ops inert
  worktreesDirectory: String?   // override for `<repo>-worktrees/` default
  defaultEditor: EditorID?  // for C8
  worktrees: [Worktree]
  selectedWorktreeID: UUID?
}

Worktree {
  id: UUID
  name: String              // usually the branch name
  path: String              // absolute
  branch: String?           // nil if the path isn't on a git branch
  tabs: [Tab]
  selectedTabID: UUID?
}

Tab {
  id: UUID
  name: String?             // user-editable; defaults to the focused Pane's title heuristic
  splitTree: SplitTree<PaneID>
  // Panes referenced by splitTree are stored flat on the Tab to simplify lookup.
  panes: [Pane]
}

Pane {
  id: UUID
  workingDirectory: String  // seeded on create; Pane's shell may cwd away from it
  initialCommand: String?   // optional command seeded at Pane start (for `codans send`)
  // Scrollback / cursor state are NOT persisted. They are live-only under Runtime.PanelState.
}

SplitTree<PaneID> = Node {
  leaf(PaneID) |
  split(Direction, ratio: Double, left: Node, right: Node)
}
```

**Why flat `panes: [Pane]` alongside `splitTree`.** SplitTree references Panes by ID; having a flat list on the Tab makes lookup O(1) and persistence layout easy to read in a text editor. Invariant: the set of leaf IDs in `splitTree` equals the set of `panes[*].id`.

**Access patterns.** Read on launch (one large read). Write on any structural mutation (debounced — see below). Hot path reads of Pane scrollback are **not** on this file; they never leave memory.

**Writing.** Atomic-rename via `CodansCore/Persistence.swift`: encode → temp file in same directory → fsync temp → `rename(2)` over original. Per [architecture.md § Persistence](../architecture.md), readers abort on unknown `version` (no silent upgrade).

**Write debouncing.** Structural mutations can arrive in bursts (opening 5 Panes across 2 Tabs in a scripted agent session). Debounce with a 500ms trailing timer, with an immediate flush on `applicationWillTerminate` and on Worktree switch. This keeps the file on disk closely coupled to user-visible state without hot-looping.

**Pruning on load.** After decoding, `HierarchyManager` prunes dangling references (missing disk paths, orphan Pane IDs) — following supaterm's `pruned()` cascade. Pruning is non-destructive on disk until the next write; users who restore an external drive get their Worktrees back.

### Component Boundaries

```
codans/Runtime (in-app module)
├── GhosttyRuntime           ─ owns ghostty_app_t; initialises once per process
├── PaneSurface             ─ one per Pane; owns ghostty_surface_t + PanelState (@Observable)
├── HierarchyManager         ─ @Observable; single writer of the tree; owns SplitTree mutations
├── CatalogStore             ─ atomic-rename JSON load/save; debounced writes
└── TerminalEngine           ─ façade; exposes AsyncStream<TerminalEvent>; holds the two managers

CodansCore (static framework)
├── IDs (SpaceID, ProjectID, WorktreeID, TabID, PaneID — all UUID newtypes)
├── Domain value types (Space, Project, Worktree, Tab, Pane structs — Codable, Equatable, Sendable)
├── SplitTree<PaneID>       ─ pure value type (no UI, no AppKit import)
└── Persistence              ─ atomic-rename JSON helper; version-checked decoder

codans/App (in-app module; TCA)
├── HierarchyClient          ─ TCA-visible command/event surface (DependencyKey)
├── TerminalClient           ─ TCA-visible input/focus surface (DependencyKey)
├── HierarchyCatalogFeature  ─ sidebar tree; reads @Observable bindings
└── PaneHostView            ─ NSViewRepresentable that resolves PaneID → surface NSView
```

**Dependency rules** (on top of [architecture.md § Dependency Direction](../architecture.md)):

- `CodansCore` has the domain types and `SplitTree`. Zero AppKit / SwiftUI / Ghostty imports — it must be buildable as a pure-Swift static framework so it is safe to import from `codans` (which must never import Runtime).
- `SplitTree<PaneID>` lives in `CodansCore` (not in supaterm's `Features/Terminal/Models/`) because persistence demands it be buildable outside the app target.
- `codans/Runtime` is the only module that imports `GhosttyKit`. `App`, `Hooks`, `Git` all see Panes through `HierarchyManager` state + event stream.
- `HierarchyManager` is the **single writer** of the tree. Features never mutate structs directly — they call `HierarchyClient` commands.
- `codans` (CLI) never imports Runtime; it talks to the app via IPC, which internally calls `HierarchyClient` / `TerminalClient`.

**What each component is NOT responsible for:**

- `GhosttyRuntime`: not responsible for hierarchy state, not responsible for which Pane is "focused by the user" (that's a TCA concept); only for surface creation, event forwarding, and teardown.
- `HierarchyManager`: not responsible for scrollback, cursor, selection of text inside a Pane. Those live in `PaneSurface.PanelState`.
- `SplitTree`: not responsible for knowing about Panes beyond their ID. It is a pure algebraic data type; no rendering, no ghostty, no persistence annotations beyond `Codable`.
- `CatalogStore`: not responsible for schema migration (v1 — abort on unknown version per architecture invariant).

**Window ↔ Space.** `Catalog.windows[i]` records which Space is selected in that window. Opening a new macOS window creates a new `Window` entry and prompts the user for which Space to attach. This is the minimum needed to satisfy architecture Open Q2's leaning without over-committing to richer multi-window semantics.

**Non-git Projects.** `Project.gitRoot == nil` means: Worktree operations (`createWorktree`, `removeWorktree`) throw; the UI shows a single synthetic Worktree at `Project.rootPath` with `branch = nil`; the git viewer (C7) shows an empty state. No hidden mode flag — a Project is either git-backed or not, resolved once at add-time.

**Worktree storage layout.** On `createWorktree`, compute the directory as `Project.worktreesDirectory ?? "<rootPath>-worktrees/<branch>"`. Create with `git worktree add -b <branch> <path>`. On `removeWorktree(keepDirectory: false)`, call `git worktree remove <path>`. Directory defaults are product-spec Q6 / architecture Q7 leanings, concretised here.

**Pane lifecycle mapping.**

```
User intent                HierarchyManager               Runtime                libghostty
openPanel(tabID)      ─▶   insert Pane(id) into Tab ─▶   ghostty_surface_new   ─▶  surface_t
                           mark Tab dirty              ─▶  register callbacks
                                                          emit .paneCreated
                           …first output…                                          ─▶  first byte
                                                         emit .paneReady
closePanel(id)        ─▶   remove Pane from Tab     ─▶   ghostty_surface_free   ─▶  surface_t*
                           collapse SplitTree if leaf     emit .paneExited
surface crash         ─◀────────────────── propagate ◀────── fault/teardown
                           keep Pane entry; show       emit .paneCrashed
                           ErrorPlaceholderState
```

**Crash isolation.** When `paneCrashed` fires, `HierarchyManager` keeps the Pane entry (so SplitTree stays stable) but flips its `PanelState` into a placeholder view showing the reason and an "Retry" action. Retry calls `reopenPanel(id)` which creates a fresh surface at the same path with the same initial command. If 3 crashes occur within 30s, escalate to closing the Tab with a user-visible toast — matching architecture Open Q6 leaning. Counter is per-Pane and resets after 30s without a crash.

**Cold start path.**

1. App launch → `CatalogStore.load()` → decoded `Catalog` in ~ms.
2. `HierarchyManager.restore(catalog)` rebuilds the in-memory tree. No surfaces created yet.
3. UI renders sidebar + Tab bar from hierarchy.
4. First visible Tab's first visible Pane requests its surface; `GhosttyRuntime.ensureSurface(paneID)` creates it. Subsequent Panes create lazily on focus.
5. `.paneReady` fires; first interactive Pane is live.

Lazy surface creation is what buys sub-1s cold start with a large tree. Both reference projects do this; we inherit the approach.

**Tab/Pane switch < 16ms.** Surfaces are never recreated on switch. `PaneHostView` toggles `NSView.isHidden` (or swaps which view is installed in the split viewport) and asks the newly visible `ghostty_surface_t` to refresh. Switching is a retained-view visibility change — well under one frame.

## Alternatives Considered

### A1. State: full-TCA (Panes as TCA state, not `@Observable`)

Put every Pane's scrollback, cursor, and selection into TCA state; route every libghostty output event through a reducer.

- **Pros:** single state paradigm; every mutation has a history; excellent testability via TCA's TestStore.
- **Cons:** at agent-heavy output rates (tens of kHz per Pane; 8 Panes = 100s of kHz), reducer value-type diffs and Effect allocations produce measurable stalls. supacode hit exactly this and explicitly split it out. Product-spec NFR demands full libghostty throughput with no regression; this alternative cannot meet it.
- **Verdict:** rejected on performance grounds with an existence proof (supacode's move).

### A2. State: full-`@Observable`

Put all app state — features, settings, command palette — behind `@Observable`. No TCA.

- **Pros:** smaller framework surface; one paradigm; Apple-native.
- **Cons:** loses testable unidirectional flow for feature-level logic (deeplinks, updates, modal sheets, settings validation) where TCA's reducer model shines. We gain nothing we don't already have from the hybrid. No existing project of this scale demonstrates it working well.
- **Verdict:** rejected — asymmetric loss of testability for feature code in exchange for uniformity.

### A3. SplitTree as actor / reference type

Make `SplitTree` a class (or actor) with internal mutation, rather than a value type with `replacing`/`inserting` copies.

- **Pros:** mutation is in-place; no tree copying on each edit.
- **Cons:** loses Equatable (TCA reducers want it), loses easy Codable, harder to unit-test mutations (no "given tree → apply op → expected tree" pattern). Tree size is bounded (realistically < 64 nodes per Tab); the value-type copy cost is negligible. supaterm proves value-type SplitTree is fine at this scale.
- **Verdict:** rejected — no real performance motivation; testability and persistence both favour value types.

### A4. Persistence: one file per Space (or per Project)

Split `catalog.json` into `spaces/<uuid>.json` or similar.

- **Pros:** smaller atomic writes; cross-machine merge conflicts are narrower.
- **Cons:** single-file read is O(spaces) opens; v1 has no merge story (local-first product); sibling Worktree/Tab cross-references still need transactional semantics we'd have to hand-build. Both reference projects use a single session file and this is cheap even with many Tabs.
- **Verdict:** rejected for v1; single file. Revisit when sync lands (outside v1 scope).

### A5. Hierarchy: skip "Tab" — go directly Worktree → Pane split-tree

Collapse the Tab level; a Worktree owns one SplitTree whose leaves are Panes.

- **Pros:** one fewer level of nesting; UI simplification.
- **Cons:** the Tab is the user's concurrency model — "dev server tab", "agent tab", "test-watcher tab". Collapsing it forces users to choose between many always-visible split panes (cognitive overload) or coding a tab concept in userland via Hooks. Product-spec explicitly defines Tab as "one Tab per concurrent task"; removing it regresses on stated user value.
- **Verdict:** rejected — removing a capability the spec calls out.

### A6. Runtime: one `ghostty_app_t` per Tab (not per process)

Each Tab owns its own ghostty app instance.

- **Pros:** tab-local crash isolation at the app level.
- **Cons:** `ghostty_app_t` is designed as a per-process singleton per its C API. Running multiple copies inside one process is unsupported territory; both reference projects and upstream Ghostty use one app instance per process. Surface-level crash isolation (our chosen approach) covers the stated NFR without leaving the supported path.
- **Verdict:** rejected — breaks ghostty's contract with no gain we can't get elsewhere.

### A7. Window ↔ Space: N:M mapping (architecture Q2 alternative)

A Space is global; any window can show any Space; multi-window is a viewport onto the same selection.

- **Pros:** flexible; matches how users sometimes want to see the same content across monitors.
- **Cons:** concurrent edits from two windows on the same Space require conflict rules; "focused Pane" becomes ambiguous (per-window or per-Space?). Opens design questions we don't have to answer in v1.
- **Verdict:** rejected for v1 — pick 1:1 now; revisit if users ask.

## Cross-Cutting Concerns

### Performance

- **`paneOutput` backpressure.** libghostty surfaces emit output callbacks on a ghostty-owned thread. `PaneSurface` buffers bytes in scrollback synchronously (cheap) and *separately* enqueues a coalesced `.paneOutput` event on the Runtime AsyncStream. Coalescing: if a prior event for the same Pane is still pending, fold bytes into it (max 16KB per batch, max 60Hz emission). This keeps hook handlers and UI refresh rate-limited even under sustained agent output.
- **Cold start.** Lazy surface creation (see Cold start path above). `catalog.json` decode benchmark target: < 20ms for 200 Panes across 20 Tabs, which is well within the 1s budget.
- **Idle CPU.** libghostty surfaces are event-driven. With no input and no output, no CPU is spent. Our additional cost is the debounce timer for persistence (one `Task.sleep` armed on mutation) and the AsyncStream plumbing — both zero-cost when idle.
- **Tab switch.** Surface views are installed once and retained; switching is AppKit `isHidden` toggling. Benchmark: < 2ms on M1 in supacode; we expect the same.

### Persistence & durability

- Version check rejects unknown versions. No silent upgrade — per architecture invariant.
- `catalog.json` writes are debounced and atomic-renamed; applicationWillTerminate flushes synchronously.
- Pruning on load handles disk-level drift (removed worktree directories, missing Project roots).
- Recovery on decode failure: back up the broken file to `catalog.json.broken-<timestamp>`, log via `os.Logger`, start with an empty catalog. Users never lose the broken file; they can report/inspect it.

### Observability

- `os.Logger` category `com.gumpw.codans.runtime` for Pane lifecycle and libghostty integration; `com.gumpw.codans.hierarchy` for tree mutations; `com.gumpw.codans.persistence` for catalog load/save.
- Every structural mutation logs the operation name and affected ID at `.info`. Hot-path Pane output does not log.
- Crash reason from ghostty (when provided) is captured in `.paneCrashed` and logged.

### Testing strategy

- **`CodansCore` (pure)** — full unit coverage. Every `SplitTree` operation has a table-driven test (adapt supaterm's SplitTree tests). Codable round-trip for every domain type.
- **`HierarchyManager`** — unit-tested with an in-memory `CatalogStore` and a fake `GhosttyRuntime` that only tracks surface create/destroy calls. No live libghostty needed.
- **Runtime surface integration** — a small XCTest suite that spins up a real `GhosttyRuntime`, opens a Pane running `/bin/sh -c "echo hi"`, verifies `.paneReady` and `.paneExited` fire. Gated behind `TC_RUN_GHOSTTY_TESTS=1` so CI can opt in once GhosttyKit is re-enabled (DEC-8 of bootstrap plan).
- **UI** — SwiftUI snapshot tests for sidebar + tab bar are sufficient for C1+C2. Pane rendering itself is libghostty's responsibility.

### Migration path

- v1: `catalog.json` ships at `version: 1`. No prior version exists.
- Future v2: bump version; implement explicit migration step in `CatalogStore.load`; never silently read unknown versions.

### Security & sandboxing

- C1+C2 introduce no new attack surface beyond libghostty (inherits ghostty's terminal emulation boundary) and `git` CLI invocation (for Worktree operations). `git` is invoked with a fixed argument list — no shell interpolation of user strings. Worktree paths are validated to live under `Project.rootPath`'s parent or the user-configured override, never `..`-traversed into arbitrary locations.
- Hook handlers (C3) are out of scope here. C1+C2 emit events; Hooks module is the sandbox boundary for handler execution.

### Seams left for later capabilities

- **C3 Hooks** subscribes to the AsyncStream<TerminalEvent>. No code change in Runtime.
- **C4 CLI** calls `HierarchyClient` / `TerminalClient` via IPC method dispatch. IPC types live in `CodansIPC`; the dispatcher maps methods to client calls.
- **C6 Notifications** subscribes to `.paneIdle` + Hooks' agent-state events.
- **C7 Git viewer** reads `Worktree.path` from `HierarchyManager`; uses its own read-only data layer.
- **C8 Editor integration** reads `Worktree.path` + `Project.defaultEditor`; invokes editor CLI. Zero feedback loop to C1+C2.

## Risks

- **R1 — libghostty API drift.** Ghostty's C API can change between commits; we pin via submodule. Mitigation: treat the pinned commit as part of the design; any bump is a deliberate PR with a before/after surface-creation smoke test. `scripts/build-ghostty.sh`'s fingerprint already detects changes.
- **R2 — Pane/surface ownership bugs.** Swift ARC + manual ghostty lifetimes are a classic leak/UAF source. Mitigation: `PaneSurface` is the single owner; `deinit` calls `ghostty_surface_free` unconditionally; invariants enforced by a debug-only `Weak<PaneSurface>` registry in `GhosttyRuntime` that asserts zero live surfaces on app terminate. Supacode's pattern is proven here.
- **R3 — SplitTree + hierarchy invariant drift.** The "leaves of splitTree == panes[*].id" invariant is easy to break on partial mutations. Mitigation: every mutator on `HierarchyManager` that touches a Tab's split tree also runs `Tab.validateInvariants()` in debug builds; release builds skip the check.
- **R4 — Catalog corruption from concurrent writes.** If two code paths call `save()` at the same time the debounce window can be bypassed. Mitigation: `CatalogStore.save` serialises via a `MainActor`-confined queue; atomic-rename prevents partial-file corruption even if the process dies mid-write.
- **R5 — Non-git Project drift.** Leaving `gitRoot == nil` scattered through UI branches invites "forgot-to-handle" bugs. Mitigation: central predicate `Project.supportsWorktrees: Bool` and surface it in `HierarchyClient` returns; features check one thing, not scattered nils.
- **R6 — Worktree directory collisions.** Two Projects might name a worktree identically, colliding on the default path. Mitigation: `createWorktree` checks for directory existence; on collision, append a short UUID suffix and persist the resolved path on the `Worktree`.
- **R7 — Schema lock-in.** Getting the `Catalog` schema subtly wrong in v1 forces a migration later. Mitigation: this design doc is the review surface for the schema; approval here should be read as approval of the schema shape. Iterate the schema in review before code lands.

## Resolved Items (locked at approval)

At approval the following defaults are locked. Revisit via amendment only.

1. **Pane title heuristic.** `Tab.name` derives from the focused Pane's last non-empty OSC 2 title, falling back to working-directory basename when absent. Users can override via rename.
2. **`codans send` cross-pane input semantics.** Default sends text followed by `\n`. A `--raw` flag suppresses the newline for raw byte injection.
3. **Persistence debounce window.** 500ms trailing debounce on structural mutations; synchronous flush on `applicationWillTerminate` and on Worktree switch.
4. **Window close with unsaved hierarchy.** Last window close does **not** terminate the app; the app keeps running headless so `codans` clients remain served. Explicit Quit from the menu terminates. A future setting toggle may expose this; not in v1.
