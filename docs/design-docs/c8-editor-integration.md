# Design Doc: External Editor Integration (C8)

**Status:** Superseded — see [c8a-editor-integration-nsworkspace.md](c8a-editor-integration-nsworkspace.md)
**Author:** Gump (with Claude)
**Date:** 2026-04-20

> **Note:** C8a (2026-04-22) retires Resolved Items #1 (CLI wrappers over Process), #2 (`$PATH` probe), #3 (6-editor allowlist), and #9 (custom-template syntax). Mechanism is now NSWorkspace / Launch Services + Bundle IDs; registry expands to 28 entries; custom templates are dropped. Items #4, #5, #7, #8 still stand; #6 (spawn timeout) is retired along with Process spawning. Read C8a first for current behaviour.

## Context and Scope

codans is deliberately not an IDE. Every code-reading or code-editing need is a hand-off to an external editor or file manager — VSCode, Cursor, Zed, Xcode, Sublime Text, Finder, and anything the user can describe with a command template. [Product-spec C8](../product-spec.md) pins the surface: a **Worktree-level** directory open, driven by either (a) a dropdown button in the Worktree header or (b) the `codans open [--in <editor>] [<worktree>]` CLI. No file-level or diff-level opens in v1.

[Open Question #7](../product-spec.md#open-questions) (editor discovery & invocation) is resolved by this doc: ship a **built-in allowlist with documented CLI wrappers**, discover installed editors by probing `$PATH`, and allow **user-defined command templates** for everything else.

Repository state at design time:

- `Project.defaultEditor: String?` already exists on the domain type in `apps/mac/CodansCore/Project.swift`. This design fixes its semantics (it stores an `EditorID` string) and adds a settings-level global default.
- The `codans-skill/` is not yet present, and no editor service has been implemented.
- supacode has a battle-tested editor-open pattern via Launch Services and bundle IDs (`OpenWorktreeAction.swift` + `WorkspaceClient.swift`). We adopt its **shape** (enum of known editors, per-project override) but invert its **mechanism** (CLI wrappers over `Process`, not `NSWorkspace.open`). Rationale in [Alternatives](#alternatives-considered).

This document is the source of truth for C8. It does not specify the `codans` CLI shell (that is C4, sibling design doc), nor the Worktree header UI beyond the minimum C8 contributes. It assumes C2 (hierarchy) provides `Worktree.path`.

## Goals and Non-Goals

**Goals**

- Open **the currently selected Worktree's directory** in one of: VSCode, Cursor, Zed, Xcode, Sublime Text, Finder — via a small, stable built-in allowlist.
- Allow arbitrary user-defined entries via a command template with a `{dir}` placeholder.
- Resolve an editor choice from: explicit request (`codans open --in vscode`) → per-Project override (`Project.defaultEditor`) → global default (`Settings.defaultEditorID`) → built-in fallback (Finder).
- Discover installed editors at app start by probing `$PATH` for each allowlist binary; expose the result so the Settings UI and the Worktree-header dropdown only show what is actually usable.
- Fail loudly and clearly on missing editor, non-zero exit, timeout, or bad template.
- Be fully testable with a mock `Process` dependency — no real editor launches in unit tests.

**Non-Goals**

- **File-level opens.** No `openPath(file, line)` in v1. The C7 viewer's `Enter` action still goes through this service, but v1 opens the file's parent directory and leaves navigation to the editor. (File-level opens are listed as Future Consideration; the protocol leaves room.)
- **No line-number mapping, no cursor positioning, no symbol navigation.**
- **No Launch Services / bundle-ID discovery.** One mechanism, not two.
- **No install help.** If VSCode is installed but `code` is not on `PATH`, we surface that as a discoverable error — we do not open VSCode's "Install 'code' in PATH" dialog on the user's behalf.
- **No editor spawning from `codans/Git/` or `codans/Runtime/`.** The editor service has a single call site per layer: the TCA editor-open action and the CLI's IPC handler.
- **No diff-view hand-off.** Sending a working-tree diff into VSCode's diff view is out of scope; that is what C7's in-app viewer is for.
- **No project-open behaviour customisation per editor** (e.g. "open in new window vs. add to workspace"). Whatever the editor's default is for "CLI passed a directory" is what we get.

## Design

### Overview

A single service, `EditorService`, exposes two capabilities:

1. **Describe** — enumerate built-in and user-defined editors, marking each as installed or missing based on a cached `$PATH` probe.
2. **Open** — given a `URL` (directory) and an optional `EditorID`, resolve the editor choice, substitute `{dir}` into the command template, spawn a `Process`, and surface the outcome.

The service lives in its own in-app module slice under `apps/mac/codans/App/Clients/Editor/` (it is TCA-feature-adjacent, not a separate Tuist target). It has no persistent state of its own; reads come from `SettingsStore` (global default + custom templates) and `HierarchyManager` (per-Project override). Writes (changing the default) go through the same stores.

There are three load-bearing decisions, covered in [Alternatives Considered](#alternatives-considered):

1. **CLI wrappers, not Launch Services.** Every open resolves to a `Process` invocation with a fixed, template-derived argv. Mockable, testable, uniform across built-in and user-defined entries.
2. **`$PATH` probe at startup, cached.** A one-time synchronous `which` scan with an on-demand refresh when Settings is opened. Avoids probing on every dropdown render.
3. **String `EditorID`, not enum.** Allowlist IDs are reserved strings (`"vscode"`, `"cursor"`, `"zed"`, `"xcode"`, `"sublime"`, `"finder"`); user-defined editors get IDs the user types (`"nvim-remote"`). Storing IDs as strings keeps `Project.defaultEditor` (already `String?`) untouched and lets user entries round-trip through JSON without an enum case for each.

### System Context Diagram

```
 ┌─────────────────────────────────────────────────────────────┐
 │  codans app                                             │
 │                                                             │
 │  Worktree header (SwiftUI)         Settings view (TCA)      │
 │  ┌──────────────┐                  ┌───────────────────┐    │
 │  │ [Open in ▼]  │                  │  Default editor:  │    │
 │  │   VSCode     │                  │    VSCode ▼       │    │
 │  │   Cursor     │◀── dropdown ─────│  Custom editors:  │    │
 │  │   Finder     │                  │    + Add...       │    │
 │  │   Custom…    │                  └───────────────────┘    │
 │  └──────┬───────┘                                           │
 │         │ .openWorktree(id, editor: nil)                    │
 │         ▼                                                   │
 │  ┌──────────────────────────────────────────────────────┐   │
 │  │  EditorService (in-app module; @Dependency wired)    │   │
 │  │  ├── describe()  → [EditorDescriptor]                │   │
 │  │  ├── open(URL, preferred: EditorID?)                 │   │
 │  │  └── resolve(preferred, project) → EditorChoice      │   │
 │  └───────┬──────────────────────────────┬───────────────┘   │
 │          │                              │                   │
 │          │ Process(argv)                │ reads             │
 │          ▼                              ▼                   │
 │  ┌────────────────────┐     ┌───────────────────────────┐   │
 │  │  Foundation.Process│     │  SettingsStore            │   │
 │  │  /usr/bin/env code │     │   - defaultEditorID       │   │
 │  │  /usr/bin/open -a  │     │   - customEditors[]       │   │
 │  └────────────────────┘     │  HierarchyManager         │   │
 │                             │   - Project.defaultEditor │   │
 │                             └───────────────────────────┘   │
 │                                                             │
 │  IPC socket (C4)            Tuist target: codans                │
 │  ┌───────────┐ method:      ┌───────────────────────────┐   │
 │  │ hierarchy │ editor.open  │  codans open [--in <editor>]  │   │
 │  │ .socket   │◀─────────────│      [<worktree>]         │   │
 │  └───────────┘              └───────────────────────────┘   │
 └─────────────────────────────────────────────────────────────┘
```

External boundaries C8 touches:

- **Spawned processes (`code`, `cursor`, `zed`, `subl`, `open`).** Fixed argv, no shell, no env inheritance beyond a whitelist (`PATH`, `HOME`, `LC_ALL`). Aligned with C7's git-process env stripping.
- **File system (read-only).** `stat` on editor binaries during the `$PATH` probe; nothing else.
- **`Project.defaultEditor`** — read and occasionally written via `HierarchyClient` (C2's command surface).
- **`Settings.defaultEditorID` / `Settings.customEditors`** — read and occasionally written via the Settings feature. Persisted in `settings.json`.

### API Design

#### EditorService protocol

```swift
public protocol EditorService: Sendable {
  /// Snapshot of the registry: built-in + user-defined, each marked installed/missing.
  func describe() async -> [EditorDescriptor]

  /// Resolve the effective choice for a Worktree without opening anything.
  /// Used by the dropdown to label its "Open" button with the current default.
  func resolve(
    preferred: EditorID?,
    projectID: ProjectID?
  ) async -> EditorChoice

  /// Open a directory. If `preferred` is nil, resolve per the fallback chain.
  /// Returns the chosen editor on success; throws EditorError on failure.
  @discardableResult
  func open(
    directory: URL,
    preferred: EditorID?,
    projectID: ProjectID?
  ) async throws -> EditorChoice
}
```

`EditorChoice` is the resolved descriptor + its argv at spawn time:

```swift
public struct EditorChoice: Equatable, Sendable {
  public let id: EditorID                 // e.g. "vscode"
  public let displayName: String          // "Visual Studio Code"
  public let binaryPath: URL              // /usr/local/bin/code
  public let argv: [String]               // ["code", "/abs/path/to/worktree"]
}
```

Keeping `argv` on the return type is what makes the service fully testable without a real `Process` — the `TestGitService` analog returns the `argv` the live path would have produced.

#### Data model

```swift
public typealias EditorID = String

public struct EditorDescriptor: Equatable, Sendable, Identifiable {
  public let id: EditorID
  public let displayName: String
  public let origin: Origin               // .builtin | .custom
  public let template: CommandTemplate
  public let installation: InstallationStatus
  public enum Origin: String, Equatable, Sendable, Codable { case builtin, custom }
  public enum InstallationStatus: Equatable, Sendable {
    case installed(resolvedBinary: URL)   // absolute path found on PATH
    case missingBinary(expected: String)  // what we looked for
  }
}

public struct CommandTemplate: Equatable, Sendable, Codable {
  public let binary: String               // "code"   or "open"   or "/usr/local/bin/idea"
  public let args: [String]               // ["{dir}"] or ["-a", "Xcode", "{dir}"]
  // If binary contains "/", we use it as an absolute path. Otherwise we resolve on PATH.
  // Exactly one arg must be the literal "{dir}"; it's substituted at spawn time.
}
```

#### Built-in allowlist (hard-coded, versioned with the app)

| `id` | Display name | Binary | argv template | Notes |
|---|---|---|---|---|
| `vscode` | Visual Studio Code | `code` | `["code", "{dir}"]` | Requires the user's "Shell Command: Install 'code' in PATH" |
| `cursor` | Cursor | `cursor` | `["cursor", "{dir}"]` | Ships a `cursor` shim |
| `zed` | Zed | `zed` | `["zed", "{dir}"]` | Ships a `zed` shim |
| `xcode` | Xcode | `open` | `["open", "-a", "Xcode", "{dir}"]` | `open` is always on macOS; `-a` resolves via Launch Services — this is the one place LS creeps in because Xcode has no CLI |
| `sublime` | Sublime Text | `subl` | `["subl", "{dir}"]` | Ships a `subl` shim |
| `finder` | Finder | `open` | `["open", "{dir}"]` | Always works on macOS |

The list is fixed in code (a Swift static). Additions to the allowlist are code changes; users who want another editor use custom templates.

#### Custom template

Stored in `settings.json` under `customEditors: [CustomEditor]`:

```swift
public struct CustomEditor: Equatable, Sendable, Codable, Identifiable {
  public var id: EditorID                 // user-typed; `[a-z][a-z0-9_-]{1,31}` enforced (lowercase, alphanumerics, `_`, `-`)
  public var displayName: String          // user-typed
  public var template: CommandTemplate
}
```

Validation on save: `id` must not collide with a built-in; `template.binary` must be non-empty; `template.args` must contain exactly one literal `"{dir}"`.

#### Resolution order

Resolution has two layers. First, **which Worktree are we opening?** For in-app callers the Worktree comes from the current selection. For the CLI (`codans open`), it comes from an explicit `<worktree>` positional argument, otherwise from the `CODANS_PANE_ID` env var injected into every Pane. If neither is set — `codans open` run outside a codans Pane with no `<worktree>` — the IPC handler returns `EditorError.unresolvedWorktree` and the CLI prints a clear message telling the user to pass `<worktree>` explicitly. We do **not** fall back to the last-focused Worktree or to any heuristic; an unresolved call is a user error, not a guess.

Second, once the Worktree is pinned, **which editor?**

```
preferred != nil
    ↓                                    (explicit `--in <editor>` or dropdown pick)
resolve → preferred
     ↓                                    (fallback 1)
project.defaultEditor != nil
    ↓
resolve → project.defaultEditor
     ↓                                    (fallback 2)
settings.defaultEditorID != nil
    ↓
resolve → settings.defaultEditorID
     ↓                                    (fallback 3)
resolve → "finder"                        (always installed on macOS)
```

If any fallback resolves to an editor that turns out not to be installed, `open()` throws `EditorError.notInstalled(id)` and the UI shows an actionable error — it does not silently fall through to the next tier. Silent fallthrough has bitten users in other tools and violates the principle of least surprise.

#### IPC (C4) — `editor.*` methods

Reserved methods, payloads pinned by the CLI design doc. Minimum surface:

- `editor.describe` → `[EditorDescriptor]`
- `editor.open { worktreeID?: UUID, preferred?: EditorID }` → `EditorChoice`
- `editor.setDefault { projectID: UUID, editorID: EditorID? }` → `void` (null → unset; falls back to global)

`codans open [--in <editor>] [<worktree>]` maps to `editor.open`. The CLI resolves `worktreeID` in this order: (1) the explicit `<worktree>` argument if given; (2) the Pane whose UUID is in the invoking shell's `CODANS_PANE_ID` env var (the app injects this into every Pane) — the handler then walks up to the Pane's owning Worktree; (3) otherwise, **no fallback** — the handler returns `EditorError.unresolvedWorktree` and the CLI prints `error: no worktree (pass <worktree> or run from inside a codans Pane)` to stderr with exit code 2.

### Data Storage

Two locations, both already established by C1+C2:

| Owner | Key | Meaning |
|---|---|---|
| `settings.json` | `defaultEditorID: String?` | Global default when the current Project has no override |
| `settings.json` | `customEditors: [CustomEditor]` | User-defined templates |
| `catalog.json` | `Project.defaultEditor: String?` | Per-Project override (existing field) |

No new files. No new schema version bump required for C8 (the `Project.defaultEditor` field already exists; `settings.json` already carries arbitrary preference keys). Writes go through the existing `AtomicFileStore` pattern.

**Volatile state:** the `$PATH`-probe result. Cached in `EditorService.live()` for the process lifetime after the first probe. Refresh is triggered (a) when the Settings editor tab becomes visible, (b) when the user adds/removes a custom editor, (c) on explicit `editor.describe` IPC requests. Never persisted.

### Component Boundaries

```
apps/mac/codans/App/Clients/Editor/
├── EditorService.swift          ─ protocol
├── EditorService+Live.swift     ─ live implementation using ProcessSpawner
├── EditorService+Test.swift     ─ preview/test double
├── EditorRegistry.swift         ─ built-in allowlist + custom-template merger
├── EditorModels.swift           ─ EditorDescriptor, EditorChoice, CommandTemplate, CustomEditor, EditorID
├── EditorError.swift            ─ .notInstalled / .spawnFailed / .nonZeroExit / .timedOut / .badTemplate / .notADirectory / .unresolvedWorktree
├── ProcessSpawner.swift         ─ protocol; live wraps Foundation.Process; test records calls
└── PathProber.swift             ─ `which`-like PATH scan; pure over a filesystem protocol

apps/mac/codans/App/Features/WorktreeHeader/        ← new feature folder; not yet in architecture.md
└── WorktreeHeaderOpenButton.swift  ─ SwiftUI dropdown + reducer wiring

apps/mac/codans/App/Features/Settings/
└── SettingsEditorSection.swift     ─ UI for global default + custom editors

apps/mac/codans/
└── OpenCommand.swift               ─ `codans open` subcommand → IPC editor.open
```

**Dependency rules:**

- `EditorService` has zero dependencies on `Runtime`, `Hooks`, `Git`, `CodansIPC`. It consumes `ProjectID`, `WorktreeID`, `Project` from `CodansCore` and `URL`/`Process` from Foundation.
- The CLI target `codans` never imports `EditorService`. It talks to the app via `editor.*` IPC and shows the response.
- `EditorService` never reads `HierarchyManager` directly; the TCA editor-open action resolves `Project.defaultEditor` at call time and passes it in. This keeps the service a pure function of inputs.
- `ProcessSpawner` is the single seam for testing. All spawns funnel through it; the live implementation constructs `Process`, the test records `(argv, env, cwd)` and returns a canned exit.

**What each component is NOT responsible for:**

- `EditorService`: not responsible for deciding *when* to open (that's a user action), not responsible for UI, not responsible for resolving the invoking Pane's worktree (that's IPC's job in `codans open`).
- `EditorRegistry`: not responsible for discovery. It returns the declared templates; `PathProber` decorates them with installation status.
- `PathProber`: not responsible for caching semantics beyond returning results; the service owns the cache.
- `ProcessSpawner`: not responsible for any business logic; it spawns and waits, nothing more.

### Spawn contract

`ProcessSpawner.spawnForOpen(argv:env:cwd:)`:

- `argv` is `[binaryPath, ...args]`. If the allowlist/custom template's `binary` is a bare name, `PathProber` resolves it to an absolute path first; the resolved path goes into `argv[0]`.
- `env` contains exactly: `PATH`, `HOME`, `LC_ALL=C.UTF-8`. Explicitly unset: `SHELL`, `EDITOR`, `VISUAL`, any `*_CONFIG` paths. None of the six allowlist wrappers need `SHELL`; stripping it matches C7's env policy and removes a potential influence vector on editor-side helper scripts.
- `cwd` is the absolute Worktree path. Helpful for editors that resolve relative paths against their spawn cwd.
- `stdin` is closed. `stdout` / `stderr` are collected (up to 8 KiB each) so we can surface the first stderr line on failure.
- Outcome is decided by the child's own exit within the **5-second wall-clock timeout**. The allowlist wrappers (`code`, `cursor`, `subl`, `zed`, `open`) all hand off to their GUI process via Mach/XPC and exit fast — typically under 500 ms, even on cold start. The contract is therefore a single rule:
  - Child exits with code `0` → success.
  - Child exits with non-zero code → `.nonZeroExit(code, stderr)`.
  - Child still running when the 5 s wall-clock elapses → `.timedOut`. The service terminates the child (SIGTERM, then SIGKILL after 1 s) so no orphan helper is left behind.
- No "assume-detached" heuristic. A wrapper that does not exit within 5 s is genuinely stuck (waiting on an XPC reply, blocked on a helper prompt, etc.) and the user sees a real error rather than a silent false-success.

### Error handling

| Error | Cause | UI surface |
|---|---|---|
| `.notInstalled(id, binary)` | `$PATH` probe did not find `binary` | Banner on the dropdown: "Visual Studio Code CLI (`code`) not found on PATH. Install via ‘Shell Command: Install code command in PATH’ in VSCode's Command Palette." |
| `.spawnFailed(reason)` | `Process.run()` threw (permissions, quarantine) | Toast: "Could not launch <editor>: <reason>" |
| `.nonZeroExit(code, stderr)` | Process returned non-zero within 5 s | Toast with first line of stderr; "Copy details" action |
| `.timedOut` | Child still running after 5 s; service sent SIGTERM/SIGKILL | Toast: "<editor> did not respond within 5 seconds. Retry or open in another editor." with a retry action |
| `.badTemplate(id, reason)` | Custom template invalid (no `{dir}`, empty binary) | Settings inline validation; never reaches runtime |
| `.notADirectory(path)` | Worktree path resolves to a file or is missing | Toast: "Worktree directory not found on disk" |
| `.unresolvedWorktree` | `codans open` invoked with no `<worktree>` and no `CODANS_PANE_ID` | CLI: stderr `error: no worktree ...`, exit 2. Never raised from in-app callers. |

All errors are also logged at `os.Logger` category `com.gumpw.codans.editor` with the editor ID and the redacted argv (the path is not a secret but is included as-is — this matches `os.Logger`'s standard privacy guarantees for string interpolation).

### Testing strategy

- **`EditorRegistry`** — table-driven: the allowlist matches expected IDs, names, and argv templates exactly. Merging custom + builtin produces the expected order, ID collisions are rejected.
- **`PathProber`** — protocol-abstracted filesystem; tests inject a fake listing and assert resolution. Cover: binary on `$PATH`, binary with multiple candidates (first wins), missing binary, absolute-path templates that bypass probing.
- **`EditorService` (resolution)** — TCA-free unit tests. Cover the full fallback chain (explicit → project → global → finder), reject silent fallthrough on a missing preferred editor, surface `.notInstalled` correctly.
- **`EditorService` (spawn)** — uses `ProcessSpawner` double. Assert: argv matches the template, `{dir}` substitution is literal (not shell-expanded), `env` has the whitelist only, `cwd` is set, exit 0 becomes success, non-zero exit becomes `.nonZeroExit`, child still running at the 5 s deadline becomes `.timedOut` (and the spawner records that SIGTERM was sent).
- **`OpenCommand` (CLI)** — argument parser tests + a fake IPC client; asserts the right `editor.open` method and payload.
- **Integration smoke** — a single XCTest that uses the live `ProcessSpawner` to invoke `/usr/bin/open` with a throwaway directory. Gated behind `TC_RUN_EDITOR_INTEGRATION_TESTS=1` so CI can opt in. Other editors (VSCode, Cursor, ...) are not in CI because they require a GUI; they are tested by dogfooding.
- **Snapshot** — settings editor section with zero/one/many custom entries.

## Alternatives Considered

### A1. Launch Services / NSWorkspace.open with bundle IDs (supacode's pattern)

Use `NSWorkspace.urlForApplication(withBundleIdentifier:)` to discover installed editors, then `NSWorkspace.open(url, withApplicationAt: appURL, configuration: .init(arguments: [dir]))`.

- **Pros:** no `$PATH` setup required — works even if the user hasn't installed VSCode's `code` shim. Battle-tested in supacode (`OpenWorktreeAction.swift`). Handles bundle-ID-only apps like Xcode naturally.
- **Cons:** different mechanism per app (some editors accept `arguments:`, others ignore CLI args and just focus the most-recent window; JetBrains needs explicit `.openConfiguration`; Finder needs `activateFileViewerSelecting`). Launch Services looks up bundles but gives us no way to pass editor-specific flags later (e.g. `code --goto file:line` if we ever add file-level opens). The mechanism is less uniform, harder to mock (no clean `Process` abstraction), and invites per-editor special cases.
- **Verdict:** rejected as the primary mechanism. Used narrowly only for Xcode (no CLI) via `open -a Xcode {dir}`. Re-evaluate when v2 adds file-level opens and we run into a real-world case where a CLI wrapper is missing on a common editor.

### A2. User-defined shell commands only (no built-in allowlist)

Ship only `customEditors` — every editor is a user template.

- **Pros:** no maintenance burden as new editors appear; no allowlist to keep current.
- **Cons:** first-run UX is terrible: user launches the app, hits "Open in editor", is told "configure an editor first, here's a templates format". Onboarding friction for the common case is unacceptable. Users in 2026 expect VSCode/Cursor/Zed/Xcode/Finder to Just Work.
- **Verdict:** rejected.

### A3. Launch Services AS WELL as CLI wrappers

Offer both mechanisms; try CLI wrapper first, fall back to LS bundle lookup.

- **Pros:** maximum compatibility.
- **Cons:** doubles the testing matrix; obscures error messages ("we tried `code`, then we tried bundle `com.microsoft.VSCode`, both failed — here's a combined stderr"). The second mechanism is a different code path with different failure modes.
- **Verdict:** rejected — pick one and make it work cleanly. The chosen mechanism (CLI wrappers + user templates) covers every installed-editor case except where the user hasn't installed the CLI shim, which is an actionable, fixable error rather than a silent failure.

### A4. Probe `$PATH` synchronously on every open

Skip the cache; `which` at each spawn.

- **Pros:** no cache-invalidation risk; user removing their `code` shim after app launch produces the right error.
- **Cons:** per-dropdown-render probe adds ~10 ms × N built-ins = noticeable flicker on Worktree header re-renders. Settings view renders the list frequently.
- **Verdict:** rejected. Cache + refresh triggers are cheap and correct; the "user removed their shim mid-session" case is rare enough that refreshing on Settings-open covers it.

### A5. `EditorID` as a Swift enum

Make `EditorID` an enum with cases for each built-in plus `.custom(String)`.

- **Pros:** exhaustive `switch` at call sites; compiler catches missing handling when we add a new built-in.
- **Cons:** `Project.defaultEditor` is already `String?` in `CodansCore`; changing it to an enum forces `CodansCore` to know about `EditorID`, which is an App-tier concept. Custom editors need associated values anyway, so the enum degenerates to `.builtin(Built)` / `.custom(String)` and the compiler-exhaustiveness benefit shrinks.
- **Verdict:** rejected. Strings are the right type for an open allowlist; validation at save time covers the invariant the enum would.

### A6. Spawn via `osascript` / AppleScript

Use scripted app activation instead of `Process`.

- **Pros:** fine control over window behaviour (bring to front vs. new window).
- **Cons:** per-editor AppleScript dictionaries; Automation permission prompts; a whole new security surface; slower. Not justified when a CLI wrapper already exists for every editor in the allowlist except Xcode.
- **Verdict:** rejected.

### A7. Confirm every open with a deeplink-style modal

Route all opens through `DeeplinkConfirmationFeature` (used by `codans://` URL handling).

- **Pros:** consistent with how the app confirms `codans send` from an untrusted source.
- **Cons:** user-initiated, in-app opens are *not* untrusted. A confirmation modal on every dropdown click is friction with no safety benefit.
- **Verdict:** rejected for in-app and for CLI-from-inside-a-Pane calls. Apply confirmation only if a future deeplink (`codans://worktree/<id>/open-in/vscode`) arrives from outside the app.

## Cross-Cutting Concerns

### Security

- **No shell.** Arguments go through `Process` as an array; nothing is joined or quoted by us. `{dir}` substitution is literal into a single argv slot; even if a Worktree path contains spaces, quotes, or shell metacharacters, they reach the editor verbatim.
- **Path validation.** Before spawning, `URL.isDirectory == true` and `FileManager.default.fileExists(atPath:)` are checked; a negative result returns `.notADirectory` rather than handing a stale path to the editor.
- **Environment whitelist.** The child receives only `PATH`, `HOME`, `LC_ALL`. This blocks `SHELL`/`EDITOR`/`VISUAL`/`GIT_*`/`JAVA_TOOL_OPTIONS`/etc. from leaking into GUI editors where they might misbehave.
- **No code execution outside the allowlist / user-saved templates.** A URL-based deeplink cannot name an arbitrary binary; only IDs that resolve to a saved template are invokable. A malicious deeplink can at worst ask for `editor.open` with a legitimate ID the user has already approved by saving.
- **Quarantine bit.** If a user-saved template points to a quarantined binary (e.g. from a DMG), `Process.run()` surfaces the system's quarantine error as `.spawnFailed` and the UI tells the user to clear quarantine manually. codans does not silently clear `com.apple.quarantine`.

### Observability

- `os.Logger` category `com.gumpw.codans.editor`. Every `open` call logs `id`, `binaryPath`, and exit code at `.info`. Template validation failures at `.error`.
- Spawn wall-clock time is recorded as `os.signpost`, category same; available in Instruments.
- On `.nonZeroExit`, the first line of stderr is logged at `.info` (not `.error`, since it's often user-fixable).

### Accessibility

- The Worktree header dropdown is keyboard-operable; each menu item has a VoiceOver label of the form `"Open in Visual Studio Code"` (not just `"VSCode"`).
- Missing-editor rows in the dropdown are explicitly marked disabled with an accessibility hint `"CLI `code` not found on PATH"` — screen-reader users get the same signal as sighted users.
- Settings validation errors are announced via `AccessibilityNotification.announcement`.

### Migration path

- v1 ships with `defaultEditorID` unset (`nil`). On first use, the app shows the dropdown with Finder as the resolved choice. Users set a real default either via the dropdown's "Set as default" or via Settings.
- Legacy values (none exist before v1) are not a concern.
- When a future version adds file-level opens, `EditorService.open(file: URL, line: Int?)` joins the protocol; the template extends with `{file}` and `{line}` placeholders. Existing custom templates with only `{dir}` still work — they receive the file's parent directory for a file-open (degrades to "open the containing folder").

### Seams left for later capabilities

- **File-level opens.** Add `open(file:line:)` to the protocol; extend `CommandTemplate` with optional placeholders.
- **Per-editor "new window" flag.** Add a `CommandTemplate.alwaysNewWindow: Bool` that appends `-n`/`--new-window`/`-a -n Xcode` as appropriate.
- **Recent-editor memory.** If the user picks a non-default from the dropdown, remember it as the effective default for the current session only. Zero new persistence.
- **Skill metadata.** The published Agent Skill (C5) can consult `editor.describe` via IPC to suggest `codans open --in ...` to agents, without any runtime coupling to the app.

## Risks

- **R1 — VSCode-or-derivative `code` shim collision.** Users with both VSCode Stable and Insiders installed have two `code` binaries (one of which is often `code-insiders`); custom derivatives (VSCodium, Positron) may alias to `code`. Mitigation: the allowlist `vscode` entry opens whichever `code` is found; power users disambiguate via a custom template (`vscode-insiders` → `code-insiders`).
- **R2 — `cursor` / `zed` CLI instability.** These shims have changed shape in past releases (e.g. Cursor's shim at one point required `cursor --new-window` to avoid reusing a stale window). Mitigation: keep template definitions co-located in one file (`EditorRegistry.swift`) so updating the allowlist is a one-line edit; dogfood each release.
- **R3 — User confusion between "editor not installed" and "CLI shim not installed".** Mitigation: error copy is explicit — "Visual Studio Code CLI (`code`) not found on PATH" beats "VSCode not installed", and offers the actionable fix.
- **R4 — Custom template injection.** A user saves a template whose `binary` is `bash` and `args` is `["-c", "rm -rf ~"]`. Mitigation: the `args` validator requires exactly one literal `"{dir}"` token; additionally, a warning banner in Settings flags any template whose binary is a known shell (`bash`/`zsh`/`fish`/`sh`). We do not block — the user is the admin of their own machine — but we surface the risk. This is not a codans-specific attack vector (the user could run anything anyway) but we avoid making it trivial.
- **R5 — Launch Services disagreement on Xcode.** `open -a Xcode` opens whichever Xcode version Launch Services thinks is preferred; users with multiple Xcode installs may land on the wrong one. Mitigation: document; add a custom-template example for "Open in Xcode 16 Beta" with an absolute `/Applications/Xcode-16-beta.app/Contents/MacOS/Xcode {dir}` template.
- **R6 — Slow editor CLI cold-start hitting the 5 s timeout.** The six allowlist wrappers typically exit in well under 500 ms even from cold, but a future editor CLI (or a congested machine) could legitimately need longer. A real timeout would surface as a `.timedOut` toast that looks like a failure when the editor is actually about to appear. Mitigation: (a) instrument the exit wall-clock via `os.signpost` and keep the 5 s budget under review during dogfooding; (b) when a user reports this, lift the timeout to 15 s with a confirmed-slow-wrapper flag on the template (not a global bump, so fast-path editors still fail fast on genuine hangs). Do **not** substitute an "assume-detached" heuristic — a user waiting on an editor that never appears is worse than a user seeing a clear timeout error.
- **R7 — Editor app sandboxing.** Some Mac-App-Store-distributed editors (e.g. TextMate, BBEdit) have CLI shims that rely on XPC connections to their sandboxed container; the connection may be refused when spawned from codans's sandbox. Mitigation: not an allowlist concern in v1 (our six built-ins do not use this pattern); users reporting this can fall back to `open -a <AppName> {dir}` via custom template.

## Resolved Items (locked at approval)

At approval the following defaults are locked. Revisit via amendment only.

1. **Mechanism.** CLI wrappers over `Process` for all opens. `open -a <app>` is used only for Xcode (no CLI) and Finder (idiomatic).
2. **Discovery.** `$PATH` probe at startup, cached; refreshed on Settings open, custom-editor edit, and explicit `editor.describe` IPC call.
3. **Built-in allowlist.** VSCode, Cursor, Zed, Xcode, Sublime Text, Finder. Additions are code changes.
4. **Fallback order.** explicit → Project override → global default → Finder.
5. **No silent fallthrough.** A missing preferred editor throws; the UI surfaces the error rather than opening a different editor.
6. **Timeout + spawn contract.** 5 s wall-clock from spawn to child exit. Exit 0 = success; non-zero exit = `.nonZeroExit`; still running at 5 s = `.timedOut` (SIGTERM then SIGKILL after 1 s). No "assume-detached" heuristic.
7. **Scope.** Worktree directory only. No file-level, no line-level, no diff-level in v1.
8. **Storage.** `defaultEditorID: String?` + `customEditors: [CustomEditor]` in `settings.json`; `Project.defaultEditor` (existing) as per-Project override.
9. **Custom-template syntax.** `binary` + `args: [String]`; exactly one `{dir}` placeholder; ID matches `[a-z][a-z0-9_-]{1,31}`.
