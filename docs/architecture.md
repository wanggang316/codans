# Architecture


## Overview

codans is a native macOS application that orchestrates terminals into a four-level hierarchy (Project → Worktree → Tab → Pane), with cross-cutting Tag classification on Projects, for CLI-agent power users. See [Product Spec](product-spec.md) for capabilities and boundaries.

The system is a **Tuist-managed monorepo** because the product ships three co-versioned artifacts — the Mac app, the `codans` CLI, and the published Agent Skill — whose development benefits from atomic cross-cutting changes (protocol edits, CLI contract changes, domain-model evolution) and shared tooling.

Architecture is adapted from two reference projects the user maintains and encourages borrowing from: **supacode** and **supaterm**. See [References](#references) for file anchors. The structural shape — Swift 6, Tuist, libghostty-via-submodule, hybrid TCA + `@Observable`, JSON-RPC over Unix socket — is lifted from these projects because they have already validated the pattern on the same workload codans targets.

## Codemap

The mac platform (Tuist project, sources, ghostty submodule) lives under `apps/mac/`. The top level holds monorepo-wide concerns (docs, root Makefile that delegates, `mise.toml`). This mirrors supaterm's multi-platform-ready layout.

### Tuist targets under `apps/mac/`

| Target | Kind | Source path | Purpose |
|---|---|---|---|
| `CodansCore` | static framework | `apps/mac/CodansCore/` | Pure domain types: Project/Worktree/Tab/Pane models, `Tag`/`TagFilter`, `SplitTree`, stable UUID identifiers. Zero internal deps. Consumed by app + CLI. |
| `CodansIPC` | static framework | `apps/mac/CodansIPC/` | JSON-RPC wire protocol: Request/Response envelopes, Method constants, payload types and framing. Socket discovery lives in `CodansKit`. Shared between app and CLI. |
| `CodansKit` | static framework | `apps/mac/CodansKit/` | Shared CLI transport, `RPCClient`, `SocketDiscovery`, alias resolution, rendering, and exit codes. Depends on `CodansCore`, `CodansIPC`, and `ArgumentParser`; consumed by the CLI, app, and tests. |
| `GhosttyKit` | static framework | `apps/mac/.build/ghostty/GhosttyKit.xcframework` | Tuist wrapper around the locally built libghostty XCFramework. |
| `codans-cli` | command-line tool | `apps/mac/codans-cli/` | CLI binary (`PRODUCT_NAME=codans`). Depends on `CodansKit`, `CodansCore`, `CodansIPC`, and `ArgumentParser`. Runtime / Hooks / Git are intentionally off-limits — CLI is a thin RPC client. |
| `Codans` | macOS app | `apps/mac/codans/{App,Runtime,Process,Git,GitHub}/` | Single app target. Internal dependencies: `CodansCore`, `CodansIPC`, `CodansKit`, `GhosttyKit`, `DiffViewKit`, and `codans-cli`; external dependencies are declared in `Project.swift`. `embed-codans.sh` embeds the CLI under `Codans.app/Contents/Resources/bin/` as `codans` (Release) or `codans-dev` (Debug). |

### In-app modules (subfolders of the `codans` target, not separate Tuist targets)

| Subfolder | Purpose |
|---|---|
| `codans/App/` | `@main CodansApp.swift`, root SwiftUI scene, TCA store construction |
| `codans/Runtime/` | libghostty integration: GhosttyKit Swift bindings, Pane lifecycle, Surface rendering adapter, `@Observable` runtime state, and the live foreground [process registry](design-docs/worktree-processes.md) |
| `codans/Hooks/` *(planned, not yet implemented)* | **Design intent, no code yet** — the `Hooks/` subfolder does not exist and `CodansIPC/Method.swift` has no `hook.*` methods. The intended subsystem: lifecycle event taxonomy (Pane created / ready / output match / idle / exit; Tab activated; Worktree activated), hook registration, out-of-process shell handler dispatch. See [Lifecycle hooks](design-docs/lifecycle-hooks.md). |
| `codans/Process/` | Shared subprocess primitive — `CommandRunner` protocol + `FoundationCommandRunner` / `RecordingCommandRunner`. `Git/` and `GitHub/` depend on this common runner without taking a sibling-module import. Timeout + SIGTERM→SIGKILL ladder + pipe-drain backpressure live here; translation from `CommandOutcome` to a domain error type is each caller's responsibility. |
| `codans/Git/` | Git queries and mutations: status/diff/log parsing, branch switching, and worktree creation/removal. Subprocess execution uses the shared `CommandRunner`; see [Worktree](design-docs/worktree.md). |
| `codans/GitHub/` | gh-delegated GitHub integration data layer (0012). `GitHubService` protocol + `LiveGitHubService` wrapping `gh` via `CommandRunner`, `GhCommand` argv builder, `GhExecutableResolver` actor, `JSONOutputParsers` translating gh stdout → `CodansCore` DTOs, `GitHubError` taxonomy. Zero HTTP in-app; auth/tokens live entirely in gh's own config store. App-layer TCA bits live in `App/Clients/GitHubClient.swift` + `App/Features/GitHub/`. |
| `codans/App/Features/GitHub/` | 0012/0013 GitHub integration TCA feature. `GitHubFeature` owns the fetch lifecycle as a **repository-batched** model: per-branch GraphQL aliases are grouped by repository and chunked at ≤25 branches with up to three concurrent requests. Workspace members use a stable fetch-group ID per source repository; ordinary Projects use their Project ID. PR data has **no TTL** — invalidation is event-driven (Worktree added/removed, branch change, post-write mutation, Project activated, manual refresh). The 30 s freshness window applies only to the `gh` *availability* probe (`availabilityFreshness`), not to PR data. `GitHubRootBindings` stacks under the Scope to fan delegate actions out to `NSWorkspace.open` / `SettingsWindowPresenter`. Data layer in `codans/GitHub/` (`BatchedPullRequestQuery`, `LiveGitHubService`). Views: `PullRequestBadge` (sidebar-row capsule), `PullRequestPopover` with split-button merge + checks list, `CheckRow`, `MergeSplitButton`, colour tokens in `Theme/`. See [GitHub integration](design-docs/github-integration.md). |
| `codans/App/Clients/Editor/` | `EditorService`, built-in `EditorRegistry`, and `AppLauncher`. `LiveEditorService` discovers installed apps by bundle identifier through Launch Services and opens them through `NSWorkspace`; remote editor support has an explicit `RemoteEditorOpen` path. `$EDITOR` is a special terminal-pane launch. See [Editor integration](design-docs/editor-integration.md) for resolution and launch contracts. |
| `codans/App/Clients/Editor/` (external git viewing) | The external Git Viewer command is separate from the built-in diff window. "Toggle Git Viewer" (⌘ chord / menu / palette → `RootFeature.diffInspectorToggledForCurrentWorktree`) resolves `general.defaultGitViewerID` (an `EditorID?` into the registry's git-client category) and opens the current Worktree in an external client (Fork / Sourcetree / GitHub Desktop / …) through the same `EditorService` open path as the default editor; `nil` or the Built-in ID opens the built-in diff window; an external ID absent from the editor descriptors is a no-op. SSH targets follow remote editor resolution. See [Editor integration § Git Viewer](design-docs/editor-integration.md). |
| `codans/App/Features/Diff/` | `DiffFeature` owns worktree-scoped Uncommitted / Outgoing selection, comparison loading, stale-result rejection, and a two-second refresh timer while visible. `DiffPanelView` hosts the independent `DiffViewKit` WKWebView renderer in a normal per-worktree NSWindow owned by DiffWindowManager. Git reads use `GitServiceClient`; current-file editor handoff uses `DiffEditorClient`. Scope/base/file preferences are session-local. No editing or Git write actions. See [Git diff viewer](design-docs/git-diff-viewer.md). |
| `codans/App/Features/WorktreeHeader/` | Branch identity and editor, Run, and Agent controls. Editor intents delegate to `RootFeature`. The surrounding Worktree detail toolbar also presents status, live processes and notifications. Git Viewer uses the configurable ⌘G command; Worktree → Show Changes opens the independent read-only comparison window. See [Main window](design-docs/main-window.md). |
| `codans/App/Features/Socket/` | Socket server + `MethodRouter` + per-namespace handlers (`SystemHandlers`, `HierarchyHandlers`, `TerminalHandlers`, `EditorHandlers`). `EditorHandlers` serves `editor.describe` / `editor.open` / `editor.setGlobalDefault` / `editor.setProjectDefault`, bridging `EditorClient` + `HierarchyClient` to the `CodansIPC/Editor/` wire types. |

Module boundaries between `Runtime`, `Hooks`, `Git`, and `App` are enforced by **folder convention + code review**, not by Tuist target edges. This matches supacode/supaterm's idiom. Promote a subfolder to its own target only when it gains a test bundle, becomes consumed by another app (e.g. iOS), or needs to restrict its public API surface.

### Directories at the repo root (monorepo-wide)

| Path | Purpose |
|---|---|
| `apps/mac/` | The mac platform: Tuist project, sources, ghostty submodule, per-app Makefile |
| `docs/` | Project documentation: this file, `product-spec.md`, plus `design-docs/`, `references/`, `generated/`, `user-tests/` |
| `mise.toml` | Pinned versions for `tuist`, `zig`, `swiftlint`, `xcbeautify` — shared across any future apps |
| `Makefile` | Top-level delegator: `make mac-build` → `$(MAKE) -C apps/mac build` |

### Directories inside `apps/mac/`

| Path | Purpose |
|---|---|
| `apps/mac/Project.swift`, `Tuist.swift`, `Tuist/` | Tuist project definitions for the mac platform |
| `apps/mac/Makefile` | Mac-platform build targets (bootstrap, generate, build, lint, etc.) |
| `apps/mac/Configurations/` | `Project.xcconfig` + `mac-Info.plist` |
| `apps/mac/scripts/` | `build-ghostty.sh` (Zig → XCFramework, fingerprint-cached) |
| `DiffViewKit` (SwiftPM, [diff-view](https://github.com/wanggang316/diff-view)) | Independent diff-view component pinned by exact tag in `apps/mac/Tuist/Package.swift` / `Package.resolved`: WKWebView bridge and bundled offline Web assets. No Codans dependency, Git access, or editor launching inside the component. |
| `apps/mac/ThirdParty/ghostty/` | Git submodule pointing at `ghostty-org/ghostty`. Built into `apps/mac/.build/ghostty/GhosttyKit.xcframework`. |
| `apps/mac/.swift-format.json`, `.swiftlint.yml` | Lint + format configs, scoped to mac sources |

### Workspace orchestration

A Workspace is a local Project with a synthetic root Worktree and member
checkouts from multiple repositories. Membership comes from
`.codans/workspace.json`; Git supplies branch and repository identity.
`WorkspaceClient` owns creation, addition, removal and rollback for both GUI
and CLI. Reconcile handles Workspace before Git-root discovery, and destructive
operations resolve each member's source repository. See [Workspace](design-docs/workspace.md).

### Agent Skill

`skills/codans-cli/SKILL.md` is the published text-only skill source. It is not a Swift target. `codans skill list/install/uninstall/path` manages links to app-bundled skill directories without a running app; see [CLI design](design-docs/cli.md).

## Dependency Direction

```text
CodansCore                  (no internal dependencies)
CodansIPC                   -> CodansCore
CodansKit                   -> CodansCore, CodansIPC, ArgumentParser
codans-cli                  -> CodansKit, CodansCore, CodansIPC, ArgumentParser
Codans (app)                -> CodansCore, CodansIPC, CodansKit, GhosttyKit, DiffViewKit,
                               codans-cli (embedded tool), external dependencies
  in-app modules            codans/{App,Runtime,Process,Git,GitHub}
                               (folder boundaries, not separate targets)
skills/codans-cli/          (text-only, no Swift dependencies)
```

**Rules:**
- `codans-cli` must NEVER `import` any in-app-module symbol (no `Runtime`, `Hooks`, `Git` usage) — it is a thin RPC client. This is enforced at file organization: those subfolders are inside the `codans` app target and not shipped as separate modules.
- `Codans` (app) and `codans-cli` must communicate only through IPC (`CodansIPC` wire types + Unix socket), never via shared state or file-based IPC.
- `CodansCore` must have zero imports from any other internal package — it is the universal leaf.
- No circular dependencies between frameworks.
- **In-app module boundaries** (`Runtime` ↔ `Hooks` ↔ `Git` ↔ `App`) are enforced by folder convention + code review only. No Tuist target edge exists between them because they compile into the same app binary. See "Architectural Invariants" for the rules that must not be violated (e.g., "Pane state mutability is localized to `Runtime`").
- `skills/codans-cli/` must not import or reference any Swift target — it is pure markdown + reference content.

**Enforcement:**
- Tuist target `dependencies:` lists in `apps/mac/Project.swift` — each Tuist target declares exactly which frameworks it depends on.
- Code review: PRs that break the in-app-module folder convention (e.g., `codans/Git/*.swift` importing from `codans/Runtime/`) are rejected.
- Future: a `make mac-inspect-dependencies` target (supacode-inspired) to flag unwanted in-app cross-imports.

## Architectural Invariants

Rules not visible in code. Violating any of these will not fail tests immediately but will rot the system.

- **Pane state mutability is localized to `Runtime`.** Pane scrollback, cursor, and selection are mutable only inside `codans/Runtime (in-app module)`. Other layers read via `@Observable` bindings or event streams; they must not call mutators directly.
- **App-control requests from the CLI go through `CodansIPC`.** The CLI uses the app Unix socket rather than file-based queues or shared mutable state. Terminal sessions and subprocesses have their own transport boundaries.
- **Hooks are out-of-process only in v1.** *(Design intent — the Hooks subsystem is not yet implemented; see [Lifecycle hooks](design-docs/lifecycle-hooks.md).)* When built, hook handlers execute as shell commands fork-exec'd by the app, receiving JSON on stdin and returning JSON on stdout. In-process handlers (embedded JS, WASM) are explicitly deferred.
- **State management is hybrid by design, with a clear boundary.** High-frequency terminal state uses `@Observable`; app flow state uses TCA. Mixing the two patterns within a single feature is a red flag. See [State Management](#state-management-hybrid-tca--observable).
- **Persistence has explicit owners and file-specific schema policies.** `AtomicFileStore` provides atomic-rename JSON I/O; callers own version validation and recovery. Do not assume all config-directory files share one schema or unsupported-version policy; see [Persistence](#persistence).
- **`codans` is stateless.** The CLI has no persistent state of its own. All truth lives in the running app; `codans` is a thin RPC client. Adding file reads/writes in `apps/mac/codans-cli/` requires a design doc.
- **Identifiers are UUIDs.** Every Project, Worktree, Tab, Pane, Tag has a stable UUID. Index-based addressing (`codans pane focus 1/2/3`) and the app-session short handles (`t3` / `p7`, printed by `codans tree` and backed by `TargetHandleRegistry`) are convenience sugar resolved to a UUID via `hierarchy.resolveAlias` before any state mutation. JSON output carries UUIDs only. Internal code must use UUIDs.
- **Agent Skill is consumed, never loaded.** The app must not parse, index, or invoke `SKILL.md`. `codans skill install` is a planned command, not shipped runtime code.
- **`codans/Runtime (in-app module)` is TCA-free.** Runtime exposes `@Observable` classes and AsyncStream events. TCA bridging lives in `apps/mac` (the `*Client` types). This keeps Runtime independently testable and portable.
- **`SplitTree<PaneID>` stores only Pane IDs, never surface objects.** Per-Tab split layout (`CodansCore.SplitTree<PaneID>`, see `CodansCore/Tab.swift`) is a recursive value type keyed on `PaneID`; view composition resolves each leaf ID to its Pane and live `ghostty_surface_t` at render time. This is what makes split state Codable/persistable (a live surface pointer cannot survive restart) and makes every split operation (grow/shrink, focus nav, swap) a pure value-type transform that is unit-testable without any libghostty bring-up. Invariant: the set of leaf IDs in a Tab's `splitTree` equals the set of `panes[*].id` on that Tab.
- **Reported pane failures have a bounded recovery policy.** `TerminalEngine.recordPaneCrash` tracks failures per pane and closes the owning Tab after the configured threshold (default: 3 within 30 seconds). The UI can retry a failed surface. This handles reported runtime failures; libghostty is in-process, so it does not provide process-level isolation from native crashes.

## Cross-Cutting Concerns

### State Management: Hybrid TCA + `@Observable`

**TCA (The Composable Architecture)** is used for:
- App shell (root reducer, launch flow)
- Feature flows: Settings, CommandPalette, GitHub, Diff, HierarchySidebar, WorktreeHeader, Updates
- Socket server lifecycle
- Deeplink dispatch

**Swift Observation (`@Observable`)** is used for:
- `Runtime.TerminalEngine` — manages N panes
- `HierarchyManager` — mutable Catalog of Projects/Worktrees/Tabs/Panes plus Tags and the active Tag filter

**Bridge:** `apps/mac/codans/App/Clients/*Client.swift` exposes:
- **Commands** (TCA → runtime): `terminalClient.ensureSurface(...)`, `terminalClient.sendInput(pane, text)`
- **Events** (runtime → TCA): `terminalClient.events()` returns an `AsyncStream<TerminalEvent>` the root reducer subscribes to and maps to `Action.terminal(...)`

Rationale: agent-heavy panes produce thousands of output events per second; routing every byte through a TCA reducer is a known anti-pattern (value-type state diffs, Effect allocation, Equatable checks). Both reference projects ended at this split — supacode explicitly; supaterm implicitly via reference-type state within TCA.

### IPC

- **Transport:** Unix domain socket, one per running app instance. Release builds default to `/tmp/codans-$UID.sock`; Debug builds default to `/tmp/codans-dev-$UID.sock`; both are overridable via `CODANS_SOCKET_PATH`
- **Wire protocol:** length-prefixed JSON envelopes. Framing is a `UInt32` **big-endian** length prefix followed by exactly N bytes of UTF-8 JSON — **no trailing newline**. Each frame is capped at **16 MiB**; an oversized length prefix raises `IPCError.invalidFrame` and the connection is closed (0003 DEC-3). Envelope shapes defined in `CodansIPC/Protocol.swift`:
  - Request: `{"id": "uuid", "method": "terminal.sendInput", "params": {...}}`
  - Success: `{"id": "uuid", "result": {...}}`
  - Error: `{"id": "uuid", "error": {"code": Int, "message": "…"}}`
- **Methods:** namespaced — `system.*`, `editor.*`, `project.*`, `workspace.*`, `agent.*`, `handoff.*`, `hierarchy.*`, `pane.*`, `terminal.*` (enumerated in `CodansIPC/Method.swift`). Skill installation is local CLI filesystem work and has no `skill.*` RPC; lifecycle hooks have no live RPC methods.
- **Discovery in `apps/mac/codans-cli/`:** `--socket` flag → env var `CODANS_SOCKET_PATH` → build-channel default (`BuildChannel.current.socketPath`). An inherited *other-channel* default is never followed: the app discards it before binding, the release CLI refuses to act on a development pane (exit 15), and the development CLI dials its own socket — see [Environment](design-docs/environment.md)
- **Context pane id:** the app sets `CODANS_PANE_ID` in each local Pane's environment so `codans` commands run inside a Pane can default to that Pane's UUID without an explicit flag; tab / worktree / project ids are *not* injected (they go stale when a pane moves) and resolve server-side from process ancestry. The full injected set is built by `PaneEnvironment` and catalogued in `CodansEnvironment.Key`

### URL scheme

- Scheme: `codans://`
- Shipping surface: `codans://focus?project=…&worktree=…&tab=…&pane=…`, parsed by `CodansApp.parseDeeplink` (`apps/mac/codans/App/CodansApp.swift`) off `onOpenURL` and resolved to a hierarchy selection. There is no standalone `DeeplinkParser`/`DeeplinkRouter` type.
- *Design intent (not yet built):* richer verbs (`…/send`, `…/exec`) and a `DeeplinkConfirmationFeature` approval gate for sensitive actions. Only `focus` exists today, and `focus` requires no confirmation.

### Persistence

Files under `~/.config/codans/` — `~/.config/codans-dev/` for Debug builds, see [Environment](design-docs/environment.md) — (JSON, UTF-8, pretty-printed with sorted keys for determinism):

| File | Version | Contents |
|---|---|---|
| `catalog.json` (`CodansCore/Catalog.swift`) | v3 | Project → Worktree → Tab → Pane tree with UUIDs, split geometry, current selection at every level; `tags: [Tag]`, per-Project `tagIDs: Set<TagID>`, top-level `activeTagFilter`, `projectSortMode`, `selectedProjectID`. The schema has no `spaces` or `CatalogWindow` container. Per-Project `defaultEditor` / `worktreesDirectory` are resolved from `settings.json`, never the `Project` struct. |
| `settings.json` (`CodansCore/Settings/`) | v3 | User preferences — global (`general`, `notifications`, `developer`) plus per-Project (`projects[ProjectID]: ProjectSettings`). `ProjectSettings` carries shared fields and an optional `git: GitProjectSettings?` subtree for Git settings; applicability is determined by Project kind. |
| `sessions.json` (`CodansCore/Session.swift`) | v1 | Live zmx daemon registry — per-Pane session id / pid / state, so a relaunch can rediscover, ping, and re-attach. Lock coordination is on a sidecar `sessions.json.lock`, not the file itself. Underpins the [Session lifecycle](#session-lifecycle-quit-snapshot--launch-restore) re-attach path. |
| `notifications.json`, `shortcuts.json` | v1 | Inbox entries and keybinding overrides (`AppDirectories.configDirectory`). Persisted JSON keys are API: e.g. `CommandID.toggleDiffInspector` keeps the raw value `"toggleGitViewer"` so renaming the Swift identifier never orphans a user's keybinding. |

The shared JSON write primitive is atomic-rename persistence (`CodansCore/AtomicFileStore.swift`):
1. Encode to temp file in the same directory
2. `fsync` temp file
3. `rename(2)` over original

Version handling belongs to each store, not `AtomicFileStore`. `catalog.json` requires `Catalog.currentVersion` (currently 3); `settings.json` migrates v1/v2 to v3 with backups (see [Settings](design-docs/settings.md)). `SessionStore` accepts versions up to its current version, quarantines corrupt JSON, and leaves a newer-version file in place while returning an empty catalog. `InboxFile` accepts legacy arrays and versioned envelopes, and quarantines forward-version envelopes. Consult each loader before changing recovery behavior; there is no universal "rename every unsupported file" rule. The planned Hooks subsystem would add `hooks.json`; it is not implemented. This table covers the main stores, not every config file or sidecar (see [Environment](design-docs/environment.md)).

### Session lifecycle: quit snapshot + launch restore

The "Snapshot and exit" quit action (`QuitAction.snapshot`) and its launch-time
restore are one end-to-end path built on the unified `zmx attach` invocation —
cold start, live re-attach, and snapshot restore are all the *same* spawn, with
`--restore-from` an optional flag, never a second spawn path.

- **Producer (quit).** `SessionLifecycle.detachAllForQuit(action:)` is `async`.
  On `.snapshot` it calls `ZmxControlClient.snapshot(for:)` per live surface with
  bounded concurrency (sliding window of 8) and a per-pane timeout (`.seconds(2)`);
  the daemon answers by writing `<paneID>.snap` and closing its control socket
  (socket EOF = acknowledgement). A pane that times out falls back to
  `ZmxControlClient.kill(for:)` so a wedged daemon can never strand quit. The
  snapshotted set and the kill-fallback set are provably disjoint (fallback is
  signalled by a *log line*, not by `.snap` absence — a clean empty-buffer pane
  also writes no file). `applicationShouldTerminate` drives this via a
  `.terminateLater` reply bounded by an outer 20 s watchdog, and a one-way
  `dispositionInProgress` latch makes a re-entrant terminate (rapid double ⌘Q)
  a clean no-op. `.keepRunning` leaves daemons alive untouched.
- **Consumer (launch).** `CodansApp.bootstrapSessionStack` keeps the
  `SessionReaper.sweep()` result and reduces its `.snapshot(url)` states (only
  those — `.alive`/`.dead` are ignored) into `TerminalEngine.pendingRestores`
  via `AppState.derivePendingRestores`, *before* bring-up. `ensureSurface`
  consumes each pane's path exactly once (`removeValue`, stable across the
  HAN-82 surface-init retry) and passes it to `ZmxAttachCommand.build(restoreFrom:)`.
  Restore is keyed on snapshot *file presence*, never on the current
  `quitAction` setting.
- **cwd by inheritance (no `--cwd`).** The restored shell's working directory is
  the daemon's cwd, which libghostty sets on the forked child from
  `pane.workingDirectory` — so each pane restores in its own directory with no
  `--cwd` flag (empirically confirmed by `ThirdParty/zmx/test/restore.bats`).
- **Files.** `.snap` files live at `${ZMX_DIR}/snapshots/<paneID-UUID>.snap`
  (`ZMX_DIR` is pinned by the app so producer, consumer, and reaper agree on the
  path); the reaper deletes a snap once its paneID is `.alive` again and ages
  out snaps older than 7 days. `.snap` files are plaintext, user-readable only.
- **Observability.** `os.Logger` under `com.gumpw.codans.runtime`:
  `zmx.snapshot send pane=<uuid>` (category `runtime.zmx.control`, per pane at
  request time), `zmx.snapshot kill-fallback pane=<uuid>` and
  `zmx.restore applied pane=<uuid>` (category `runtime.session.lifecycle`).

### Logging

- `os.Logger` with subsystem `com.gumpw.codans.*`
- Per-package category: `com.gumpw.codans.runtime`, `com.gumpw.codans.ipc`, etc.
- `apps/mac/codans-cli/` logs to stderr only; `--verbose` flag controls level
- No custom logger layer; no file-based logs in v1

### Error handling

- `CodansIPC` defines a small `IPCError` enum (e.g., `.unknownMethod`, `.invalidParams`, `.panelNotFound`, `.internal`)
- Domain errors stay inside their package; converted to `IPCError` only at the IPC boundary
- Panics (Swift fatalError) are reserved for invariant violations, never for user input

### Accessibility (probeable contracts)

User-observable accessibility values are a stable probe contract — validation keys on them, and renaming a vocabulary string breaks a unit test. Two SwiftUI traps to avoid (both bit the worktree-creation in-progress UI):

- `.accessibilityValue(_:)` / `.accessibilityLabel(_:)` applied to a view that is also `.accessibilityElement(children: .contain)` is a **no-op** — the container exposes its children, not its own value. Put the value on a **leaf child** (e.g. the row's name `Text` carries the in-progress/settled value; the status `Text` carries the stage value) so it provably reaches the accessibility tree.
- `.accessibilityRepresentation { … }` replaces the modified subtree's accessibility entirely (per Apple's docs), so it can shadow contained leaves. Use it only where the element has no children to probe (e.g. a settled failure announced as one element), not to bolt a value onto a `.contain` row whose leaves must stay individually probeable.

`AgentStateRowView` and `PendingWorktreeRow` are the worked examples; decorative spinners/glyphs/shimmer stay `.accessibilityHidden(true)` since the value/label carries the meaning.

### Build toolchain

- `mise.toml` pins `tuist`, `zig`, `swiftlint`, `xcbeautify`
- `apps/mac/scripts/build-ghostty.sh` runs Zig to build `GhosttyKit.xcframework` from the submodule; uses fingerprint-based caching (git HEAD + local diff + mise.toml hash)
- `apps/mac/scripts/xcode-compat/` lets the pinned zig 0.15.2 link on Xcode 26.4+: `build-ghostty.sh` / `build-zmx.sh` source its `activate.sh`, which checks the SDK's `libSystem.tbd` and, only when needed, puts an `xcrun` wrapper on PATH that points zig at an older installed SDK. The companion libtool fix lives in the ghostty fork (backport of upstream #11999). See `docs/lessons-learned/2026-09-17-zig-builds-broke-on-xcode-26-4-and-later.md`
- Top-level `Makefile` orchestrates: `make bootstrap` (submodules + mise), `make mac-build-ghostty`, `make mac-generate` (Tuist), `make mac-build`, `make mac-test`

### Build & concurrency invariants

Hard-won constraints that are invisible in the code but break the build or crash the runtime if violated:

- **GhosttyKit linking.** Xcode 26 ships without the Metal toolchain — a one-time `xcodebuild -downloadComponent MetalToolchain` is required. The app target must link `-lc++ -framework Carbon -framework Metal -framework MetalKit -framework CoreText -framework QuartzCore` because `ghostty-internal.a` pulls in the spirv_cross/glslang C++ runtime and Carbon HIToolbox.
- **`ghostty_init(argc, argv)` first.** It must be the first libghostty call of the process — `ghostty_config_new` null-derefs otherwise. Enforced via a `GhosttyRuntime` static global-init on first access.
- **Swift 6 actor isolation.** The app uses `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`; shared targets such as `CodansKit` explicitly use `nonisolated` in `Project.swift`. Three recurring gotchas: use `@Dependency(Type.self)`, never the keypath form (`WritableKeyPath` is not `Sendable`); `AnyView`-erase recursive SwiftUI views or the type-checker hangs (>5 min); fully-qualify `CodansCore.Tab` because `SwiftUI.Tab` shadows it.
- **Swift Testing landmine.** `String.split(whereSeparator:)` + `String.Index` slicing crashes inside a `@Test` (Signal 5, `dispatch_assert_queue_fail`); use `components(separatedBy:)` + UTF-8-view slicing instead.
- **`xcodebuild` invocation.** Target `codans.xcworkspace`, not `-project` (SwiftPM deps resolve at the workspace level). `make mac-test` runs the `Codans`, `CodansCore`, and `CodansKit` schemes; select the relevant scheme when diagnosing a specific failure. Historical host-app crashes are not a reason to permanently skip that suite. `xcodebuild test ENV=value` sets *build* settings, not test-runtime env (Xcode 15+) — gate integration/perf tests with `.enabled(if:)` reading `ProcessInfo` (a thrown skip counts as a failure).

## Technology Choices

| Technology | Scope | Purpose | Rationale |
|---|---|---|---|
| Swift 6 | all | Language | Native macOS; libghostty has first-class Swift/C interop via GhosttyKit; aligns with both reference projects |
| Tuist 4 | workspace | Project + target generation | Modular Xcode workspace; internal targets declared in `apps/mac/Project.swift`. Same pattern as supacode/supaterm |
| SPM (via Tuist `Package.swift`) | workspace | External dependencies | Standard tool for fetching third-party libraries (TCA, ArgumentParser, Sparkle); integrated into Tuist |
| mise | workspace | Tool version pinning | Committed `mise.toml` pins `tuist`, `zig`, `swiftlint`, `xcbeautify`; keeps supported tool versions explicit |
| libghostty (via `ThirdParty/ghostty` submodule → Zig → `GhosttyKit.xcframework`) | `codans/Runtime (in-app module)` | Terminal emulator | Best macOS-native terminal renderer with a stable C API; building from submodule (not prebuilt XCFramework) matches supacode/supaterm and lets us patch Ghostty if needed |
| The Composable Architecture | `apps/mac` | App/UI state | Testable unidirectional flows for features (Settings, CommandPalette, GitHub); proven in both reference projects |
| Swift Observation (`@Observable`) | `codans/Runtime (in-app module)`, parts of `apps/mac` | Runtime state | Hybrid complement to TCA for high-frequency terminal state; native Swift 6 feature; proven in supacode |
| ArgumentParser | `apps/mac/codans-cli/` | CLI parsing | Apple's official CLI framework; same as both reference projects |
| Sparkle | `apps/mac` | Auto-update | De facto standard for macOS app updates; same as supacode |
| SwiftLint + swift-format | workspace | Lint + format | Style consistency; enforced in CI; configured via `.swiftlint.yml` and `.swift-format.json` |

## Entry Points

| Surface | File | Responsibility |
|---|---|---|
| App launch | `apps/mac/codans/App/CodansApp.swift` | `@main`, root TCA store construction, window lifecycle |
| CLI launch | `apps/mac/codans-cli/CodansCLI.swift` | `ArgumentParser` root; dispatches to subcommand |
| Socket server | `apps/mac/codans/App/Features/Socket/SocketServer.swift` | Accepts Unix socket connections; `MethodRouter` routes JSON-RPC to per-namespace handlers |
| libghostty bootstrap | `apps/mac/codans/Runtime/Ghostty/GhosttyRuntime.swift` | Initializes `ghostty_app_t`, registers callbacks (`ghostty_init(argc,argv)` must be the first libghostty call — see Build & concurrency invariants) |
| Hook dispatcher | *(planned)* | Fan-out of lifecycle events to configured handlers — not yet implemented (see [Lifecycle hooks](design-docs/lifecycle-hooks.md)) |
| Deeplink handler | `apps/mac/codans/App/CodansApp.swift` (`parseDeeplink`) | Receives `codans://` URLs via `onOpenURL`; current shipping surface is `codans://focus?project=…&worktree=…&tab=…&pane=…` |
| Persistence boundary | `apps/mac/CodansCore/AtomicFileStore.swift` | Atomic-rename JSON read/write; version checks belong to callers |

## References

### Reference projects — borrow first, deviate with reason

- **supaterm** — `/Users/wanggang/dev/opensource/supaterm`
  - JSON-RPC wire protocol: `apps/mac/SupatermCLIShared/SupatermSocketProtocol.swift`
  - Agent hook JSON format: `apps/mac/SupatermCLIShared/SupatermAgentHook.swift`
  - `SplitTree<ViewType>` generic: `apps/mac/supaterm/Features/Terminal/Models/`
  - Persistence pattern + schema version: `apps/mac/supaterm/Features/Terminal/Models/TerminalSession.swift`
  - Ghostty submodule build: `apps/mac/scripts/build-ghostty.sh`

- **supacode** — `/Users/wanggang/dev/opensource/supacode`
  - Hybrid TCA + `@Observable` bridge: `supacode/Clients/Terminal/TerminalClient.swift`
  - AgentHookSocketServer: `supacode/Infrastructure/AgentHookSocketServer.swift`
  - Worktree terminal manager: `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`
  - Deeplink parser: `supacode/Domain/Deeplink*`
  - `mise.toml` + `scripts/build-ghostty.sh` with fingerprint cache
  - Tuist modular targets: `Project.swift`

- **supaterm-skills** — `/Users/wanggang/dev/opensource/supaterm-skills`
  - Reference layout for our `skills/codans-cli/`: `SKILL.md` + `references/` + `agents/`

### External references

- matklad, *ARCHITECTURE.md* — <https://matklad.github.io/2021/02/06/ARCHITECTURE.md.html>
- The Composable Architecture — <https://github.com/pointfreeco/swift-composable-architecture>
- Swift Observation — <https://developer.apple.com/documentation/observation>
- Ghostty — <https://ghostty.org>
- mise — <https://mise.jdx.dev>
- Tuist — <https://tuist.dev>

## Architectural Decisions

1. **Internal Tuist target granularity in `apps/mac`.** the app is a single Tuist target with folder-level module organization (`App` / `Runtime` / `Process` / `Git` / `GitHub`); in-app boundaries are folder convention + code review, not target edges. Promote a subfolder to its own framework target only when it gains a test bundle, is consumed by another app, or needs to restrict its public API.

2. **Single main window.** A single `Window(id:)` owns the main workspace; Settings has its own window. Close Tab and application quit have different effects. Confirmation and daemon disposition follow `quitConfirmation` and `quitAction`; see [Project Tags and Single Main Window](design-docs/project-tags.md).

3. **CLI binary distribution.** from Settings → Developer, one macOS administrator-authorization dialog symlinks the bundle-embedded signed binary (`Contents/Resources/bin/codans`) into `/usr/local/bin/codans` (Debug: `/usr/local/bin/codans-dev`). Callers must have the installation directory on their `PATH` or invoke the binary by absolute path; an unprivileged probe classifies the destination as absent / our-symlink / foreign and aborts on a foreign file before opening the dialog. See [CLI design doc §D2 and §CLI 安装](design-docs/cli.md#cli-安装).

4. **Hook handler execution policy.** Serial per event vs. concurrent with a cap. **Unimplemented** in the Hooks subsystem (see [Lifecycle hooks](design-docs/lifecycle-hooks.md)). *Leaning:* concurrent with a global cap (default 8); single-handler-at-a-time flag per hook subscription as opt-in.

5. **IPC request handling.** `SocketConnection` awaits each request serially. Its in-flight limit guard does not implement a queued 64-request workload or a two-second overflow wait. See [CLI request processing](design-docs/cli.md#decisions) for the current connection contract.

6. **Runtime failure recovery.** See the reported-pane-failure policy under "Architectural Invariants"; this is not isolation from native process crashes.

7. **Worktree storage layout defaults.** Local creation resolves its base through `WorktreeSettings.resolveBaseDirectory`: per-Project `worktreesDirectory` verbatim → global `defaultWorktreesDirectory/<canonicalProjectName>` → `~/.codans/repos/<canonicalProjectName>`. The new worktree name is appended to that base. `HierarchySidebarFeature` uses the path-derived canonical project name, so renaming the display name does not change the suggested directory. Remote creation instead uses the parent of the remote git root. See [Worktree](design-docs/worktree.md) and [Remote SSH projects](design-docs/remote-ssh-projects.md).
