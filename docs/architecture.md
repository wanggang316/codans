# Architecture

## Overview

codans is a native macOS application that orchestrates terminals into a four-level hierarchy (Project → Worktree → Tab → Pane), with cross-cutting Tag classification on Projects, for CLI-agent power users. See [Product Spec](product-spec.md) for capabilities and boundaries.

The system is a **Tuist-managed monorepo** because the product ships three co-versioned artifacts — the Mac app, the `codans` CLI, and the published Agent Skill — whose development benefits from atomic cross-cutting changes (protocol edits, CLI contract changes, domain-model evolution) and shared tooling.

Architecture is adapted from two reference projects the user maintains and encourages borrowing from: **supacode** and **supaterm**. See [References](#references) for file anchors. The structural shape — Swift 6, Tuist, libghostty-via-submodule, hybrid TCA + `@Observable`, JSON-RPC over Unix socket, out-of-process shell hooks — is lifted from these projects because they have already validated the pattern on the same workload codans targets.

## Codemap

The mac platform (Tuist project, sources, ghostty submodule) lives under `apps/mac/`. The top level holds monorepo-wide concerns (docs, root Makefile that delegates, `mise.toml`). This mirrors supaterm's multi-platform-ready layout.

### Tuist targets under `apps/mac/`

| Target | Kind | Source path | Purpose |
|---|---|---|---|
| `CodansCore` | static framework | `apps/mac/CodansCore/` | Pure domain types: Project/Worktree/Tab/Pane models, `Tag`/`TagFilter`, `SplitTree`, stable UUID identifiers. Zero internal deps. Consumed by app + CLI. |
| `CodansIPC` | static framework | `apps/mac/CodansIPC/` | JSON-RPC wire protocol: Request/Response envelopes, Method constants, payload types, socket discovery. Shared between app and CLI. |
| `codans-cli` | command-line tool | `apps/mac/codans-cli/` | CLI binary (`PRODUCT_NAME=codans`). Depends on `CodansCore`, `CodansIPC`, `ArgumentParser`. Runtime / Hooks / Git are intentionally off-limits — CLI is a thin RPC client. |
| `codans` | macOS app | `apps/mac/codans/{App,Runtime,Hooks,Git}/` | The Mac app. Buildable subfolders compile as one target. Depends on `CodansCore`, `CodansIPC`, `codans`; the `codans` binary is embedded inside the app bundle at `Codans.app/Contents/Resources/bin/codans` via the `Embed codans` post-script (`apps/mac/scripts/embed-codans.sh`), giving the c4-cli first-launch installer a stable symlink target. The `.app` filename is `Codans.app` (no space) to keep packaging tools happy; user-facing identity is "Codans" via `CFBundleDisplayName` + `CFBundleName`. |

### In-app modules (subfolders of the `codans` target, not separate Tuist targets)

| Subfolder | Purpose |
|---|---|
| `codans/App/` | `@main CodansApp.swift`, root SwiftUI scene, TCA store construction |
| `codans/Runtime/` | libghostty integration: GhosttyKit Swift bindings, Pane lifecycle, Surface rendering adapter, `@Observable` runtime state |
| `codans/Hooks/` | Lifecycle event taxonomy (Pane created / ready / output match / idle / exit; Tab activated; Worktree activated), hook registration, out-of-process shell handler dispatch |
| `codans/Process/` | Shared subprocess primitive — `CommandRunner` protocol + `FoundationCommandRunner` / `RecordingCommandRunner`. Extracted from `Git/` during the GitHub integration (0012 DEC-5) so `Git/` and `GitHub/` can depend on a common runner without taking a sibling-module import. Timeout + SIGTERM→SIGKILL ladder + pipe-drain backpressure live here; translation from `CommandOutcome` to a domain error type is each caller's responsibility. |
| `codans/Git/` | Read-only git data access: diff parsing, log enumeration, commit detail extraction. No write operations. |
| `codans/GitHub/` | gh-delegated GitHub integration data layer (0012). `GitHubService` protocol + `LiveGitHubService` wrapping `gh` via `CommandRunner`, `GhCommand` argv builder, `GhExecutableResolver` actor, `JSONOutputParsers` translating gh stdout → `CodansCore` DTOs, `GitHubError` taxonomy. Zero HTTP in-app; auth/tokens live entirely in gh's own config store. App-layer TCA bits live in `App/Clients/GitHubClient.swift` + `App/Features/GitHub/`. |
| `codans/App/Features/GitHub/` | 0012 GitHub integration TCA feature. `GitHubFeature` owns per-Worktree PR snapshots + 30 s availability cache + popover presentation bit; `GitHubRootBindings` stacks under the Scope to fan delegate actions out to `NSWorkspace.open` / `SettingsWindowPresenter`. Views: `PullRequestBadge` (sidebar-row capsule), `PullRequestPopover` with split-button merge + checks list, `CheckRow`, `MergeSplitButton`, colour tokens in `Theme/`. |
| `codans/App/Clients/Editor/` | `EditorService` / `EditorRegistry` / `PathProber` / `ProcessSpawner` — C8 external-editor handoff. `LiveEditorService` merges built-in allowlist (VSCode / Cursor / Zed / Xcode / Sublime / Finder) with user-defined templates from `SettingsStore`, probes `$PATH` for installation status, and spawns with a 5 s budget + SIGTERM→SIGKILL ladder. |
| `codans/App/Features/GitViewer/` | C7 read-only git viewer: `GitViewerFeature` TCA reducer + SwiftUI column hierarchy (`GitViewerView` / `CommitLogView` / `FileChangeListView` / `UnifiedDiffView`) + 50k-line `LargeDiffPlaceholderView` with POSIX-quoted "Copy command" button. |
| `codans/App/Features/WorktreeHeader/` | T2 Header row above the terminal Tab bar. `WorktreeHeaderFeature` owns bell + split-button + GV-toggle state; subscribes to `InboxClient.observe()` for the badge. Views: `WorktreeHeaderView` (row container) + `HeaderBellView` / `HeaderBellPopover` (notifications) + `HeaderOpenSplitButton` (primary open + editor picker + "Set default for this Project" sub-menu + "+ Custom editors…" deeplink) + `HeaderGitViewerToggle` (flips `Worktree.gitViewerVisible`). Editor opens flow as `.delegate(.openEditor…)` actions consumed by `RootFeature`. |
| `codans/App/Features/Socket/` | `EditorHandlers` — server-side RPC handlers for `editor.describe` / `editor.open` / `editor.setDefault`. Bridges `EditorClient` + `HierarchyClient` to wire types in `CodansIPC/Editor/`. MethodRouter registration lands at the 0003 merge per plan 0005 DEC-21. |

Module boundaries between `Runtime`, `Hooks`, `Git`, and `App` are enforced by **folder convention + code review**, not by Tuist target edges. This matches supacode/supaterm's idiom. Promote a subfolder to its own target only when it gains a test bundle, becomes consumed by another app (e.g. iOS), or needs to restrict its public API surface.

### Directories at the repo root (monorepo-wide)

| Path | Purpose |
|---|---|
| `apps/mac/` | The mac platform: Tuist project, sources, ghostty submodule, per-app Makefile |
| `docs/` | Project documentation (this file, product-spec, design-docs, exec-plans, references) |
| `mise.toml` | Pinned versions for `tuist`, `zig`, `swiftlint`, `xcbeautify` — shared across any future apps |
| `Makefile` | Top-level delegator: `make mac-build` → `$(MAKE) -C apps/mac build` |

### Directories inside `apps/mac/`

| Path | Purpose |
|---|---|
| `apps/mac/Project.swift`, `Tuist.swift`, `Tuist/` | Tuist project definitions for the mac platform |
| `apps/mac/Makefile` | Mac-platform build targets (bootstrap, generate, build, lint, etc.) |
| `apps/mac/Configurations/` | `Project.xcconfig` + `mac-Info.plist` |
| `apps/mac/scripts/` | `build-ghostty.sh` (Zig → XCFramework, fingerprint-cached) |
| `apps/mac/ThirdParty/ghostty/` | Git submodule pointing at `ghostty-org/ghostty`. Built into `apps/mac/.build/ghostty/GhosttyKit.xcframework`. |
| `apps/mac/.swift-format.json`, `.swiftlint.yml` | Lint + format configs, scoped to mac sources |

### Future peer directories

| Path | Purpose |
|---|---|
| `codans-skill/` | A Claude Code / Codex / pi Agent Skill (`SKILL.md` + `references/` + `agents/`). Co-located for version alignment but **not a Swift target** — not imported by anything, not built, not signed. Distributed to coding agents via `codans skill install`. Currently a planned peer of `apps/`; not yet created. |

## Dependency Direction

```
CodansCore                               (leaf — zero internal deps)
    │
    └── CodansIPC                        (CodansCore)
            │
            ├── codans                          (CodansCore, CodansIPC — nothing else)
            └── codans (app)            (CodansCore, CodansIPC, codans, external deps)
                    │
                    └── in-app modules:     codans/{App,Runtime,Hooks,Git}
                        (not separate targets; folder-level boundary only)

codans-skill/                           (orthogonal — no Swift dependency;
                                             consumed by coding agents, not by the app)
```

**Rules:**
- `codans` must NEVER `import` any in-app-module symbol (no `Runtime`, `Hooks`, `Git` usage) — it is a thin RPC client. This is enforced at file organization: those subfolders are inside the `codans` app target and not shipped as separate modules.
- `codans` (app) and `codans` must communicate only through IPC (`CodansIPC` wire types + Unix socket), never via shared state or file-based IPC.
- `CodansCore` must have zero imports from any other internal package — it is the universal leaf.
- No circular dependencies between frameworks.
- **In-app module boundaries** (`Runtime` ↔ `Hooks` ↔ `Git` ↔ `App`) are enforced by folder convention + code review only. No Tuist target edge exists between them because they compile into the same app binary. See "Architectural Invariants" for the rules that must not be violated (e.g., "Pane state mutability is localized to `Runtime`").
- `codans-skill/` must not import or reference any Swift target — it is pure markdown + reference content.

**Enforcement:**
- Tuist target `dependencies:` lists in `apps/mac/Project.swift` — each Tuist target declares exactly which frameworks it depends on.
- Code review: PRs that break the in-app-module folder convention (e.g., `codans/Git/*.swift` importing from `codans/Runtime/`) are rejected.
- Future: a `make mac-inspect-dependencies` target (supacode-inspired) to flag unwanted in-app cross-imports.

## Architectural Invariants

Rules not visible in code. Violating any of these will not fail tests immediately but will rot the system.

- **Pane state mutability is localized to `Runtime`.** Pane scrollback, cursor, and selection are mutable only inside `codans/Runtime (in-app module)`. Other layers read via `@Observable` bindings or event streams; they must not call mutators directly.
- **All cross-process communication goes through `CodansIPC`.** No other channel between `apps/cli` and `apps/mac`. No HTTP, no TCP, no file-based queues, no shared memory.
- **Hooks are out-of-process only in v1.** Hook handlers execute as shell commands fork-exec'd by the app, receiving JSON on stdin and returning JSON on stdout. In-process handlers (embedded JS, WASM) are explicitly deferred.
- **State management is hybrid by design, with a clear boundary.** High-frequency terminal state uses `@Observable`; app flow state uses TCA. Mixing the two patterns within a single feature is a red flag. See [State Management](#state-management-hybrid-tca--observable).
- **Persistence is atomic-rename JSON with a top-level `version: Int`.** All files under `~/.config/codans/` include a schema version. Readers that encounter an unknown version abort rather than silently upgrade. Writers write to a temp file and rename over the original.
- **`codans` is stateless.** The CLI has no persistent state of its own. All truth lives in the running app; `codans` is a thin RPC client. Adding file reads/writes in `apps/cli` requires a design doc.
- **Identifiers are UUIDs.** Every Project, Worktree, Tab, Pane, Tag has a stable UUID. Index-based addressing (`codans pane focus 1/2/3`) is convenience sugar resolved to a UUID before any state mutation. Internal code must use UUIDs.
- **Agent Skill is consumed, never loaded.** The app must not parse, index, or invoke `SKILL.md`. The only skill-related runtime code is the `codans skill install` helper, which copies files to the agent's skill directory.
- **`codans/Runtime (in-app module)` is TCA-free.** Runtime exposes `@Observable` classes and AsyncStream events. TCA bridging lives in `apps/mac` (the `*Client` types). This keeps Runtime independently testable and portable.
- **Git counts that gate a destructive action fail closed.** A `GitWorktreeClient` primitive whose result decides whether data may be discarded (e.g. `branchUniqueCommitCount`, which gates the Recreate force-delete) MUST throw on any git error and MUST NOT coerce a failure to `0`. Callers treat a thrown/absent count as "unknown → require explicit confirmation", never as "0 → safe to discard". Collapsing an error into `0` would silently bypass the no-silent-data-loss guard, and a test that asserted the collapsed `0` would still pass — so this is enforced by convention + review, not the type system.

## Cross-Cutting Concerns

### State Management: Hybrid TCA + `@Observable`

**TCA (The Composable Architecture)** is used for:
- App shell (root reducer, launch flow)
- Feature flows: Settings, CommandPalette, GitViewer, HierarchyCatalog, Updates
- Socket server lifecycle
- Deeplink dispatch

**Swift Observation (`@Observable`)** is used for:
- `Runtime.PanelState` — libghostty surface, scrollback, cursor
- `Runtime.TerminalEngine` — manages N panes
- `HierarchyManager` — mutable Catalog of Projects/Worktrees/Tabs/Panes plus Tags and the active Tag filter

**Bridge:** `apps/mac/Clients/*Client.swift` exposes:
- **Commands** (TCA → runtime): `terminalClient.openPanel(in: worktree)`, `terminalClient.sendInput(pane, text)`
- **Events** (runtime → TCA): `terminalClient.events()` returns an `AsyncStream<TerminalEvent>` the root reducer subscribes to and maps to `Action.terminal(...)`

Rationale: agent-heavy panes produce thousands of output events per second; routing every byte through a TCA reducer is a known anti-pattern (value-type state diffs, Effect allocation, Equatable checks). Both reference projects ended at this split — supacode explicitly; supaterm implicitly via reference-type state within TCA.

### IPC

- **Transport:** Unix domain socket, one per running app instance. Release builds default to `/tmp/codans-$UID.sock`; Debug builds default to `/tmp/codans-dev-$UID.sock`; both are overridable via `CODANS_SOCKET_PATH`
- **Wire protocol:** length-prefixed JSON envelopes. Framing: `\n`-terminated length header followed by the JSON body. Envelope shapes defined in `CodansIPC/Protocol.swift`:
  - Request: `{"id": "uuid", "method": "terminal.open_panel", "params": {...}}`
  - Success: `{"id": "uuid", "result": {...}}`
  - Error: `{"id": "uuid", "error": {"code": Int, "message": "…"}}`
- **Methods:** namespaced (`terminal.*`, `hierarchy.*`, `git.*`, `skill.*`, `system.*`)
- **Discovery in `apps/cli`:** env var `CODANS_SOCKET_PATH` → build-channel default path probe → (optional) launch app and wait up to 10s
- **Context pane id:** the app sets `CODANS_PANE_ID` in each Pane's environment so `codans` commands run inside a Pane can default to that Pane's UUID without an explicit flag (mirrors `SUPATERM_PANE_ID`)

### URL scheme

- Scheme: `codans://`
- Examples: `codans://worktree/<id>/focus`, `codans://pane/<id>/send?text=...`
- Parsed by `apps/mac/Features/Deeplink/DeeplinkParser.swift`; maps onto the same IPC methods used by `codans`
- Routed through `DeeplinkConfirmationFeature` for user approval on sensitive actions (send, exec)

### Persistence

Files under `~/.config/codans/` (JSON, UTF-8, pretty-printed with sorted keys for determinism):

| File | Version | Contents |
|---|---|---|
| `catalog.json` | v3 | Project → Worktree → Tab → Pane tree with UUIDs, split geometry, current selection at every level; `tags: [Tag]`, per-Project `tagIDs: Set<TagID>`, top-level `activeTagFilter`. v3 was the rm-space refactor: prior v2 `Catalog.spaces` and `CatalogWindow` are dropped, each Space migrated to a Tag with the same name. Per-Project `defaultEditor` and `worktreesDirectory` moved to `settings.json` in v2 (one-shot read of v1 values through `HierarchyManager.drainLegacyOverrides`). |
| `settings.json` | v3 | User preferences — global (`general`, `notifications`, `developer`) plus per-Project (`projects[ProjectID]: ProjectSettings`). v3 renamed `repositories` → `projects` and widened the value type to `ProjectSettings` with an optional `git: GitProjectSettings?` subtree for `git_repo`-kind overrides. |
| `hooks.json` | v2 | User-configured hook subscriptions (event → shell command + options). v2 added `.projectID` / `.projectPathGlob` scope cases and made Scope decoding fail-soft on unknown kinds. |

Writers always go through atomic-rename JSON persistence:
1. Encode to temp file in the same directory
2. `fsync` temp file
3. `rename(2)` over original

Readers abort or migrate on version mismatch: `settings.json` accepts v1/v2/v3 (migrating v1/v2 to v3 in place with a backup); `catalog.json` accepts v1/v2; `hooks.json` accepts v1/v2. Unknown `version` values route the file aside as `*.broken-<ts>` and start from defaults.

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
- `apps/cli` logs to stderr only; `--verbose` flag controls level
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
- `scripts/build-ghostty.sh` runs Zig to build `GhosttyKit.xcframework` from the submodule; uses fingerprint-based caching (git HEAD + local diff + mise.toml hash)
- Top-level `Makefile` orchestrates: `make bootstrap` (submodules + mise), `make build-ghostty`, `make generate` (Tuist), `make build`, `make test`

## Technology Choices

| Technology | Scope | Purpose | Rationale |
|---|---|---|---|
| Swift 6 | all | Language | Native macOS; libghostty has first-class Swift/C interop via GhosttyKit; aligns with both reference projects |
| Tuist 4 | workspace | Project + target generation | Modular Xcode workspace; cacheable builds via `warm-cache`; internal targets (`apps/*`, `packages/*`) declared in `Project.swift`. Same pattern as supacode/supaterm |
| SPM (via Tuist `Package.swift`) | workspace | External dependencies | Standard tool for fetching third-party libraries (TCA, ArgumentParser, Sparkle); integrated into Tuist |
| mise | workspace | Tool version pinning | Committed `mise.toml` pins `tuist`, `zig`, `swiftlint`, `xcbeautify`; guarantees reproducible first-clone builds |
| libghostty (via `ThirdParty/ghostty` submodule → Zig → `GhosttyKit.xcframework`) | `codans/Runtime (in-app module)` | Terminal emulator | Best macOS-native terminal renderer with a stable C API; building from submodule (not prebuilt XCFramework) matches supacode/supaterm and lets us patch Ghostty if needed |
| The Composable Architecture | `apps/mac` | App/UI state | Testable unidirectional flows for features (Settings, CommandPalette, GitViewer); proven in both reference projects |
| Swift Observation (`@Observable`) | `codans/Runtime (in-app module)`, parts of `apps/mac` | Runtime state | Hybrid complement to TCA for high-frequency terminal state; native Swift 6 feature; proven in supacode |
| ArgumentParser | `apps/cli` | CLI parsing | Apple's official CLI framework; same as both reference projects |
| Sparkle | `apps/mac` | Auto-update | De facto standard for macOS app updates; same as supacode |
| SwiftLint + swift-format | workspace | Lint + format | Style consistency; enforced in CI; configured via `.swiftlint.yml` and `.swift-format.json` |

## Entry Points

| Surface | File | Responsibility |
|---|---|---|
| App launch | `apps/mac/codans/App/CodansApp.swift` | `@main`, root TCA store construction, window lifecycle |
| CLI launch | `apps/mac/codans/main.swift` | `ArgumentParser` root; dispatches to subcommand |
| Socket server | `apps/mac/codans/App/Features/Socket/SocketServer.swift` | Accepts Unix socket connections, routes JSON-RPC to IPC methods |
| libghostty bootstrap | `apps/mac/codans/Runtime/GhosttyRuntime.swift` | Initializes `ghostty_app_t`, registers callbacks |
| Hook dispatcher | `apps/mac/codans/Hooks/HookDispatcher.swift` | Fan-out of lifecycle events to configured handlers |
| Deeplink handler | `apps/mac/codans/App/Features/Deeplink/DeeplinkRouter.swift` | Receives `codans://` URLs, converts to IPC-equivalent actions |
| Persistence boundary | `apps/mac/CodansCore/Persistence.swift` | Atomic-rename JSON read/write with version checks |

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
  - Reference layout for our `codans-skill/`: `SKILL.md` + `references/` + `agents/`

### External references

- matklad, *ARCHITECTURE.md* — <https://matklad.github.io/2021/02/06/ARCHITECTURE.md.html>
- The Composable Architecture — <https://github.com/pointfreeco/swift-composable-architecture>
- Swift Observation — <https://developer.apple.com/documentation/observation>
- Ghostty — <https://ghostty.org>
- mise — <https://mise.jdx.dev>
- Tuist — <https://tuist.dev>

## Open Architectural Questions

1. **Internal Tuist target granularity in `apps/mac`.** Split each Feature into its own framework target (supacode pattern — slower clean build, better cache) vs. single app target with folder-level organization. **Blocks:** initial Tuist configuration. *Leaning:* separate framework targets for heavy features (Terminal, Hierarchy, GitViewer); single target for the rest.

2. **Multi-window semantics.** *Resolved by docs/design-docs/project-tags.md (M3):* the app is single main window. The prior `WindowGroup` allowed multiple instances but was never wired into application state. M3 collapses the scene to `Window(id: "main")`, suppresses the default ⌘N "New Window" command, and gates ⌘Q with a confirmation alert when running terminal sessions exist. Settings is a separate `Window(id: "settings")`, unchanged. If multi-window demand emerges later it would re-introduce a `windows: [CatalogWindow]` array on `Catalog`.

3. **CLI binary distribution.** *Resolved by exec-plan 0003 (C4 D2):* manual `codans install-cli` — the app copies the bundled `codans` binary into `~/.local/bin/codans` (creating the directory + offering a shell-rc PATH update if needed), collision-checks against an existing `codans` on `$PATH`, and aborts without writing when one is found. See [C4 design doc §D2](design-docs/c4-cli.md). *No system-path writes.*

4. **Hook handler execution policy.** Serial per event vs. concurrent with a cap. **Blocks:** `codans/Hooks (in-app module)` scheduler. *Leaning:* concurrent with a global cap (default 8); single-handler-at-a-time flag per hook subscription as opt-in.

5. **IPC backpressure.** *Resolved by exec-plan 0003 (DEC-9):* per-connection bounded queue, **64 in-flight**, 2-second overflow wait before the server returns `IPCError.overloaded` (CLI exit 5). Global queue rejected — slow clients would starve healthy ones. See [exec-plan 0003 DEC-9](exec-plans/0003-hooks-and-cli.md). Implementation of the actual queue deferred to M3.1 (the wire surface already returns `.overloaded` when it lands).

6. **Runtime crash recovery.** A single Pane's libghostty surface crashes — should Runtime restart just the Pane, surface the crash to the user, or tear down the whole Tab? *Leaning:* per-Pane restart with a user-visible placeholder showing the error; 3 crashes in 30s escalates to Tab tear-down.

7. **Worktree storage layout defaults.** Where do new worktrees live? Per product-spec Q6. **Blocks:** `apps/mac/Features/Hierarchy` Worktree creator. *Leaning:* sibling `<repo>-worktrees/<branch>/` by default, per-Project override.
