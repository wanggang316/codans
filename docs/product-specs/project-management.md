# Product Spec: Project Management

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-21

## Summary

A **Project** is a single git repository — or in a minority case, a scratch folder — that the user has registered with codans. Projects live inside a Space and own Worktrees (or a single synthetic "main" Worktree when the Project is not git-backed). This spec covers the full Project management lifecycle: adding an existing local repository, viewing its health, renaming, configuring per-Project preferences (default editor, worktree storage path), reordering inside a Space, and removing it from codans. A Project registration is pure bookkeeping in `catalog.json` — codans **never moves, copies, or deletes files on disk** as part of Project management.

## User Stories

- As a developer onboarding a new repository, I want to pick a folder on disk and register it as a Project so it shows up in the sidebar and I can start opening terminals in its Worktrees.
- As a user who already uses git worktrees outside codans, I want the app to detect the existing worktrees of a newly-added Project so they appear alongside the main checkout without extra setup.
- As a user whose repo is in an unusual state (missing, moved, not a git repo), I want the sidebar to clearly mark the Project as failed and explain why so I can fix or remove it without confusion.
- As a user with several Projects per Space, I want to reorder them in the sidebar so my most-used Project sits at the top.
- As a user with project-specific tooling preferences, I want to set a default editor for each Project so "Open in ▾" defaults to the right app per repo.
- As a user with one-off scratch folders, I want to register a non-git folder as a Project so I can still open terminals in it, even though Worktree features don't apply.
- As a user cleaning up, I want to remove a Project from codans without deleting the repository on disk.

## Requirements

### Must Have

- [ ] **Add Project — pick existing folder.** Sidebar "+ Add Project" button opens a macOS folder picker (`NSOpenPanel`). The chosen folder is validated and classified as one of:
  - **Git repo** — folder contains `.git/` (or is a git worktree pointing back to a main repo); codans records `rootPath` and resolved `gitRoot`, and enumerates existing worktrees.
  - **Non-git folder** — folder does not contain a git repository; codans records `rootPath` only, with `gitRoot = nil`. A single synthetic "main" Worktree pointing at `rootPath` is created; the sidebar "+ Worktree" affordance is disabled for this Project.
- [ ] **Scope check.** The chosen folder must not already be registered as a Project in any Space; if it is, surface an inline error with a "Reveal existing Project" action.
- [ ] **Project name.** Default name is the folder's last path component; user can edit the name inline at add-time and later via rename. Max 64 chars, min 1 char after trim.
- [ ] **Worktree discovery on add.** For a git-backed Project, populate the Worktree list by reading existing `git worktree list` output via the bundled `git-wt` helper. The main checkout is always present; pre-existing worktrees appear in the sidebar immediately.
- [ ] **Health state per Project.** Each Project has a load state surfaced in the sidebar:
  - `ready` — Project resolved; Worktrees visible.
  - `loading` — initial scan or reconcile in progress (brief, usually sub-second).
  - `failed(reason)` — path missing, not a git repo anymore, or scan error. Reasons shown as a human-readable message in a failure row with "Retry" / "Remove" actions.
- [ ] **Reconcile on app launch and on window focus.** For every registered Project, re-check existence and refresh the Worktree list. New worktrees added outside codans appear; removed worktrees are pruned from the sidebar (with the same "Project last-active Worktree" safety behavior the model already handles).
- [ ] **Rename Project** inline from the sidebar row context menu. Same validation as add-time.
- [ ] **Reorder Projects** inside a Space by drag. Order is persisted and honored across launches.
- [ ] **Per-Project default editor.** A per-Project override for the Worktree-header "Open in ▾" default; falls back to the global default editor when unset. Already specified by C8; this spec references the existing contract.
- [ ] **Per-Project worktree storage path.** Editable in a "Project options" surface. Default value is `~/.codans/repos/<project-name>/`. Users can override per Project (e.g. point at a sibling of the repo). Empty / invalid paths are rejected inline. See [Worktree Management spec](worktree-management.md) for how this path is consumed.
- [ ] **Remove Project.** Context-menu action on a Project row, with confirmation. Removal is **data-only**:
  - Unregisters the Project from the Space in `catalog.json`.
  - Closes all tabs and panels belonging to the Project's Worktrees.
  - Does **not** run `git worktree remove`, does **not** delete the repository directory, does **not** delete the worktrees directory.
  - The confirmation copy must state "Files on disk are not affected" so intent is unambiguous.
- [ ] **No-clone guarantee.** v1 does not clone or fetch repositories from remote URLs. The Add Project flow only accepts existing local folders. If a user tries to register a folder that doesn't exist yet, the picker cannot even surface it.

### Nice to Have

- [ ] **Drag-to-add.** Dropping a folder from Finder onto the sidebar triggers the Add Project flow pre-filled with that path.
- [ ] **Project description / note.** A free-text blurb editable in Project options, shown as tooltip on the sidebar row.
- [ ] **Recently-removed Projects** — undo a removal within 10 seconds via a toast.
- [ ] **Per-Project section collapse memory.** Each Project section in the sidebar remembers its expanded/collapsed state per Space (independent of other Spaces where the same Project path may or may not exist — not allowed in v1 anyway).

