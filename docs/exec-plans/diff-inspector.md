# ExecPlan: Diff Inspector

**Status:** Draft
**Author:** Gump
**Date:** 2026-04-29

This is a living document. The Progress, Surprises & Discoveries, Decision
Log, and Outcomes & Retrospective sections must be kept up to date as work
proceeds.

## Purpose

After this plan completes, a codans user can:

- Press ⌘⇧G (or click the Header GV button) on any Worktree and see a
  280 pt right-edge **Diff inspector** listing that Worktree's working-tree
  changes (status + `+adds / −dels`). Visibility persists per-Worktree.
- Click a file row in the inspector to slide a **diff drawer** in from the
  right; the drawer fills the entire terminal region edge-to-edge,
  showing that file's diff (Shiki-syntax-highlighted, with word-level
  inline highlights) rendered via `@pierre/diffs` inside an embedded
  `WKWebView`.
- Switch between unified and split style via a picker on the drawer
  header; the choice persists across launches.
- Select and copy lines from the diff.
- Close the drawer via its `×` button or the inspector row's ▶ chevron.
- Continue using the sidebar, command palette, and tab bar while the
  inspector + drawer are visible.

## Progress

- [x] M0 — Cleanup: deleted `App/Features/GitViewer/`, 5 GitViewer test
  files, `MainWindowConstants.swift`, 3 obsolete docs; stubbed entry
  points in `RootFeature` / `ContentView` / `WorktreeDetailView`; one
  RootFeatureTests case removed and one trimmed. Build green; full
  suite shows only pre-existing baseline failures. (2026-04-29)
- [x] M1 — Rename: bulk perl rename across 28 .swift files moves all
  `gitViewer*` Swift identifiers + the `Worktree.gitViewerVisible`
  Codable key to `diff*` / `diffInspector*` per Design's Renamed table.
  Build green; full suite shows 48 issues (same as M0 baseline). Comments
  / docstrings referencing the historical `GitViewer` name kept as-is —
  only functional identifiers renamed. (2026-04-29)
- [x] M2 — Vendor web bundle + Public API skeleton: 4 web assets
  (`index.html` / `renderer.js` / `renderer.css` / `manifest.json`)
  copied from YiTong tag `0.1.0` (note: tag is `0.1.0`, not `v0.1.0`,
  per upstream — D5); `LICENSE` + `NOTICES.md` added with Apache-2.0
  attribution; `Public.swift` contains the design's public surface plus
  a placeholder `DiffRendererView.body`; `DiffPublicTests` (3 tests)
  pin the configuration defaults. Build green; bundle verified to
  ship the assets at `Contents/Resources/`. (2026-04-29)
- [x] M3 — WebView host + bridge: `DiffWebViewBridge` (276 lines),
  `DiffWebViewCoordinator` (69 lines), `DiffWebView` (87 lines), and
  `DiffRendererView` body update landed; `DiffWebViewBridgeTests`
  (8 tests) all pass. Build green. Bridge protocol diverged from the
  design's table; see Decision Log D8–D14. (2026-04-29)
- [x] M4 — `DiffFeature` reducer: 254-line `DiffFeature.swift` (state +
  six action branches + cancellable per-path effects), `GitService` /
  `GitServiceClient` extended with `diffNumstat` + `showFileAtHEAD`,
  parser additions in `GitOutputParser` for `--numstat -z` /
  `--name-status -z`, `RootFeature.State.diff` mounted with selection
  forwarding through `.diff(.worktreeSelected(...))`. `DiffFeatureTests`
  (6 tests) pass; full suite drops from 48 → 47 issues. (2026-04-29)
- [x] M5 — Inspector view: `DiffInspectorView` + `DiffFileRow` added
  under `App/Features/Diff/Views/`. `ContentView` mounts via
  `.inspector(isPresented: diffInspectorBinding)` on the detail subtree
  with fixed 280 pt column width. Binding routes through the shared
  `.diffInspectorToggledForCurrentWorktree` reducer branch (D21). Build
  green; full suite stable at 47 baseline issues. (2026-04-29)
- [x] M6 — Drawer view: `DiffDrawerView` + `DiffStylePicker` added under
  `App/Features/Diff/Views/`. `WorktreeDetailView` accepts a
  `diffStore: StoreOf<DiffFeature>` parameter and overlays the drawer on
  `terminalRegion` whenever `presentedFilePath != nil`, with
  `.move(edge: .trailing)` + `.opacity` transition and a spring
  animation. `@AppStorage("diffStyle")` persists the unified ↔ split
  toggle (D22). Build green; full suite stable at 47 baseline issues.
  (2026-04-29)
- [x] M7 — End-to-end + review: review fixes landed (C1, I1, I2, I3, I4,
  I5, S2, S6) — see Decision Log D24–D31. Deferred to follow-up:
  XCUITest WebView smoke (low payoff vs. unit tests on the bridge +
  reducer + manifest), `@Environment(\.colorScheme)` plumbing for
  `.automatic` appearance, WebView pre-warm if first-open latency proves
  problematic in real use. Manual smoke walkthrough is the merge-gate
  remaining for the human reviewer. (2026-04-29)

## Surprises & Discoveries

- **M3 — Bridge protocol divergence (2026-04-29)**: The design doc's
  Bridge Protocol v1 table (`setOptions` / `render`) does not match the
  actual vendored JS in renderer.js, which expects `updateConfiguration`
  / `renderDocument` / `initialize` / `teardown`. Discovered while
  inspecting `apps/mac/codans/App/Features/Diff/WebAssets/renderer.js`
  before writing `DiffWebViewBridge`. We honour the JS — the bundle is
  Apache-2.0 NOTICE-clean and we agreed not to patch it. Captured in
  Decision Log D8–D11.
- **M3 — `DiffConfiguration.appearance` projection (2026-04-29)**: The
  JS reads `resolvedAppearance: "dark" | "light"`, not
  `appearance: "automatic" | …`. The bridge resolves `.automatic` to
  `"light"` for now (D15); proper `@Environment(\.colorScheme)` plumbing
  is a follow-up at the SwiftUI boundary in M5/M6.
- **M2 — YiTong tag is `0.1.0`, not `v0.1.0` (2026-04-29)**: GitHub's
  contents-API rejects `--ref v0.1.0` with 404; the working URL pattern
  is `repos/onevcat/YiTong/contents/<path>?ref=0.1.0`.
- **M7 — Stale per-file diff load could leak across Worktree switches
  (2026-04-29)**: `CancelID.diff(path:)` only cancelled re-taps of the
  same row. A Worktree switch left in-flight per-file loads alive, so a
  late `.diffSucceededFor` could write into the post-switch
  `diffsByPath`. Fixed by collapsing `CancelID` to a flat `.diff` slot
  and adding `.cancel(id: .diff)` to `worktreeSelected`'s effect. See
  D24.
