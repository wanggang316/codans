# Terminal runtime

The terminal runtime makes a Pane a live terminal. It starts and keeps the shell process, draws the terminal with libghostty, turns libghostty events into app events, samples what runs in each Pane, and decides what happens to the shells when the app quits and starts again. The main design choice is that the shell does not belong to the window: a per-Pane zmx daemon owns it, so the app can close, reclaim, or lose a terminal view while the work in the Pane continues.

## Scope and ownership

This page owns the runtime model of a Pane, the routing of libghostty actions, surface reclaim, foreground process sampling and the process registry, the session lifecycle on quit and launch, and the behavior when a Pane cannot start.

Neighbor topics:

- How the Pane shell starts, and the command wrapper: [Pane shell integration](pane-shell-integration.md).
- The Pane environment and the runtime root (`ZMX_DIR`): [Environment](environment.md).
- Agent identification and agent state, which consume the samples of this page: [Agent state](agent-state.md).
- Notifications from bells, OSC 9, and desktop notifications: [Notifications](notifications.md).
- Themes and the Ghostty config: [Appearance](appearance.md).
- Panes of a Remote Project: [Remote projects](remote-projects.md).
- What the tab hover card shows: [Main window](main-window.md).

## Three parts of a Pane

A Pane at runtime is three things with different lifetimes:

```
 Pane row (catalog.json)       saved; lives until the Pane is closed or removed
   |  PaneID = zmx session name = socket file name
   v
 zmx daemon  <ZMX_DIR>/<PaneID>   owns the PTY and the shell; setsid, so it
   ^                              outlives the app, a crash, and a force quit
   |  `zmx attach <PaneID>` (a client process, forked by libghostty)
   |
 libghostty surface (PaneSurface)  memory only; Metal buffers + 4 threads;
                                   created lazily when the Pane is first shown
```

- **The row** is the identity. Its `PaneID` names the zmx session and the socket, so the app finds the daemon again from the catalog alone.
- **The daemon** is the session. Closing the surface ends only the `zmx attach` client. The daemon reads that as a detach and keeps the shell.
- **The surface** is a view of the session. `zmx attach` is an upsert: it attaches to a daemon that runs, or creates a new one. A cold start, a re-attach after reclaim, a resume after relaunch, and a restore from a snapshot all use this one invocation. A restore only adds `--restore-from <file>`. There is no second spawn path.

`TerminalEngine.terminalState(for:)` names the three runtime states of a Pane:

| State | Surface | Daemon | Example |
|---|---|---|---|
| `attached` | yes | yes | A Pane that is or was on screen. |
| `detached` ("asleep") | no | yes | A restored Pane not shown yet, or a reclaimed Pane. |
| `stopped` | no | no | The daemon exited while no surface watched it. Opening the Pane starts a new session. |

A detached Pane is not observed through the screen. A passive zmx watcher reads its title, desktop notifications, and OSC 7501 program status, so agent state stays current. When the daemon exits, the watcher reports it, the engine drops the per-session state, and the agent row goes away. The watcher stops before a surface attaches, so a signal is never delivered twice. A signal written between the stop and the attach reaches neither; the next report of the agent corrects it.

Rules:

- A surface does not own the session. Only deliberate destruction kills a daemon: closing the Pane, closing its Tab or Worktree, archiving its Worktree, or removing it. Archive kills the daemon also when the Pane has no surface.
- A re-attach never replays `initialCommand` and does not emit `paneCreated` or `paneReady`. The Pane did not stop to exist, and the text would go into a running program as typed input.
- Per-session state in the engine (program status records, foreground snapshot, process entry) is keyed by Pane, not by surface, so it survives reclaim and re-attach.
- Each SwiftUI host gets its own container view and re-parents the shared surface view into it. Do not give the registry's view to SwiftUI directly. See [Pane blank after closing its split sibling](../lessons-learned/2026-08-15-pane-blank-after-closing-its-split-sibling.md).

## libghostty actions

libghostty draws and reads keys by itself. Everything that needs the host to act (a key binding, a title change, a bell, a URL click, a config reload) arrives through one C callback, `action_cb`. An action that the host does not consume is a silent no-op for the user, so the runtime routes every action that has a meaning in codans, not a subset.

The callback works in two passes:

1. **Decode, synchronously, on the calling thread.** libghostty can call from any thread, and the C pointers in the action are freed when the callback returns. `GhosttyActionDecoder` copies every pointer field into a `Sendable` Swift value (a config change clones the config), and reads the `PaneID` from the surface userdata. The callback returns `consumed` at once: `false` only for an unsupported action.
2. **Apply on the main actor.** The decoded value goes to the main queue and is applied by its kind.

