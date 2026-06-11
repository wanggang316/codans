# Design Doc: Diff Inspector

**Status:** Draft
**Author:** Gump
**Date:** 2026-04-29

## Context

The current `GitViewer` shows working/staged/log scope tabs in a 360 pt
right-edge overlay. We replace it with a thinner two-piece UI: a 280 pt
right-edge **Diff inspector** lists changed files for the active Worktree,
and an on-demand **drawer** fills the entire terminal region with a single
file's diff.

Diff rendering reuses YiTong's WKWebView bundle (Apache-2.0, vendored — not
imported as a Swift package), which wraps `@pierre/diffs` (Apache-2.0) +
Shiki + `kpdecker/jsdiff` (BSD-3-Clause).

Superseded by this doc (delete during execution):
- `docs/design-docs/c7-git-viewer.md`
- `docs/design-docs/mw-t3-gitviewer-overlay-shortcuts.md`
- `docs/exec-plans/mw-t3-gitviewer-overlay-shortcuts.md`
- `docs/exec-plans/0005-git-viewer-and-editor.md` — GitViewer half only;
  retain file if editor portion still load-bearing.

## Goals

User-observable behavior after this change:

- ⌘⇧G / Header GV button / Command-Palette "Toggle Git Viewer" shows the
  per-Worktree Diff inspector. Visibility persists per-Worktree.
- Inspector lists all working-tree changes with status + `+adds / −dels`.
- Click a file row → drawer slides in from the right and fills the
  terminal region.
- Drawer header has unified ↔ split picker; choice persists via
  `@AppStorage("diffStyle")`.
- Diffs are syntax-highlighted (Shiki), with word-level inline highlights
  and selectable text.
- Close drawer via `×` button **or** the row's ▶ chevron (inverse).
- Sidebar / Command Palette / TabBar remain interactive while inspector +
  drawer are visible.
- The Diff component is self-contained; reusable for future commit-detail
  / blame / stash surfaces.

## Non-Goals

- Commit log / history view (deferred).
- Stage / unstage from inspector (read-only).
- Schema backwards compatibility. `Worktree.gitViewerVisible` is renamed
  directly to `Worktree.diffInspectorVisible`; no alias decode.
- Bundling `@pierre/diffs` from npm; we vendor pre-bundled JS, no Node
  toolchain.
- Cross-platform parity. macOS only.

## Architecture

### Layout

Default (no file selected):

```
┌────────┬────────────────────────────┬────────────────┐
│        │                            │ Changes (3)    │
│ Side   │  Terminal / Code           │  ─────────     │
│ bar    │                            │   path/A.swift │
│        │                            │   path/B.swift │
└────────┴────────────────────────────┴────────────────┘
```

After clicking file B:

```
┌────────┬─────────────────────────────────┬────────────────┐
│        │  TabBar  (visible, unchanged)   │ Changes (3)    │
│        ├─────────────────────────────────┤  ─────────     │
│ Side   │                                 │   path/A.swift │
│ bar    │  Diff drawer for B              │   path/B ◀     │
│        │  (covers entire terminal region)│   path/C.swift │
└────────┴─────────────────────────────────┴────────────────┘
```

**Inspector** — mounted via `.inspector(isPresented:)` on the detail-column
subtree (macOS 14+). Width: fixed 280 pt. Visibility binds to
`RootFeature.diffInspectorVisible(in:)`.

**Drawer** — mounted via `.overlay { ... }` on
`WorktreeDetailView.terminalRegion`. Fills entire terminal region edge-to-
edge. Slides in via `.move(edge: .trailing).combined(with: .opacity)` +
`.spring(response: 0.32, dampingFraction: 0.85)`. Terminal stays mounted
underneath.

Z-order: terminal `0`, drawer `80`, command palette `100`, SwiftUI sheets
above all.

### Diff Component

```
DiffRendererView (NSViewRepresentable)
        │
        ▼
   DiffWebView (WKWebView)
        │  loads WebAssets/index.html
        │  bridge: WKScriptMessageHandler + evaluateJavaScript
        ▼
   DiffWebViewBridge — encode(document, config) ↔ decode(host event)
        │  protocolVersion: 1
        ▼
   vendored renderer.js (from YiTong v0.1.0+; wraps @pierre/diffs + Shiki)
```

Vendored web assets:

```
apps/mac/codans/App/Features/Diff/WebAssets/
├── index.html
├── renderer.js
├── renderer.css
├── manifest.json
└── LICENSE
```

Source: YiTong v0.1.0
`Sources/YiTongWebAssets/Resources/{index.html,renderer.js,renderer.css,manifest.json}`.