- **M7 — `updateNSView` re-encode + re-send storms (2026-04-29)**:
  SwiftUI runs `updateNSView` on every parent re-evaluation (geometry,
  environment, sibling state). Without dedupe, every such tick
  re-serialised the full `renderDocument` envelope and re-tokenised
  Shiki on the JS side — visible jank on color-scheme toggles and
  window resizes. Compounded by `WireDocument.identifier` being a fresh
  UUID per call, which made byte-equality dedupe impossible. Fixed via
  deterministic identifier (S2) plus a two-layer Coordinator dedupe
  (queue dedupe + post-ready send-cache). See D25–D27.
- **M7 — Persisted JSON keys are part of the API surface (2026-04-29)**:
  M1's `toggleGitViewer` → `toggleDiffInspector` rename also rewrote the
  `CommandID` raw value, which is the JSON key in
  `~/.config/codans/shortcuts.json`. Renaming it would silently
  orphan every existing user override of ⌘⇧G. Fixed by keeping the
  Swift identifier renamed but pinning the raw value back to
  `"toggleGitViewer"`. See D28.

## Decision Log

- **D1** (M0, 2026-04-29): Kept `Tests/Performance/DiffParsePerformanceBaselineTests.swift` and its fixture. Reason: `DiffParser` is defined in `apps/mac/codans/Git/DiffParser.swift` (the git-domain module), not in the deleted GitViewer feature; the perf test exercises that domain parser, which still lives.
- **D2** (M0, 2026-04-29): Kept `docs/exec-plans/0005-git-viewer-and-editor.md`. Reason: Status: `Completed (2026-04-20)`. The doc is a historical archive that covers both GitViewer (M1–M4, M8 — superseded) and Editor (M5–M7 — still load-bearing reference). Per plan's "decided per editor-portion at execution" guidance, leave the file as-is.
- **D3** (M0, 2026-04-29): Deleted `docs/design-docs/c7-git-viewer.md`. Reason: 100% GitViewer content with no editor cross-cuts.
- **D4** (M0, 2026-04-29): Deleted `apps/mac/codans/App/Theme/MainWindowConstants.swift` (only contained `gvOverlayWidth` / `gvOverlayMinTerminalWidth`). Plan didn't list it explicitly but its sole consumers are gone.
- **D5** (M2, 2026-04-29): YiTong's git tag is `0.1.0` (not `v0.1.0` as the design doc said). The `--ref v0.1.0` form via `gh api` 404s; the working URL is `repos/onevcat/YiTong/contents/<path>?ref=0.1.0`. Plan's Concrete Steps M2 transcript updated implicitly — runners on this plan should use `0.1.0` (no `v` prefix).
- **D6** (M2, 2026-04-29): `Public.swift`'s `DiffRendererView` ships an inert SwiftUI placeholder body in M2 (M3 wires the WKWebView). The placeholder lets `Public.swift` compile + ship the public surface independently of the bridge work, which keeps M2 a self-contained commit.
- **D7** (M2, 2026-04-29): `DiffPublicTests` is annotated `@MainActor` because the project compiles with main-actor-default isolation (SwiftUI `View` types push the isolation onto sibling types in the same import graph). The test alternative — `nonisolated` initializers on `DiffConfiguration` — would have leaked into the public surface contract.
- **D8** (M3, 2026-04-29): The vendored renderer.js's inbound vocabulary is `initialize` / `renderDocument` / `updateConfiguration` / `teardown` — NOT the design doc's `setOptions` / `render`. Because the bundle is NOTICE-clean (we cannot patch), the wire `type` strings match the JS; Swift API names (`encodeRender`, `encodeSetOptions`) keep the design's vocabulary. Design doc Bridge Protocol table is now superseded by the actual JS contract — followers should reference the live JS.
- **D9** (M3, 2026-04-29): `renderStateChanged` payload shape is `{state, documentIdentifier, summary?, error?}` — not `{phase, fileCount?, error?}`. Bridge maps `state == "rendered"` + `summary.fileCount` → `.didRender(fileCount:)`.
- **D10** (M3, 2026-04-29): `lineActivated` payload uses `number` (not `lineNumber`). Bridge maps `number` → `DiffEvent.didClickLine(lineNumber:)`.
- **D11** (M3, 2026-04-29): `selectionChanged` JS payload carries per-side `start`/`end` (each with `side` + `number`). When `start.side == end.side` we map to `.additions` / `.deletions`; mismatched sides collapse to `.both`.
- **D12** (M3, 2026-04-29): Protocol-version mismatch surfaces as `.didFail(code: "protocol_mismatch", ...)` rather than throwing, so the host UI can render an error rather than silently dropping the message.
- **D13** (M3, 2026-04-29): `DiffDocument.title` doubles as the renderer's required `document.identifier`; if `nil` we mint a `UUID().uuidString` per render.
- **D14** (M3, 2026-04-29): The Coordinator queues outbound `renderDocument` / `updateConfiguration` messages until the `ready` event arrives, then flushes; stale `renderDocument`s in the queue are de-duped (only the latest survives) so we don't flash through outdated content during initial load.
- **D15** (M3, 2026-04-29): `DiffConfiguration.appearance == .automatic` doesn't have a direct renderer equivalent — the JS expects `resolvedAppearance: "dark" | "light"`. M3 resolves `.automatic` → `"light"`. M5/M6 will plumb `@Environment(\.colorScheme)` to resolve this dynamically at the SwiftUI boundary before passing to `DiffWebView`.
- **D16** (M4, 2026-04-29): `refreshRequested` re-fetches the changed-files list using the cached `worktreePath` and *preserves* the per-file diff cache (`diffsByPath` not cleared). Rationale: refresh is "I just edited files in the worktree, recompute the list," not "I switched Worktrees" — surviving file caches stay correct (the per-file diff is recomputed on row-tap if needed). Switching Worktrees still drops everything via `worktreeSelected`.
- **D17** (M4, 2026-04-29): `ChangedFile` / `ChangeStatus` are `public nonisolated` so the `GitService` protocol (also `public`) can return `[ChangedFile]` from `diffNumstat`. Lives in `DiffFeature.swift` rather than `Public.swift` (sealed surface from M3) or a new file under `CodansCore` — keeping the row model adjacent to the reducer that owns its lifecycle.
- **D18** (M4, 2026-04-29): `loadDiff` reads the working-tree side via `String(contentsOf:)` (filesystem) rather than through a new `GitServiceClient` closure. The HEAD side goes through `showFileAtHEAD` because `git show HEAD:<path>` is the only correct way to read a non-current blob, but the working-tree side is just a file read — adding a client seam there would just be a `Process` round-trip via `git show :<path>` for no test benefit (tests use temp directories with real files).
- **D19** (M4, 2026-04-29): `loadDiff` hops onto `MainActor` via `MainActor.run` to construct `DiffFile` / `DiffDocument`. Those types' initializers inherit the App target's MainActor default isolation (SwiftUI `View`-adjacent code in `Public.swift`), and the `.run` closure runs nonisolated. Per the constraint not to touch `Public.swift`, the hop lives in `DiffFeature` instead.
- **D20** (M4, 2026-04-29): `RootFeatureTests.onLaunchExhaustivelyPropagatesSelectionFromStream` updated to receive the new `.diff(.worktreeSelected)` action and to drop the no-op state-change closure on `.selectionChanged` (TestStore reports "no observable modification" when the assigned value matches the existing default). Two other tests (`selectionChangedMirrorsActiveTabFromSnapshot`, `diffInspectorVisibleTracksSelectionAgainstCatalog`) had `gitService.diffNumstat = { _ in [] }` added to their dependency stubs — both run with `exhaustivity = .off`, so the change just neutralizes the new "Unimplemented" issues that the M4 forwarding triggered. Net: full-suite issue count drops from 48 (M3 baseline) to 47.
- **D24** (M7 review fix C1, 2026-04-29): Collapsed `DiffFeature.CancelID` from `case diff(path: String)` to a flat `case diff` and added `.cancel(id: CancelID.diff)` to the `worktreeSelected` effect (both the empty-path and non-empty-path branches). A per-path slot was sufficient for re-tapping the same row but allowed a per-file load from the previous Worktree to survive a Worktree switch and write into the new Worktree's `diffsByPath`. Pinned by `staleDiffLoadIsCancelledOnWorktreeSwitch` in `DiffFeatureTests` — uses an actor-gated continuation to suspend `showFileAtHEAD`, switches Worktrees, and asserts no `.diffSucceededFor` is delivered post-switch.
- **D25** (M7 review fix S2, 2026-04-29): `WireDocument.identifier` is now `doc.title ?? "doc-\(doc.files.map(\.id).joined(separator: ","))"` instead of `doc.title ?? UUID().uuidString`. The UUID-per-call form defeated the Coordinator's send-cache: every call produced a different envelope JSON, so `lastRenderScript == script` could never match. Pinned by `encodeRenderProducesByteIdenticalJSONForEqualInputs` in `DiffWebViewBridgeTests`.
- **D26** (M7 review fix I1, 2026-04-29): Added a post-ready send-cache to `DiffWebViewCoordinator` keyed on `(SendKind, lastScript)`. SwiftUI's `updateNSView` runs on every parent re-evaluation; without this cache an unchanged document and configuration would still re-cross the bridge each tick, re-tokenising Shiki on color-scheme toggles, window resizes, etc. The cache lives behind a `resetSendCache()` hook called from `dismantleNSView` so a fresh WebView mount starts clean. Test-only `markReadyForTesting()` (DEBUG-gated) lets `DiffWebViewCoordinatorTests` exercise the dedupe without rigging up a `WKScriptMessage` round-trip.
- **D27** (M7 review fix I2, 2026-04-29): Replaced the queue's substring-based dedupe (`script.contains("\"renderDocument\"")`) with explicit `(script, kind)` tuples. Substring matching against an opaque envelope JSON is fragile — a queued `.options` payload that happened to contain the literal `"renderDocument"` (e.g. inside a future config string) would have been wrongly evicted. Tuple-based queue dedupe and the post-ready send-cache act on different lifecycles (queue dedupe = before ready; sent-cache = after ready) so they compose cleanly.
- **D28** (M7 review fix I3, 2026-04-29): Pinned `CommandID.toggleDiffInspector` raw value to `"toggleGitViewer"` (Swift identifier renamed during M1; JSON key kept). The override store persists `CommandID.rawValue` as the JSON key, so M1's rename would have silently orphaned every existing user override of ⌘⇧G. Caught by the post-shipping convention documented in `CommandID`'s docstring ("Raw values … must not change once shipped"). Updated `ShortcutOverrideStoreCodableTests`: the `modifierTokensDecodeRegardlessOfOrder` fixture now uses the legacy key, and a new `toggleDiffInspectorPersistsAsLegacyToggleGitViewerKey` test pins the encoded shape. Design doc Renamed table updated to flag this exception.
- **D29** (M7 review fix I4, 2026-04-29): Wrapped `DiffEntryState.loaded` payload in a `LoadedDiffDocument` reference type with identity-based equality (`l === r`). The auto-Equatable on `DiffDocument` walked the full UTF-8 of `oldContents` + `newContents` on every State equality check — with the 500 KB cap that's ~1 MB per parent re-eval. Identity-based wrapper makes State equality O(1). DiffFeatureTests' `fileRowTappedLoadsAndCachesDiff` switched to `exhaustivity = .off` after `.diffSucceededFor` because the test cannot predict the reducer's wrapper instance; the document content is asserted via the live state instead. New `loadedStateEqualityIsConstantTime` pins both the same-instance-equal and different-instance-not-equal contracts.
- **D30** (M7 review fix I5, 2026-04-29): Added `DiffFeatureTests` cases for refresh-preserves-cache, changed-files-failure path, cached-error-short-circuits-row-tap, and line-count-cap. Added `DiffWebViewBridgeTests` cases for fallback-patch round-trip, render-failed → didFail mapping, mixed-side selection collapsing to `.both`, malformed-JSON throwing path, and the deterministic-identifier pinning test. The earlier `mapRenderState` "loading" branch already returns `.didFail(code: "render_state", ...)`; we kept that behaviour because the host UI does not currently distinguish loading-in-progress from a hard failure, and surfacing it as `.didFail` keeps the signal addressable rather than dropping it.
- **D31** (M7 review fix S6, 2026-04-29): Added `DiffWebAssetsManifestTests.manifestProtocolVersionMatchesBridgeExpectation` which decodes `manifest.json` from the app bundle and asserts `protocolVersion == DiffBridgeProtocol.version`. Drift here means every outbound bridge message would surface as `protocol_mismatch` at runtime; the test catches the mismatch in CI instead of in production logs.

