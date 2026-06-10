# Design Doc: Editor Integration — NSWorkspace Rewrite (C8a)

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-22
**Supersedes:** [c8-editor-integration.md](c8-editor-integration.md) — Resolved Items #1, #2, #3, #9 are retired; #4–#8 stand.

## Context and Scope

C8 shipped an editor service built on `$PATH` probing + `Foundation.Process` spawning of CLI wrappers (`code`, `cursor`, `subl`, `zed`, `open -a Xcode`). In real use it fails the detection contract: a macOS GUI app inherits `launchd`'s minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), so editors installed into `/usr/local/bin` or `/opt/homebrew/bin` — i.e. every Homebrew-style install and every "Install 'code' command in PATH" user — are reported as **not installed** even when their `.app` bundle is sitting in `/Applications`.

C8's Alternative A1 (Launch Services / `NSWorkspace` + bundle IDs) was rejected on grounds of "mechanism non-uniformity" and "harder to mock". Real-world failure rate trumps that aesthetic. macOS app discovery happens through Launch Services, not through the caller's `PATH`, so bundle-ID detection works regardless of whether the editor's optional CLI shim (`code`, `cursor`, `subl`, …) was ever installed.

This doc retires the CLI-wrapper mechanism entirely and replaces it with NSWorkspace-based detection and launch. It also drops **Custom command templates** — a C8 feature that adds complexity without a concrete user request. The net effect is a service roughly half the size of today's.

It additionally **decouples the feature from Worktree**: "Open in X" is fundamentally a path-open action, not a Worktree-specific one. Callers (Worktree header, Git viewer, CLI, future deeplinks) resolve their own context to a `URL` and hand it to the service; the service never learns what a Worktree is.

## Goals and Non-Goals

**Goals**

- Ship a curated registry of 28 entries spanning editors, terminals, git clients, Xcode, Finder, and `$EDITOR`, each pinned to a bundle identifier.
- Detect every installed entry reliably regardless of `$PATH`, using `NSWorkspace.urlForApplication(withBundleIdentifier:)`.
- Take an arbitrary directory URL and launch it in the resolved target via `NSWorkspace` (or, for `.editor`, by spawning a Pane that runs `$EDITOR`), with the real .app icon visible in every UI surface.
- Keep the service strictly path-oriented: the open API is `(directory: URL, preferred: EditorID?)`. No Worktree, Pane, Project, or any other domain type appears in the signature.
- Settings UX is a single dropdown of **installed** entries (uninstalled are hidden); no install-guidance, no download CTAs, no PATH troubleshooting.
- Default resolution cascades: explicit request → global default → priority-list auto-pick → Finder.
- Fully testable via a narrow `AppLauncher` seam — no real app launches in unit tests.

**Non-Goals**

- File-level / line-level / diff-level opens (unchanged from C8).
- User-defined command templates ("Custom editors"). Adding a new entry is a code change. If this turns out to be wrong, amend later.
- Install / download / quarantine help. If the entry isn't installed, it doesn't appear. That's the whole UX.
- Disambiguation between multiple installed versions of the same app (e.g. Xcode stable vs. Xcode-beta). Launch Services' choice wins. Document the limitation.
- Subsetting the registry based on touch-code's own overlapping capabilities (e.g. "we already have a built-in terminal, skip terminal apps"). Respect user choice — don't prune.
- Coupling the editor service to Worktree, Project, or Pane types. The service is a pure path-opener; any per-Project semantics live one layer up, in the feature/handler that calls it.

## Design

### Overview

Three mechanism changes and one UX consequence:

1. **Detection = `NSWorkspace.urlForApplication(withBundleIdentifier:)`.** Each built-in editor is pinned to its Apple-assigned bundle identifier. "Installed" is a single LS query per bundle ID; results are cached for the app lifetime and refreshed when the Settings window opens or an IPC `editor.describe` call arrives. No `$PATH`, no `stat`, no `which`.

