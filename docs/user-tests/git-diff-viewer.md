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

## Native presentation revision

The window uses a native unified toolbar for Changes/Outgoing, Unified/Split, and Refresh. The All/Staged/Unstaged selector and both open-file buttons are removed. Changes uses the aggregate comparison. The native file list/header owns paths and statistics; embedded Web chrome is disabled. Outgoing base selection uses a sidebar popover, and editor navigation remains on line numbers and the file context menu.

Component: 6 JavaScript tests, 5 WebKit browser tests, 6 Swift tests, and native WKWebView smoke passed. Host build-for-testing and 27 focused tests passed. The lifecycle test drives native toolbar comparison/layout actions and verifies layout persistence. Earlier GUI cases involving removed controls describe the previous revision only.

| Native presentation GUI case | Observed result | Result |
|---|---|---|
| Removed controls | No All/Staged/Unstaged, Open Selected File, Web Open file, Web toolbar/context/footer, or READ ONLY badge | PASS |
| Native toolbar | Changes/Outgoing and Unified/Split update real content; Refresh remains accessible | PASS |
| Sidebar/file header | Compact system-font filenames, status characters, file icons, selected path and statistics | PASS |
| Outgoing base popover | Explicit main applies and committed.txt remains correct | PASS |
| Appearance | Application Dark and Auto update native controls and Web content together; Auto restored | PASS |
| Half-screen / restore | All toolbar controls remain available; code and sidebar resize correctly | PASS |
| Line navigation | New-side line 4 opens Demo.swift in Cursor at Ln 4, Col 1 | PASS |

Evidence: /tmp/codans-diff-native-build.log, /tmp/codans-diff-native-tests.log, /tmp/codans-diff-qa-test/native-result.xcresult; GUI screenshots are in the task transcript. The exported component is pinned to 664e49a. `make mac-check` was run; the two newly introduced image-label violations were fixed and scoped lint passed. The 61 existing repository violations remain. Generated minified highlight.js contains significant trailing whitespace inside a string literal; it is retained from the reproducible component build rather than trimmed. Source diff checks exclude that generated asset.


## Sidebar tree revision (2026-09-17)

The sidebar now owns Changes/Outgoing, file filtering, and Tree/List presentation. Tree is the default; macOS content-type icons decorate file rows. The earlier toolbar-comparison cases above describe the previous revision.

Host build-for-testing and 33 focused tests in 8 suites passed, including six tree-model cases and per-window presentation restoration. The tree cases cover nested paths, natural ordering, duplicate basenames, deleted/renamed files, Unicode/whitespace, file-to-directory transitions, and directory/file identity collisions. Component sources are unchanged from the previous verified revision.

| GUI case | Observation | Result |
|---|---|---|
| Native tree | Expanded docs, Sources/App, Sources/Models, and Tests show nested files and macOS type icons | PASS |
| Selection and refresh | Selecting Model.swift displays Sources/Models/Model.swift; collapsing Sources and refreshing preserves collapse and preview | PASS |
| Search | main.swift reveals both Sources/App and Tests with their ancestors | PASS |
| Tree/list switch | List shows parent paths for duplicate names; selecting Tests/main.swift and switching back retains the selection | PASS |
| Sidebar modes/base | Outgoing shows only committed.txt against main; explicit main comparison works through the sidebar popover | PASS |
| Window restoration | Closing Diff leaves the main window intact; reopening restores Outgoing, main, and List | PASS |
| Appearance and sizing | Tree, mode controls, and code remain visible in half-screen and dark appearance; Auto and previous size restored | PASS |
| Editor handoff | Tree-row Open in Editor opens Sources/Models/Model.swift in Cursor; URL and line 1 verified | PASS |

Fixtures include Swift, Markdown, JSON, duplicate basenames, and nested directories. Evidence: `/tmp/codans-diff-tree-final-build.log`, `/tmp/codans-diff-tree-tests.log`, `/tmp/codans-diff-qa-test/tree-result.xcresult`, plus GUI observations in the task transcript. `make mac-check` reports the same 61 existing violations outside the changed files; unrelated formatter edits were restored. No remote-host GUI or additional Agent CLI matrix was rerun for this sidebar-only revision.


## Native sidebar container correction (2026-09-17)

The earlier tree revision used HSplitView and an opaque sidebar background, so its list style did not match the main window's native Sidebar. Diff now uses NavigationSplitView, the main window's column sizing, NSHostingController, and a SwiftUI-managed unified toolbar. The system supplies the sidebar material, titlebar partition, and collapse control.

Build-for-testing and 33 focused tests passed. Window tests cover sidebar routing isolation, controller cleanup, and preference restoration. GUI confirmed the rounded native sidebar, system Hide/Show Sidebar button, View → Toggle Sidebar routing to Diff, Changes/Outgoing, and unified/split rendering. Full-repository lint still reports the same 61 pre-existing violations outside the changed files.

Evidence: `/tmp/codans-native-sidebar-final-build.log`, `/tmp/codans-native-sidebar-final-tests.log`, `/tmp/codans-diff-qa-test/native-sidebar-final-result.xcresult`, and the task's GUI observations.

The final sizing correction explicitly restores 1000×700 content size when no saved frame exists. The lifecycle test was rerun with minimum initial-frame assertions and passed (`/tmp/codans-native-sidebar-size-tests.log`); final GUI confirmed the full initial size and loaded tree/code surface.


## Comparison selector styling (2026-09-17)