## Outcomes & Retrospective

**Completion date:** 2026-04-29

**Summary:** All eight planned milestones (M0–M7) shipped on
`feat/git-changes-inspector` against `origin/main` (`310ecf3`) in nine
commits. The legacy `GitViewerFeature` is gone; the new
`DiffFeature` + 280 pt right-edge inspector + edge-to-edge drawer is in
its place. Diff rendering reuses YiTong's WKWebView bundle (Apache-2.0,
vendored — not imported as a Swift package), wrapping `@pierre/diffs` +
Shiki + `kpdecker/jsdiff`.

**Commits in chronological order:**

1. `d1aacca` docs(diff): add design doc and exec plan for Diff inspector
2. `e66f48b` chore(gitviewer): delete legacy GitViewer implementation and obsolete docs
3. `d45a4b4` refactor: rename gitViewer* identifiers to diff* / diffInspector*
4. `42c8e9f` feat(diff): vendor YiTong web bundle and add public API surface
5. `28ab9ff` feat(diff): implement WebView host + bridge for diff rendering
6. `7c33c84` feat(diff): implement DiffFeature reducer and Root integration
7. `aac6dd0` feat(diff): add Diff inspector column
8. `9e9eb1b` feat(diff): add diff drawer with style picker
9. `5bee4e3` fix(diff): address code-review must-fix items C1, I1-I5, S2, S6

**Verification:**

