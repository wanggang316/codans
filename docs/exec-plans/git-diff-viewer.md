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

Implementation in progress. GUI verification pending.
