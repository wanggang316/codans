---
name: worktree-branch-switcher-and-history
description: User-test set for the Worktree Branch Switcher & Diff History feature — header two-row layout, click-to-switch popover, branch switching, and Diff Viewer Changes/History tabs. Authored by /hs-test-spec. Read docs/user-test-patterns.md for project-wide testing conventions before editing.
---

# User Tests: Worktree Branch Switcher & Diff History

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-05-24
**Spec:** [docs/product-specs/worktree-branch-switcher-and-history.md](../product-specs/worktree-branch-switcher-and-history.md)
**Design:** [docs/design-docs/worktree-branch-switcher-and-history.md](../design-docs/worktree-branch-switcher-and-history.md)

## Personas Used

- `git_branch_navigator` — switches between feature branches inside the app multiple times per session; drives the header + popover + switch journeys.
- `history_browser` — opens Diff Viewer to read past commits without changing branch; drives the History tab journeys.

Both personas are new and were added to `docs/user-tests/_shared/personas.yaml` as part of this document; see [Personas / Fixtures Added](#personas--fixtures-added-during-authoring).

## Shared Fixtures

| Fixture | Path | Purpose |
|---|---|---|
| Multi-branch repo bundle | `_shared/fixtures/repo-multi-branch.bundle` | git bundle restored to `<tmp>/repo-multi-branch` before app launch. Contains local branches `main`, `feat/header-redesign`, `bugfix/menu`; a remote `origin` with `origin/main`, `origin/feat/new-shell`, `origin/HEAD → origin/main`; ≥ 60 commits on `main` (for pagination); HEAD checked out on `feat/header-redesign`. |
| Empty repo bundle | `_shared/fixtures/repo-empty.bundle` | git repo with `git init` only — no commits, no remotes, no branches. Restored to `<tmp>/repo-empty`. |
| Detached-HEAD repo bundle | `_shared/fixtures/repo-detached.bundle` | Same content as `repo-multi-branch.bundle` but with HEAD detached at the third commit of `main`. Restored to `<tmp>/repo-detached`. |
| Catalog seed (multi-branch) | `_shared/fixtures/catalog/branch-switcher.json` | `catalog.json` with one Project `"playground"` whose root and only Worktree both point at `<tmp>/repo-multi-branch`. |
| Catalog seed (empty repo) | `_shared/fixtures/catalog/branch-switcher-empty.json` | Same shape, pointing at `<tmp>/repo-empty`. |
| Catalog seed (detached) | `_shared/fixtures/catalog/branch-switcher-detached.json` | Same shape, pointing at `<tmp>/repo-detached`. |

All bundles are checked into the repo as small git-format bundles (≤ 200 KB each). The runner is responsible for `git clone <bundle> <tmp>/...` (or `git bundle unbundle …` + `git reset`) into a fresh tmpdir before launch, and removing the tmpdir on teardown.

## Source-Code Seams

These accessibility identifiers must be declared by the implementation (per patterns doc, brittle selectors are forbidden). The test runner queries elements by these identifiers — if a case fails because an identifier is absent, the implementation is missing the seam, not the test.

| Identifier | Surface |
|---|---|
| `worktree_header.branch_button` | Tap target on header row 1 (branch name + chevron). |
| `worktree_header.branch_text` | The branch-name text element on row 1. |
| `worktree_header.context_text` | `folder · project` text on row 2. |
| `worktree_header.switching_spinner` | Spinner element replacing the chevron during a switch. |
| `worktree_header.git_viewer_toggle` | Toolbar button (trailing cluster) that opens/closes the Diff Inspector — same action as ⌘⇧G. |
| `branch_switcher.popover` | Popover container view. |
| `branch_switcher.branch_row.<local\|remote>.<short-name>` | One row per branch. `<short-name>` is the branch's short ref (e.g. `main`, `origin/feat/new-shell`); the `local`/`remote` segment disambiguates rare collisions when a local branch happens to share its short name with a remote ref. |
| `branch_switcher.current_marker` | Checkmark element on the current row. |
| `branch_switcher.commit_row.<short-sha>` | One row per recent commit. |
| `branch_switcher.history_button` | Inline "History" button on the Branches section header that opens the Diff Inspector's History tab. |
| `branch_switcher.branch_row.menu_button.current` | Hover-revealed ellipsis (`...`) menu button on the current branch row. The menu contains `Rename…`. |
| `branch_switcher.branch_row.menu_button.checkout` | Hover-revealed ellipsis (`...`) menu button on non-current, non-blocked branch rows. The menu contains `Checkout`. |
| `branch_switcher.branch_row.blocked_marker` | `+` icon in the leading slot of rows whose branch is currently checked out in another worktree of the same project. Replaces the checkmark slot. |
| `branch_switcher.rename_field` | Inline TextField that replaces the current branch's name while the user is editing the rename draft. |
| `branch_switcher.rename_spinner` | Mini spinner shown next to the TextField while the `git branch -m` effect is in flight. |
| `branch_switcher.error_banner` | Inline error banner displayed under the header. |
| `branch_switcher.error_dismiss_button` | The banner's close button. |
| `diff_inspector.tab_picker` | Segmented control (Changes / History). |
| `diff_inspector.close_button` | Close button in inspector header. |
| `diff_inspector.changes_list` | Existing changed-files list container (renamed if currently unidentified). |
| `diff_inspector.history_list` | History list container. |
| `diff_inspector.history_row.<short-sha>` | One row per commit in History tab. |
| `diff_inspector.history_empty_state` | Empty-state element in History tab. |
| `diff_drawer.title_text` | Left-side title text (file path or `<sha> · <subject>`). |

## Ready Signals

In addition to the project's standard "App launched" signal, cases in this document use:

- **"Popover opened"** — `branch_switcher.popover` is visible AND either `branch_switcher.branch_row.<current>` or `branch_switcher.commit_row.*` is visible (whichever loads first).
- **"Switch settled"** — `worktree_header.switching_spinner` is absent AND `worktree_header.branch_text` reads the requested target's short name.
- **"History first page loaded"** — `diff_inspector.history_list` is visible AND at least one `diff_inspector.history_row.*` element exists AND no progress indicator is visible in the list.

## Journeys

### Journey HD: Header reflects identity at a glance

**Persona:** `git_branch_navigator`
**Outcome:** Opening worktree detail shows current branch on row 1 and `folder · project` on row 2; the row is visibly interactive.

#### Case `UT-BSH-HD-001`: Two-row header on a git worktree

**Covers AC:** AC-HD-1

**Preconditions:**
- Catalog seed `_shared/fixtures/catalog/branch-switcher.json` placed at `~/.config/touch-code/catalog.json` (Worktree HEAD = `feat/header-redesign`).
- Multi-branch repo bundle restored to `<tmp>/repo-multi-branch`.
- App started; "App launched" ready signal observed.

**Steps:**
1. Select the only Worktree in the only Project (sidebar single row).
2. Wait until `worktree_header.branch_text` is visible.

**Assertions:**
1. (UI) `worktree_header.branch_text` reads `feat/header-redesign`.
2. (UI) `worktree_header.context_text` reads `repo-multi-branch · playground` (worktree folder name · project name, joined by ` · `).
3. (UI) `worktree_header.context_text` is rendered in a smaller font than `worktree_header.branch_text` (visually secondary — verified by the runner reading the resolved font size and confirming it is strictly smaller).

**Artifacts on FAIL:** `screenshot.png` of the worktree detail header.

#### Case `UT-BSH-HD-002`: Header row 1 is visibly interactive

**Covers AC:** AC-HD-2

**Preconditions:**
- State at end of `UT-BSH-HD-001`.

**Steps:**
1. Move the pointer over `worktree_header.branch_button`.
2. Wait until `worktree_header.branch_button`'s hover state is reflected (background fill present OR underline trait set on `worktree_header.branch_text`).
3. Move the pointer away.

**Assertions:**
1. (UI) After step 2: `worktree_header.branch_button` reports an explicit hover affordance — either an `isHovered` accessibility trait OR a non-default background colour OR an underlined `worktree_header.branch_text`.
2. (UI) After step 3: the hover affordance is removed (pointer-off state matches the initial-state snapshot from step 0).

**Artifacts on FAIL:** screenshots before/after hover.

#### Case `UT-BSH-HD-003`: Detached HEAD renders explicit text

**Covers AC:** AC-HD-3

**Preconditions:**
- Catalog seed `_shared/fixtures/catalog/branch-switcher-detached.json`.
- Detached-HEAD repo bundle restored to `<tmp>/repo-detached`.
- App started.

**Steps:**
1. Select the only Worktree.
2. Wait until `worktree_header.branch_text` is visible.

**Assertions:**
1. (UI) `worktree_header.branch_text` matches the regex `^\(detached( @ [0-9a-f]{7,12})?\)$`.
2. (UI) `worktree_header.branch_button` is still hittable (the click target exists; see Journey BP for its behaviour on detached HEAD).

**Artifacts on FAIL:** `screenshot.png` of the header.

### Journey BP-Open: Popover contents

**Persona:** `git_branch_navigator`
**Outcome:** Clicking the branch button opens a popover with a Branches group and a Recent Commits group, both correctly populated.

#### Case `UT-BSH-BP-001`: Popover opens and shows both groups

**Covers AC:** AC-BP-1

**Preconditions:**
- State at end of `UT-BSH-HD-001`.

**Steps:**
1. Click `worktree_header.branch_button`.
2. Wait for the "Popover opened" ready signal (≤ 1 s observed).

**Assertions:**
1. (UI) `branch_switcher.popover` is visible.
2. (UI) The popover contains a section header with text `Branches` AND a section header with text `Recent commits` (or the equivalent localized labels in the active locale).
3. (UI) At least one `branch_switcher.branch_row.*` exists.
4. (UI) At least one `branch_switcher.commit_row.*` exists (within ≤ 2 s of step 2 — the two loads run in parallel and the slower one settles within this window).

**Artifacts on FAIL:** `screenshot.png` of the popover.

#### Case `UT-BSH-BP-002`: Current branch is marked and pinned to top

**Covers AC:** AC-BP-2

**Preconditions:**
- State at end of `UT-BSH-BP-001` (popover open).

**Steps:**
1. Read the ordered list of `branch_switcher.branch_row.*` elements in the Branches section.

**Assertions:**
1. (UI) The first row in the Branches section is `branch_switcher.branch_row.feat/header-redesign` (the current branch).
2. (UI) That row contains `branch_switcher.current_marker` (checkmark).
3. (UI) No other row contains `branch_switcher.current_marker`.

**Artifacts on FAIL:** `screenshot.png` of the popover.

#### Case `UT-BSH-BP-003`: Recent commits group lists exactly 10 rows on a repo with ≥ 10 commits

**Covers AC:** AC-BP-7

**Preconditions:**
- State at end of `UT-BSH-BP-001`.
- The current branch (`feat/header-redesign`) has ≥ 10 commits in its history (the bundle guarantees this; the multi-branch fixture's HEAD branch is rebased onto main + ≥ 5 local commits).

**Steps:**
1. Count the `branch_switcher.commit_row.*` elements in the Recent commits section.
2. Read the displayed subject of the first row.

**Assertions:**
1. (UI) Exactly 10 `branch_switcher.commit_row.*` elements are present.
2. (UI) The first row's subject matches the subject of the current HEAD commit, as obtained by running `git -C <tmp>/repo-multi-branch log -n 1 --format=%s HEAD` before the test and capturing the value into the runner.
3. (UI) Rows are ordered with newest first (each row's row index increasing matches monotonically older commit dates per `git log --format=%aI`).

**Artifacts on FAIL:** `screenshot.png` of the popover + `git_log.txt` snapshot of `git log -n 10 --format=%H%x09%s` against the repo.

#### Case `UT-BSH-BP-004`: No remote → no Remote subsection rendered

**Covers AC:** AC-BP-6

**Preconditions:**
- A variant of the multi-branch fixture without any remote: before app launch, the runner runs `git -C <tmp>/repo-multi-branch remote remove origin`.
- Catalog still points at `<tmp>/repo-multi-branch`.
- App started; popover opened on the Worktree per Journey BP-001 steps 1–2.

**Steps:**
1. With the popover open, read the Branches section content.

**Assertions:**
1. (UI) No `branch_switcher.branch_row.origin/*` element exists.
2. (UI) No section header / divider labelled `Remote` (or equivalent) is present.
3. (UI) Local branches are still rendered (`branch_switcher.branch_row.main`, `.feat/header-redesign`, `.bugfix/menu` are visible).

**Artifacts on FAIL:** `screenshot.png` of the popover.

### Journey BP-Switch: Switching via the popover

**Persona:** `git_branch_navigator`
**Outcome:** The user selects another branch in the popover and the worktree is on that branch; the UI reflects the in-flight switch and any errors.

#### Case `UT-BSH-BP-005`: Local-branch switch updates the header

**Covers AC:** AC-SW-1, AC-SW-2

**Preconditions:**
- State at end of `UT-BSH-BP-001` (popover open on a clean worktree, current branch `feat/header-redesign`).

**Steps:**
1. Click `branch_switcher.branch_row.main`.
2. Immediately (within 100 ms of click) read `worktree_header.switching_spinner` and `worktree_header.branch_text`.
3. Wait for the "Switch settled" ready signal targeting `main`.

**Assertions:**
1. (UI) Within ≤ 200 ms of step 1: `branch_switcher.popover` is no longer visible.
2. (UI) During step 2: `worktree_header.switching_spinner` is visible AND `worktree_header.branch_text` still reads `feat/header-redesign`.
3. (UI) After step 3 settles (≤ 3 s end-to-end): `worktree_header.switching_spinner` is absent.
4. (UI) After step 3: `worktree_header.branch_text` reads `main`.
5. (UI) After step 3: `branch_switcher.error_banner` is absent.
6. (Repo) After step 3: `git -C <tmp>/repo-multi-branch rev-parse --abbrev-ref HEAD` returns `main`.

**Artifacts on FAIL:** `screenshot.png` of the header at first failed assertion + `git_head.txt` snapshot.

#### Case `UT-BSH-BP-006`: Remote-only branch switch creates a local tracking branch

**Covers AC:** AC-BP-3

**Preconditions:**
- State at end of `UT-BSH-HD-001`.
- Confirm the local repo has no branch named `feat/new-shell`: runner asserts `git -C <tmp>/repo-multi-branch branch --list feat/new-shell` is empty (fixture-guaranteed).
- Popover opened.

**Steps:**
1. Click `branch_switcher.branch_row.origin/feat/new-shell`.
2. Wait for the "Switch settled" ready signal targeting `feat/new-shell`.

**Assertions:**
1. (UI) After step 2: `worktree_header.branch_text` reads `feat/new-shell` (NOT `origin/feat/new-shell`).
2. (Repo) `git -C <tmp>/repo-multi-branch branch --list feat/new-shell` is non-empty.
3. (Repo) `git -C <tmp>/repo-multi-branch config branch.feat/new-shell.remote` returns `origin`.
4. (Repo) `git -C <tmp>/repo-multi-branch config branch.feat/new-shell.merge` returns `refs/heads/feat/new-shell`.

**Artifacts on FAIL:** `screenshot.png` of the header + `git_config.txt` snapshot of `git -C <tmp>/repo-multi-branch config --local --list`.

#### Case `UT-BSH-BP-007`: Clicking `origin/main` when local `main` exists fast-paths to local

**Covers AC:** AC-BP-4

**Preconditions:**
- State at end of `UT-BSH-HD-001` — current branch `feat/header-redesign`, local `main` exists, `origin/main` exists.
- Capture `git -C <tmp>/repo-multi-branch rev-parse main` into `main_local_sha_before`.
- Popover opened.

**Steps:**
1. Click `branch_switcher.branch_row.origin/main`.
2. Wait for the "Switch settled" ready signal targeting `main`.

**Assertions:**
1. (UI) After step 2: `worktree_header.branch_text` reads `main`.
2. (Repo) `git -C <tmp>/repo-multi-branch rev-parse main` equals `main_local_sha_before` (no new commit / no new local branch was created).
3. (Repo) `git -C <tmp>/repo-multi-branch branch --list` lists exactly the original local branches plus no `origin/main` local copy (i.e. no `git switch --track` happened).

**Artifacts on FAIL:** `screenshot.png` + `git_branch.txt` snapshot of `git -C <tmp>/repo-multi-branch branch -vv`.

#### Case `UT-BSH-BP-008`: Dirty tree blocks switch with inline error

**Covers AC:** AC-BP-5, AC-SW-3

**Preconditions:**
- State at end of `UT-BSH-HD-001`.
- Before opening the popover, the runner makes a file dirty in a way that would conflict on `main`: edit a tracked file with a known divergent edit between `main` and `feat/header-redesign` (the fixture's `README.md` is committed differently on both branches; appending text to it on disk makes a switch to `main` unsafe).
- Popover opened.

**Steps:**
1. Click `branch_switcher.branch_row.main`.
2. Within 100 ms read `worktree_header.switching_spinner`.
3. Wait until `branch_switcher.error_banner` becomes visible OR `worktree_header.switching_spinner` disappears, whichever comes first (≤ 5 s).
4. Click `branch_switcher.error_dismiss_button`.

**Assertions:**
1. (UI) Within ≤ 200 ms of step 1: `branch_switcher.popover` is no longer visible.
2. (UI) During step 2: `worktree_header.switching_spinner` is visible.
3. (UI) After step 3 settles: `branch_switcher.error_banner` is visible AND `worktree_header.switching_spinner` is absent.
4. (UI) The visible text inside `branch_switcher.error_banner` contains either the literal substring `local changes` OR matches the regex `(?i)would be overwritten|cannot switch` (these are git's documented error fragments — the banner surfaces git's stderr verbatim).
5. (UI) `worktree_header.branch_text` still reads `feat/header-redesign` (the original branch).
6. (Repo) `git -C <tmp>/repo-multi-branch rev-parse --abbrev-ref HEAD` returns `feat/header-redesign`.
7. (UI) After step 4: `branch_switcher.error_banner` is absent.

**Artifacts on FAIL:** `screenshot.png` of the header + banner + `git_status.txt` snapshot of `git -C <tmp>/repo-multi-branch status --short`.

#### Case `UT-BSH-BP-009`: "View all" opens Diff Viewer on the History tab

**Covers AC:** AC-BP-8

**Preconditions:**
- State at end of `UT-BSH-BP-001` (popover open).
- The Diff Viewer is currently closed (verified by absence of `diff_inspector.tab_picker`).

**Steps:**
1. Click `branch_switcher.history_button`.
2. Wait for `diff_inspector.tab_picker` to appear.

**Assertions:**
1. (UI) After step 1 ≤ 500 ms: `branch_switcher.popover` is no longer visible.
2. (UI) After step 2 settles: `diff_inspector.tab_picker` is visible.
3. (UI) `diff_inspector.tab_picker` reports its selected segment as `History`.
4. (UI) `diff_inspector.history_list` is visible AND at least one `diff_inspector.history_row.*` is loaded within ≤ 2 s.

**Artifacts on FAIL:** `screenshot.png` of the application window.

### Journey DV: Diff Viewer History tab

**Persona:** `history_browser`
**Outcome:** Opening Diff Viewer's History tab lists commits on the current branch and selecting one renders its diff on the left, all without affecting the working tree.

#### Case `UT-BSH-DV-001`: First-time switch to History tab loads commits

**Covers AC:** AC-DV-1

**Preconditions:**
- State at end of `UT-BSH-HD-001`.
- Diff Viewer is opened by the user via the existing ⌘⌥G chord; `diff_inspector.tab_picker` is visible AND its selected segment is `Changes`.
- `diff_inspector.history_list` is NOT yet visible (because the History tab has not been activated this session).

**Steps:**
1. Select the `History` segment in `diff_inspector.tab_picker`.
2. Wait for the "History first page loaded" ready signal (≤ 2 s).

**Assertions:**
1. (UI) During step 1 → step 2 transition: a progress indicator is visible inside the inspector content area within 500 ms.
2. (UI) After step 2 settles: `diff_inspector.history_list` is visible.
3. (UI) `diff_inspector.history_list` contains at least 10 `diff_inspector.history_row.*` elements (the fixture HEAD branch has ≥ 50 commits; the first page is 50, so this lower bound is conservative for fixtures that may shrink).
4. (UI) The first row's `<short-sha>` segment in its identifier matches the first 7 chars of `git -C <tmp>/repo-multi-branch rev-parse HEAD`.

**Artifacts on FAIL:** `screenshot.png` of the inspector + `git_log.txt` snapshot of `git log -n 1 --format=%H HEAD`.

#### Case `UT-BSH-DV-002`: Clicking a commit shows its diff with `<sha> · <subject>` title

**Covers AC:** AC-DV-2

**Preconditions:**
- State at end of `UT-BSH-DV-001` (History tab populated).
- Capture the third row's `<short-sha>` from its identifier into `target_sha`; capture its rendered subject text into `target_subject`.
- Capture `git -C <tmp>/repo-multi-branch log -n 1 --format=%s <target_sha>` into `expected_subject` (must equal `target_subject`).

**Steps:**
1. Click `diff_inspector.history_row.<target_sha>`.
2. Wait until `diff_drawer.title_text` updates to reflect a commit subject (text changes from its prior value OR appears for the first time).

**Assertions:**
1. (UI) After step 2: `diff_drawer.title_text` matches the regex `^[0-9a-f]{7,12}\s+·\s+.+$`.
2. (UI) The leading hex group of `diff_drawer.title_text` starts with `<target_sha>` (case-insensitive prefix match).
3. (UI) The text after the `·` separator equals `expected_subject` (after trimming whitespace).
4. (UI) The left-side diff renderer shows at least one hunk (presence of any `+`-prefixed line OR `-`-prefixed line in the rendered diff body — or equivalently, the file-header element for at least one file is visible).
5. (Repo) `git -C <tmp>/repo-multi-branch rev-parse HEAD` is unchanged from the value captured at the end of `UT-BSH-DV-001` (selection must not mutate working state).

**Artifacts on FAIL:** `screenshot.png` of the Diff Viewer + `git_head.txt` snapshot.

#### Case `UT-BSH-DV-003`: Selection persists across Changes ↔ History tab toggles

**Covers AC:** AC-DV-3

**Preconditions:**
- State at end of `UT-BSH-DV-002` (a commit is selected in History; left side shows that commit's diff).
- Note `target_sha` and the prior `diff_drawer.title_text` value.

**Steps:**
1. Select the `Changes` segment in `diff_inspector.tab_picker`.
2. Wait until `diff_inspector.changes_list` is visible OR the "no changes" empty state is visible.
3. Select the `History` segment again.
4. Wait until `diff_inspector.history_list` is visible.

**Assertions:**
1. (UI) After step 2: `diff_inspector.history_list` is hidden AND `diff_inspector.changes_list` (or its empty state) is visible.
2. (UI) After step 4: the row `diff_inspector.history_row.<target_sha>` is marked as selected (selection trait set OR visibly highlighted vs. its sibling rows).
3. (UI) After step 4: `diff_drawer.title_text` is unchanged from the value captured in preconditions (no re-fetch flicker; cached diff is reused).

**Artifacts on FAIL:** `screenshot.png` of the inspector after each step.

#### Case `UT-BSH-DV-004`: Infinite scroll loads the next page

**Covers AC:** AC-DV-4

**Preconditions:**
- State at end of `UT-BSH-DV-001` (History tab populated with the first page; page size 50).
- The fixture HEAD branch has ≥ 60 commits, so a second page is expected.
- Capture the count of `diff_inspector.history_row.*` elements into `count_before` (should be 50 by design).

**Steps:**
1. Scroll the `diff_inspector.history_list` until the last visible row is the 45th row (≤ 5 rows of buffer from the end).
2. Wait either ≤ 2 s OR until the count of `diff_inspector.history_row.*` elements exceeds `count_before`, whichever comes first.

**Assertions:**
1. (UI) After step 2: count of `diff_inspector.history_row.*` is strictly greater than `count_before`.
2. (UI) The new rows are appended at the tail (the prior last row is still present at its prior index; the new rows extend below it).
3. (UI) No duplicate `<short-sha>` appears across the combined list.

**Artifacts on FAIL:** `screenshot.png` of the scrolled list + `row_shas.txt` snapshot of all identifiers.

#### Case `UT-BSH-DV-005`: Empty repository shows the History empty state

**Covers AC:** AC-DV-5

**Preconditions:**
- Catalog seed `_shared/fixtures/catalog/branch-switcher-empty.json`.
- Empty repo bundle restored to `<tmp>/repo-empty`.
- App started.
- Diff Viewer opened.

**Steps:**
1. Select the `History` segment in `diff_inspector.tab_picker`.
2. Wait ≤ 2 s.

**Assertions:**
1. (UI) `diff_inspector.history_empty_state` is visible.
2. (UI) Its text contains the substring `No commits` (or the localized equivalent for the active locale).
3. (UI) No `diff_inspector.history_row.*` element exists.

**Artifacts on FAIL:** `screenshot.png` of the inspector.

### Journey VS: Visual & system integration

**Persona:** `git_branch_navigator`
**Outcome:** The new popover and tab respect the system's accessibility and chrome rules.

#### Case `UT-BSH-VS-001`: macOS 26+ popover has no extra glass capsule

**Covers AC:** AC-VS-1

**Preconditions:**
- macOS version ≥ 26.0 (runner skips this case on older OS with status `SKIP` + reason `macOS < 26`).
- State at end of `UT-BSH-BP-001` (popover open).

**Steps:**
1. Capture the visible bounds of `branch_switcher.popover`.
2. Capture the visible bounds of the toolbar area immediately above the popover anchor.

**Assertions:**
1. (UI) `branch_switcher.popover`'s container does not paint a glass capsule background (the runner inspects the element's effective material — if SwiftUI's introspection exposes the material, assert it is `nil` or `.regular` not the toolbar's `.thickMaterial`; if introspection is unavailable, compare rendered pixel samples at the popover corners against the toolbar's known capsule samples — they must differ).
2. (UI) The toolbar's existing branch label and surrounding chips are visually unaffected (their bounds + computed colours match a snapshot taken before the popover opened).

**Artifacts on FAIL:** `screenshot.png` of the toolbar + popover boundary + pixel-sample dump.

#### Case `UT-BSH-VS-002`: VoiceOver announces the branch button correctly

**Covers AC:** AC-VS-2

**Preconditions:**
- State at end of `UT-BSH-HD-001`.
- VoiceOver enabled (runner activates VoiceOver before the steps; deactivates on teardown).

**Steps:**
1. Move VoiceOver focus to `worktree_header.branch_button`.
2. Read VoiceOver's announcement.

**Assertions:**
1. (Accessibility) The announcement starts with the prefix `Branch ` followed by `feat/header-redesign`.
2. (Accessibility) The announcement includes the trait `button` (or its localized form).

**Artifacts on FAIL:** `voiceover_log.txt` of the announcement string + `screenshot.png`.

#### Case `UT-BSH-VS-003`: Tab switch transition is visually smooth — manual

**Covers AC:** AC-VS-3

**Preconditions:**
- State at end of `UT-BSH-DV-001` (History first page loaded).

**Procedure:**

This case is intentionally **manual-only**. The runner reports `MANUAL` status with the case captured as a screen recording for human review. A human dogfooder evaluates whether the segmented-control transition between Changes and History causes visible flicker or layout jump in the left diff area.

**Acceptance for MANUAL:**
1. The reviewer toggles `diff_inspector.tab_picker` between `Changes` and `History` three times.
2. The reviewer subjectively confirms there is no flash, no white/black flash frame, and no horizontal layout jump in either pane.

**Artifacts:**
- `tab_switch.mov` — 5–10 s screen recording of the toggle sequence.
- Reviewer name + verdict line in the case run report.

## Coverage Matrix

| Spec AC | Covered by |
|---|---|
| AC-HD-1 | UT-BSH-HD-001 |
| AC-HD-2 | UT-BSH-HD-002 |
| AC-HD-3 | UT-BSH-HD-003 |
| AC-BP-1 | UT-BSH-BP-001 |
| AC-BP-2 | UT-BSH-BP-002 |
| AC-BP-3 | UT-BSH-BP-006 |
| AC-BP-4 | UT-BSH-BP-007 |
| AC-BP-5 | UT-BSH-BP-008 |
| AC-BP-6 | UT-BSH-BP-004 |
| AC-BP-7 | UT-BSH-BP-003 |
| AC-BP-8 | UT-BSH-BP-009 |
| AC-SW-1 | UT-BSH-BP-005 |
| AC-SW-2 | UT-BSH-BP-005 |
| AC-SW-3 | UT-BSH-BP-008 |
| AC-DV-1 | UT-BSH-DV-001 |
| AC-DV-2 | UT-BSH-DV-002 |
| AC-DV-3 | UT-BSH-DV-003 |
| AC-DV-4 | UT-BSH-DV-004 |
| AC-DV-5 | UT-BSH-DV-005 |
| AC-VS-1 | UT-BSH-VS-001 |
| AC-VS-2 | UT-BSH-VS-002 |
| AC-VS-3 | UT-BSH-VS-003 (manual) |

## Personas / Fixtures Added During Authoring

### Personas (to be added to `docs/user-tests/_shared/personas.yaml`)

```yaml
  - id: git_branch_navigator
    role: Developer who switches between feature branches frequently
    description: >
      Works across multiple local + remote branches within a single
      worktree per session, expects to switch in-app rather than dropping
      to a terminal, and reads the worktree header as the primary "where
      am I" cue. Comfortable with git's native error messages when a
      switch fails.
    defaults:
      authStatus: authorized

  - id: history_browser
    role: Contributor reading past commits for context
    description: >
      Uses the Diff Viewer's History tab to read commit diffs without
      modifying the working tree. Often new to a project and unfamiliar
      with terminal git, so relies on the in-app inspector to navigate
      the branch's commit history.
    defaults:
      authStatus: authorized
```

### Fixtures (to be added under `docs/user-tests/_shared/fixtures/`)

- `repo-multi-branch.bundle` — checked in as a git bundle; restore script in `_shared/fixtures/setup/restore-repo-multi-branch.sh`.
- `repo-empty.bundle` — git-init-only bundle.
- `repo-detached.bundle` — multi-branch repo with HEAD detached.
- `catalog/branch-switcher.json`, `catalog/branch-switcher-empty.json`, `catalog/branch-switcher-detached.json` — catalog seeds parametrised by `<tmp>` path replaced at runner setup time.

### Source-code seams added

See [Source-Code Seams](#source-code-seams) — the implementation must declare every listed accessibility identifier. The /hs-planner exec plan should pick these up as a Definition-of-Done item per touchpoint.

## Open Questions

1. **OQ-UT1** — On detached HEAD, the spec text shows `(detached @ <short-sha>)` but does not state whether the short sha must come from `Worktree.headSha` (model field) or from a fresh `git rev-parse --short HEAD`. UT-BSH-HD-003's assertion uses a permissive regex that accepts either. **Default:** keep the permissive regex; if the design doc's OQ-D1 lands on the model-field path, tighten the assertion in a follow-up.

2. **OQ-UT2** — UT-BSH-VS-001 needs SwiftUI material introspection that may not be exposed in our XCUITest harness today. **Default:** if introspection is unavailable, fall back to the pixel-sample comparison branch of the assertion; if both prove infeasible, downgrade this case to MANUAL like VS-003.

3. **OQ-UT3** — `Recent commits` group section header label and `History` segment label are placeholder text; localizable wording will be finalized in implementation. **Default:** runner reads labels from the active locale via the same `Localizable.strings` keys the implementation declares; the assertions match by key, not by literal English.

4. **OQ-UT4** — UT-BSH-BP-005 asserts the popover dismisses within 200 ms of the click. If the reducer batches the dismiss with the switch-effect dispatch, this should be near-instant; if it waits on the switch's first I/O, 200 ms may be tight. **Default:** keep 200 ms; if real measurements miss this consistently, raise to 500 ms with a one-line note here.