- `mise exec -- xcodebuild test -workspace codans.xcworkspace -scheme codans` — `Test run with 1094 tests in 139 suites failed after ~18s with 47 issues`. The 47 issues are pre-existing baseline failures (themes / command-palette-run-script / color-parsing / `RootFeatureTests.diffInspectorVisibleTracksSelectionAgainstCatalog` due to unstubbed `HierarchyClient.openPane`/`createTab`); none introduced by this PR.
- All Diff* test suites pass: `DiffPublicTests` (3), `DiffWebViewBridgeTests` (12), `DiffWebViewCoordinatorTests` (5), `DiffFeatureTests` (12), `DiffWebAssetsManifestTests` (1).
- Code review by `agent-skills:code-reviewer` returned `REQUEST CHANGES`; all critical (C1) + important (I1–I5) + the I-related suggestion (S2, S6) items addressed in commit 9 (`5bee4e3`).

**What remains for the human reviewer / follow-up PRs:**

1. Manual smoke walkthrough on a real worktree with mixed working-tree changes (modified, added, deleted, renamed, binary, > 500 KB). The orchestrator could not run the app; the reviewer should validate ⌘⇧G open/close, drawer slide-in, style picker, chevron toggle, and Worktree-switch retargeting.
2. XCUITest for drawer smoke (deferred — bridge + reducer + manifest unit tests cover the same surface from the Swift side).
3. `@Environment(\.colorScheme)` plumbing for `DiffConfiguration.appearance == .automatic` — currently resolves to `.light` at the bridge boundary; M5/M6 wired the colorScheme inside `DiffDrawerView.makeConfig` but standalone embeddings of `DiffRendererView` still need it.
4. WebView pre-warm at inspector mount — only chase if first-open latency feels slow in actual use.
5. Per-Project disable of ⌘⇧G when `supportsWorktrees == false` — currently a silent no-op (Header GV button is hidden but the keyboard shortcut still toggles the flag).

**Lessons:**

- Vendoring a web bundle from a Swift-package-distributed dependency (rather than taking the whole Swift package) is a clean middle path — zero build-system impact, full control of the JS payload — but requires honouring whatever wire vocabulary the JS chose, even if the design doc imagined something simpler. D8 is the canonical example; future bridge work should sniff the JS first before drafting the protocol table.
- Persisted JSON keys are part of the API surface (D28). The "rename Swift identifier, pin raw value" pattern shipping in `CommandID.toggleDiffInspector = "toggleGitViewer"` is the template for any future enum-based persisted-key rename.
- `Equatable` on TCA State enums carries cost when the payload is a large value type (D29). Reference-wrap large payloads — the wrapper's identity-equality is constant-time and the surrounding TCA machinery only cares about structural change, not byte-equal content.

## Context and Orientation

Related documents:

- Design doc (drives this plan): `docs/design-docs/git-changes-inspector.md` —
  read in full before touching code. Owns the API surface, vendoring scope,
  state shape, and rename table.
- Architecture doc: `docs/architecture.md`. Golden rules:
  `docs/golden-rules.md`.
- Reference patterns:
  - `apps/mac/codans/App/Features/CommandPalette/CommandPaletteView.swift` —
    the existing scrim+overlay composition we mirror for the drawer's
    z-stacked overlay attachment style.
  - `~/dev/opensource/Prowl/supacode/Features/DiffView/DiffWindowContentView.swift` —
    supacode's YiTong integration; demonstrates how `DiffDocument` is
    fed and how events are observed. Not in this repo; read on disk.
  - `~/dev/opensource/Prowl/Sources/YiTongWebAssets/Resources/` (via the
    upstream `onevcat/YiTong` repo, not on disk locally) — the source
    of truth for the four web-asset files we vendor.

Key source files in this repo:

- `apps/mac/codans/App/Features/Root/RootFeature.swift` — owns
  `gitViewerOverlayVisible(in:)`, `gitViewerToggledForCurrentWorktree`,
  `toggleGitViewer`, and the `Scope(state: \.gitViewer, action: \.gitViewer)
  { GitViewerFeature() }` mount. M1 renames every `gitViewer*` identifier
  here; M0 stubs the scope mount.
- `apps/mac/codans/App/ContentView.swift` — composes the
  `NavigationSplitView`. M5 attaches `.inspector(isPresented:)` to the
  detail column.
- `apps/mac/codans/App/Features/WorktreeDetail/WorktreeDetailView.swift` —
  hosts the `terminalRegion`. M6 attaches the drawer overlay.
- `apps/mac/codans/App/Features/WorktreeHeader/WorktreeHeaderFeature.swift` —
  owns `gitViewerToggleTapped` and its delegate. M1 renames.
- `apps/mac/codans/App/Features/WorktreeHeader/HeaderGitViewerToggle.swift` —
  the toolbar button view. M1 renames file + type.
- `apps/mac/CodansCore/Worktree.swift` — owns the persisted
  `gitViewerVisible: Bool` and its `CodingKeys`. M1 renames the property
  and the JSON key together (no alias decode).
- `apps/mac/CodansCore/HierarchyClient.swift` — owns
  `setWorktreeGitViewerVisible`. M1 renames the method.
- `apps/mac/codans/App/Shortcuts/` — owns the ⌘⇧G shortcut catalog
  entry whose command id is `toggleGitViewer`. M1 renames.
- `apps/mac/codans/App/Features/GitViewer/` — entire directory deleted
  in M0. M2+ creates `apps/mac/codans/App/Features/Diff/` from scratch.

Terms of art used in this plan:

- **Bridge protocol** — the JSON-message convention between the Swift
  host (the `DiffWebViewBridge`) and the JavaScript renderer running
  inside the `WKWebView`. Every message is wrapped in
  `{ protocolVersion: 1, type, payload, id }` per the table in the design
  doc.
- **Vendored web bundle** — the four files (`index.html`, `renderer.js`,
  `renderer.css`, `manifest.json`) copied from YiTong v0.1.0's
  `Sources/YiTongWebAssets/Resources/` into our repo at
  `apps/mac/codans/App/Features/Diff/WebAssets/`. We do not modify
  these files in v1.
- **Inspector** — the SwiftUI third column attached via the macOS 14+
  `.inspector(isPresented:)` modifier on the detail-column subtree.
- **Drawer** — the SwiftUI overlay attached to `terminalRegion` via
  `.overlay { ... }` (not a system-level `.sheet` or `.fullScreenCover`).

## Plan of Work

The work splits into eight milestones (M0–M7). Each milestone is a single
independently-verifiable commit (or, for M7, two commits: one for review
fixes plus the PR creation). The order is non-negotiable: M0 has to
finish before M1 because M1 renames require a green build, which M0
provides; M2 cannot start before M1 because the `Worktree` rename touches
catalog encoding which the rest of the app depends on. M3 and M4 are
internal-to-Diff modules that can in principle proceed in parallel, but
the plan keeps them sequential because both touch the same module
namespace and both need passing tests before the next milestone consumes
them.

### Milestone 0 — Cleanup

Delete the existing GitViewer implementation, its tests, and its obsolete
design / exec-plan documents; stub the remaining entry points so the
project compiles cleanly with no GitViewer feature mounted. After M0 the
toolbar GV button and ⌘⇧G binding still exist (the entry framework
stays), but pressing them only toggles the persisted
`Worktree.gitViewerVisible` flag and renders nothing — which is fine for
the duration of this PR's branch.

The work, in narrative order:

