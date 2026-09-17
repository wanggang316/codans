# Git Diff Viewer

Status: implemented; local GUI validation is recorded in `../user-tests/git-diff-viewer.md`.

## Scope

A read-only worktree window displays current changes and branch changes relative to a selected base. The independently maintained DiffViewKit package renders code in an offline WKWebView. Codans owns Git operations, file selection, refresh, and editor dispatch.

The toolbar and Worktree menu expose **View Changes and Outgoing**; the command palette has the same entry. The existing external Git Viewer command and its saved shortcut retain their meaning.

## Comparison contract

| Mode | Left | Right |
|---|---|---|
| Changes | HEAD, or empty tree before the first commit | Working directory, including untracked |
| Outgoing | Common ancestor of target and HEAD | HEAD |

Changes always shows the aggregate comparison; Staged and Unstaged remain Git-service capabilities but are not exposed as viewer modes.

Outgoing includes all committed branch changes against main or the PR target. Pushing does not clear it. Uncommitted content remains in Changes. Target-only commits are not shown as reversed edits.

An explicit base entered through the Outgoing sidebar base popover takes priority. Otherwise, a known PR target is used when its repository matches origin; an unmapped fork target requires manual selection. Without PR metadata, resolve origin's symbolic default branch, then local main/master if present. Always show the resolved base. Missing refs, unrelated histories, and repositories without a usable base surface errors.

Refresh reads local state only. The window does not fetch, stage, discard, commit, push, or resolve conflicts. Fetching in a terminal updates local refs that subsequent refreshes observe.

## Data boundary

`GitComparisonSnapshot` contains scope, repository identity, file metadata, resolved blob IDs, modes, and a deterministic fingerprint. A single raw+numstat diff supplies tracked file status and statistics. Unmerged entries and untracked paths are added separately. Untracked entries do not invent aggregate line counts.

Outgoing commit endpoints and index blob identities are resolved before content is read. Working-directory contents remain mutable: each selected file is re-read on refresh. A generation token rejects responses from older scopes, files, and worktrees. Index/worktree reads are not a transactional filesystem snapshot.

`LiveGitService` uses the existing CommandRunner and SSH routing. Content reads are capped at 2 MiB per side. Binary, non-UTF-8, symlink, submodule, conflict, metadata-only and oversized changes have explicit notices. Special paths use NUL-delimited Git metadata and literal argv; no source path is interpolated into shell code.

## Rendering and package delivery

The pinned source package lives at `apps/mac/ThirdParty/DiffViewKit`. Its UPSTREAM.md records the independent diff-view revision. SwiftPM/Tuist compiles the wrapper and embeds generated HTML/JavaScript/CSS resources. Codans builds require no npm install, CDN, HTTP server, or absolute path to the independent repository.

To update the package, build and test the independent repository, commit it, then run:

```bash
node scripts/export-swift-package.mjs /path/to/codans/apps/mac/ThirdParty/DiffViewKit
```

The renderer accepts two text snapshots and emits validated file/line intents. Its jsdiff presentation can group hunks differently from Git. Git remains the authority for status, rename detection, and file statistics. Web limits are stricter than the transport limit: 1M UTF-16 units / 10,000 lines per side, 10,000 characters per line, 4,000 rendered lines, and a bounded diff calculation. Unavailable previews are never silently truncated.

The unified window toolbar owns Changes/Outgoing, unified/split layout, and refresh. The native sidebar uses system text, file icons, compact rows, and status characters. A 32-point native file header shows the selected path and line statistics. DiffViewKit receives `chrome: "none"` and renders only code, edge-to-edge: no Web toolbar, duplicate path, instruction strip, footer, or open-file button. Appearance follows the window rather than a separate Web theme toggle. Syntax highlighting and text selection remain inside the component. The WebView stays mounted across loading, scope and file changes. Content updates preserve its presentation; closing the window or explicitly recovering a failed renderer restores host defaults. Search UI, context expansion and large-file virtualization are not implemented. Failed Web content can be recreated using Refresh.

## State and refresh

`DiffFeature` owns worktree identity, mode, base draft/applied base, file filter, selection, loading/error state, and request generations. Preferences are remembered per worktree for the current app session. Base edits take effect on Compare/Return, not on background refresh.

Each open window performs bounded, non-overlapping refreshes every two seconds. Closing cancels its timer/loads. Refresh re-reads the selected file but preserves the Web document when content is unchanged. Local index updates, HEAD movements and remote-ref changes are therefore observed even when no working-directory event fires. Remote requests use the same transport and timeout; no second SSH connection model is introduced.

`DiffWindowManager` owns one normal, resizable NSWindow and independent DiffFeature store per Worktree. Reopening focuses the same window without resetting its comparison. Main-window selection never retargets an existing window. Window titles identify the project and branch. Window frames persist through AppKit autosave; scope/base/file preferences survive close/reopen for the app session.

Closing cancels refresh, content, and editor effects, detaches the hosting view, and releases WKWebView. Only lightweight scope/base/file/layout preferences remain. The standard red close button and Command-W close this window; they do not close terminal tabs. Diff windows can be moved, minimized, resized, and placed on another display. They are neither modal sheets nor floating panels.

The main terminal view has no dependency on Diff visibility, width, or selection. Opening and closing Diff does not resize or remount it. Terminal sessions remain owned by TerminalEngine. Renderer layout/theme changes may reset the component's scroll/selection; restoration is not yet implemented.

## Editor handoff

The host validates the component's document ID and opens the selected current file through `DiffEditorClient`. Local/remote editor selection respects project/global preferences. Supported editors receive line arguments; others open the file without a guaranteed line position.

Old-side/deleted targets are explicitly unavailable. Outgoing/Staged requests open the current file without a historical line. Changes requests re-read the selected content before forwarding a line; if content changed, open without a line. File rows provide an **Open in Editor** context-menu action, including binary/large-file notices. The header and footer do not expose open-file buttons. The component never starts an editor itself.

## Validation

See [execution plan](../exec-plans/git-diff-viewer.md) and [GUI case record](../user-tests/git-diff-viewer.md). Tests include real temporary Git repositories, reducer generation races, editor argument construction, PR-base decoding, independent WebKit rendering and native bridge validation. Remote transport tests must not be described as actual SSH GUI verification.

The file list and code area remain independently resizable inside the Diff window. Background polling does not flash a loading indicator over an existing snapshot.
