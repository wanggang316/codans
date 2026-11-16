# Architecture

This page shows how the system is put together: the modules, the direction of their dependencies, and the rules that span more than one module. The behavior of one area is on its page under [domains/](domains/). What the product is and for whom: [product.md](product.md). Terms: [glossary.md](glossary.md).

## Overview

codans is a native macOS app that organizes terminals in a four-level hierarchy: Project → Worktree → Tab → Pane. Tags classify Projects across the hierarchy. The repository is one Tuist-managed monorepo that ships three artifacts with one version:

- **The Mac app** (`Codans.app`): the GUI, the owner of all app state, and the IPC server.
- **The `codans` CLI**: a thin RPC client of the running app, embedded in the app bundle.
- **The Agent Skills** (`skills/`): text that teaches agents to drive codans through the CLI.

```
  shell / agent in a Pane                         Codans.app
  -----------------------                         ----------
  codans <verb> ---- JSON-RPC, Unix socket ---->  Socket handlers
                                                     |
                                                     v
                                     MainActor owners of app state
                                     (HierarchyManager, TerminalEngine, stores)
                                       |            |              |
                     libghostty (in-process)   CommandRunner     store files
                     renders surfaces, PTYs        |             ~/.codans[-dev]/{config,state}
                       |                           |             ~/Library/Caches/codans[-dev]
                       v                           v
                     zmx session daemon      git, wt, gh, glab, ssh
                     (one per Pane, socket in ~/.codans[-dev]/run)
```

A Pane is a libghostty surface whose shell runs inside a zmx daemon. The daemon outlives the app, so a relaunch attaches to the same session. The app is the only process that changes the catalog; the CLI and the GUI are two clients of the same owners.

## Modules

Tuist targets under `apps/mac/` (declared in `apps/mac/Project.swift`):

| Target | Kind | Responsibility |
|---|---|---|
| `CodansCore` | static framework | Domain model (catalog, Project, Worktree, Tab, Pane, Tag, `SplitTree`, IDs), settings model, channel and paths, store primitives and the stores that both sides or tests need, workflow and agent parsing. Depends only on `Yams`. |
| `CodansIPC` | static framework | The JSON-RPC wire protocol: envelopes, framing, the `IPC.Method` table, wire types. |
| `CodansKit` | static framework | The client side of the CLI: socket discovery, `RPCClient`, alias resolution, rendering, exit codes, the skill installer. |
| `codans-cli` | command-line tool | The `codans` binary (`codans-dev` in Debug): one ArgumentParser command tree. |
| `GhosttyKit` | foreign build | `GhosttyKit.xcframework`, built from the libghostty submodule. |
| `Codans` | app | The Mac app. One target, with the in-app folders below. |

The test targets (`CodansCoreTests`, `CodansKitTests`, `CodansTests`) sit beside them. External packages are pinned in `apps/mac/Tuist/Package.swift`: The Composable Architecture, ArgumentParser, Sparkle, Sentry, Yams, `DiffViewKit` (the diff renderer, an independent package), and SnapshotTesting for tests.

Folders of the app target (`apps/mac/codans/`):

| Folder | Responsibility |
|---|---|
| `App/` | Entry point, SwiftUI scenes and views, TCA features (`App/Features/<Feature>/`), the `*Client` dependencies that bridge features to services, the socket server and its handlers. |
| `Runtime/` | The owners of live state: `HierarchyManager` (the catalog) and `TerminalEngine` (surfaces and Pane lifecycle), the libghostty and zmx integration, session lifecycle, and the watchers and monitors of Worktrees. |
| `Process/` | `CommandRunner`, the one subprocess primitive (timeouts, kill ladder, pipe draining, launch modes), and command execution on a Host over `ssh`. |
| `Git/` | Git reads and writes for local and remote Worktrees, through `CommandRunner`. |
| `GitPlatform/` | The provider-neutral Git Platform service and its `gh` and `glab` implementations. See [Git Platform](domains/git-platform.md). |

Repository root: `apps/website/` is the codans.dev site (Astro), not coupled to the app. `skills/` holds the published Agent Skills, which the app bundle embeds; see [CLI](domains/cli.md). `workflows/` holds the built-in workflow definitions, which the app bundle embeds as the lowest-precedence scope; see [Workflow](domains/workflow.md).