1. Delete the directory `apps/mac/codans/App/Features/GitViewer/`
   and these test files: `GitViewerFeatureTests.swift`,
   `GitViewerLargeDiffCommandTests.swift`, `GitViewerSnapshotTests.swift`,
   `WorktreeDetailViewLayoutTests.swift`,
   `Performance/GitViewerReducerPerformanceTests.swift`. For
   `Performance/DiffParsePerformanceBaselineTests.swift` and
   `Performance/fixtures/diff-1000-lines.txt`: read the test once; if the
   parser it exercises is the deleted GitViewer parser, delete; if it
   exercises a parser still living in the git-domain library, keep.
2. Read `docs/exec-plans/0005-git-viewer-and-editor.md` once. If the
   editor portion is no longer load-bearing (i.e. the editor work has
   shipped and the doc is purely historical), delete the file. If the
   editor portion still contains plan items relevant to current work,
   leave the file in place. Same call for
   `docs/design-docs/c7-git-viewer.md` (delete unless still load-bearing
   for non-GitViewer reasons).
3. Delete `docs/design-docs/mw-t3-gitviewer-overlay-shortcuts.md` and
   `docs/exec-plans/mw-t3-gitviewer-overlay-shortcuts.md` unconditionally.
4. In `RootFeature.swift`, delete:
   - `var gitViewer: GitViewerFeature.State = .init()` (the State field).
   - `case gitViewer(GitViewerFeature.Action)` (the Action case).
   - The `Scope(state: \.gitViewer, action: \.gitViewer) { GitViewerFeature() }`
     reducer mount.
   - The `.gitViewer(.worktreeSelected(...))` forwarding inside the
     selection-changed reducer branch.
   Leave intact: `gitViewerOverlayVisible(in:)`, the
   `.gitViewerToggledForCurrentWorktree` reducer branch (still calls
   `setWorktreeGitViewerVisible`), and `.toggleGitViewer`. The toggle path
   now persists the flag with no observable downstream effect.
5. In `ContentView.swift`, delete the `gitViewerStore:
   store.scope(state: \.gitViewer, action: \.gitViewer)` argument
   threaded into `WorktreeDetailView`. Delete any in-line GV-overlay
   view code.
6. In `WorktreeDetailView.swift`, delete the `gitViewerStore`,
   `overlayVisible` parameters, the `overlayContent` body, the
   `shouldShowOverlay(totalWidth:)` helper, and any `.overlay { ... }`
   / `MainWindowConstants.gv*` references. Drop `MainWindowConstants`
   itself if empty after removal.
7. Run `mise exec -- xcodebuild build-for-testing -workspace
   apps/mac/codans.xcworkspace -scheme codans -destination
   'platform=macOS,arch=arm64'` until it returns `TEST BUILD SUCCEEDED`.
   Run the full test suite; the only delta against `origin/main` should
   be the deleted tests.

Acceptance: `make -C apps/mac mac-build` succeeds; the test suite shows
the same baseline failures as `origin/main` minus the deleted GitViewer
tests; `git status` shows only deletions and minimal stub edits to
ContentView / WorktreeDetailView / RootFeature.

Commit message: `chore(gitviewer): delete legacy GitViewer implementation
and obsolete docs`.

### Milestone 1 — Rename to diff / diffInspector

Rename every `gitViewer*` Swift identifier (and the `Worktree` Codable key)
to `diff*` / `diffInspector*` per the Renamed table in the design doc.
This is mechanical grep-and-replace plus a single `Codable` key change;
zero behavioral changes.

The work:

1. In `apps/mac/CodansCore/Worktree.swift`, rename the property
   `gitViewerVisible` → `diffInspectorVisible` and the `CodingKeys` case
   `gitViewerVisible` → `diffInspectorVisible`. Update both the
   `init(from:)` decode and the `encode(to:)` paths so the JSON key on
   disk is `diffInspectorVisible`. Remove all references to the old key
   name in this file.
2. In `apps/mac/CodansCore/HierarchyClient.swift`, rename
   `setWorktreeGitViewerVisible` → `setWorktreeDiffInspectorVisible`.
   Update the closure type, all call sites, and any test doubles in the
   live + test variants.
3. In `RootFeature.swift`, perform the renames listed in the design
   doc's Renamed table for this file. Remove old names completely; the
   shortcut catalog command id `toggleGitViewer` becomes
   `toggleDiffInspector` here.
4. In `WorktreeHeaderFeature.swift`, rename `gitViewerToggleTapped` →
   `diffInspectorToggleTapped` and the delegate case
   `.gitViewerToggleRequested` → `.diffInspectorToggleRequested`. Update
   call sites in `RootFeature` (the receiver of the delegate event).
5. Rename the file `HeaderGitViewerToggle.swift` →
   `HeaderDiffInspectorToggle.swift`, the type inside, and all
   references in the toolbar item construction in `WorktreeDetailView.swift`.
6. In the shortcut catalog (`apps/mac/codans/App/Shortcuts/...`),
   rename the command id `toggleGitViewer` → `toggleDiffInspector`.
   This is a string id; the bound action keypath also changes
   accordingly.
7. Update test files that reference any of the renamed symbols
   (`RootFeatureTests.swift`, `WorktreeHeaderFeatureTests.swift`, any
   test that constructs `Worktree(...)` with the old parameter label).
   Test files referencing the JSON key `gitViewerVisible` need their
   fixtures updated; tests that exercise old-format catalogs may need
   to be deleted (decided per test on read).
8. Run the build + full test suite. Expected result: same baselines as
   M0, no new failures.

Acceptance: `git grep -l 'gitViewer\|GitViewer'` returns only this
ExecPlan, the design doc, and the (deleted-this-PR) `0005-` exec plan
if it survived M0. `make -C apps/mac mac-build` succeeds. Test suite
shows same delta as M0.

Commit message: `refactor: rename gitViewer* to diff* / diffInspector*`.

### Milestone 2 — Vendor web bundle + Public API skeleton

Create the new feature module, copy the four vendored web-asset files
into it, write the public API surface (types only, no `WKWebView` yet),
and register the asset resources with Tuist so they ship in the bundle.

The work:

1. Create directory `apps/mac/codans/App/Features/Diff/` and
   subdirectories `Internal/`, `Views/`, `WebAssets/`.
2. Source the four files from the upstream YiTong v0.1.0 release:
   - `index.html`
   - `renderer.js`
   - `renderer.css`
   - `manifest.json`
   Use `gh api repos/onevcat/YiTong/contents/Sources/YiTongWebAssets/Resources/<file>
   --ref v0.1.0 -H 'Accept: application/vnd.github.raw'` (or pin to the
   commit SHA referenced in `manifest.json`). Save into
   `apps/mac/codans/App/Features/Diff/WebAssets/`. Do not modify the
   files.
3. Create `WebAssets/LICENSE` containing the Apache-2.0 license text plus
   the NOTICE block listed in the design doc's Vendoring & License
   section. Create or amend top-level `NOTICES.md` to point to this file.
