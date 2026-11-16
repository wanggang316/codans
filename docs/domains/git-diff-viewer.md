# Git Diff Viewer

The Git Diff Viewer is a read-only window that shows the changes of one Worktree. It answers two questions: "what did I change and not commit?" (Uncommitted) and "what does my branch add to its base?" (Outgoing). It reads git and never writes to the repository: it does not fetch, stage, discard, commit, push, or resolve conflicts. A `git fetch` in a Pane updates the local refs, and the next refresh shows the result.

Availability: Available, for local and Remote Projects. Hidden: the Staged and Unstaged comparisons (the git service and the reducer support them; no control selects them).

## Scope and ownership

| Topic | Owner |
|---|---|
| Pull Request data, including its target ref | [Git Platform](git-platform.md) |
| Editor choice, file opening, and the external Git Viewer setting | [Editor Integration](editor-integration.md) |
| Sidebar Worktree row, its diff chip, and the window toolbar | [Main Window](main-window.md) |
| SSH transport of git calls | [Remote Projects](remote-projects.md) |

## Comparisons

| Comparison | Left side | Right side |
|---|---|---|
| Uncommitted | `HEAD`, or the empty tree before the first commit | Working directory, untracked files included |
| Outgoing | Merge base of the base ref and `HEAD` | `HEAD` |

- Uncommitted adds untracked files (`--exclude-standard`) and marks unmerged paths as conflicts.
- Outgoing shows only committed changes. Pushing does not clear it. Commits that exist only on the base do not show as reversed edits, because the left side is the merge base.
- Git is the authority for the file status, rename detection, and line counts. The renderer computes its own hunks from the two texts, so its hunk grouping can differ from git.

### The base of Outgoing

The base is either an explicit ref or the remote default branch:

1. **Explicit.** The "Against <base>" control at the bottom of the sidebar opens a popover with Remote Default Branch, the remote branches, and the local branches. A row applies at once; there is no free-form input. The branch list loads each time the popover opens, offers Retry on failure, and drops late results.
2. **Remote default branch.** The target of `refs/remotes/origin/HEAD`, then `origin/main`, then `origin/master`, each as a fully qualified remote-tracking ref.

Rules:

- No fallback. An explicit base that does not resolve shows the git error. With no remote default branch, the window shows an error that asks for a fetch or a chosen base; it never falls back to a local `main`.
- No common ancestor (unrelated histories) is an error.
- The resolved base label is always shown in the control.
- The Pull Request target does not choose the base. The window receives `baseRefName` and `baseRepositoryURL` of the Worktree's Pull Request snapshot and keeps them in its state, but no comparison reads them. Do not derive a target from the branch name when they are missing: a fork Pull Request targets another repository.

## Data path

```
 git (local, or over SSH) ──► LiveGitService+Comparison ──► GitComparisonSnapshot
                                                              │ files, status, counts,
                                                              │ blob IDs, modes, base label
 DiffWindowManager ──► DiffFeature (one store) ◄──────────────┘
                          │ selected file ──► comparison content (old text, new text, or notice)
                          ▼
                    DiffPanelView ──► DiffView (DiffViewKit, WKWebView)
                          ▲                │ events: rendered, openFile(side, line), error
                          └────────────────┘
```

- A comparison is a typed, scope-aware `GitComparisonSnapshot`. One `git diff --raw --numstat -z` call gives the tracked files with their status and counts. The fingerprint covers the diff output, the scope, the base label, and the paths.
- **List first.** When nothing is on screen for a scope, the file list shows before the line counts of untracked files are read; the totals show "—" until then. A refresh with a snapshot on screen swaps in the complete comparison at once, so the totals do not flicker.
- **Content per file.** Old and new texts come from blob IDs that the snapshot resolved. For Uncommitted, the new side is the current working file, read again at each load; the index and the working directory are not one atomic snapshot.
- **Bounded content.** Each side is capped at 2 MiB. Binary, non-UTF-8, symlink, submodule, conflict, empty, metadata-only, and oversized changes show a notice instead of a diff, never a truncated text.
- **Path safety.** A working file read refuses absolute paths, `..`, and any symbolic link on the path. On a Remote Host the read runs as a small `sh` script with the path in positional arguments, never in the shell text.
- **Same transport.** All calls go through `GitService` with the `HostID` of the Project, so a Remote Project uses the same SSH routing as the rest of the app. A Project directory without a git repository shows "This directory is not a Git repository."
- **Generations.** The comparison, the file content, and the branch list each carry a request number. A response with an old number is dropped, so a late result of another scope, file, or Worktree never shows.

