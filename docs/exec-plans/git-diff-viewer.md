# Git Diff Viewer Execution Plan

## Objective

Integrate the independent DiffViewKit WKWebView component into Codans for read-only Changes and Outgoing inspection, support editor handoff, and verify real GUI behavior. Commit verified changes in both repositories; do not push.

## Scope and ownership

- Independent component: reproducible offline Swift package, pinned vendored snapshot in Codans.
- Git data: typed scope-aware snapshots and bounded file content through the existing local/SSH Git transport.
- UI: Worktree-level resizable/expanded panel, file list, All/Staged/Unstaged and Outgoing, explicit base, loading/error/empty states.
- Editor: current-file opening with supported line locations, explicit historical/deleted limitations.
- Validation: unit/integration tests, build/lint, isolated application GUI fixtures and case record.

## Sequence

1. Commit the verified independent component and create a reproducible export artifact.
2. Implement Git comparison data and editor dispatch in parallel with panel/package integration.
3. Generate/build the application, resolve compile/lint issues, run focused tests.
4. Run GUI cases in an isolated development app profile with fixture repositories.
5. Fix observed failures, repeat affected cases, update documentation and commit final changes.

## Acceptance matrix

- Changes All/Staged/Unstaged display consistent files and content, including untracked.
- Outgoing compares merge-base(target, HEAD) to HEAD; pushed commits remain visible; target-only commits do not appear as deletions.
- Unified/split, themes, file filter, selection, resizing, expand/close work.
- File/line editor requests do not reinterpret historical lines as current lines.
- Refresh after content/index/HEAD changes, switching files/worktrees and late results stays consistent.
- Empty/no-base/unborn/binary/conflict/deletion/rename/large-file cases have explicit outcomes.
- Terminal session survives and focus returns after close.
- GUI evidence records actual pass/fail/not-exercised; no unexecuted remote tests are claimed passed.

## Status

Completed: independent component exported, Codans integration built, 26 focused app tests and 6 Core tests passed, and local GUI fixture cases including narrow/wide layouts and editor line navigation passed. The verification record explicitly excludes actual SSH, live PR discovery, and forced Web-content process termination. Full-repository lint has 61 pre-existing errors; scoped new/final UI files pass. Changes are committed without pushing.

## Independent window revision

Approved: replace the terminal split with one normal NSWindow per worktree. Reopening focuses the existing window; changing the main selection does not retarget open windows. Closing cancels work and releases the renderer while preserving scope/base/file preferences and frame. The terminal hierarchy and geometry remain untouched.

Validation completed: build-for-testing succeeded; 27 focused tests passed. GUI verified repeated open/close, multiple worktrees, zoom/restore, selection isolation, and unchanged terminal dimensions (37 × 78 with zero WINCH events). Command-W and red close affect only the Diff window. Multi-display and exhaustive Agent CLI visual matrices are not claimed.

## Native presentation revision

Approved: remove All/Staged/Unstaged, Open Selected File, and the large Web footer action. Changes uses the aggregate HEAD-to-working-tree comparison. Match existing Settings/sidebar patterns: real unified window toolbar, system typography, compact sidebar rows, native file summary header, and an edge-to-edge Web code surface. Toolbar owns Changes/Outgoing, unified/split, and refresh. Outgoing base selection is a compact sidebar popover. Editor line navigation remains, with a file context menu for notices without line numbers. Validation completed: component 6 JavaScript / 5 WebKit / 6 Swift tests, host build and 27 focused tests passed. Real GUI verified native toolbar actions, explicit base selection, dark/auto appearance, half-screen/restore layout, removed controls, and Cursor line-4 navigation.