4. Create `apps/mac/codans/App/Features/Diff/Public.swift`
   containing the public types from the design doc's Public API section
   verbatim. Implement `DiffRendererView.body` as a placeholder
   (`Color.gray` + `Text("DiffRendererView placeholder")`) — M3 fills it
   in.
5. Update Tuist project (`apps/mac/Project.swift`) to include the new
   directory in the codans target sources and the `WebAssets/`
   directory as resources. Run `make -C apps/mac generate` to regenerate
   the Xcode project. Verify `xcodebuild ...` build succeeds and the
   `Codans.app` bundle includes the four web-asset files at
   `Contents/Resources/WebAssets/` (or wherever Tuist places copy-bundle
   resources).
6. Add a single smoke unit test `Tests/DiffPublicTests.swift` asserting
   `DiffConfiguration()` defaults match the design doc table
   (style=.unified, indicators=.bars, allowsSelection=true, etc.). This
   pins the API contract.

Acceptance: build succeeds; the new test passes; `unzip -l
DerivedData/.../Codans.app | grep WebAssets` shows the four files
plus LICENSE.

Commit message: `feat(diff): vendor YiTong web bundle and add public API
surface`.

### Milestone 3 — WebView host + bridge

Implement the `WKWebView` host, the JS↔Swift bridge, and the public
`DiffRendererView`. End of milestone: a SwiftUI preview can render a
hardcoded two-line patch and observes `didFinishInitialLoad`.

The work:

1. `Internal/DiffWebViewBridge.swift` — JSON encode/decode between the
   public `DiffDocument` / `DiffConfiguration` / `DiffEvent` types and
   the protocol-v1 envelope from the design's Bridge Protocol table.
   `Codable` types for each message, a `BridgeProtocolVersion` constant,
   and round-trip helpers. ~80 lines.
2. `Internal/DiffWebViewCoordinator.swift` — `WKScriptMessageHandler`
   that decodes incoming messages, surfaces them as `DiffEvent` callbacks,
   and forwards `protocol_mismatch` errors. Holds a weak ref to the
   `DiffWebView` for outbound messages.
3. `Internal/DiffWebView.swift` — `NSViewRepresentable` wrapping a
   `WKWebView`. On `makeNSView`: configure `WKWebViewConfiguration` with
   `.nonPersistent()` data store, register the script-message handler,
   load `WebAssets/index.html` via `loadFileURL(_:allowingReadAccessTo:)`.
   On `updateNSView`: if `document` or `configuration` changed, send
   `setOptions` then `render` via `evaluateJavaScript`.
4. Update `DiffRendererView.body` to embed `DiffWebView`.
5. Add a minimal SwiftUI Preview (`#Preview`) at the bottom of
   `Public.swift` that renders a two-line `DiffFile` and prints
   `DiffEvent` values to console. Verify the preview in Xcode shows a
   syntax-highlighted diff.
6. Tests:
   - `Tests/DiffWebViewBridgeTests.swift` — encode/decode round-trips
     for each message type, protocolVersion mismatch surfaces as
     `didFail`, payload schema matches what `renderer.js` expects (we
     read `renderer.js` to extract its parser regex once and pin a
     fixture).
   - No automated WebView smoke test in M3 (deferred to M7).

Acceptance: bridge tests pass; SwiftUI preview renders a diff (manual
Xcode preview check); `DiffEvent.didFinishInitialLoad` is observed by
the preview's `onEvent` closure within ~500 ms on M1 hardware.

Commit message: `feat(diff): implement WebView host + bridge for diff
rendering`.

### Milestone 4 — DiffFeature reducer

Implement the TCA feature: state, actions, reducer body, GitClient calls
for the changed-files list and per-file diff load. Wire
`RootFeature.State.diff` and the `Scope(...)` mount. End of milestone:
`TestStore` exercises the worktreeSelected → changedFilesSucceeded →
fileRowTapped → diffSucceeded happy path plus error/cancel paths.

The work:

