# Sidebar update cost

## Scope

Remove filesystem queries from sidebar rendering and limit agent activity
updates to the views that display them. Preserve workspace ownership guards,
native selection, project ordering, and Agents View auto-open behavior.

## Implementation

1. Build a workspace membership index from catalog identity and path fields.
   Rebuild only when those fields change; keep live path queries for commands.
2. Publish agent activity projections only when their values change. Isolate
   worktree activity rendering from the hierarchy list.
3. Cover membership aliases, invalidation, and unchanged-state observation.

## Validation

- Run focused core, hierarchy, and agent-state regression tests.
- Build the app and run `make mac-check`; preserve unrelated existing files.
- Compare runtime samples only after testing the changed build. The initial
  production sample is diagnostic evidence, not validation of this change.

## Status

Implemented and validated on 2026-10-22.

- Core: 10 tests passed across `WorkspaceMembershipIndexTests` and
  `WorkspaceCatalogTests`.
- App: unsigned Debug build succeeded; 158 tests passed across seven suites:
  hierarchy, workspace, run-script panes, sidebar behavior and ordering, and
  agent screen/program status. This run used the final implementation.
- `git diff --check` passed.
- `make mac-check` failed because the formatter adds trailing call commas that
  the current SwiftLint configuration rejects. Its unrelated edits were removed.
- Targeted lint reports only the existing image accessibility violation in
  `HierarchySidebarView.appIcon`; the unchanged HEAD file reports the same issue.
- The first red-test attempt stopped at the worktree build environment, before
  test execution. Do not count that attempt as a behavioral regression result.
- No runtime performance comparison of the changed build has been completed.
