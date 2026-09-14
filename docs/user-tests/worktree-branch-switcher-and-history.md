---
name: worktree-branch-switcher-and-history
description: Current user-test specification for worktree header identity and branch switching. Read docs/user-test-patterns.md before editing.
---

# User Tests: Worktree Branch Switcher

**Status:** Active specification; runtime verification pending
**Author:** Gump (with Claude)
**Last source review:** 2026-09-08
**Design:** [docs/design-docs/worktree.md](../design-docs/worktree.md)

## Scope

This specification covers the current header and branch popover. The popover renders branches and a filter field; it no longer renders recent commits or an entry to an embedded history viewer. Diff and history inspection is delegated to external Git clients. The filename and surviving case IDs remain stable for existing links.

The [status companion](./worktree-branch-switcher-and-history-status.md) records evidence separately from the steps here. Source review is not a successful runtime test.

## Personas Used

- `git_branch_navigator` — switches local and remote branches and uses the header to confirm worktree identity. Registered in `_shared/personas.yaml`.

## Shared Fixtures

| Fixture | Path | Purpose |
|---|---|---|
| Multi-branch repo bundle | `_shared/fixtures/repo-multi-branch.bundle` | git bundle restored to `<tmp>/repo-multi-branch` before app launch. Contains local branches `main`, `feat/header-redesign`, `bugfix/menu`; remote-tracking refs `origin/main`, `origin/feat/new-shell`, `origin/HEAD → origin/main`; HEAD checked out on `feat/header-redesign`. |
| Detached-HEAD repo bundle | `_shared/fixtures/repo-detached.bundle` | Same content as `repo-multi-branch.bundle` but with HEAD detached at the third commit of `main`. Restored to `<tmp>/repo-detached`. |
| Catalog seed (multi-branch) | `_shared/fixtures/catalog/branch-switcher.json` | `catalog.json` with one Project `"playground"` whose root and only Worktree both point at `<tmp>/repo-multi-branch`. |
| Catalog seed (detached) | `_shared/fixtures/catalog/branch-switcher-detached.json` | Same shape, pointing at `<tmp>/repo-detached`. |

Use the matching restore script in `_shared/fixtures/setup/` with a new disposable destination beneath the run's temporary directory. Restore scripts remove their destination, so never pass an existing project path. Do not substitute a plain clone: the multi-branch script preserves the bundled remote-tracking refs explicitly.

The multi-branch restore script does not configure `origin`. Before remote-switch cases, add a local disposable remote and its fetch mapping so Git can recognize tracking refs:

With `test_tmp` set to the run's temporary directory:

```bash
git init --bare "$test_tmp/fixture-origin.git"
git -C "$test_tmp/repo-multi-branch" remote add origin "$test_tmp/fixture-origin.git"
```

Both paths must belong to this disposable run; no network access is required for these cases. Confirm the local branches and remote-tracking refs listed above before launch. Catalog seeds contain `__TMP__`, which must be replaced with the run's temporary directory. Back up and restore any app state used for seeding, and use an isolated validation session per [user-test patterns](../user-test-patterns.md); do not overwrite the active user's catalog.

## Source-Code Seams

These identifiers are declared by the current branch-switcher and header views. Query them in the running UI before acting. A source declaration alone does not prove that an element is rendered or accessible.