2. **Launch = three branches by category.**
   - **`.directory` mode** — `NSWorkspace.open(urls:withApplicationAt:configuration:)` with a single directory URL. Covers editors (Cursor, Zed, VSCode, Windsurf, Antigravity, Sublime, Xcode, …), terminals (Ghostty, Wezterm, Alacritty, Kitty, Warp, Terminal.app), git clients (GitHub Desktop, Sourcetree, Fork, GitKraken, Sublime Merge, SmartGit, GitUp), and Finder.
   - **`.applicationWithArguments` mode** — `NSWorkspace.openApplication(at:configuration:)` with `configuration.arguments = [dir]` + `createsNewApplicationInstance = true`. JetBrains-family only (IntelliJ, WebStorm, PyCharm, RubyMine, RustRover); any other mode makes JetBrains IDEs focus their last-opened window and ignore the argument.
   - **`.shellEditor` mode** — the special `.editor` case. Creates a new Pane at the target directory and sends `$EDITOR\n` as input; the user's login shell expands `$EDITOR` with its own environment. No bundle ID, no LS involvement. Requires the terminal/Pane side to expose a "create Pane at path with initial input" primitive — flagged as an implementation dependency in /hs-planner.

   No `Process` spawning, no argv substitution, no env whitelist, no 5-second timeout. The kernel (for `.directory` / `.applicationWithArguments`) or the Pane's shell (for `.shellEditor`) is doing the work.

3. **Priority-based auto-resolution.** When no default is set, walk a concatenated priority list (`editorPriority + [xcode, finder] + terminalPriority + gitClientPriority`) and pick the first that is installed. Finder is always installed, so the chain always terminates. Recomputed on every resolve, so installing a higher-priority editor takes effect on the next open with no restart.

4. **UX consequence: one dropdown, installed-only, fixed menu order.** The Settings "Default editor" pane becomes a single `Picker` over installed entries in `menuOrder` (`editorPriority + [xcode] + [finder] + terminalPriority + gitClientPriority + [editor]`), each row showing the real `.app` icon via `NSWorkspace.shared.icon(forFile:)` (and a generic terminal glyph for `.editor`). No tabs, no Custom section, no installation status column. Per-Project override in the Project Options sheet uses the same picker plus one extra row "Use global default".