## Dependency direction

```
 codans-cli ---> CodansKit ---> CodansIPC ---> CodansCore ---> Yams
     |                              ^              ^
     +------------------------------+--------------+
                                    |              |
 Codans (app) ---> CodansKit, CodansIPC, CodansCore, GhosttyKit,
                   codans-cli (embedded), TCA, DiffViewKit, Sparkle, Sentry

 inside the app:   App ---> Runtime ---> Git ---------> Process
                    |                                   ^
                    +-------------> GitPlatform --------+
   (App also calls Git and Process directly; every folder uses CodansCore)
```

Rules between targets (enforced by the target edges in `Project.swift`):

- `CodansCore` imports no internal target. It is the shared leaf.
- `codans-cli` depends only on `CodansKit`, `CodansIPC`, `CodansCore`, and ArgumentParser. It cannot see app code, because the app folders compile into the app target only.
- The app and the CLI exchange data only through `CodansIPC` over the socket. They share no state and no files. The CLI keeps no state of its own; its only file work is local (`codans skill` links).

Rules inside the app (one compile unit, so folder convention and review enforce them):

- `Runtime/`, `Git/`, `GitPlatform/`, and `Process/` define no reducer and hold no TCA state. Features in `App/` reach them through `*Client` dependencies (`TerminalClient`, `HierarchyClient`, `GitServiceClient`, `GitPlatformClient`). Some services in `Runtime/` and `Git/` (the Worktree watchers, `ProjectReconciler`, `GitWorktreeClient`) conform to TCA's `DependencyKey` so that reducers can inject them; that is the only use of TCA there.
- `GitPlatform/` depends only on `Process/` and `CodansCore`. Only `App/Clients/GitPlatformClient.swift` selects an implementation by kind.
- `Process/` knows no feature. It is the only place that starts a `Process`.

Known references against the direction: `AgentBinder` and `ProjectReconciler` in `Runtime/` hold a `HierarchyClient`; two Worktree monitors build `GitServiceClient.live()`; `HierarchyManager` reads `SocketPaths`; small UI helpers from `App/` are called from `Runtime/Ghostty/`; `Git/` uses `RemoteSkillReader` from `App/Clients/`; `RemoteGitService` in `Process/` returns `Git/` value types.

## Cross-module invariants