| Identifier | Surface |
|---|---|
| `worktree_header.branch_button` | Tap target on header row 1 (branch name + chevron). |
| `worktree_header.branch_text` | The branch-name text element on row 1. |
| `worktree_header.context_text` | Worktree name and project context on row 2; only the project name when the worktree name repeats the branch. |
| `worktree_header.switching_spinner` | Spinner element replacing the chevron during a switch. |
| `branch_switcher.popover` | Popover container view. |
| `branch_switcher.search` | Filter field, visible after a non-empty branch inventory loads. |
| `branch_switcher.branch_row.<local\|remote>.<short-name>` | One row per branch. `<short-name>` is the branch's short ref (e.g. `main`, `origin/feat/new-shell`); the `local`/`remote` segment disambiguates rare collisions when a local branch happens to share its short name with a remote ref. |
| `branch_switcher.current_marker` | Checkmark element on the current row. |
| `branch_switcher.branch_row.menu_button` | Hover-revealed ellipsis (`...`) menu button present on every branch row (local, remote, blocked). The menu exposes a uniform three-item action set: `Switch`, `New Branch From "<name>"…`, `Rename…`. Per-item disabled state is set by the implementation (e.g. `Switch` is disabled on the current row, `Rename…` is disabled on remote-tracking rows). |
| `branch_switcher.branch_row.blocked_marker` | `+` icon in the leading slot of rows whose branch is currently checked out in another worktree of the same project. Replaces the checkmark slot; the sole visual signal for blocked rows (no trailing `@<worktree>` label is rendered). |
| `branch_switcher.rename_field` | Inline TextField that replaces the branch name while the user is editing the rename draft. Works on any local branch row, not only the current one. |
| `branch_switcher.rename_spinner` | Mini spinner shown next to the TextField while the `git branch -m` effect is in flight. |
| `branch_switcher.new_branch_field` | TextField inside the "New branch from <base>" alert presented when the user invokes `New Branch From "<base>"…` on any branch row. The alert's Create button triggers `git switch -c <new> <base>`. |
| `branch_switcher.error_banner` | Inline error banner displayed under the header. |
| `branch_switcher.error_dismiss_button` | The banner's close button. |

## Ready Signals

In addition to the project's standard "App launched" signal, cases in this document use:

- **"Popover opened"** — `branch_switcher.popover` and `branch_switcher.branch_row.local.feat/header-redesign` are visible for the populated fixture.
- **"Switch settled"** — the spinner is absent and the header reads the requested local branch name, or an error banner is visible. Assert the success or error outcome separately.

Use bounded polling and report a timeout with evidence; do not rely on fixed sleeps or require a fast Git command to display an observable spinner frame. In-flight state can be checked separately under a controlled delayed service; it is not a timing gate for these user journeys.

## Journeys

### Journey HD: Header reflects identity at a glance

**Persona:** `git_branch_navigator`
**Outcome:** Opening worktree detail shows the branch on row 1 and worktree name plus project context on row 2. When the worktree name equals the branch name, row 2 shows only the project name.

#### Case `UT-BSH-HD-001`: Two-row header on a git worktree

**Preconditions:**
- Catalog seed `_shared/fixtures/catalog/branch-switcher.json` placed at `~/.config/codans/catalog.json` (Worktree HEAD = `feat/header-redesign`).
- Multi-branch repo bundle restored to `<tmp>/repo-multi-branch`.
- App started; "App launched" ready signal observed.

**Steps:**
1. Select the only Worktree in the only Project (sidebar single row).
2. Wait until `worktree_header.branch_text` is visible.

**Assertions:**
1. (UI) `worktree_header.branch_text` reads `feat/header-redesign`.
2. (UI) `worktree_header.context_text` reads `repo-multi-branch · playground` (worktree folder name · project name, joined by ` · `).
3. (UI) `worktree_header.context_text` is visibly secondary to the branch title (manual visual check).

**Artifacts on FAIL:** `screenshot.png` of the worktree detail header.

#### Case `UT-BSH-HD-002`: Header reveals a chevron on hover — manual

**Preconditions:** State at end of `UT-BSH-HD-001`; no branch operation is running.

**Steps:**
1. Observe the header with the pointer away from the branch button.
2. Move the pointer over `worktree_header.branch_button`, then away again.

**Assertions:**
1. A downward chevron appears beside the branch name while hovered and disappears when the pointer leaves.
2. The branch text stays in place. The decorative chevron need not appear in the accessibility tree.

**Artifacts on FAIL:** Header screenshots before, during, and after hover.

#### Case `UT-BSH-HD-003`: Detached HEAD renders explicit text

**Preconditions:**
- Catalog seed `_shared/fixtures/catalog/branch-switcher-detached.json`.
- Detached-HEAD repo bundle restored to `<tmp>/repo-detached`.
- App started.

**Steps:**
1. Select the only Worktree.
2. Wait until `worktree_header.branch_text` is visible.

**Assertions:**
1. (UI) `worktree_header.branch_text` matches the regex `^Detached HEAD @[0-9a-f]{7}$` (`Worktree.detachedHeadTitle`; the launch reconcile must have discovered the fixture worktree and recorded its `headSHA` — the catalog seed itself has no `headSHA` key).
2. (UI) `worktree_header.branch_button` is still hittable (the click target exists; see Journey BP for its behaviour on detached HEAD).

**Artifacts on FAIL:** `screenshot.png` of the header.