Changes/Outgoing use full-width equal segments, icon-and-text labels, a capsule track, and an accent-colored capsule selection. The selector uses native SwiftUI buttons with accessible selected state. Build-for-testing passed; real GUI verified both appearances and switching between current changes and the outgoing committed-file comparison. Evidence: `/tmp/codans-diff-picker-capsule-build.log` and GUI observations in the task transcript.


## Uncommitted, remote base, and Built-in defaults (2026-09-17)

Final build-for-testing succeeded. The focused app run passed 51 tests in 10 suites, covering comparison resolution, mode changes, external/Built-in routing, window lifecycle, and preference persistence. Core migration tests passed 11 tests after fixing assertions to evaluate mutations before passing their results to the expectation macro.

| Case | Observed result | Status |
|---|---|---|
| Sidebar header | Text-only 12-point labels in a 24-point selector; its lower divider aligns with the 32-point code header | PASS |
| Worktree context menu | Show Changes opens the clicked QA no-base worktree while main selection remains Diff QA feature/review | PASS |
| Main toolbar | Dedicated Diff entry absent | PASS |
| Default Git Viewer | Built-in selected and listed first; GitHub Desktop and Fork follow; None absent | PASS |
| Viewer command | Worktree → Toggle Git Viewer opens the built-in Diff window | PASS |
| Remote default | Against origin/main shows only committed.txt, excluding uncommitted files and target-only changes | PASS |
| Explicit base and reset | HEAD yields zero files; Use Remote Default restores origin/main and committed.txt | PASS |
| Missing remote | Explicit unavailable-base message shown for QA no-base | PASS |

The GUI used an isolated QA app/config and synthetic local remote-tracking refs; no network fetch, SSH, or live PR discovery is claimed. The QA bundle required copying the existing zmx runtime into its resources before terminal-backed checks. A final display-only correction makes an empty Outgoing header say Outgoing; that correction was build-verified after the GUI run.

Evidence: `/tmp/codans-refinement-final-build.log`, `/tmp/codans-refinement-tests.log`, `/tmp/codans-diff-qa-test/refinement-result.xcresult`, `/tmp/codans-refinement-core-final-tests.log`, and `/tmp/codans-diff-qa-test/refinement-core-final-result.xcresult`, plus GUI observations in the task transcript. `make mac-check` still reports 61 existing repository violations; unrelated formatter edits were restored.


## Sidebar line statistics (2026-09-17)

Each tree/list file row displays added and deleted lines beside its status. The header totals the full comparison rather than filtered rows; incomplete non-binary statistics are marked partial. Untracked text uses bounded safe reads, with unknown values for symlinks, oversized/unreadable content, and binary files.

Build-for-testing and 25 tests in GitComparisonTests, DiffFeatureTests, and DiffFileTreeTests passed. The new fixture test covers terminated and unterminated lines, empty files, binary data, oversized files, symlinks, and both working-directory scopes. Real GUI verified tree and flat rows, empty-file zeroes, binary/symlink dashes, aggregate +10/−2 with partial indication, unchanged totals while filtering to Demo.swift, and Outgoing switching to +1/−0. The default-width sidebar and dark appearance were visually checked; SSH GUI and additional width matrices were not rerun.

Evidence: `/tmp/codans-line-counts-build.log`, `/tmp/codans-line-counts-tests.log`, `/tmp/codans-diff-qa-test/line-counts-result.xcresult`, and GUI observations in the task transcript. Full-repository `make mac-check` reports the same 61 existing violations; unrelated formatter edits were restored.


## Selectable comparison branches (2026-09-18)

The comparison popover contains Remote Default Branch followed by grouped remote and local branch buttons. Selection applies immediately, closes the popover, and is checked when reopened. Short lists receive content-based height; long lists scroll within 280 points. Manual ref entry and the Compare button are removed.

Final build-for-testing and 26 tests across DiffFeatureTests, DiffWindowManagerTests, GitComparisonTests, and GitServiceClientBranchTests passed. Reducer coverage includes inventory success, failure/retry, stale results after closing/context changes, and immediate remote/local/default selection. Scoped SwiftLint passed. Full-repository checks retain 61 existing violations after fixing the new brace-format warning; unrelated formatter edits were restored.

Real GUI verified the default checkmark, explicit origin/main selection and checked state, feature/review selection yielding zero files, and Remote Default Branch restoring origin/main and committed.txt. Final visual verification confirms both branch groups and all three fixture branches are visible without an input field or confirmation button. No network fetch or SSH GUI testing was performed.

Evidence: `/tmp/codans-base-picker-sized-build.log`, `/tmp/codans-base-picker-tests.log`, `/tmp/codans-diff-qa-test/base-picker-result.xcresult`, `/tmp/codans-base-picker-scoped-lint.log`, and task GUI observations.


## Quieter file rows and context-menu order (2026-09-18)

Removed per-file line counts from the shared tree/list row while preserving header totals and selected-file statistics. Show Changes now has its own group after Open/Reveal and before Copy. Build-for-testing passed. GUI confirmed Reveal in Finder → Show Changes → Copy ordering, successful opening, rows without line counts, and retained +10/−2 header totals. The two menu dividers were checked in source. No reducer or Git behavior changed, so automated behavior suites were not rerun. Full-repository lint remains at 61 existing violations. Evidence: `/tmp/codans-sidebar-cleanup-build.log`, `/tmp/codans-sidebar-cleanup-check.log`, and task GUI observations.