| Kind | Examples | Where it goes |
|---|---|---|
| Info | title, pwd, mouse shape, search, progress, OSC 7501 | Written on the surface's `SurfaceInfo` (memory only); a `paneInfoChanged` event when a field changes. No reducer. |
| Effect | open URL, desktop notification, bell, undo, copy title | The runtime does the side effect and emits an event. |
| Intent | new tab, split, close, goto, window, quit | Emitted as `paneActionRequested` or `windowActionRequested`. |
| Config | config change, reload | Applied by `GhosttyRuntime` to the config it owns. |
| Unsupported | inspector, render, unknown tags | Logged; the callback returns `false`. |

Rules:

- `GhosttyActionDecoder` is the only module that knows the libghostty action tags and union. Ghostty C types do not go into `CodansCore`.
- The terminal runtime does not use TCA. It exposes `@Observable` objects and the `TerminalEvent` stream (see [Architecture](../architecture.md)). Intents carry no policy: `PaneActionRouterFeature` and `WindowActionRouterFeature` decide (is the Worktree archived, is a confirmation needed) and are the only consumers of their events. A quit intent goes through the quit flow, never through a direct `NSApp.terminate`.
- The `TerminalEvent` stream drops only output events under back pressure. Lifecycle events are never dropped.
- `PaneSurface` keeps the environment buffers it gives to `ghostty_surface_new` alive until the surface is freed, because libghostty does not copy them.
- `CODANS_DISABLE_ACTION_ROUTING=1` makes the callback consume nothing. It is a diagnostic switch.

## Surface reclaim

Each live surface holds window-sized Metal buffers and four threads, and hiding it frees nothing. Memory grows with the number of Panes the user has looked at, not with the number in use. Reclaim closes the surface of a Pane that stays hidden and keeps its daemon. The Pane becomes detached. When it is shown again, its host calls `ensureSurface` and the Pane re-attaches; the user sees the same session, with the screen replayed by zmx.

The engine sweeps on a timer and on each system memory-pressure event. `SurfaceReclaimPolicy` decides, as a pure function. A Pane is reclaimed only when all of these are true:

- It is in the catalog, local (a remote surface holds an ssh tunnel), and its surface is ready.
- It is not in a window. An occluded or minimized window still counts as in a window.
- The foreground is a shell prompt or an agent, not a running command. An unknown foreground blocks reclaim.
- No veto from the app layer: the Pane has no queued command (commands go out only through a surface), and its agent is not mid-turn with a state that only the screen tracks. An agent that reports OSC 7501 does not need the screen.
- Timer sweep only: hidden for 20 minutes, screen unchanged for 60 seconds, and not in the selected Tab of one of the three most recently selected Worktrees. A memory-pressure sweep skips these three conditions.

Settings › General › Memory › "Release terminal views of hidden panes" turns reclaim off. The sweep reads the setting each time, so a change applies at once.

A re-attach starts at the size of the slot that will show the Pane, or else at the size the surface had when reclaimed. A placeholder size would resize a running TUI to a narrow width first. Programs that subscribe to color-scheme reports (mode 2031) get the current appearance again when zmx replays the terminal state.

Costs of reclaim: while detached, the screen is not read, so screen-derived agent state stays at its last value; a reclaimed Pane is not counted in the "running processes" count of a forced Worktree removal; queued commands wait until the Pane is shown.

## Foreground process sampling

The engine samples the foreground process group of each attached local Pane's terminal. One poll covers all of them: every 300 ms while any of them has an agent, 500 ms while any runs a command, and 2 s otherwise. Remote Panes are sampled on the Host, because their local foreground is always `ssh`. Both feed one pipeline: agent binding, the busy state of Tabs and Worktrees, the reclaim policy, and the process registry. A reclaimed Pane keeps its last sample and its process entry, so its observers see no false unbind.