### Journey BP-Open: Popover contents

**Persona:** `git_branch_navigator`
**Outcome:** Clicking the branch button opens the branch list and filter field.

#### Case `UT-BSH-BP-001`: Popover opens and shows branches

**Preconditions:**
- State at end of `UT-BSH-HD-001`.

**Steps:**
1. Click `worktree_header.branch_button`.
2. Wait for the "Popover opened" ready signal.

**Assertions:**
1. (UI) `branch_switcher.popover` is visible.
2. (UI) A `Branches` section and `branch_switcher.search` are visible.
3. (UI) Local and remote branch rows match the prepared fixture; `origin/HEAD` is not listed.

**Artifacts on FAIL:** `screenshot.png` of the popover.

#### Case `UT-BSH-BP-002`: Current branch is marked and pinned to top

**Preconditions:**
- State at end of `UT-BSH-BP-001` (popover open).

**Steps:**
1. Read the ordered list of `branch_switcher.branch_row.*` elements in the Branches section.

**Assertions:**
1. (UI) The first row in the Branches section is `branch_switcher.branch_row.local.feat/header-redesign` (the current branch).
2. (UI) That row contains `branch_switcher.current_marker` (checkmark).
3. (UI) No other row contains `branch_switcher.current_marker`.

**Artifacts on FAIL:** `screenshot.png` of the popover.

#### Case `UT-BSH-BP-004`: No remote refs leaves only local rows

**Preconditions:**
- A variant of the multi-branch fixture without any remote: prepare `origin` as described above, then run `git -C <tmp>/repo-multi-branch remote remove origin` and verify no refs remain under `refs/remotes/`.
- Catalog still points at `<tmp>/repo-multi-branch`.
- App started; popover opened on the Worktree per Journey BP-001 steps 1–2.

**Steps:**
1. With the popover open, read the Branches section content.

**Assertions:**
1. (UI) No `branch_switcher.branch_row.remote.origin/*` element exists.
2. (UI) No remote rows or local/remote separator is present; the current popover does not use a `Remote` section label.
3. (UI) Local branches are still rendered (`branch_switcher.branch_row.local.main`, `branch_switcher.branch_row.local.feat/header-redesign`, `branch_switcher.branch_row.local.bugfix/menu` are visible).

**Artifacts on FAIL:** `screenshot.png` of the popover.

### Journey BP-Switch: Switching via the popover

**Persona:** `git_branch_navigator`
**Outcome:** The user selects another branch in the popover and the worktree is on that branch; the UI reflects the in-flight switch and any errors.

#### Case `UT-BSH-BP-005`: Local-branch switch updates the header

**Preconditions:**
- State at end of `UT-BSH-BP-001` (popover open on a clean worktree, current branch `feat/header-redesign`).

**Steps:**
1. Click `branch_switcher.branch_row.local.main`.
2. Wait for the "Switch settled" ready signal targeting `main`.

**Assertions:**
1. (UI) The popover closes after selection.
2. (UI) Once settled, the spinner is absent and the header reads `main`.
3. (UI) No error banner is visible.
4. (Repo) `git -C <tmp>/repo-multi-branch rev-parse --abbrev-ref HEAD` returns `main`.

**Artifacts on FAIL:** `screenshot.png` of the header at first failed assertion + `git_head.txt` snapshot.

#### Case `UT-BSH-BP-006`: Remote-only branch switch creates a local tracking branch

**Preconditions:**
- State at end of `UT-BSH-HD-001`.
- Confirm the local repo has no branch named `feat/new-shell`: runner asserts `git -C <tmp>/repo-multi-branch branch --list feat/new-shell` is empty (fixture-guaranteed).
- Popover opened.

**Steps:**
1. Click `branch_switcher.branch_row.remote.origin/feat/new-shell`.
2. Wait for the "Switch settled" ready signal targeting `feat/new-shell`.

**Assertions:**
1. (UI) After step 2: `worktree_header.branch_text` reads `feat/new-shell` (NOT `origin/feat/new-shell`).
2. (Repo) `git -C <tmp>/repo-multi-branch branch --list feat/new-shell` is non-empty.
3. (Repo) `git -C <tmp>/repo-multi-branch config branch.feat/new-shell.remote` returns `origin`.
4. (Repo) `git -C <tmp>/repo-multi-branch config branch.feat/new-shell.merge` returns `refs/heads/feat/new-shell`.