### Bridge Protocol (v1)

| Direction | Type | Payload |
|---|---|---|
| host → web | `setOptions` | `DiffConfiguration` |
| host → web | `render` | `DiffDocument` |
| web → host | `ready` | `{ rendererVersion }` |
| web → host | `renderStateChanged` | `{ phase, fileCount?, error? }` |
| web → host | `lineActivated` | `{ fileIndex, lineNumber, side }` |
| web → host | `selectionChanged` | `{ selection: SelectionRange? }` |

Each message wraps a `protocolVersion: 1` envelope; mismatched versions
surface as `DiffEvent.didFail(code: "protocol_mismatch", ...)`.

## Public API

`apps/mac/codans/App/Features/Diff/Public.swift`:

```swift
public struct DiffDocument: Equatable, Sendable {
  public let files: [DiffFile]
  public let title: String?
  public let fallbackPatch: String?
  public init(files: [DiffFile], title: String? = nil, fallbackPatch: String? = nil)
}

public struct DiffFile: Equatable, Sendable, Identifiable {
  public var id: String { newPath ?? oldPath ?? "" }
  public let oldPath: String?
  public let newPath: String?
  public let oldContents: String
  public let newContents: String
}

public struct DiffConfiguration: Equatable, Sendable {
  public var appearance: DiffAppearance = .automatic
  public var style: DiffStyle = .unified
  public var indicators: DiffIndicators = .bars
  public var showsLineNumbers: Bool = true
  public var showsChangeBackgrounds: Bool = true
  public var wrapsLines: Bool = false
  public var showsFileHeaders: Bool = true
  public var inlineChangeStyle: InlineChangeStyle = .wordAlt
  public var allowsSelection: Bool = true
  public init() {}
}

public enum DiffAppearance: String, Equatable, Sendable { case automatic, light, dark }
public enum DiffStyle: String, Equatable, Sendable { case unified, split }
public enum DiffIndicators: String, Equatable, Sendable { case bars, classic, none }
public enum InlineChangeStyle: String, Equatable, Sendable { case wordAlt, word, char, none }

public enum DiffEvent: Equatable, Sendable {
  case didFinishInitialLoad
  case didRender(fileCount: Int)
  case didClickLine(fileIndex: Int, lineNumber: Int)
  case didChangeSelection(SelectionRange?)
  case didFail(code: String, message: String)
}

public struct SelectionRange: Equatable, Sendable {
  public let fileIndex: Int
  public let start: Int
  public let end: Int
  public let side: SelectionSide
}

public enum SelectionSide: String, Equatable, Sendable { case additions, deletions, both }

public struct DiffRendererView: View {
  public let document: DiffDocument
  public let configuration: DiffConfiguration
  public let onEvent: ((DiffEvent) -> Void)?
  public init(
    document: DiffDocument,
    configuration: DiffConfiguration = .init(),
    onEvent: ((DiffEvent) -> Void)? = nil
  )
  public var body: some View
}
```

## TCA State

`apps/mac/codans/App/Features/Diff/DiffFeature.swift`:

```swift
@Reducer
struct DiffFeature {
  @ObservableState
  struct State: Equatable {
    var worktreeID: WorktreeID?
    var projectID: ProjectID?
    var worktreePath: String?

    var changedFiles: ChangedFilesState = .idle
    var presentedFilePath: String?
    var diffsByPath: [String: DiffEntryState] = [:]
    var style: DiffStyle = .unified
  }

  enum ChangedFilesState: Equatable {
    case idle, loading, loaded([ChangedFile]), error(GitError)
  }

  enum DiffEntryState: Equatable {
    case loading
    case loaded(DiffDocument)
    case error(GitError)
    case tooLarge(reason: TooLargeReason, copyCommand: String)
  }

  enum TooLargeReason: Equatable {
    case byteCount(Int), lineCount(Int), binary
  }

  enum Action {
    case worktreeSelected(projectID: ProjectID?, worktreeID: WorktreeID?, path: String?)
    case refreshRequested
    case changedFilesSucceeded([ChangedFile])
    case changedFilesFailed(GitError)
    case fileRowTapped(path: String)
    case drawerCloseRequested
    case diffSucceededFor(path: String, document: DiffDocument)
    case diffFailedFor(path: String, error: GitError)
    case diffTooLargeFor(path: String, reason: TooLargeReason, copyCommand: String)
    case styleChanged(DiffStyle)
  }
}

struct ChangedFile: Equatable, Identifiable, Sendable {
  var id: String { newPath ?? oldPath ?? "" }
  let oldPath: String?
  let newPath: String?
  let status: ChangeStatus    // modified | added | deleted | renamed
  let addedLines: Int
  let removedLines: Int
  let isBinary: Bool
}
```