`WorktreeProcessRegistry` (on `HierarchyManager`) keeps at most one entry for each Pane: its live foreground task. It is session state and is not saved. After a restart, entries come only from new samples. Availability: the tab hover card shows one entry for its Tab (the focused Pane's, or else the oldest). Hidden: the per-Worktree list.

- An entry exists only while a sample shows an agent or a command that is not a shell. A launch record alone never makes an entry. An agent that waits for input stays an entry.
- A command the user types and a launch from the app use the same sampling path.
- PID and start time identify the entry. If one changes, it is a new entry.
- The name is, in order: the name of a valid launch record (from a Run script or an agent launch of the app), the agent display name, the process name. The icon is the agent mark, or the tool mark of the executable, or the terminal symbol. A Run script name never selects the icon.
- A launch record is invalid when the Pane's process is replaced, when the launch went to a busy Pane and the sampled process started before the request, or when 15 seconds pass with no entry.

| Sample | Effect |
|---|---|
| Pane not in the catalog, or its Worktree archived | Entry removed. |
| Only a shell | Entry removed at once. |
| Local sample empty | Ignored; the third empty sample in a row removes the entry. |
| Remote probe failed | Entry hidden; it comes back only if a sample in 30 seconds shows the same process. |

## Session lifecycle

Settings › General has two quit settings. "Confirm before quitting" is `Auto` (ask only when a Pane runs a command or an agent is mid-task), `Always`, or `Never`. "On quit" is the action to apply, and the default button of the dialog:

- **Keep session running.** Daemons keep running. The next launch attaches each Pane to its daemon when the Pane is shown.
- **Snapshot and exit.** Each live surface's daemon writes `<ZMX_DIR>/snapshots/<PaneID>.snap` and exits. A daemon that does not answer in time is killed. The next launch starts each such Pane in a new shell, seeded with the saved screen, in the Pane's working directory.

> **Discrepancy:** "Snapshot and exit" is expected to end every Pane daemon (`QuitAction.snapshot`, the dialog text). It acts only on Panes with a live surface. Detached Panes keep their daemons, and they resume live on the next launch (`SessionLifecycle.detachAllForQuit`).

Quit is bounded: the app answers `terminateLater`, a watchdog ends the wait after 20 seconds, and a second ⌘Q during the wait does nothing. The quit pass of both actions writes `sessions.json` with no sessions and with the agent records, which seed agent state on the next launch. With no attached Pane and no dialog, the app quits at once and runs no quit pass.

At launch, before any surface exists, `SessionReaper` does this:

1. Moves daemon sockets from an old `ZMX_DIR` into the current one (a bound socket stays reachable after `rename`).
2. Probes each row in `sessions.json` and kills the daemon when it is stale (7 days without attach), stranded (started in a login session that is no longer current), or orphaned (no Pane in the catalog). Dead rows are pruned.
3. Turns each `.snap` file with no live daemon into a pending restore. A live daemon wins, and its snapshot is deleted. Restore depends on the file, not on the current setting.
4. After launch, kills each socket in `ZMX_DIR` that has neither a row nor a Pane, and deletes snapshots that no Pane claims.

The engine writes a row to `sessions.json` each time a surface comes up, with the login session it was born in. A re-attach keeps the birth session, so a daemon stranded by a session change is recycled and not re-stamped. See [Pane stranded after WindowServer restart](../lessons-learned/2026-06-22-pane-stranded-after-windowserver-restart.md).

A second instance that cannot lock `sessions.json` runs in no-resume mode: no reaper, no watchers of detached Panes, no quit pass.

Settings › General › "Forget all sessions…" kills each daemon recorded in `sessions.json`, removes its socket, and empties the file.

## A Pane that fails to start

`ensureSurface` fails when the zmx binary is missing from the bundle, when the Pane is not in a Tab, or when `ghostty_surface_new` fails. A surface init failure that libghostty marks retryable is tried once more after one tick of the runtime. If it still fails, the Pane shows "Pane Failed to Start" with the reason, the raw error (selectable), and a Retry button. Nothing retries without the user. The Pane stays in the catalog, and a passive watcher that was running comes back.

## Traps

- **The socket path is the only way to the daemon.** If its file is deleted, the daemon runs on but no one can reach it, and the next attach creates a new session. Keep `ZMX_DIR` out of cache directories. See [Cache cleaner wiped zmx sockets](../lessons-learned/2026-10-20-cache-cleaner-wiped-zmx-sockets.md).
- **A clean quit empties the session list.** The stale, stranded, and orphan checks of step 2 act only on rows written after the last clean quit, for example after a crash. Step 4 still finds daemons with no Pane.
- **libghostty forks `zmx attach` inside `ghostty_surface_new`,** before any layout. The initial size must be right at that call.
- **A child exit does not close the surface,** because embedded libghostty waits after the command. Observe the `childExited` info change for "program finished", not the Pane exit event.
- **Counts that look at surfaces miss detached Panes.** `liveZmxClientCount`, `busyPaneCount`, and `runningPaneCount` count only attached Panes.

## Implementation shape

`Runtime/TerminalEngine` owns the per-Pane runtime state: `ensureSurface`, close and suspend, the reclaim sweep, the detached-Pane watchers, foreground sampling, and the `TerminalEvent` stream. `Runtime/Ghostty/` holds the libghostty bridge: `GhosttyRuntime` (the surface registry and `action_cb`), `GhosttyActionDecoder`, `PaneSurface`, and the zmx clients (`ZmxAttachCommand`, `ZmxControlClient`, `ZmxPassiveWatcher`). `SessionLifecycle` runs the quit pass, `SessionReaper` the launch sweep, and `SessionCoordinator` in `CodansCore` holds `sessions.json`. The App layer mounts surfaces through `PaneHostFeature` and receives intents in the two router features. The zmx and ghostty submodules are not described here.