1. `DiffFeature.swift` per the design doc's TCA State section. The
   reducer has six branches:
   - `worktreeSelected(...)` — caches projectID/worktreeID/path, sets
     `changedFiles = .loading`, kicks off two parallel `GitClient`
     calls (`diffNumstat` for adds/removes counts, `statusPorcelain`
     for status letters). Cancels any prior in-flight loads via
     `.cancellable(id:)`.
   - `changedFilesSucceeded([ChangedFile])` / `changedFilesFailed` —
     stores result.
   - `fileRowTapped(path:)` — toggles `presentedFilePath`. If newly
     selected and not yet in `diffsByPath`, sets
     `diffsByPath[path] = .loading` and kicks off the per-file diff
     load. The load reads `oldContents` (via `git show HEAD:<path>`)
     and `newContents` (via filesystem read) and packages them into a
     `DiffDocument`. Above caps it produces
     `.tooLarge(reason:, copyCommand:)`. Cancellation as above.
   - `drawerCloseRequested` — sets `presentedFilePath = nil`. Does NOT
     clear `diffsByPath` (cache survives).
   - `diffSucceededFor(...)` / `diffFailedFor(...)` /
     `diffTooLargeFor(...)` — stores result.
   - `styleChanged(DiffStyle)` — updates `state.style`. The view layer
     also writes `@AppStorage("diffStyle")` (not the reducer's job).
2. Extend `GitClient` (in the git-domain module the project already
   has) with two methods if they don't exist:
   - `diffNumstat(at:) async throws -> [(oldPath, newPath, +N, −M)]`
   - `showFileAtHEAD(path:in:) async throws -> String?`
   Reuse existing methods where they already cover this.
3. Add `var diff: DiffFeature.State = .init()` to `RootFeature.State`,
   `case diff(DiffFeature.Action)` to `RootFeature.Action`, and the
   `Scope(state: \.diff, action: \.diff) { DiffFeature() }` mount in
   `RootFeature.body`. In the selection-changed reducer branch (where
   the old `.gitViewer(.worktreeSelected(...))` lived), forward the
   new tuple to `.diff(.worktreeSelected(...))`.
4. Tests `Tests/DiffFeatureTests.swift`:
   - Happy path: worktreeSelected → changedFilesSucceeded → state has
     `loaded([...])`.
   - Per-file load: fileRowTapped → diffsByPath[path] = .loading →
     diffSucceededFor → .loaded(doc).
   - Cache: a second fileRowTapped on the same path doesn't re-issue
     the load.
   - Cancel: worktreeSelected during in-flight load cancels the prior
     load (no .changedFilesSucceeded with the old worktree's data is
     accepted).
   - Drawer close: drawerCloseRequested clears `presentedFilePath`,
     keeps `diffsByPath`.
   - Style change: `.styleChanged(.split)` updates state.style.

Acceptance: `mise exec -- xcodebuild test ...` shows the new test suite
passes; existing RootFeatureTests pass unchanged.

Commit message: `feat(diff): implement DiffFeature reducer and Root
integration`.

### Milestone 5 — Inspector view

Implement the inspector column body and mount it on the detail subtree
via `.inspector(isPresented:)`. End of milestone: ⌘⇧G shows the
inspector, sidebar Worktree-switch retargets it in place.

The work:

1. `Views/DiffFileRow.swift` — single row: status badge (M / A / D / R),
   path (truncated head-first to ~32 chars), `+N -M` adds/removes, and
   an open/closed chevron (▶/▼). Tap action calls a closure passed by
   parent (will dispatch `fileRowTapped(path:)`).
2. `Views/DiffInspectorView.swift` — the inspector body. Fixed 280 pt
   width. Header: `Changes (N)` + a refresh button that dispatches
   `.refreshRequested`. Body: a `LazyVStack` of `DiffFileRow` over
   `state.changedFiles.loaded`. Empty state for `.loaded([])`. Loading
   state with `ProgressView()`. Error state with retry button.
3. In `ContentView.swift`'s detail-column subtree, attach
   `.inspector(isPresented: bindingFromRootFeature)
   { DiffInspectorView(store: store.scope(...)) }`. The binding maps
   `RootFeature.diffInspectorVisible(in:)` (read) to
   `.toggleDiffInspector` (write); the read uses
   `hierarchyManager.catalog` exactly as the previous overlay-visible
   binding did.
4. Manual smoke (run `make mac-run-app`):
   - Select a Worktree with changes. Press ⌘⇧G. Inspector slides in
     from the right showing the 3 file rows.
   - Press ⌘⇧G again. Inspector slides out.
   - With inspector visible, switch to a different Worktree via the
     sidebar. Inspector retargets in place; rows refresh.
5. No new automated test added in M5 (the inspector body is a thin
   render of state already covered by `DiffFeatureTests`).

Acceptance: build succeeds; test suite stays green; manual smoke passes.

Commit message: `feat(diff): add Diff inspector column`.

### Milestone 6 — Drawer view

Implement the diff drawer overlay attached to `terminalRegion`, the
unified-vs-split picker, and the row-tap → drawer-open / `×`-or-chevron
→ drawer-close flow.

The work:

1. `Views/DiffStylePicker.swift` — segmented picker for unified ↔ split.
   Reads/writes `@AppStorage("diffStyle")` AND dispatches
   `.styleChanged(...)` so the reducer state mirrors the persisted
   value.
2. `Views/DiffDrawerView.swift` — the drawer body. Header with: file
   path label, `DiffStylePicker`, `×` close button (dispatches
   `.drawerCloseRequested`). Body: an `if-let` switch on
   `state.diffsByPath[state.presentedFilePath ?? ""]`:
   - `.loading` → `ProgressView()` filling the body.
   - `.loaded(doc)` → `DiffRendererView(document: doc, configuration:
     DiffConfiguration(style: state.style, ...))`.
   - `.error(err)` → error block + Retry button.
   - `.tooLarge(...)` → placeholder + Copy-command button.
3. In `WorktreeDetailView.swift`, on `terminalRegion(address:)` attach:
   `.overlay { if state.diff.presentedFilePath != nil { DiffDrawerView(store: ...).zIndex(80).transition(.move(edge: .trailing).combined(with: .opacity)) } }`
   and `.animation(.spring(response: 0.32, dampingFraction: 0.85),
   value: state.diff.presentedFilePath)`. The store reference is
   threaded by `ContentView` as a new parameter.
4. Update `DiffFileRow`'s tap closure to dispatch `fileRowTapped(path:)`
   to the diff store. Update the chevron icon: ▶ when `presentedFilePath
   != row.path`, ▼ when equal. Re-tapping a row that is already
   presented is a no-op (per design — the drawer doesn't toggle from
   the row, it only opens; close must come from `×` or chevron-on-the-
   currently-open-row, not double-tap-the-same-row).
   Wait — that's a subtle point: the design says "再次点击同一文件 = 无响应"
   AND "inspector 上的 ▶ chevron 可同步关闭详情". Reconciliation:
   tapping the **row body** when its file is already open → no-op.
   Tapping the **chevron icon** of the currently-open row → close.
   Implementation: split the tap target — the chevron has its own
   `Button` that dispatches `.drawerCloseRequested`; the rest of the
   row's body dispatches `.fileRowTapped(path:)` only when not
   currently presented. (Decision Log entry for this split.)
5. Manual smoke:
   - Click a row → drawer slides in, diff renders with syntax highlight.
   - Click the picker → unified ↔ split switch is visible.
   - Click `×` → drawer slides out.
   - Click the same row's chevron → drawer slides out (chevron flips
     ▼→▶).
   - Click a different row while drawer is open → drawer content
     swaps to that file's diff (smooth, no slide-out-and-in).
   - Re-launch the app → `diffStyle` persists.

Acceptance: build + test suite green; manual smoke walkthrough passes
all six steps.

Commit message: `feat(diff): add diff drawer with style picker`.

### Milestone 7 — End-to-end + review

Final hardening + external review.

The work:

1. End-to-end manual smoke walkthrough on a Worktree with realistic
   changes (modified, added, deleted, renamed, binary, one >500 KB
   file). Record any regression in Surprises & Discoveries; if
   blocking, fix before commit.
2. Add a single XCUITest `Tests/DiffDrawerSmokeUITests.swift` that
   launches the app with a fixture worktree, opens the inspector via
   ⌘⇧G, taps the first file row, asserts the drawer becomes visible
   within 2 s. Don't snapshot the WebView's pixel output.
3. Spawn `agent-skills:code-reviewer` against the cumulative diff from
   M0–M6. Hand the agent: design doc path, this exec plan path, and
   the commit SHAs. Address any blocker / must-fix findings as a
   follow-up commit; suggestion-grade comments weighed against scope
   discipline (defer to a follow-up if out of scope, note in Decision
   Log).
4. Open PR. Ensure PR description references the design doc and lists
   the eight commit SHAs.