## Acceptance Criteria

- **Given** the user clicks "+ Add Project" and picks a folder containing a `.git` directory, **when** the picker closes, **then** the Project appears in the current Space with status `ready`, its main Worktree is selected, and any additional pre-existing worktrees are listed.
- **Given** the user picks a folder that has no `.git`, **when** they confirm, **then** the Project is registered as a non-git Project, a single synthetic Worktree pointing at the folder appears, and the sidebar "+ Worktree" affordance on that Project is disabled (tooltip explains why).
- **Given** the user picks a folder that is already registered as a Project in any Space, **when** they confirm, **then** the add is rejected with an inline error and a "Reveal existing Project" action jumps to the existing row.
- **Given** a Project whose on-disk folder was deleted since last launch, **when** the app starts, **then** the Project appears with status `failed(reason: "folder no longer exists at <path>")` and offers "Retry" and "Remove" actions.
- **Given** a Project in `failed` state, **when** the user clicks "Retry" after fixing the folder, **then** the state resolves to `ready` without re-entering the Add Project flow.
- **Given** a git-backed Project with three pre-existing worktrees created outside codans, **when** the Project is added, **then** all three worktrees appear in the sidebar immediately with correct branch labels.
- **Given** the user renames a Project, **when** they confirm, **then** the Project row, terminal tab titles, and any Project references in header text update immediately. The worktrees directory default (`~/.codans/repos/<project-name>/`) is **not** auto-renamed — existing worktree paths on disk are preserved untouched.
- **Given** the user removes a Project, **when** they confirm, **then** the Project disappears from the sidebar, all its terminals are closed, and the repository folder and its worktree directories remain on disk unmodified.
- **Given** a Project has a per-Project default editor set to Cursor, **when** the user clicks the Worktree-header "Open in" button without a picker, **then** Cursor opens — not the global default.
- **Given** a user edits the worktree storage path to `/tmp/wt-custom/<name>` in Project options, **when** they next create a Worktree for that Project, **then** the new worktree is created under that path.

## Scope

### In Scope

- Register / reconcile / rename / reorder / remove existing local Projects (git-backed and non-git).
- Per-Project default editor and worktree storage path overrides.
- Health state visibility and recovery affordances (retry, remove).

### Out of Scope (v1)

- **Clone from URL** — no network-backed Project creation. Users who want to clone run `git clone` in a terminal (or in a future version) and then register the resulting folder.
- **Initialize a new repo** (`git init`) from inside codans.
- **Import from GitHub / GitLab integration.**
- **Move a Project between Spaces.**
- **Bulk operations** (add many folders at once, remove all Projects in a Space with one action).
- **Project-level search / tags / filtering** beyond the sidebar tree.
- **Editing `.git/worktrees` config manually from the UI.**

### Future Consideration

- Clone from URL with progress UI and branch selection.
- `git init` on an empty folder as part of Add Project.
- GitHub-integration-assisted Add (authenticated remote browse → local clone).

## Design

This spec is deliberately product-facing; it does not prescribe TCA shapes, reducer structure, or persistence wiring. Relevant references for the follow-up design doc:

- **supacode** — `RepositoryPersistenceClient` persists just the list of roots; the full Repository state is computed on launch (`/Users/wanggang/dev/opensource/supacode/supacode/Clients/Repositories/RepositoryPersistenceClient.swift`). supacode's "FailedRepositoryRow" is the `failed(reason)` UX we're adopting.
- **Existing code** — `CodansCore/Project.swift` already has `rootPath`, `gitRoot`, `worktreesDirectory`, `defaultEditor`, and `supportsWorktrees`. The data model is adequate; the gap is user-facing flow and reconciliation.
- **C8 editor override** — per-Project default editor is already wired through `HierarchyClient.setDefaultEditor`; this spec only affirms its UI surface belongs in Project options.

## Open Questions

1. **`worktreesDirectory` rename on Project rename** — when the user renames a Project, the default worktree path still contains the *old* name. Do we rename the on-disk directory, or keep existing paths and only apply the new name to *future* worktrees? *Leaning:* keep existing paths untouched; new Worktrees use the new name. Acceptance criteria above reflect this leaning.
2. **Project-options surface** — sheet, inspector, or Settings section? *Leaning:* sheet triggered from the Project row's `⋯` menu; per-Project edits should feel lightweight.
3. **Add-Project progress UI for slow disks** — spin inline in the row, or block in a modal, if the initial worktree scan takes >500ms? *Leaning:* inline spinner on the row; never block the window.
4. **Non-git Project affordances** — besides disabling "+ Worktree", do we also hide the branch label in the header row and the git-viewer toggle? *Leaning:* yes — both become inert for non-git Projects.