**Artifacts on FAIL:** `screenshot.png` of the header + `git_config.txt` snapshot of `git -C <tmp>/repo-multi-branch config --local --list`.

#### Case `UT-BSH-BP-007`: Clicking `origin/main` when local `main` exists fast-paths to local

**Preconditions:**
- State at end of `UT-BSH-HD-001` — current branch `feat/header-redesign`, local `main` exists, `origin/main` exists.
- Capture `git -C <tmp>/repo-multi-branch rev-parse main` into `main_local_sha_before`.
- Popover opened.

**Steps:**
1. Click `branch_switcher.branch_row.remote.origin/main`.
2. Wait for the "Switch settled" ready signal targeting `main`.

**Assertions:**
1. (UI) After step 2: `worktree_header.branch_text` reads `main`.
2. (Repo) `git -C <tmp>/repo-multi-branch rev-parse main` equals `main_local_sha_before` (no new commit / no new local branch was created).
3. (Repo) `git -C <tmp>/repo-multi-branch branch --list` lists exactly the original local branches plus no `origin/main` local copy (i.e. no `git switch --track` happened).

**Artifacts on FAIL:** `screenshot.png` + `git_branch.txt` snapshot of `git -C <tmp>/repo-multi-branch branch -vv`.

#### Case `UT-BSH-BP-008`: Dirty tree blocks switch with inline error

**Preconditions:**
- State at end of `UT-BSH-HD-001`.
- Before opening the popover, the runner makes a file dirty in a way that would conflict on `main`: edit a tracked file with a known divergent edit between `main` and `feat/header-redesign` (the fixture's `README.md` is committed differently on both branches; appending text to it on disk makes a switch to `main` unsafe).
- Popover opened.

**Steps:**
1. Click `branch_switcher.branch_row.local.main`.
2. Wait until `branch_switcher.error_banner` becomes visible.
3. Capture the banner text and current header before dismissing the error.
4. Click `branch_switcher.error_dismiss_button` and wait until the banner disappears.

**Assertions:**
1. (UI) The popover closes after selection.
2. (UI) On failure, the spinner is absent and the banner explains the conflicting local changes using Git's error message.
3. (UI) The header still reads `feat/header-redesign`.
4. (Repo) `git -C <tmp>/repo-multi-branch rev-parse --abbrev-ref HEAD` still returns `feat/header-redesign`; the dirty file is preserved.
5. (UI) Dismissing the banner clears it without changing the branch.

**Artifacts on FAIL:** `screenshot.png` of the header + banner + `git_status.txt` snapshot of `git -C <tmp>/repo-multi-branch status --short`.

### Journey VS: Accessibility

#### Case `UT-BSH-VS-002`: VoiceOver announces the branch button correctly

**Persona:** `git_branch_navigator`
**Outcome:** The branch switch entry can be identified with VoiceOver.

**Preconditions:** State at end of `UT-BSH-HD-001`; VoiceOver enabled for this check and restored to its prior state afterward.

**Steps:**
1. Move VoiceOver focus to `worktree_header.branch_button`.
2. Record the announcement.

**Assertions:**
1. The announcement includes `Branch feat/header-redesign` and the button role (or their localized equivalents).

**Artifacts on FAIL:** `voiceover_log.txt` and a header screenshot.

## Retired Cases

The following IDs are retired and must not be reported as current failures or passing tests:

- `UT-BSH-BP-003`: the popover no longer displays recent commits.
- `UT-BSH-BP-009`, `UT-BSH-DV-001` through `UT-BSH-DV-005`, and `UT-BSH-VS-003`: the embedded Diff Viewer and its History tab were removed.
- `UT-BSH-VS-001`: material introspection and pixel-comparison assertions are outside the current [user-test conventions](../user-test-patterns.md#范围之外deferred).

External Git-client launching has its own product behavior and should receive a separate user-test set. Retired IDs are not reused.

## Coverage and Follow-up

The 11 active cases cover header identity, hover and accessibility, populated branch inventory, current-branch ordering, absent remote refs, local switching, remote tracking, existing-local fast paths, and conflicting dirty changes.

Search, blocked branches, rename, create-from-branch, empty inventory, and the context-row suppression variant remain candidates for a follow-up user-test expansion. Their presence in the seam inventory does not imply tested coverage. No fixtures or personas were added by this revision.
