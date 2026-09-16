# Git Diff Viewer GUI Verification

Status: in progress. Only cases marked PASS below have been exercised.

Fixtures: `python3 apps/mac/scripts/create-diff-fixtures.py /tmp/codans-diff-qa` creates dedicated repositories; use a fresh directory on each run. Application config, terminal cache, and socket must be isolated using CODANS_CONFIG_DIR, CODANS_CACHE_DIR, and CODANS_SOCKET_PATH.

| Case | Expected | Result |
|---|---|---|
| Changes All | Working result plus untracked files | Pending |
| Staged / Unstaged | Distinct index and worktree content | Pending |
| Outgoing divergence | Branch contribution only, no target-only reversal | Pending |
| Explicit / missing base | Correct comparison or visible error | Pending |
| Unified / Split | Consistent text and line sides | Pending |
| File filter | Matching files and no-match state | Pending |
| Binary / large / symlink / metadata | Explicit notice, no false empty diff | Pending |
| Rename / delete / odd path / untracked | Correct file identity and content | Pending |
| Clean / unborn / conflict / no base | Clear state for each fixture | Pending |
| Auto refresh / index changes | Updated list/content without manual restart | Pending |
| Worktree switch / stale response | No previous-worktree content | Pending |
| Expand / close / terminal focus | Session preserved, correct input target | Pending |
| Editor file / line / old-side | Current-file handoff or explicit unavailable | Pending |
| Renderer failure / retry | Refresh can recreate content | Pending |
| Narrow / wide / resize | Operable controls and readable code | Pending |
| Actual SSH GUI | Same data and editor routing on an SSH host | Not exercised |