- **One owner of the catalog.** `HierarchyManager` (MainActor, `@Observable`) is the only code that changes the Project → Worktree → Tab → Pane tree, the Tags, and the Host list. GUI features and socket handlers call it; neither keeps a copy that it writes back. Because both paths go through the same MainActor owners, the GUI and the CLI cannot disagree, and two CLI calls that change the same thing apply in arrival order. See [CLI](domains/cli.md).
- **One writer per store file.** Each file on disk has one owning type in the app process. Two writers of one file erase each other's keys ([Settings › One writer](domains/settings.md#one-writer)). A feature that needs its own data gets its own file.
- **Subprocesses go through `CommandRunner`.** No feature module starts a `Process` directly. The runner gives every call a timeout, a process-group kill, and a launch mode ([Environment › Background command launch](domains/environment.md#background-command-launch)). Terminals are not subprocesses: libghostty starts the Pane shell.
- **IDs are UUIDs.** Every Project, Worktree, Tab, Pane, and Tag has a stable UUID. Short handles and indexes are CLI sugar, resolved to UUIDs before any change ([CLI › Addressing targets](domains/cli.md#addressing-targets)).
- **Split layout holds IDs, not surfaces.** A Tab's `SplitTree<PaneID>` is a value type keyed by Pane ID. Views resolve each leaf to its live surface at render time. This keeps the layout savable and its operations pure. The leaf IDs of a Tab equal the IDs of its Panes.
- **State management is split by frequency.** TCA owns app flow and feature state (`RootFeature` and the features under `App/Features/`). Swift Observation owns high-frequency and shared live state: `HierarchyManager`, `TerminalEngine`, `AgentStateStore`, `SettingsStore`. Terminal output does not pass through a reducer. A `*Client` turns runtime events into an `AsyncStream` that a reducer subscribes to, and turns reducer intents into calls on the owner.
- **MainActor by default.** The app target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`; `CodansCore`, `CodansIPC`, `CodansKit`, the CLI, and the test targets use `nonisolated`. In the app, an un-annotated class is MainActor. A closure that a `DispatchSource`, FSEvents, a libghostty callback, or a pipe reader calls on another thread traps at run time, with no compile warning, unless its type or function is `nonisolated`. An `@Observable` class held in `@State` needs an explicit `deinit`, because the synthesized isolated `deinit` can crash.
- **The Agent Skill is text.** The app never loads or runs an Agent Skill. It reads skill frontmatter only to offer completions ([Agent Skill completion](domains/agent-skill-completion.md)).

## Persistence

Each build channel has its own roots ([Environment › Build channel](domains/environment.md#build-channel)). Release paths:

| File | Root | Owner | Page |
|---|---|---|---|
| `settings.json` | config `~/.codans/config/` | `SettingsStore` | [Settings](domains/settings.md) |
| `shortcuts.json` | config | `ShortcutsStore` | [Keyboard shortcuts](domains/keyboard-shortcuts.md) |
| `catalog.json` | state `~/.codans/state/` | `HierarchyManager` through `CatalogStore` | this section |
| `remote-hosts.json` | state | `RemoteHostSidecar` (repair copy of Remote Project connections) | [Remote Projects](domains/remote-projects.md) |
| `sessions.json` | state | `SessionStore` (exclusive lock on `sessions.json.lock`) | [Terminal runtime](domains/terminal-runtime.md#session-lifecycle) |
| `notifications.json` | state | `NotificationStore` | [Notifications](domains/notifications.md) |
| `github-snapshots.json` | cache `~/Library/Caches/codans/` | `PullRequestSnapshotCache` | [Git Platform](domains/git-platform.md) |
| zmx sockets, snapshots, logs | runtime `~/.codans/run/` | zmx daemons, `SessionLifecycle` | [Terminal runtime](domains/terminal-runtime.md) |
| `.codans/workspace.json`, `workspace-groups.json` | Workspace directory | `WorkspaceClient` | [Workspace](domains/workspace.md) |
| `.codans/workflow-runs/` | Worktree | `WorkflowRunStore` | [Workflow](domains/workflow.md) |

Rules for every store:

- **Atomic write.** `AtomicFileStore` writes a temp file beside the target, `fsync`s it, and renames it over the target. A symlinked file is written at the end of the link chain. At launch, `PersistenceLaunch` deletes temp files that a crash left behind. JSON is pretty-printed with sorted keys.
- **A version field.** Each file has a top-level version (`version`, `schemaVersion` in the Workspace manifests, or the `{ version, entries }` envelope of `VersionedFile`). The store, not `AtomicFileStore`, checks it and migrates.
- **Never overwrite a file this build cannot read.** A corrupt file, a file of a version this build does not support, and the original of a migration go to `<root>/backups/<stem>.<reason>-<UTC timestamp>.json` through `StoreBackup` (reason `corrupt`, `unsupported-v<N>`, or `migrated-v<N>`; the newest five per reason are kept). The store then starts empty. If the move fails, the store does not save for the rest of the session.
- **The catalog keeps a newer file in place.** A `catalog.json` from a newer build stays byte-identical, a copy goes to `backups/`, the app starts with an empty catalog, saving is off, and the user sees an alert. An older catalog (v3, v4) is migrated in memory, the original is copied to `backups/`, and the result is saved at once.
- **Older builds drop unknown keys.** A build decodes leniently and writes the whole file again, so an older build that shares the roots removes fields it does not know. Sidecars (`remote-hosts.json`, the Workspace manifests) let a newer build repair such a catalog at load.
- **No file watch.** The catalog, settings, shortcuts, and notifications stores save after a short debounce and flush at quit. No store watches its file. A hand edit while the app runs is lost at the next save. Quit the app first.

Catalog content rules belong to the domains that use the fields: Project order ([ADR 0001](adrs/0001-project-order-is-manual-only.md)), Hosts ([ADR 0003](adrs/0003-hosts-are-managed-records.md), [Remote Projects](domains/remote-projects.md)), Workspace groups ([Workspace](domains/workspace.md)), Tags ([Project tags](domains/project-tags.md)), the command queue ([Command queue](domains/command-queue.md)).

## IPC

The CLI connects to a Unix socket that the app binds, one per app instance, and sends length-prefixed JSON-RPC frames. `CodansIPC` defines the method table and wire types for both sides; handlers under `App/Features/Socket/` convert wire types and errors and call the MainActor owners. Socket paths per channel and their resolution: [Environment › Socket resolution](domains/environment.md#socket-resolution). Transport, handshake, addressing, and the exit-code contract: [CLI](domains/cli.md).

The app registers no URL scheme and has no `onOpenURL`. The `codans://focus?…` link exists only in the payload of the app's own notification banners, and the notification delegate parses it ([Notifications › Authorization and banners](domains/notifications.md#authorization-and-banners)).

Session lifecycle (attach, quit snapshot, restore, reaping): [Terminal runtime › Session lifecycle](domains/terminal-runtime.md#session-lifecycle).

## Build and toolchain

[AGENTS.md › Quick Start](../AGENTS.md#quick-start) gives the commands. The invariants behind them:

- **Swift 6 language mode** everywhere, so strict concurrency checking is on. Default actor isolation is per target (see the invariant above).
- **Generated project.** `Project.swift` and `Tuist/Package.swift` are the source; do not edit the generated `.xcodeproj` or `.xcworkspace`. `Package.resolved` is committed, and some packages are pinned exactly, because a floated transitive version has broken the release archive.
- **Vendored native builds.** libghostty (`ThirdParty/ghostty`) and zmx (`ThirdParty/zmx`) are submodules of forks, built with the zig version that `mise.toml` pins. `build-ghostty.sh` and `build-zmx.sh` cache their output under `apps/mac/.build/` with a fingerprint of the submodule state, the script, the Xcode compatibility layer, and `mise.toml`; an unchanged fingerprint skips the build. On Xcode 26.4 and later, both scripts point zig at an adjusted view of the SDK ([Zig builds broke on Xcode 26.4 and later](lessons-learned/2026-09-17-zig-builds-broke-on-xcode-26-4-and-later.md)).
- **Static libghostty.** The app links C++, Carbon, Metal, MetalKit, CoreText, and QuartzCore for the static libghostty. `ghostty_init` must be the first libghostty call of the process; `GhosttyBootstrap` makes sure of it.
- **Bundle contents.** Build phases embed the CLI, `zmx`, the bundled `wt` (from the `git-wt` submodule), the Ghostty resources, the skills, and the workflows into `Codans.app/Contents/Resources/`. A new zmx binary must replace the old file, not overwrite it in place: macOS kills a process whose signed executable changed under it.
- **CI floor.** Pull requests build on Xcode 26.0, the lowest supported version, which rejects some code that a newer local Xcode accepts.

## Technology choices

| Choice | Reason |
|---|---|
| libghostty, built from a fork submodule | A native renderer with a C API; the fork carries patches that codans needs. |
| zmx session daemons | Pane sessions outlive the app, so a relaunch or update keeps running shells and agents. |
| Hybrid TCA and `@Observable` | Testable feature flows, without a reducer pass for each terminal event. |
| JSON-RPC over a Unix socket | One local, same-user transport that scripts and agents can call from any shell. |
| `gh` and `glab` subprocesses, no HTTP | The CLIs own authentication; codans stores no token ([ADR 0004](adrs/0004-gitlab-support-through-glab.md)). |
| Tuist monorepo | App, CLI, and skills change together in one commit and ship with one version. |

## Entry points

- **App launch:** `apps/mac/codans/App/CodansApp.swift`: scenes, the root store, the store bootstrap, and the notification delegate.
- **CLI:** `apps/mac/codans-cli/CodansCLI.swift`: the ArgumentParser root.
- **Socket server:** `apps/mac/codans/App/Features/Socket/`: the server, `MethodRouter`, and the handlers per namespace.
- **libghostty bootstrap:** `apps/mac/codans/Runtime/Ghostty/GhosttyBootstrap.swift` and `GhosttyRuntime.swift`.
- **Catalog owner:** `apps/mac/codans/Runtime/HierarchyManager.swift`.
- **Persistence primitives:** `apps/mac/CodansCore/AtomicFileStore.swift` and `apps/mac/CodansCore/Persistence/`.