## The renderer

DiffViewKit is a separate component: a Swift wrapper around HTML, JavaScript, and CSS, from its own repository. The app takes it as a SwiftPM dependency pinned by exact version in `apps/mac/Tuist/Package.swift`. Each tag commits the built web resources, so the app build needs no npm, CDN, server, or local checkout of the component. To change the renderer, change and tag the component, then bump the exact version and regenerate.

The boundary between the app and the renderer:

- The app gives a `DiffDocument` (ID, path, old text, new text) and options: layout, light or dark theme from the window appearance, and `chrome: "none"`. The renderer draws only code, edge to edge; the native window owns the path header, line counts, and all controls.
- The renderer sends events back. The app ignores an event whose document ID is not the current one. `openFile` carries the side and the line; the renderer never starts an editor itself.
- The app makes a new document ID only when the path or a text changes, so a refresh with unchanged content does not redraw.
- The web view stays mounted across loading, scope, and file changes. A renderer error shows a message; Refresh then recreates the web view.

## The window

There is one diff window in the app. Opening it for another Worktree retargets the same window; it does not open a second one. The title is "<Project> — <branch>". Changing the main-window selection never retargets the window. The window is a normal, resizable window, not a sheet or a panel. Its frame persists through AppKit autosave. The standard close button and ⌘W close only this window, never a terminal Tab, and closing it cancels all its work and releases the web view.

For each Worktree, the window remembers the comparison, the base, the selected file, the file presentation, and the layout, in memory for the app session. A switch between Uncommitted and Outgoing shows the last snapshot of that comparison at once, while a refresh runs.

- **Sidebar.** At the top, the Uncommitted / Outgoing selector. Below it, the file count with total line counts (all files, the filter does not apply), a tree / list switch, and a filter field. The tree is the default; it lists folders before files and keeps the collapse state across refreshes. Selecting a file reveals its folders. A file row has an "Open in Editor" context menu item.
- **Detail.** A header with the selected path and its line counts, then the renderer. The window toolbar holds the unified / split layout control and Refresh.
- **States.** A loading indicator appears only when loading is slow, and never for a background refresh. An empty comparison says so ("No changes in this worktree." or "No committed changes against this base."). A failed comparison shows the error in place of the code. A failed file shows its notice in place of the code; the file list stays.

## Refresh

The window loads on open, on a change of comparison or base, and on Refresh. While it is open, it reloads every two seconds; a tick is skipped while a comparison or a file is still loading, so loads never overlap. The tick catches changes that no file event shows: index updates, `HEAD` moves, and fetched remote refs. A tick reloads the selected file but keeps the renderer document when the text is the same.

## Opening a file in an editor

The window opens the current file of the Worktree, through the editor choice of the Project or the global default (see [Editor Integration](editor-integration.md)).

- Only the new side can open. The old side and a deleted file show a message instead; their lines are historical.
- Outgoing opens the file without a line, because the line in `HEAD` need not be the current line.
- Uncommitted reads the file again before it sends the line. If the text changed since it was drawn, the file opens without a line.
- The "Open in Editor" context menu item opens the file without a line, also for files that show a notice.
- Line navigation depends on the editor; an editor without line support opens the file only.

## Entry points

| Entry point | Opens |
|---|---|
| Worktree context menu in the sidebar: "Show Uncommitted", "Show Outgoing" | The built-in window, for the clicked row, with that comparison. The selection does not change. |
| Same menu when an external Git Viewer is set: "Show Changes" | The external client |
| Worktree menu and command palette: "Show Changes" | The built-in window, for the selected Worktree |
| Worktree menu and command palette: "Toggle Git Viewer", and its shortcut | The external client if one is set, else the built-in window |

"Toggle Git Viewer" opens or focuses the window; it does not close it. Without an explicit comparison, the window opens on the one remembered for the Worktree, else Uncommitted.

The `+N −M` diff chip on a sidebar Worktree row shows the totals of the Uncommitted comparison: it calls the same comparison, so the chip and the window agree. The chip is not a control; it does not open the window.

## Traps

- The window keeps the Pull Request target but does not use it. A change that makes Outgoing follow the Pull Request must handle a missing target and a target in another repository.
- A refresh does not fetch. A stale remote default branch gives a stale Outgoing until a fetch.
- The reads of the index and of the working files are separate git calls. A write between them can show a mixed state for one refresh.
