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

## Sidebar tree revision

Approved: move Changes/Outgoing to the top of the native left sidebar. Default to a directory tree, support a flat-list toggle, preserve selection and the session-local presentation preference, and use macOS file-type icons without reading the worktree filesystem. Directories start expanded and retain collapsed state during refresh; filtering reveals matching paths. Completed: host build and 33 focused tests passed, including tree identity collision regression and presentation restoration. Real GUI verified nested selection, refresh/collapse stability, duplicate-name search, tree/list selection retention, Outgoing/base selection, close/reopen persistence, dark/auto appearance, half-screen/restore, and nested-file Cursor handoff. See the user-test record.


## Native sidebar container correction

Use the same NavigationSplitView and 220/260/320 column sizing as the main window. Remove opaque sidebar and whole-split backgrounds. Let SwiftUI manage the unified window toolbar and system sidebar toggle. Preserve the existing tree/list navigation and independent-window lifecycle. Completed: real GUI confirmed native sidebar material, titlebar integration, collapse/restore, active-window menu routing, mode/layout controls, and the restored 1000×700 initial content size. Build and 33 focused tests passed; the lifecycle test was rerun after the sizing correction and passed.


## Uncommitted, remote base, and built-in viewer defaults

Approved scope: align the compact 24-point text-only Uncommitted/Outgoing selector within the same 32-point header band as the code header; default Outgoing to remote default-branch merge-base comparison with explicit override and reset; move the main-toolbar entry to Worktree → Show Changes without changing main selection; add Built-in as the first/default Git Viewer and migrate absent/None values while preserving external choices. Verify remote/local divergence and missing-ref cases, preference decoding/normalization and command routing, then real GUI alignment/menu/settings/base switching. Completed: final build-for-testing succeeded, 51 app tests and 11 Core migration tests passed. GUI verified aligned dividers, text-only modes, the context-menu entry without changing main selection, Built-in first/default without None, command routing, and explicit-base/reset behavior. See the user-test record.


## Selectable comparison branches

Replace the free-form comparison field and Compare button with selectable remote/local branches and a Remote Default Branch option. Reuse the shared Git branch inventory, load on opening, expose retry, discard late results after context changes or closing, and apply selection immediately without checking out a branch. Verify reducer selection/loading races, native GUI groups, selected checkmarks, comparison results, and default reset.

Completed: final build-for-testing and 26 tests in four relevant suites passed. Scoped lint passed. GUI verified remote/local selection, checked state, automatic reset, and a fully visible short branch list without a text field or Compare button.