Acceptance: reviewer agent returns no blocker / must-fix items (or
they're fixed); manual smoke passes; XCUITest green; PR is open with
clean description.

Commit messages: `test(diff): add drawer smoke UI test` (for M7 step 2),
`fix(diff): <reviewer-finding>` (for any review-driven fixes).

## Concrete Steps

All commands run from the repo root unless noted. The repo root is
`/Users/wanggang/.prowl/repos/codans/refactor/git`.

### Common build / test commands

```
$ cd apps/mac
$ mise exec -- xcodebuild build-for-testing \
    -workspace codans.xcworkspace -scheme codans \
    -destination 'platform=macOS,arch=arm64' 2>&1 | tail -5
# expected: ** TEST BUILD SUCCEEDED **

$ mise exec -- xcodebuild test \
    -workspace codans.xcworkspace -scheme codans \
    -destination 'platform=macOS,arch=arm64' 2>&1 | tail -10
# expected: ** TEST SUCCEEDED ** (modulo pre-existing baseline failures)

$ make -C apps/mac lint
# expected: same baseline lint violations as origin/main; no new ones
# in our touched files

$ cd ../..
$ /commit
# at each milestone's tail
```

### M2 specifics — fetching vendored assets

```
$ mkdir -p apps/mac/codans/App/Features/Diff/WebAssets
$ for f in index.html renderer.js renderer.css manifest.json; do \
    gh api repos/onevcat/YiTong/contents/Sources/YiTongWebAssets/Resources/$f \
       --ref v0.1.0 -H 'Accept: application/vnd.github.raw' \
       > apps/mac/codans/App/Features/Diff/WebAssets/$f; \
  done
$ wc -l apps/mac/codans/App/Features/Diff/WebAssets/*
# expected: nonzero line counts; renderer.js is the largest (~50–100 KB)

$ cat apps/mac/codans/App/Features/Diff/WebAssets/manifest.json
# expected: { "rendererVersion": "...", "protocolVersion": 1, "files": [...] }
```

### M3 specifics — bridge round-trip test

```
$ mise exec -- xcodebuild test \
    -workspace apps/mac/codans.xcworkspace -scheme codans \
    -only-testing:codans/DiffWebViewBridgeTests \
    -destination 'platform=macOS,arch=arm64'
# expected: all DiffWebViewBridgeTests tests pass (>= 6)
```

### M7 specifics — code review handoff

Spawn via the Agent tool (`subagent_type: "agent-skills:code-reviewer"`):

```
prompt:
Review eight commits on branch feat/git-changes-inspector that introduce
the Diff inspector + drawer (replacing the legacy GitViewer):

- Design: docs/design-docs/git-changes-inspector.md
- ExecPlan: docs/exec-plans/diff-inspector.md
- Commits: <SHAs filled in at runtime>

Decisions already made (don't re-litigate):
- D1: WKWebView-backed renderer via vendored YiTong web bundle
  (Apache-2.0). Reasons in Design's Vendoring & License section.
- D2: Inspector + drawer composition. Reasons in Design's Architecture
  section (Alternatives D, E, F).
- D3: gitViewer* → diff* rename with no Codable alias. Reason: design
  freshness over migration cost; data loss bounded to a single
  per-Worktree boolean.

Focus on:
- Correctness (state machine, bridge protocol, error handling).
- Resource lifecycle (WKWebView lifetime, message-handler retain
  cycles).
- Tests (coverage of error paths, cancellation).
- License compliance (NOTICE, LICENSE, attribution).
- Scope discipline (no opportunistic refactors outside the design's
  Component Boundaries).
```

## Validation and Acceptance

End-to-end behavior the user will exercise to confirm the feature works:

1. Launch the app with a Worktree that has modified, added, deleted, and
   renamed files in working tree. Press ⌘⇧G. Within 200 ms, the right-
   edge inspector slides in and lists each file with its status badge
   and `+adds / −dels`.
2. Click the first row. Within 500 ms, the drawer slides in over the
   terminal region and renders that file's unified diff with Shiki
   syntax highlighting and word-level inline highlights for changed
   regions.
3. Click the unified ↔ split picker on the drawer header. The diff
   reflows to side-by-side. Re-launch the app. The picker remembers
   `split`.
4. Select a span of lines in the diff and press ⌘C. A normal text copy
   lands in the clipboard (mixed-line edge case acceptable per Risk).
5. Click the drawer's `×`. Drawer slides out; terminal regains focus
   immediately (typing into the terminal works without an extra click).
6. Click a different row in the inspector. Drawer slides in for that
   file. Click the same row's `▼` chevron. Drawer slides out; chevron
   flips to `▶`.
7. With the drawer open, click another Worktree in the sidebar. The
   drawer closes; the inspector retargets to the new Worktree's
   changes; clicking a file there opens the drawer with that file's
   diff (no leakage from the previous Worktree's cache).
8. Open the largest file (>500 KB or binary). The drawer shows
   "This diff is too large to render. Run `cd <path> && git diff
   <file>`" with a Copy button.
9. Press ⌘⇧G again. Inspector slides out. Re-launch the app. Visibility
   per-Worktree is preserved (the Worktree that was visible is visible
   again, others are not).

Automated acceptance: full `xcodebuild test` is green (modulo pre-
existing baseline failures); `make -C apps/mac lint` shows no new
violations in touched files; the new XCUITest from M7 passes.

## Idempotence and Recovery

- M0 is destructive (deletes files). If interrupted mid-way: `git
  status` shows partial deletions; resume by running the remaining
  `rm` calls plus the stub edits. The `git checkout -- <path>`
  command reverts a partial deletion if needed.
- M1 is mostly mechanical rename. If a build error reveals a missed
  reference, grep with `git grep -i "gitViewer\|GitViewer"` and rename
  the residual occurrences.
- M2's vendoring is idempotent: re-running the `for f in ...; do gh
  api ... ; done` loop overwrites the four files with the same content
  (provided the `--ref v0.1.0` pin doesn't move). Verify with `shasum`
  if drift is suspected.
- M3–M6 are additive (new files). Partial progress is recoverable via
  `git stash` then `git checkout` of the in-progress files.
- M7's review pass is the only milestone whose action (PR creation) is
  externally visible; if it fails partway, `gh pr close <num>` removes
  the PR and the local branch can be re-pushed.

## Artifacts and Notes

(To be filled with command output during execution.)

## Interfaces and Dependencies

In `apps/mac/codans/App/Features/Diff/Public.swift`:

```swift
public struct DiffDocument: Equatable, Sendable { ... }
public struct DiffFile: Equatable, Sendable, Identifiable { ... }
public struct DiffConfiguration: Equatable, Sendable { ... }
public enum DiffAppearance: String, Equatable, Sendable { ... }
public enum DiffStyle: String, Equatable, Sendable { ... }
public enum DiffIndicators: String, Equatable, Sendable { ... }
public enum InlineChangeStyle: String, Equatable, Sendable { ... }
public enum DiffEvent: Equatable, Sendable { ... }
public struct SelectionRange: Equatable, Sendable { ... }
public enum SelectionSide: String, Equatable, Sendable { ... }
public struct DiffRendererView: View { ... }
```

(Field-by-field signatures live in the design doc.)

In `apps/mac/codans/App/Features/Diff/Internal/DiffWebViewBridge.swift`:

```swift
struct DiffWebViewBridge {
  static let protocolVersion: Int = 1
  static func encode(_ document: DiffDocument) throws -> String  // JSON
  static func encode(_ configuration: DiffConfiguration) throws -> String
  static func decode(_ rawMessage: String) throws -> DiffEvent
}
```

In `apps/mac/codans/App/Features/Diff/DiffFeature.swift`:

```swift
@Reducer
struct DiffFeature {
  @ObservableState struct State: Equatable { /* per design */ }
  enum Action { /* per design */ }
  // body uses .cancellable(id:) for changedFiles + per-file diff loads
  // dependencies: \.gitClient (existing live + test variants)
}
```

In `apps/mac/CodansCore/Worktree.swift`:

```swift
public struct Worktree: Codable, Equatable, Sendable {
  // ...
  public var diffInspectorVisible: Bool   // renamed from gitViewerVisible
  // CodingKeys updated; no alias decode
}
```

In `apps/mac/CodansCore/HierarchyClient.swift`:

```swift
public struct HierarchyClient {
  // ...
  public var setWorktreeDiffInspectorVisible:
    @Sendable (ProjectID, WorktreeID, Bool) async throws -> Void
}
```

No new third-party Swift dependencies. The four vendored web-asset
files are bundle resources, registered via Tuist; they have no
dependency-management surface.
