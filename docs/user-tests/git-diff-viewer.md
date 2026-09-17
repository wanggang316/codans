# Git Diff Viewer Verification

Status: independent-window build, focused tests, and local GUI regression passed. The earlier comparison matrix remains the baseline for unchanged Git/rendering behavior. Tested on macOS with the native Codans application, using CUA interactions and real WKWebView content.

## Automated verification

- Codans app build-for-testing succeeded.
- 27 focused app tests passed: DiffFeature (9), GitComparison (7), EditorFileOpen (5), GitServiceClientBranch (2), PullRequestBase (2), Root missing-selection regression (1), DiffWindowManager lifecycle (1).
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
| Previous split-view expand / focus | Passed in the previous revision; superseded by independent windows | Historical |
| Editor file / line / historical side | Cursor opens the correct Demo.swift at Ln 4, Col 1; old-side and deleted targets are refused | PASS |
| Renderer error / retry | Oversized preview fails explicitly; replacing content and Refresh renders Recovered preview | PASS |
| Previous split-view narrow / wide | Passed in the previous revision; superseded by independent windows | Historical |
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

## Independent window regression

The main terminal split was removed. The isolated native application used a regular titled Diff window with standard close/minimize/zoom controls.

| Case | Observed result | Result |
|---|---|---|
| Open Changes / Outgoing | Demo.swift and committed.txt render in the independent window | PASS |
| Repeat open | Existing window remains active with Outgoing selection retained | PASS |
| Repeated close/reopen | Scope and committed.txt selection restored across cycles | PASS |
| Command-W / red close | Only Diff closes; both original terminal tabs remain | PASS |
| Multiple Worktrees | Window menu simultaneously lists review and unborn windows | PASS |
| Main selection isolation | Original review window retains Outgoing/committed.txt after main selection changes to unborn | PASS |
| Independent close | Closing review leaves unborn window and its first.txt content intact | PASS |
| Zoom / restore | Diff expands to screen and restores without changing the main terminal | PASS |
| Terminal dimensions | Before, after repeated cycles, and after multiwindow checks: 37 rows × 78 columns | PASS |
| Terminal resize signals | Shell WINCH trap recorded zero events; trap removed after verification | PASS |

The resize check targets the trigger behind CLI reflow. It does not establish a full visual matrix across every Agent CLI, multi-display configuration, or macOS version. Dedicated multi-display and post-relaunch frame restoration checks were not run.

Current evidence: /tmp/codans-diff-window-build-final.log, /tmp/codans-diff-window-tests.log, and /tmp/codans-diff-qa-test/window-result.xcresult. Full `make mac-check` still reports the same 61 pre-existing lint errors; new window files and changed Diff UI have no reported violations. Unrelated formatting changes were restored.
