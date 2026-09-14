---
name: worktree-branch-switcher-and-history-status
description: Source-review evidence and pending runtime verification for the active worktree branch-switcher user tests. This is not a test execution report.
---

# UT Status: Worktree Branch Switcher

**Parent user-test set:** [worktree-branch-switcher-and-history.md](./worktree-branch-switcher-and-history.md)
**Design:** [worktree.md](../design-docs/worktree.md)
**Last source review:** 2026-09-08
**Runtime result:** Not run in this documentation revision.

## Evidence Boundary

This companion separates existing implementation and test-source evidence from user-visible verification. The earlier status inventory included the removed embedded Diff Viewer and named UI seams that are no longer mounted. It is superseded by this review; it must not be used as evidence that the current UI passed.

All 11 active cases are **RUNTIME-PENDING**. A cited unit test means that relevant assertions exist in the source tree, not that the test was executed or passed during this review. It also does not establish the complete user journey. Record an actual execution date, revision, build, environment, outcome, and artifacts before promoting a case to PASS.

## Current Source Entry Points

| Source | Evidence available through static inspection |
|---|---|
| [WorktreeHeaderInfoLabel.swift](../../apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderInfoLabel.swift) | Two-row identity, `(detached)` fallback, hover-only chevron, branch button accessibility label. |
| [BranchSwitcherView.swift](../../apps/mac/codans/App/Features/BranchSwitcher/BranchSwitcherView.swift) | Branch-only popover, search, local/remote rendering, remote-to-existing-local target resolution. No recent-commit section is rendered. |
| [BranchRowView.swift](../../apps/mac/codans/App/Features/BranchSwitcher/BranchRowView.swift) | Row IDs use `branch_switcher.branch_row.<local-or-remote>.<short-name>`; current and blocked markers, row menu, rename controls. |
| [BranchSwitcherErrorBannerView.swift](../../apps/mac/codans/App/Features/BranchSwitcher/BranchSwitcherErrorBannerView.swift) | Error banner and dismiss identifiers. |
| [BranchSwitcherFeature.swift](../../apps/mac/codans/App/Features/BranchSwitcher/BranchSwitcherFeature.swift) | Switch, error, and HEAD-change state transitions. Cached recent-commit data is not evidence of a rendered history surface. |

The active seam inventory is maintained in the parent specification. Source declarations still require a running UI probe to confirm accessibility visibility and interaction.

## Per-case Evidence

All statuses below are **RUNTIME-PENDING**. Test names refer to source assertions only.

| Case | Existing evidence | Remaining runtime check |
|---|---|---|
| UT-BSH-HD-001 | Header source renders branch title and context row; suppresses the worktree name when it repeats the branch. | Text, layout, and visual hierarchy with the prepared fixture. |
| UT-BSH-HD-002 | Header source shows a decorative chevron only on hover when idle. | Pointer entry/exit and stable text placement; manual observation. |
| UT-BSH-HD-003 | Header source uses `(detached)`; parser test `parseBranchInventoryDetachedHEADHasNilCurrent`. | Detached header text and a usable branch button. |
| UT-BSH-BP-001 | Reducer test `popoverTappedKicksInventoryAndCommitsLoadsInParallel`; view renders only branches and search. Parser test `parseBranchInventoryFiltersOriginHEAD`. | Popover, filter, and expected branch rows visible after loading. |
| UT-BSH-BP-002 | Parser tests `parseBranchInventoryMixedLocalAndRemoteSortedAndPinned` and `parseBranchInventorySingleLocalMarkedCurrent`. | Current row first with exactly one visible current marker. |
| UT-BSH-BP-004 | View omits the remote divider and rows when the filtered remote list is empty. | Prepared no-remote fixture displays only local rows. Filtering `origin/HEAD` alone does not establish this case. |
| UT-BSH-BP-005 | Reducer test `branchTappedSetsSwitchingAndClosesPopoverThenSwitchSucceeds`; service test `switchBranchLocalIssuesPlainSwitch`. | Popover dismissal, final header state, no banner, and actual repository HEAD. |
| UT-BSH-BP-006 | Service test `switchBranchRemoteTrackingIssuesTrackFlag`. | Local tracking branch creation, upstream configuration, and displayed local name. |
| UT-BSH-BP-007 | Target resolution is in the view, which prefers a matching local branch. | Selecting `origin/main` switches to existing `main` without changing its SHA or creating a duplicate local branch. |
| UT-BSH-BP-008 | Reducer test `branchTappedSurfacesFirstLineOfGitErrorAsBanner`; service test `switchBranchPropagatesDirtyTreeError`. | Rendered failure and dismissal, unchanged HEAD, and preserved dirty file. |
| UT-BSH-VS-002 | Header declares the accessibility label `Branch <branch-title>`. | Actual VoiceOver announcement and button role. |

Test-source locations:

- [BranchSwitcherFeatureTests.swift](../../apps/mac/codans/Tests/BranchSwitcherFeatureTests.swift)
- [GitOutputParserTests.swift](../../apps/mac/codans/Tests/GitTests/GitOutputParserTests.swift)
- [LiveGitServiceBranchTests.swift](../../apps/mac/codans/Tests/GitTests/LiveGitServiceBranchTests.swift)

## Fixture Readiness

The shared fixture directory contains the multi-branch and detached bundles, catalog seeds, and matching restore scripts. Restore uses explicit refspecs to preserve the bundled remote-tracking refs. It does not configure `origin`; remote-switch cases require the disposable remote setup described in the parent specification. Catalog seeds require `__TMP__` substitution and must be checked against the current app's catalog format before a runtime run.

Fixture files being present does not mean they were restored or exercised in this review. Follow the isolation and backup rules in [user-test patterns](../user-test-patterns.md), and never seed or drive the user's active app state as a shortcut.

## Next Verification Run

1. Prepare an isolated app session and disposable fixtures, including remote configuration where required.
2. Use the available CLI and accessibility tooling under the project conventions; the absence of XCUITest alone does not rule out a human or accessibility-driven run.
3. Run the 11 active cases and record per-case outcomes and failure artifacts. Do not infer UI PASS from unit-test success.
4. Keep the retired IDs listed in the parent specification excluded from active totals. Add separate tests for external Git-client launching when that workflow is validated.