Cap thresholds: `maxFileBytes = 500_000`, `maxFileLines = 5_000`, binary
always too-large. Above caps the drawer renders a placeholder + Copy-command
button.

## Component Boundaries

### New module — `apps/mac/codans/App/Features/Diff/`

```
Diff/
├── DiffFeature.swift                ← TCA reducer
├── Public.swift                     ← public surface
├── Internal/
│   ├── DiffWebView.swift            ← NSViewRepresentable wrapper
│   ├── DiffWebViewBridge.swift      ← JS ↔ Swift bridge codec
│   └── DiffWebViewCoordinator.swift ← WKScriptMessageHandler
├── Views/
│   ├── DiffInspectorView.swift      ← inspector column body
│   ├── DiffFileRow.swift            ← one file row
│   ├── DiffDrawerView.swift         ← drawer container + close button
│   └── DiffStylePicker.swift        ← unified ↔ split toggle
└── WebAssets/
    ├── index.html
    ├── renderer.js
    ├── renderer.css
    ├── manifest.json
    └── LICENSE
```

### Renamed (no schema aliases; rename Codable key + Swift identifier together)

| Before | After |
|---|---|
| `Worktree.gitViewerVisible` | `Worktree.diffInspectorVisible` |
| `HierarchyClient.setWorktreeGitViewerVisible` | `setWorktreeDiffInspectorVisible` |
| `RootFeature.gitViewerOverlayVisible(in:)` | `diffInspectorVisible(in:)` |
| `RootFeature.Action.gitViewerToggledForCurrentWorktree` | `diffInspectorToggledForCurrentWorktree` |
| `RootFeature.Action.toggleGitViewer` | `toggleDiffInspector` |
| `WorktreeHeaderFeature.Action.gitViewerToggleTapped` | `diffInspectorToggleTapped` |
| `.delegate(.gitViewerToggleRequested)` | `.delegate(.diffInspectorToggleRequested)` |
| `HeaderGitViewerToggle` view | `HeaderDiffInspectorToggle` |
| ⌘⇧G shortcut catalog command-id `toggleGitViewer` | Swift identifier `toggleDiffInspector`; **JSON raw value pinned to `toggleGitViewer`** to avoid orphaning existing user shortcut overrides — the override store persists `CommandID.rawValue` as its key. (See ExecPlan Decision Log D24.) |
| `RootFeature.State.gitViewer` | `RootFeature.State.diff` |
| `RootFeature.Action.gitViewer(...)` | `RootFeature.Action.diff(...)` |

User-facing strings ("Git Viewer", menu item label) unchanged in v1.

### Deleted

```
apps/mac/codans/App/Features/GitViewer/             ← entire directory
apps/mac/codans/Tests/GitViewerFeatureTests.swift
apps/mac/codans/Tests/GitViewerLargeDiffCommandTests.swift
apps/mac/codans/Tests/GitViewerSnapshotTests.swift
apps/mac/codans/Tests/WorktreeDetailViewLayoutTests.swift
apps/mac/codans/Tests/Performance/GitViewerReducerPerformanceTests.swift
apps/mac/codans/Tests/Performance/DiffParsePerformanceBaselineTests.swift   ← decided per parser ownership at execution
apps/mac/codans/Tests/Performance/fixtures/diff-1000-lines.txt              ← decided alongside
docs/design-docs/c7-git-viewer.md
docs/design-docs/mw-t3-gitviewer-overlay-shortcuts.md
docs/exec-plans/mw-t3-gitviewer-overlay-shortcuts.md
docs/exec-plans/0005-git-viewer-and-editor.md          ← decided per editor-portion at execution
```

## Alternatives Considered

### A. Hand-roll a pure-SwiftUI diff renderer — *rejected*

Estimated 9–10 dev-days to reach feature parity (split + syntax
highlight + word-level inline + selection + theme integration). The
Swift / WebKit gap on syntax highlighting is large: we'd need Splash for
Swift and Highlightr (which embeds highlight.js in WKWebView anyway) for
everything else, plus per-token attributed-string handling that Foundation
`AttributedString` only partially supports cleanly. Net cost vs. vendoring
the existing JS bundle: ~7 dev-days, with materially less polish on day 0.

### B. Depend on YiTong as a Swift package — *rejected*

YiTong is Apache-2.0 and supacode-proven. We don't take it as a Swift
package because:

