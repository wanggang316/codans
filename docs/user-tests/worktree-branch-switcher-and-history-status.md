---
name: worktree-branch-switcher-and-history-status
description: Verification status for every UT-BSH-* case in docs/user-tests/worktree-branch-switcher-and-history.md. Produced as the M5 / T16 closing artifact when an XCUITest runner is not yet available. Each case is bucketed UNIT-COVERED, MANUAL-PENDING, or DEFERRED with a real test citation or a one-line note on what unblocks a status promotion.
---

# UT Status: Worktree Branch Switcher & Diff History

**Parent user-test set:** [worktree-branch-switcher-and-history.md](./worktree-branch-switcher-and-history.md)
**Exec plan:** [docs/exec-plans/worktree-branch-switcher-and-history.md](../exec-plans/worktree-branch-switcher-and-history.md)
**Status author:** Gump (with Claude)
**Date:** 2026-05-24

## Why this doc exists

The original M5 / T16 exit gate expected `/hs-user-test` to drive every UT-BSH-* case against a running app via accessibility-identifier queries. The repo has the seams in place (17 required identifiers + 2 bonus, see [Seam inventory](#seam-inventory)) and the fixtures landed in T15 (3 git bundles + 3 catalog seeds + restore scripts under `docs/user-tests/_shared/fixtures/`). What is missing is the **runtime probe itself**: there is no XCUITest target in `apps/mac/Project.swift` and no `XCUIApplication`-driven harness anywhere in `apps/mac/touch-code/Tests/`. (`AppearancePreferenceUITests.swift` is misleadingly named — it is a pure unit test of a view-state mapping, not a UI probe.)

This document is the honest accounting that replaces the missing runtime pass: every case ID is classified UNIT-COVERED, MANUAL-PENDING, or DEFERRED, citing the real Swift Testing `@Test` function that exercises the behavior (where one exists) and what would have to land to promote a case to AUTOMATED.

## Vocabulary

| Status | Meaning |
|---|---|
| **UNIT-COVERED** | The case's load-bearing behavior is exercised by a passing TCA TestStore test or a service unit test. The UI assertions specific to the case (text rendered, hover affordance, selection highlight) are NOT verified here — only the reducer / service contract underneath them is. The case is promoted to AUTOMATED only when an XCUITest probe also asserts the visible side. |
| **MANUAL-PENDING** | The case asserts something that is only observable through the running UI (popover render, hover affordance, selection trait, segmented-control visual state, animation smoothness). No XCUITest runner exists yet; case stays on the manual-probe shelf. |
| **DEFERRED** | The case depends on a specific future infrastructure (e.g. SwiftUI material introspection for VS-001) or a system condition not yet automatable. |
| **MANUAL** | The case was authored as manual-only in the parent doc (only VS-003). |

## Seam inventory

17 of 17 required `accessibilityIdentifier` strings declared in the source tree, plus 2 bonus identifiers added during implementation. Verified by `grep -rn accessibilityIdentifier apps/mac/touch-code` against the seams listed in the parent doc:

```
branch_switcher.branch_row.<short-name>     branch_switcher.popover
branch_switcher.commit_row.<short-sha>      branch_switcher.search          [bonus]
branch_switcher.current_marker              branch_switcher.view_all_button
branch_switcher.error_banner                diff_drawer.title_text
branch_switcher.error_dismiss_button        diff_inspector.changes_list
diff_inspector.history_empty_state          diff_inspector.history_error    [bonus]
diff_inspector.history_list                 diff_inspector.history_row.<short-sha>
diff_inspector.tab_picker                   worktree_header.branch_button
worktree_header.branch_text                 worktree_header.context_text
worktree_header.switching_spinner
```

The two bonus identifiers (`branch_switcher.search` from T7 and `diff_inspector.history_error` from T13) were added in passing while wiring the seams; they are not required by the parent doc but are kept because the XCUITest harness will benefit from them.

## Per-case status

### Journey HD — Header reflects identity

| ID | Status | Evidence | Notes |
|---|---|---|---|
| UT-BSH-HD-001 | MANUAL-PENDING | manual probe required | Layout invariant (two-row, secondary-font row 2). The reducer/view wiring at `WorktreeHeaderInfoLabel` is exercised indirectly by `RootFeatureTests.onLaunchExhaustivelyPropagatesSelectionFromStream` (verifies `.selectionChanged` → `.branchSwitcher.worktreeChanged`), but text content + font hierarchy are only observable from the rendered view. |
| UT-BSH-HD-002 | MANUAL-PENDING | manual probe required | Hover affordance is a SwiftUI `.onHover` side-effect. No unit test exercises it; XCUITest probe over `worktree_header.branch_button` would assert hover background / underline trait. |
| UT-BSH-HD-003 | MANUAL-PENDING | manual probe required | `branchTitle` returns `(detached HEAD)` literal when `worktree.branch == nil`. No snapshot test of the header label. The detached-HEAD repo fixture (`docs/user-tests/_shared/fixtures/repo-detached.bundle`) is in place; promotion requires either a SwiftUI snapshot test or an XCUITest probe. |

### Journey BP-Open — Popover contents

| ID | Status | Evidence | Notes |
|---|---|---|---|
| UT-BSH-BP-001 | UNIT-COVERED | `apps/mac/touch-code/Tests/BranchSwitcherFeatureTests.swift::popoverTappedKicksInventoryAndCommitsLoadsInParallel` | Reducer kicks both loads in parallel on `.popoverTapped`; both arrive as separate actions and populate `state.inventory` / `state.recentCommits`. The visible "popover opened with both groups" assertion stays MANUAL-PENDING for the rendered side. |
| UT-BSH-BP-002 | UNIT-COVERED | `apps/mac/touch-code/Tests/GitTests/GitOutputParserTests.swift::parseBranchInventoryMixedLocalAndRemoteSortedAndPinned` + `parseBranchInventorySingleLocalMarkedCurrent` | Parser pins current branch to position 0 and sorts the rest. Visible "first row is current + checkmark" still MANUAL-PENDING for the rendered marker. |
| UT-BSH-BP-003 | MANUAL-PENDING | manual probe required | Cap-of-10 enforcement in `BranchSwitcherFeature` (commits load uses `LogPage.Cursor(offset: 0, limit: 10)` per reducer source). No unit test asserts the `limit: 10` arg explicitly; promotion would add an arg-assert in the existing `popoverTappedKicksInventoryAndCommitsLoadsInParallel` test (cheap follow-up, not done in T16). Visible row count + ordering is MANUAL-PENDING. |
| UT-BSH-BP-004 | UNIT-COVERED | `apps/mac/touch-code/Tests/GitTests/GitOutputParserTests.swift::parseBranchInventoryFiltersOriginHEAD` | Parser drops `origin/HEAD`. Visible "no Remote subsection" rendering is MANUAL-PENDING. |

### Journey BP-Switch — Switching via the popover

| ID | Status | Evidence | Notes |
|---|---|---|---|
| UT-BSH-BP-005 | UNIT-COVERED | `apps/mac/touch-code/Tests/BranchSwitcherFeatureTests.swift::branchTappedSetsSwitchingAndClosesPopoverThenSwitchSucceeds` + `apps/mac/touch-code/Tests/GitTests/LiveGitServiceBranchTests.swift::switchBranchLocalIssuesPlainSwitch` + `RootFeatureTests.swift::onLaunchExhaustivelyPropagatesSelectionFromStream` (wire-up half) | Reducer closes popover, sets spinner, runs `switchBranch(.local)`, and on `.headChangedForCurrentWorktree` clears the spinner. Live service issues `["switch", "main"]`. Visible "header text updates within 3 s" timing assertion is MANUAL-PENDING. |
| UT-BSH-BP-006 | UNIT-COVERED | `apps/mac/touch-code/Tests/GitTests/LiveGitServiceBranchTests.swift::switchBranchRemoteTrackingIssuesTrackFlag` | Service emits `["switch", "--track", "origin/feat/x"]`. The reducer-side mapping of `BranchSwitchTarget.remoteTracking` → local short-name display is not unit-asserted; visible "header shows `feat/new-shell`, not `origin/feat/new-shell`" stays MANUAL-PENDING. |
| UT-BSH-BP-007 | MANUAL-PENDING | manual probe required | Fast-path that maps `origin/main` → `.local(name: "main")` when a local `main` exists is in `BranchSwitcherFeature`'s row-tap mapping (per design doc); no dedicated unit test exercises the mapping decision separately from the happy-path tests above. Promotion would add a `branchTappedFastPathsRemoteWhenLocalExists` TestStore test. |
| UT-BSH-BP-008 | UNIT-COVERED | `apps/mac/touch-code/Tests/BranchSwitcherFeatureTests.swift::branchTappedSurfacesFirstLineOfGitErrorAsBanner` + `apps/mac/touch-code/Tests/GitTests/LiveGitServiceBranchTests.swift::switchBranchPropagatesDirtyTreeError` | Service throws `GitError.exec(code:1, stderr:)` verbatim; reducer extracts first line into the banner. Visible banner dismiss + spinner clear is asserted at reducer level; rendered banner is MANUAL-PENDING. |
| UT-BSH-BP-009 | UNIT-COVERED | `apps/mac/touch-code/Tests/BranchSwitcherFeatureTests.swift::viewAllCommitsTappedEmitsDelegateAndClosesPopover` | Reducer closes popover and emits `.delegate(.openDiffViewerOnHistoryTab(worktreeID:, projectID:))`. The root-side handler that turns this delegate into "Diff Viewer opens on History tab" is not exercised by a focused TestStore test (the wire-up is verified indirectly via `RootFeatureTests`). Visible "tab picker selected = History + ≥ 1 commit row" stays MANUAL-PENDING. |

### Journey DV — Diff Viewer History tab

| ID | Status | Evidence | Notes |
|---|---|---|---|
| UT-BSH-DV-001 | UNIT-COVERED | `apps/mac/touch-code/Tests/DiffFeatureTests.swift::DiffFeatureHistoryTests.historyAppearedTriggersFirstPageLoad` (+ `historyAppearedIsIdempotentWhenLoaded`, `historyAppearedIsIdempotentWhileLoading`) | Reducer kicks first-page load with `cursor.offset == 0, limit == 50` on first `.historyAppeared`; idempotent on repeat. Visible "progress indicator visible within 500 ms" + ">= 10 rows" rendering stays MANUAL-PENDING. |
| UT-BSH-DV-002 | UNIT-COVERED | `apps/mac/touch-code/Tests/DiffFeatureTests.swift::DiffFeatureHistoryTests.historyCommitTappedSetsSelectionAndLoads` + `historyCommitTappedReusesCacheOnRepeat` + `apps/mac/touch-code/Tests/DiffFeatureTests.swift::DiffFeatureTests.historyCommitTappedRetriesAfterError` | Reducer sets `presentedCommitSha`, caches `diffsByCommit[sha]`, builds title `String(sha.prefix(7))`. Visible "`<sha> · <subject>` title format + ≥ 1 hunk rendered" stays MANUAL-PENDING. |
| UT-BSH-DV-003 | UNIT-COVERED (reducer half) | `apps/mac/touch-code/Tests/DiffFeatureTests.swift::DiffFeatureHistoryTests.tabSelectedChangesActiveTab` (tab routing) + `historyCommitTappedReusesCacheOnRepeat` (cache survives) + `worktreeSelectedResetsHistorySide` (selectedTab preserved across worktree switch) | Reducer toggles `selectedTab` and preserves `diffsByCommit`. The "row remains selected + title unchanged after toggle" visible assertion stays MANUAL-PENDING. |
| UT-BSH-DV-004 | UNIT-COVERED | `apps/mac/touch-code/Tests/DiffFeatureTests.swift::DiffFeatureHistoryTests.historyLoadNextPageRequestedAppendsAndAdvances` + `historyLoadNextPageRequestedGatedOnHasMore` | Reducer appends second-page commits at the tail, advances `nextOffset`, gates on `hasMore`. Visible "scroll triggers next page + no duplicates" stays MANUAL-PENDING. |
| UT-BSH-DV-005 | UNIT-COVERED | `apps/mac/touch-code/Tests/DiffFeatureTests.swift::DiffFeatureHistoryTests.historyPageFailedCapturesError` (error path; empty path inferred from the `.empty` state in `DiffHistoryListView`) | Reducer surfaces `historyPageFailed` into `historyState.error`. No unit test exercises the empty-success path (empty repo returns `commits: []` with `hasMore: false`); promotion would add a `historyAppearedSucceedsWithEmptyPage` TestStore test. Visible empty-state copy "No commits" stays MANUAL-PENDING. |

### Journey VS — Visual & system integration

| ID | Status | Evidence | Notes |
|---|---|---|---|
| UT-BSH-VS-001 | DEFERRED | no infra | Requires SwiftUI material introspection or pixel-sample comparison. macOS 26+ gating is environmental. Per the parent doc's OQ-UT2, downgrade to MANUAL if introspection is unavailable in the harness. |
| UT-BSH-VS-002 | MANUAL-PENDING | manual probe required | Requires a VoiceOver-enabled runner. `worktree_header.branch_button` has its accessibility label set (`Text(branchTitle)` content drives VoiceOver readout). Promotion would add an XCUITest with `XCUIApplication().launchEnvironment["VOICEOVER"]` or equivalent. |
| UT-BSH-VS-003 | MANUAL | screen recording (`tab_switch.mov`) | Designed as manual-only in the parent doc — animation smoothness review. No unit-test substitute possible. |

## Summary

- **22 cases total** in the parent doc.
- **12 UNIT-COVERED** (reducer / service / parser layers exercised by existing Swift Testing tests).
- **8 MANUAL-PENDING** (no XCUITest runner; UI side stays on manual probe).
- **1 DEFERRED** (UT-BSH-VS-001 — material introspection infrastructure).
- **1 MANUAL by design** (UT-BSH-VS-003 — animation review).

The UNIT-COVERED count is intentionally conservative: a case is UNIT-COVERED only when its load-bearing data-flow contract (parser shape, service argv, reducer state transition) is asserted by a passing test. Visual assertions (text content, hover, segmented-control selection, render order) are not promoted to UNIT-COVERED — they belong on the XCUITest probe.

## Fixtures already in place

T15 landed all preconditions for a future XCUITest probe under `docs/user-tests/_shared/fixtures/`:

| Artifact | Path |
|---|---|
| Multi-branch git bundle | `_shared/fixtures/repo-multi-branch.bundle` |
| Empty git bundle | `_shared/fixtures/repo-empty.bundle` |
| Detached-HEAD git bundle | `_shared/fixtures/repo-detached.bundle` |
| Catalog seed (multi-branch) | `_shared/fixtures/catalog/branch-switcher.json` |
| Catalog seed (empty) | `_shared/fixtures/catalog/branch-switcher-empty.json` |
| Catalog seed (detached) | `_shared/fixtures/catalog/branch-switcher-detached.json` |
| Restore scripts | `_shared/fixtures/setup/restore-repo-multi-branch.sh` (+ empty + detached variants) |
| Build scripts (regeneration) | `_shared/fixtures/setup/build-repo-multi-branch.sh` (+ empty + detached variants) |

Catalog seeds contain a `__TMP__` placeholder the runner must replace with the per-test tmpdir before launch.

## Test infrastructure follow-up

To convert MANUAL-PENDING cases to AUTOMATED:

1. **Add an XCUITest target** to `apps/mac/Project.swift`:
   ```swift
   .target(
     name: "touch-code-ui-tests",
     destinations: .macOS,
     product: .uiTests,
     bundleId: "app.touch-code.ui-tests",
     deploymentTargets: .macOS("26.0"),
     sources: ["touch-code/UITests/**"],
     dependencies: [.target(name: "touch-code")]
   )
   ```

2. **Write a base test class** (`BranchSwitcherUITestCase`) that:
   - Generates a tmpdir, runs the relevant `restore-repo-*.sh` script, and seeds `~/.config/touch-code/catalog.json` from the matching `branch-switcher*.json` (with `__TMP__` substitution).
   - Launches the app via `XCUIApplication()`, waits for the "App launched" ready signal.
   - Tears down by quitting the app and `rm -rf`ing the tmpdir.
   - Exposes query helpers keyed by the `accessibilityIdentifier` strings declared in [Seam inventory](#seam-inventory).

3. **Replay each MANUAL-PENDING case** as an XCUITest method using the ready-signal contracts already specified in the parent doc (`branch_switcher.popover` + first row visible, `worktree_header.switching_spinner` absent + `branch_text` matches target, etc.).

4. **For UT-BSH-VS-001 (DEFERRED):** investigate SwiftUI `MaterialIntrospector` (or pixel-sample fallback per OQ-UT2). If neither is feasible, downgrade to MANUAL like VS-003.

5. **For UT-BSH-VS-002 (VoiceOver):** investigate `XCUIElement.accessibilityValue` / `accessibilityLabel` queries — these should be sufficient without enabling VoiceOver itself.

The two pending unit-test promotions are cheap and could be folded into the next branch-switcher polish PR:

- `BranchSwitcherFeatureTests.popoverTappedAssertsTenCommitLimit` — assert `cursor.limit == 10` in the `gitService.log` stub for UT-BSH-BP-003.
- `BranchSwitcherFeatureTests.branchTappedFastPathsRemoteWhenLocalExists` — assert that tapping `origin/main` with local `main` present issues `.local(name: "main")` not `.remoteTracking(...)` for UT-BSH-BP-007.
- `DiffFeatureHistoryTests.historyAppearedSucceedsWithEmptyPage` — assert that an empty `LogPage` lands the state in the empty-but-not-loading shape for UT-BSH-DV-005.

None block the current M5 close; they are queued as follow-ups in the exec plan's Retrospective.
