# Git Diff Viewer Verification

Status: local functional and narrow/wide-window regression cases passed. Tested on macOS with the native Codans application, using CUA interactions and real WKWebView content.

## Automated verification

- Codans app build-for-testing succeeded.
- 26 focused app tests passed: DiffFeature (9), GitComparison (7), EditorFileOpen (5), GitServiceClientBranch (2), PullRequestBase (2), Root sidebar/expansion regression (1).
- 6 Core configuration/cache isolation tests passed.
- Independent component: 5 JavaScript unit tests, 4 WebKit browser tests, 5 Swift tests; native layout-update and 20-cycle mount/unmount smoke tests passed.
- `make mac-check` ran. Full-repository lint reports 61 existing errors; all 11 newly added Swift files pass scoped lint. Final DiffPanelView and WorktreeDetailView scoped lint also passed. Unrelated formatter changes were restored.

## GUI cases

| Case | Observed result | Result |
|---|---|---|
| Changes All | HEAD `base` to working `working`, with untracked files | PASS |
| Staged / Unstaged | `base` to `staged`, then `staged` to `working` | PASS |
| Outgoing divergence | Only committed.txt with branch contribution content; target-only.txt is absent | PASS |
| Explicit / missing base | main succeeds; invalid ref and missing default produce visible errors | PASS |
| Unified / Split / theme | Both layouts render; light and dark themes verified | PASS |
| File filter | A nonmatching query shows No matching files | PASS |
| Binary / symlink / metadata | Binary notice; symlink refused; executable mode change reported | PASS |
| Large / empty | 1M-character limit notice; empty added file retains metadata status | PASS |
| Rename / delete / odd path / untracked | Rename metadata, removed text, literal Tab filename and script text, added content | PASS |
| Clean / unborn / conflict / no base | Empty state, empty-tree comparison, unmerged notice, base selection error | PASS |
| Automatic content and index refresh | Edited working text updates; git add changes Staged without pressing Refresh | PASS |
| Worktree switch | Clean/unborn/conflict/no-base/review contexts display their own data | PASS |
| Expand / Tab / close / focus | Terminal hidden while expanded; new Tab reveals it; close preserves session and keyboard output | PASS |
| Editor file / line / historical side | Cursor opens the correct Demo.swift at Ln 4, Col 1; old-side and deleted targets are refused | PASS |
| Renderer error / retry | Oversized preview fails explicitly; replacing content and Refresh renders Recovered preview | PASS |
| Narrow / wide / resize | 900px and wide layouts render; expanded mode hides sidebar; Collapse restores sidebar/terminal; Show Sidebar exits expansion | PASS |
| Actual SSH and live PR target discovery | Not exercised; transport/editor argv and PR parsing have automated coverage | Not exercised |
| Actual Web-content process termination | Not killed in GUI; timeout/disposal covered in component tests | Not exercised |

## Reproduction

Generate disposable repositories in a fresh directory:

```bash
python3 apps/mac/scripts/create-diff-fixtures.py /tmp/codans-diff-new-run
```

Use separate CODANS_CONFIG_DIR, CODANS_CACHE_DIR and CODANS_SOCKET_PATH values. The GUI run used /tmp/codans-diff-qa. The test host used /tmp/codans-diff-qa-test, including explicit environment entries in a copied xctestrun file. A uniquely identified, locally signed application copy avoided ambiguity with other running development builds.

Bring the application window to the foreground before asserting WebKit visual or accessibility output. During this run, background/occluded-window captures appeared blank despite ready/rendered callbacks and valid geometry. Activating the window restored the content without reload. This was a test-observation issue, not evidence of a failed renderer. Temporary geometry diagnostics were removed.

The GUI test deliberately changes the fixture's Demo.swift and index, replaces large.txt with a small recovery document, and creates a second terminal tab. Regenerate fixtures for a repeatable fresh run. No staging/discard/commit/push controls exist in the viewer.

Local evidence: /tmp/codans-diff-final-focused-tests.log, /tmp/codans-diff-final-sidebar-test.log, /tmp/codans-diff-final-test-build.log, /tmp/codans-diff-core-tests.log, and the xcresult bundles under /tmp/codans-diff-qa-test. GUI observations and screenshots are in the task transcript; these are not committed as source assets.