1. Tuist's Swift Package Manager integration is healthy but every new
   product dependency is a small build-system tax. Vendoring assets has
   zero build-system impact.
2. Pinning matters — YiTong v0.1.0 is the version supacode validates; we
   want bit-exact control over what JS runs in our WebView.
3. We will already need a Swift host / bridge layer, since YiTong's host
   layer carries its own naming + protocol conventions. Reusing the web
   assets while reimplementing the Swift side gives us name-space hygiene
   without re-doing the hard work (`@pierre/diffs` integration).

### C. Depend on `@pierre/diffs` directly via npm bundling — *rejected*

Most "original" path: pull `@pierre/diffs` as an npm dependency, wire up
esbuild/Vite, write our own bundle.js + index.html + bridge JS. Reasons
to skip:

1. Introduces a Node toolchain to a Swift project. Mise + Tuist would
   need a `node_modules` story; CI gets a npm install step.
2. We re-discover problems YiTong's renderer.js has already solved
   (selection clamping, hunk regex robustness, theme switching).
3. The peer-dependency model of `@pierre/diffs` (React 18+ peer dep)
   means we'd also bundle React or use the web-components export, neither
   of which is documented as a stable surface.

We therefore vendor YiTong's `renderer.js` directly. If YiTong ever
diverges from `@pierre/diffs` upstream in a way that hurts us, we can
re-evaluate.

### D. Modal overlay / centered presentation — *rejected*

The previous attempt
(`docs/design-docs/git-viewer-modal-overlay.md`, scrapped). Centered modal
covers the whole window; review flow becomes "open modal → look → close
modal → look at terminal → repeat," with constant context loss. The
inspector-plus-drawer pattern preserves continuous context: the file list
stays pinned, the diff covers only the terminal region (not the sidebar
or tab bar), and ⌘⇧G toggles the inspector without dismissing the diff.

### E. Inline accordion inside the inspector — *rejected*

Earlier in the design discussion we considered making each inspector row a
`DisclosureGroup` whose body shows the diff inline. The 280 pt inspector
column is too narrow for unified diffs (~600 pt is the comfortable
minimum), and multiple expanded rows would scroll the file list out of
view. The drawer pattern keeps the file list always pinned.

### F. NavigationSplitView 3-column with file-list as middle column — *rejected*

The supacode pattern: a dedicated `NavigationSplitView` whose middle column
is the changed-files list and whose right column is the diff. We do not
adopt this because we already use the third column for the inspector slot,
and stacking another split inside the inspector is visual chaos at typical
window widths. The drawer-over-terminal layout gives the diff more
horizontal room than a middle-column file list would permit.

## Vendoring & License

Vendored from YiTong v0.1.0 (Apache-2.0).
`apps/mac/codans/App/Features/Diff/WebAssets/LICENSE` contains the
Apache-2.0 license text plus a NOTICE listing:

- Portions derived from YiTong (https://github.com/onevcat/YiTong), © onevcat, Apache-2.0
- renderer.js bundles `@pierre/diffs` (Apache-2.0, https://github.com/pierrecomputer/pierre)
- renderer.js bundles `kpdecker/jsdiff` (BSD-3-Clause, https://github.com/kpdecker/jsdiff)

Top-level `NOTICES.md` (create or amend) points to this file. No
modifications to vendored files in v1; any future patches must be called
out per Apache-2.0 §4.

## Risks

- **WebView startup latency**: first drawer open hits Shiki theme-load
  path (~150–250 ms M1). If observed >300 ms, pre-warm WebView at
  inspector mount.
- **WebView memory**: ~25–30 MB JS heap per WebView. We mount one drawer
  at a time. Closing the drawer destroys the WebView (recreated on next
  open) to avoid leak; revisit if first-load latency becomes painful.
- **Theme drift**: Shiki ships `pierre-light` / `pierre-dark`; bridge
  sends `setOptions({ appearance })` on `@Environment(\.colorScheme)`
  change. Visual match is "close enough," not exact.
- **Vendored bundle drift**: `manifest.protocolVersion` asserted in unit
  test against the Swift bridge's expected version.
- **Selection clipboard quirks**: mixed-line WebKit selection includes
  `+`/`-` prefixes in clipboard. Acceptable for v1.
- **`git diff --numstat` binary detection**: parser handles both
  `-\t-\tpath` and `-\t-\told\tnew` shapes.
- **Drawer re-mount on Worktree switch**: `worktreeSelected` resets
  `presentedFilePath`; previous Worktree's diffs purged.
- **Inspector path truncation**: paths >32 chars truncate head-first
  (`.lineLimit(1).truncationMode(.head)`); hover tooltip shows full path.