5. **Path-in, nothing else.** The service API is `(directory: URL, preferred: EditorID?)`. Callers (Worktree header, Git viewer, CLI, future deeplinks) turn their own context into a `URL` before dispatching — no domain type crosses the service boundary. Per-Project default editor override (C8's `Project.defaultEditor`) is **kept** as a feature, but resolved **outside** the service: the caller (TCA `EditorFeature` reducer, or the IPC handler) looks up the containing `Project`, reads its override, filters to installed, and passes the result as `preferred` to the service. The service sees only an `EditorID?` — never a `ProjectID`.

The load-bearing trade-off is **"uniform mechanism" (C8's aesthetic) vs. "mechanism that fits macOS reality" (C8a)**. We lose the clean "everything is `Process` + argv" story and pay with one extra test seam (`AppLauncher`), but we gain correct detection on ~100% of installs and earn consistency with macOS conventions (icons, LS, activation semantics). That's the right trade.

### System Context Diagram

```
 ┌──────────────────────────────────────────────────────────────────┐
 │  touch-code app                                                  │
 │                                                                  │
 │  Callers (resolve context → URL)     Settings · Editor pane      │
 │  ┌─────────────────────────┐         ┌──────────────────────┐    │
 │  │ Worktree header button  │         │ Default editor:      │    │
 │  │ Git viewer "Enter"      │◀── same │   🅲 Cursor      ▼   │    │
 │  │ CLI `tc open [<path>]`  │   list  │ (installed only)     │    │
 │  │ Future deeplink handler │         └──────────────────────┘    │
 │  └──────────┬──────────────┘                                     │
 │             │ openInEditor(path: URL,                            │
 │             │              preferred: EditorID? = nil)           │
 │             ▼                                                    │
 │  ┌────────────────────────────────────────────────────────┐      │
 │  │  EditorService (in-app; @Dependency wired)             │      │
 │  │  ├── describe()  → [EditorDescriptor] (installed)      │      │
 │  │  ├── resolve(preferred) → EditorDescriptor             │      │
 │  │  └── open(directory, preferred) async throws           │      │
 │  └────────────┬──────────────────────┬──────────────────┬─┘      │
 │               │                      │                  │        │
 │        ┌──────▼──────────┐    ┌──────▼────────┐    ┌────▼─────┐  │
 │        │  AppLauncher    │    │ SettingsStore │    │  Pane   │  │
 │        │  (NSWorkspace)  │    │ defaultEditor │    │  spawner │  │
 │        │ open(urls:      │    │ ID (read)     │    │ (for     │  │
 │        │ withApp:config) │    │               │    │ $EDITOR) │  │
 │        └──────┬──────────┘    └───────────────┘    └──────────┘  │
 │               │                                                  │
 │               ▼                                                  │
 │       macOS Launch Services                                      │
 └──────────────────────────────────────────────────────────────────┘
```

`Foundation.Process`, `PathProber`, `EditorEnv`, `ProcessSpawner`, `SpawnContract`, `CommandTemplate`, `CustomEditor` — all gone from the runtime path.

### API Design

#### EditorService protocol (shape unchanged; semantics simplified)

```swift
protocol EditorService: Sendable {
  func describe() async -> [EditorDescriptor]                            // installed only
  func resolve(preferred: EditorID?) async -> EditorDescriptor
  @discardableResult
  func open(directory: URL, preferred: EditorID?) async throws -> EditorChoice
}
```

Contract change on `describe()`: returns **only installed** editors. The old C8 shape included missing entries so the dropdown could grey them out. That's incompatible with the new UX ("uninstalled → invisible"), so the service itself filters.

No `projectID`, no `worktreeID`, no catalog types. The service takes a URL and returns a choice; that is the entire coupling.

`EditorChoice` keeps the fields `id / displayName / binaryPath?` but `argv: [String]` is **removed**. There is no argv when the launch goes through LS; nothing consumes it externally today.

#### EditorDescriptor

```swift
struct EditorDescriptor: Identifiable, Equatable, Sendable {
  let id: EditorID                    // "cursor" | "zed" | "editor" | ...
  let displayName: String
  let bundleIdentifier: String        // empty string for .shellEditor
  let launchMode: LaunchMode
  let appURL: URL?                    // nil for .shellEditor; otherwise resolved from LS
  enum LaunchMode: Equatable, Sendable {
    case directory                    // NSWorkspace.open(urls:withApplicationAt:configuration:)
    case applicationWithArguments     // NSWorkspace.openApplication(at:configuration:) with args
    case shellEditor                  // new Pane, send "$EDITOR\n" to stdin
  }
}
```

Absence of the descriptor from `describe()` IS the "not installed" signal — no `InstallationStatus` enum needed. `.shellEditor` is always considered installed (it falls back to the shell's resolution of `$EDITOR`).

#### Built-in registry (34 cases)

| `id` | Display | Bundle ID | Launch mode | Category |
|---|---|---|---|---|
| `cursor` | Cursor | `com.todesktop.230313mzl4w4u92` | directory | editor |
| `zed` | Zed | `dev.zed.Zed` | directory | editor |
| `vscode` | Visual Studio Code | `com.microsoft.VSCode` | directory | editor |
| `windsurf` | Windsurf | `com.exafunction.windsurf` | directory | editor |
| `vscodeInsiders` | VSCode Insiders | `com.microsoft.VSCodeInsiders` | directory | editor |
| `vscodium` | VSCodium | `com.vscodium` | directory | editor |
| `sublimeText` | Sublime Text | `com.sublimetext.4` (alt `com.sublimetext.3`) | directory | editor |
| `intellij` | IntelliJ IDEA | `com.jetbrains.intellij` | applicationWithArguments | editor |
| `webstorm` | WebStorm | `com.jetbrains.WebStorm` | applicationWithArguments | editor |
| `pycharm` | PyCharm | `com.jetbrains.pycharm` | applicationWithArguments | editor |
| `rubymine` | RubyMine | `com.jetbrains.rubymine` | applicationWithArguments | editor |
| `rustrover` | RustRover | `com.jetbrains.rustrover` | applicationWithArguments | editor |
| `androidStudio` | Android Studio | `com.google.android.studio` | applicationWithArguments | editor |
| `antigravity` | Antigravity | `com.google.antigravity` | directory | editor |
| `trae` | Trae | `com.trae.app` | directory | editor |
| `traeCN` | Trae CN | `cn.trae.app` | directory | editor |
| `qoder` | Qoder | `com.qoder.ide` | directory | editor |
| `codebuddy` | CodeBuddy | `com.tencent.codebuddy` (alt `com.tencent.codebuddycn`) | directory | editor |
| `xcode` | Xcode | `com.apple.dt.Xcode` | directory | editor |
| `finder` | Finder | `com.apple.finder` | directory | (always) |
| `ghostty` | Ghostty | `com.mitchellh.ghostty` | directory | terminal |
| `wezterm` | WezTerm | `com.github.wez.wezterm` | directory | terminal |
| `alacritty` | Alacritty | `org.alacritty` | directory | terminal |
| `kitty` | Kitty | `net.kovidgoyal.kitty` | directory | terminal |
| `warp` | Warp | `dev.warp.Warp-Stable` | directory | terminal |
| `terminal` | Terminal | `com.apple.Terminal` | directory | terminal |
| `githubDesktop` | GitHub Desktop | `com.github.GitHubClient` | directory | git client |
| `sourcetree` | Sourcetree | `com.torusknot.SourceTreeNotMAS` | directory | git client |
| `fork` | Fork | `com.DanPristupov.Fork` | directory | git client |
| `gitkraken` | GitKraken | `com.axosoft.gitkraken` | directory | git client |
| `sublimeMerge` | Sublime Merge | `com.sublimemerge` | directory | git client |
| `smartgit` | SmartGit | `com.syntevo.smartgit` | directory | git client |
| `gitup` | GitUp | `co.gitup.mac` | directory | git client |
| `editor` | `$EDITOR` | — | shellEditor | (always) |

Priority lists:

```swift
static let editorPriority: [EditorID] = [
  "cursor", "zed", "vscode", "windsurf", "vscodeInsiders", "vscodium", "sublimeText",
  "intellij", "webstorm", "pycharm", "rubymine", "rustrover", "androidStudio",
  "antigravity", "trae", "traeCN", "qoder", "codebuddy",
]
static let terminalPriority: [EditorID] = [
  "ghostty", "wezterm", "alacritty", "kitty", "warp", "terminal",
]
static let gitClientPriority: [EditorID] = [
  "githubDesktop", "sourcetree", "fork", "gitkraken", "sublimeMerge", "smartgit", "gitup",
]
// Finder sits at the tail — if it appeared mid-list the priority walk would stop
// there (Finder is always installed) and shadow every terminal / git-client entry
// after it.
static let defaultPriority: [EditorID] =
  editorPriority + ["xcode"] + terminalPriority + gitClientPriority + ["finder"]
static let menuOrder: [EditorID] =
  editorPriority + ["xcode"] + ["finder"] + terminalPriority + gitClientPriority + ["editor"]
```

Adding a new entry is a two-line code change (registry row + priority insertion).

#### Resolution chain — split across two layers

**Caller layer** (TCA `EditorFeature` or IPC handler) decides what to pass as `preferred`:

```
userExplicitPick   (dropdown click, `tc open --in …`)
  → pass as `preferred`, strictly (throw if uninstalled: user asked for a specific thing)
OR, if no user pick:
projectOverride    (project.defaultEditor via hierarchy lookup from path)
  → if installed, pass as `preferred`; if uninstalled, pass nil (lenient: silently fall through)
```

**Service layer** (`EditorService.open`) then cascades:

```
preferred (from caller)    → if nil, skip; if set and uninstalled, throw `.notInstalled`
 ↓
Settings.defaultEditorID   → if installed, use; otherwise skip
 ↓
priority auto-pick         → first installed in the `defaultPriority` list
 ↓ always terminates at
Finder
```

Why split the cascade: the **strict vs. lenient** distinction is about *how a missing editor is handled*, not about *which tier it comes from*. An explicit user pick is strict (loud error: "Cursor is not installed"); any stored default (project or global) is lenient (silently fall through). Placing the strictness boundary at the service `preferred` parameter — "if set, it's strict" — keeps the service unaware of where the ID originated while still honouring the right UX.

The caller owns the `projectOverride` filter-if-installed step; the service owns the global-default cascade. Neither layer knows what the other is doing beyond the `preferred` hand-off.

#### IPC (C4)

- `editor.describe` → `[EditorDescriptor]` — payload shape changes (new fields, `argv` gone), method name/semantics the same. No CLI consumers depend on the old shape today.
- `editor.open { path: String, preferred?: EditorID }` → `EditorChoice`.
  - `path` is **mandatory** and must be an absolute directory path. Callers (including the CLI) resolve their own context to a path; `tc open` with no argument uses `$PWD`.
  - `preferred` is optional; supplied when the user invoked `tc open --in <editor>`.
  - When `preferred` is absent, the IPC handler does `hierarchyClient.project(containing: path)?.defaultEditor` and, if that ID is installed, passes it as the service `preferred`. This keeps CLI invocations consistent with in-app "click Open" behaviour: both honour the per-Project override silently. The handler is the only place this lookup happens — the service itself never imports `HierarchyClient`.
  - `argv` removed from the response.
- `editor.setGlobalDefault { editorID? }` → `void`. Sets `settings.general.defaultEditorID`; `null` clears it. (Renamed from `editor.setDefault` for clarity now that per-Project default lives on a different surface.)
- `editor.setProjectDefault { projectID: UUID, editorID? }` → `void`. Writes `project.defaultEditor` via `HierarchyClient.setRepositoryDefaultEditor`. Invoked by the Project Options sheet; `null` clears the override.

Gone: `editor.customEditors.*` (there were no IPC methods for these; the settings surface wrote directly).

#### Icon access

```swift
let icon: NSImage = NSWorkspace.shared.icon(forFile: descriptor.appURL.path)
```

In SwiftUI: `Image(nsImage: icon)` with `.resizable().frame(width: 16, height: 16)` in dropdown rows, or `Image(nsImage: icon).resizable().frame(width: 20, height: 20)` in the Settings picker. No caching needed — LS already caches.

### Data Storage

No new files. One field simplifies, one removed, one kept:

| Owner | Key | v1 (C8) | v2 (C8a) |
|---|---|---|---|
| `settings.json` | `general.defaultEditorID: EditorID?` | builtin or custom ID | builtin ID only |
| `settings.json` | `general.customEditors: [CustomEditor]` | **exists** | **removed** — decode tolerantly (ignored if present) |
| `catalog.json` | `Project.defaultEditor: EditorID?` | per-Project override | **kept** — same shape; value domain narrows to built-in IDs only (legacy custom IDs that are no longer in the registry are normalised to `nil` on load) |

**Migration** (runs once at startup after decode):

1. Ignore any `general.customEditors` entries from older settings files — log at `.info` level, do not warn the user.
2. If `general.defaultEditorID` is a string that is not in the new builtin registry, set it to `nil` and log at `.info`. Next resolution falls through to the priority auto-pick.
3. If any `Project.defaultEditor` is a string that is not in the new builtin registry (i.e. it was a custom editor ID from C8), set it to `nil` and log at `.info`.

No schema version bump (touch-code's settings/catalog readers are tolerant of unknown keys). Rollback is safe in both directions.

### Component Boundaries

```
apps/mac/touch-code/App/Clients/Editor/
├── EditorService.swift          ─ protocol (unchanged signature)
├── EditorService+Live.swift     ─ live: uses AppLauncher + NSWorkspace
├── EditorService+Test.swift     ─ test double (now trivially smaller)
├── EditorRegistry.swift         ─ built-in allowlist + bundle IDs
├── EditorModels.swift           ─ EditorDescriptor, EditorChoice, EditorID, LaunchMode
├── EditorError.swift            ─ .notInstalled / .launchFailed / .notADirectory
└── AppLauncher.swift            ─ protocol + LiveAppLauncher (NSWorkspace facade)

REMOVED:
├── PathProber.swift             ─ no PATH probing
├── ProcessSpawner.swift         ─ no child processes
├── SpawnContract.swift          ─ no timeout contract
├── EditorEnv.swift              ─ no env whitelist
└── (CustomEditor, CommandTemplate, EditorTemplateError types in EditorModels.swift) ─ removed
```

`AppLauncher` is the new seam; it exposes two methods:

```swift
protocol AppLauncher: Sendable {
  func urlForApplication(bundleIdentifier: String) -> URL?
  func open(urls: [URL], withApplicationAt appURL: URL,
            configuration: NSWorkspace.OpenConfiguration) async throws
}
```

Live implementation wraps `NSWorkspace.shared`. Tests use a `RecordingAppLauncher` that verifies `(appURL, urls, configuration.arguments, configuration.createsNewApplicationInstance)` matches expectations per editor.

**Responsibilities:**

- `EditorService`: resolution logic, cache of `describe()` results, fallback chain.
- `AppLauncher`: macOS LS/NSWorkspace abstraction — **only** place `NSWorkspace` is imported outside test code.
- `EditorRegistry`: static list of `EditorDescriptor` templates (bundle ID, display, launch mode); `describe()` filters through the launcher to produce installed-only view.

**NOT responsible:**

- `EditorService` is NOT responsible for UI, for storing selections, for IPC transport, for icon rendering.
- `AppLauncher` is NOT responsible for business logic or resolution — it just opens what it's told.

### Settings UX

Single pane, single picker. Mock:

```
┌─ General ─────────────────────────────────────────────┐
│                                                       │
│  Default editor                                       │
│  ┌─────────────────────────────────────────────┐      │
│  │ 🅲  Cursor                             ▼    │      │
│  └─────────────────────────────────────────────┘      │
│                                                       │
│  Used when opening a directory. Falls back to Finder  │
│  if the chosen editor is uninstalled later.           │
│                                                       │
└───────────────────────────────────────────────────────┘
```

Dropdown contents follow `menuOrder`, filtered to installed entries, with thin category separators between editor / xcode+finder / terminal / git-client / `.editor`:

```
🅲  Cursor
⎓   Zed
📘  Visual Studio Code
🧠  IntelliJ IDEA
────────────────────
🛠  Xcode
📂  Finder
────────────────────
👻  Ghostty
⬛  Terminal
────────────────────
🦑  GitHub Desktop
────────────────────
⌨   $EDITOR
```

Uninstalled entries: **not shown**. No banner, no explanation, no download link. If the user installs Cursor after touch-code is running, opening Settings re-probes on pane appear and the dropdown now includes Cursor. `.editor` is always shown (no bundle to probe) as long as the Pane primitive it depends on is available.

**Per-Project override** lives in the Project Options sheet and uses the same picker shape, with one extra row `↩ Use global default` at the top (equivalent to setting `Project.defaultEditor = nil`). Writes go through `HierarchyClient.setRepositoryDefaultEditor(projectID, editorID)` — unchanged from C8. The value domain is now restricted to installed built-in IDs (the picker only offers installed editors, like the global picker).

### Auto-default semantics

`settings.general.defaultEditorID` starts at `nil`. On every resolve:

```
resolved = settings.defaultEditorID ?? preferredDefault()
```

No "first-run wizard", no persistence of the auto-picked default — the computed default is re-derived each time, which means the moment the user installs Cursor (having previously had only VSCode), the priority walk flips the effective default from VSCode to Cursor on the next resolve. No restart or settings visit required.

The user's *explicit* pick in the dropdown writes `settings.defaultEditorID`. That write pins the choice — even if Cursor is installed later, an explicit "VSCode" preference sticks. Clearing the picker (setting to `nil`) is not exposed in the basic UX; if the user wants to go back to auto, they can choose the currently auto-picked editor, which persists an explicit preference that happens to match the current priority — same effective behaviour.

### Error handling

| Error | Cause | UI |
|---|---|---|
| `.notInstalled(id, bundleID)` | Explicit preferred editor not found on LS | Toast: "Cursor is not installed." |
| `.launchFailed(reason)` | `NSWorkspace.open` callback returned an `Error` | Toast: "Could not open in Cursor: <reason>" |
| `.notADirectory(path)` | Target path missing on disk or not a directory | Toast: "Directory not found: <path>" |

Gone: `.nonZeroExit`, `.timedOut`, `.spawnFailed`, `.badTemplate`, `.unresolvedWorktree`. The LS path has no timeout (the kernel opens the bundle async; our call returns as soon as LS dispatches) and no exit code. The CLI-specific error is gone because the CLI now always sends a path (default `$PWD`).

## Alternatives Considered

### A1. Keep C8's `Process`+`PATH`, add common-prefix fallbacks

Augment the probed PATH with `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, plus hardcoded in-bundle shim paths like `/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`.

- **Pros:** minimal diff; keeps C8's single-mechanism story.
- **Cons:** only fixes detection for users who ran the "Install 'code' command in PATH" step. Fresh VSCode installs don't have the shim. Cursor / Zed have their own shims with version-specific paths. Path-hack lists rot. Doesn't help at all for JetBrains (no CLI shim model) or Xcode. Still needs the `zsh -lc` dance to make the spawned child's `$PATH` usable if the editor reopens files from a terminal — subprocess env propagation is a separate can of worms.
- **Verdict:** rejected. Patches the visible symptom, leaves the structural problem.

### A2. Hybrid — NSWorkspace for detection, Process for launch

Detect via bundle IDs, but still spawn the CLI shim (`code`, `cursor`, ...) once detection passes.

- **Pros:** keeps the `argv` seam that the existing `EditorChoice` exposes.
- **Cons:** detection/launch via different mechanisms means an editor can be "detected" (bundle exists) but not "launchable" (shim never installed by user). That's exactly the current bug in inverted form. No consumer needs `argv`. Two failure modes per editor.
- **Verdict:** rejected.

### A3. Subset the list to only code editors

Cut terminals and git clients on the grounds that touch-code has built-in Panes (terminal) and C7 Git Viewer (git client), making external equivalents redundant.

- **Pros:** shorter dropdown, smaller registry, matches touch-code's "Pane IS the terminal" stance.
- **Cons:** pre-empts the user's choice. Some users want Warp's AI, Ghostty on a second monitor, or GitHub Desktop's PR UI alongside the built-in features. The cost of keeping them is ~20 rows in a Swift enum; the benefit is "no one ever has to ask where X went".
- **Verdict:** rejected. Ship all 28.

### A4. Keep CustomEditor templates alongside NSWorkspace

Retain `settings.general.customEditors` so power users can wire `emacsclient`, remote `nvim`, etc.

- **Pros:** escape hatch for the 1% who want it.
- **Cons:** re-introduces all the rejected complexity (PATH probing for custom binaries, Process spawner, timeout contract, env whitelist, template validator, "is it a shell" heuristic, etc.) for a user segment we have not actually heard from.
- **Verdict:** rejected for v2. If real demand surfaces, re-add as a separate "Advanced" pane in a future amendment — the plumbing is straightforward to restore because the types would come back from git history.

### A5. Single dropdown without auto-default — user must pick first

Start with `defaultEditorID = nil`; first "Open in editor" click opens Settings with a toast "pick an editor".

- **Pros:** never guesses wrong.
- **Cons:** friction on every fresh install. Priority-walk is right for ~99% of users (whichever of Cursor/Zed/VSCode is installed is almost always what they'd have picked anyway); the 1% wrong case costs one dropdown click to correct.
- **Verdict:** rejected.

## Cross-Cutting Concerns

### Security

- **Reduced attack surface.** No `Process`, no argv substitution, no env whitelist, no shell concerns. The remaining surface is "LS opens a directory in a bundle identified by string" — a well-trodden macOS path.
- **Quarantine / Gatekeeper.** LS handles quarantine prompts on behalf of touch-code; if a bundle is quarantined the user sees the OS-standard dialog, not a touch-code error. Acceptable.
- **Deeplink risk.** If a future `touch-code://` URL requests `editor.open` with a `preferred` ID that is not in the built-in registry, the service rejects it — there is no user-provided template it can weaponise. Strictly safer than C8.

### Observability

- `os.Logger` category `com.touch-code.editor`. Log at `.info` on every resolve (editor ID + dir path) and every launch (success/fail). Log at `.error` on migration anomalies (unknown `defaultEditorID`, legacy `customEditors` present).
- No signposts for launch wall-clock; LS returns near-instantly and the meaningful latency is in the editor's own cold-start, which we can't measure from here.

### Accessibility

- Dropdown rows expose `Image(nsImage: icon)` with `.accessibilityHidden(true)`; the row label carries the full display name (`"Cursor"`, not just the icon).
- Picker is keyboard-operable via standard SwiftUI.

### Testing

Test matrix shrinks substantially:

- **`EditorRegistry`**: table-driven — every ID has a unique bundle ID, no collisions, expected order for `preferredDefault()`.
- **`EditorService` (resolution)**: fakes `AppLauncher.urlForApplication` to return URLs for a controlled subset; cover the four tiers + cascade-on-stale-default rule + throw-on-stale-explicit rule.
- **`EditorService` (launch)**: fakes `AppLauncher.open`; verify JetBrains branch uses `configuration.arguments + createsNewApplicationInstance=true`; verify non-JetBrains branch uses `open(urls:withApplicationAt:)` with the directory URL.
- **Migration**: decode a settings.json with legacy `customEditors` + a stale `defaultEditorID`; verify normalisation.
- **Integration smoke** (gated behind `TC_RUN_EDITOR_INTEGRATION_TESTS=1`): actually ask `NSWorkspace.urlForApplication(bundleIdentifier: "com.apple.finder")` and `open` a temp directory. No other editors touched in CI.

Snapshot tests for Settings pane: empty (only Finder) / few installed / many installed.

### Migration path

Covered under Data Storage above. One-line summary: decode is tolerant, stale IDs are reset to `nil` at startup, custom entries are ignored, no user action required, downgrade to C8 is safe.

### Performance

- `NSWorkspace.urlForApplication(withBundleIdentifier:)` is ~1 ms/call on a warm LS cache, ~5 ms cold. Ten editors × 5 ms = 50 ms at first `describe()`. Cached thereafter; re-probe on Settings-pane appear and on `editor.describe` IPC. No startup impact.
- `NSWorkspace.shared.icon(forFile:)` is ~2 ms/call and LS-cached. Dropdown renders ~10 items at a time; negligible.

## Risks

- **R1 — ToDesktop-style bundle ID drift.** Cursor's bundle ID is a ToDesktop hash (`com.todesktop.230313mzl4w4u92`). If a future Cursor release re-publishes under a different ID, detection misses it. **Mitigation:** `alternateBundleIdentifiers: [String]` on every descriptor; probe primary first, fall through alternates. Update the list when the shim moves (code change).
- **R2 — JetBrains special-case drift.** If JetBrains changes how its apps accept folder-open via `configuration.arguments`, our one branch breaks silently (app launches, folder ignored) for all five JetBrains entries (IntelliJ, WebStorm, PyCharm, RubyMine, RustRover). **Mitigation:** manual smoke test on one JetBrains IDE in every release; if fragile in practice, prefer `ides-openFolder` URL scheme as a per-editor override.

- **R2b — `.editor` depends on a Pane primitive that may not exist yet.** touch-code needs a "create Pane at path with initial stdin input (`$EDITOR\n`)" capability for the `.shellEditor` launch mode. If the Pane feature doesn't already expose this, C8a's `.editor` case can't ship. **Mitigation:** /hs-planner's first task is to verify or build this primitive. If it's not trivial, drop `.editor` from this iteration (one-line registry change) and re-add it when the Pane side is ready — the rest of the 28-entry parity is unaffected.
- **R3 — Launch Services picks wrong Xcode version.** User has Xcode and Xcode-beta installed; LS picks whichever is "default". **Mitigation:** document as a known limitation; consider a separate `xcodeBeta` descriptor with bundle ID `com.apple.dt.Xcode-beta` (if Apple uses a stable alternate ID) in a follow-up.
- **R4 — First-install race.** User installs Cursor while touch-code is running; the cached `describe()` still says it's missing. **Mitigation:** `describe()` re-probes when Settings pane becomes visible and when IPC `editor.describe` is called. Sufficient for the use case; avoids polling.
- **R5 — Loss of escape hatch for niche editors.** A user who was using a Custom template for, say, Helix, loses their setup on upgrade. **Mitigation:** add Helix to the built-in registry if requested (2-line change). The current `customEditors` surface has no known users per logs, so the migration-loss blast radius is near zero. If wrong, revert via amendment.
- **R6 — `NSWorkspace.open` async callback error swallowing.** The callback-based API returns errors via completion handler; miswiring could drop errors silently. **Mitigation:** wrap in `withCheckedThrowingContinuation`; unit test asserts the continuation resumes exactly once in success and failure paths.

## Resolved Items (locked at approval)

Supersedes C8's Resolved Items #1, #2, #3, #9:

1. **Mechanism.** NSWorkspace / Launch Services for detection AND launch. No `Process`, no `$PATH`, no CLI shims. (Was: "CLI wrappers over Process for all opens".)
2. **Discovery.** `NSWorkspace.urlForApplication(withBundleIdentifier:)` per built-in editor, cached; refreshed on Settings-appear and IPC `editor.describe`. (Was: "`$PATH` probe at startup".)
3. **Built-in allowlist.** 28 entries — 12 editors + Xcode + Finder + 6 terminals + 7 git clients + `$EDITOR`. Additions remain code changes. (Was: 6 editors.)
4. **Custom templates.** Removed. (Was: `customEditors: [CustomEditor]` in settings.) Re-add only via future amendment with concrete user demand.
5. **Service coupling.** The service API is `(directory: URL, preferred: EditorID?)`. No Worktree, Project, Pane, or catalog type appears in any service signature. Per-Project override semantics live in the caller layer (TCA feature / IPC handler), which pre-resolves a `preferred EditorID?` and hands it to the service. (Was: service signature mixed path with `ProjectID`.)
6. **Resolution cascade — split across two layers.** Caller resolves `userExplicitPick ?? (projectOverride if installed)` into a single `preferred`. Service then cascades `preferred` (strict) → `Settings.defaultEditorID` (lenient) → priority auto-pick → Finder.

C8 Resolved Items #4 (fallback order — preserved in spirit, re-factored across layers), #5 (no silent fallthrough for explicit preferred), #7 (directory-only scope; no file-level, line-level, or diff-level opens), #8 (storage: `defaultEditorID` + `Project.defaultEditor` both kept) still stand.

C8 Resolved Item #6 (5 s timeout + SIGTERM/SIGKILL) is retired along with Process spawning.
