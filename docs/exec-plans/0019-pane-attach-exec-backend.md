# ExecPlan: Move pane I/O to the exec backend via `zmx attach`

**Status:** Draft
**Author:** Gump
**Date:** 2026-06-01

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

A freshly opened Pane (new worktree, new tab, split) currently renders at the wrong column width for a beat and then "jumps" to the correct width — a visible reflow/jitter — and switching to a not-yet-resident worktree shows a loading placeholder followed by that same jolt. After this change, a Pane renders at its correct size from the first frame: no width mismatch, no post-load reflow. Resume (a Pane's shell surviving app quit and reconnecting on next launch) keeps working.

The change replaces how libghostty is wired to the per-Pane `zmx` daemon: instead of handing libghostty a raw socketpair as an external PTY (`external_pty_fd`) and letting the daemon's terminal *be* the rendered terminal, we run `zmx attach <session>` as the surface's `config.command` under libghostty's standard exec backend. libghostty then owns a correctly-sized local PTY (its mature sizing path spawns the child only once a real post-layout size is known), and `zmx attach` bridges that local PTY to the daemon for persistence.

## Progress

- [x] T0 — Unblock the build: deduplicate the `event.h` / `encoder.h` header basenames in the generated `GhosttyKit.xcframework` (`prepare_xcframework`); clean `make mac-build` → BUILD SUCCEEDED. (commit 4c44e874)
- [x] T0b — Double-pane fix lands on a green build; compiles end-to-end. (commit cabd5e97)
- [x] P1 — `ZmxControlClient` (transient control-socket `.info` / `.history` / `.kill`) + `ZmxAttachCommand` (the `zmx attach <session>` command builder). (commit 263ff3cb)
- [x] P2 — `PaneSurface` uses `config.command` + exec backend (drops `external_pty_fd`, the resize/attach handshake, and the `externalPtyResize` dispatch); sizing is libghostty's. `TerminalEngine.ensureSurface` + `MasterTerminalController` build the exec-backend surface; bringup is the single `zmx attach` invocation (cold/live both upsert — folds in P3). (commit 39c09826)
- [x] P4 — Out-of-band capabilities rewired off the live client: foreground-shell PID via `ZmxControlClient.info` (retrying probe in `PaneSurface`), `tc pane read` via `ZmxControlProbe`/`ZmxControlClient.history`, `pane.close` kill + quit-time kill via `ZmxControlClient.kill`; quit keeps daemons alive (resume) or kills them (resume off). (folded into 39c09826)
- [x] P5 — Removed the unused external-PTY path: deleted `ZmxClient`, trimmed `PaneDaemonBringup` to the canonical path helpers, dropped `TerminalEngine.pendingReattach/pendingRestore/seedReattachableSessions/dropPendingResumeState` and their launch-path wiring (`SessionReaper.sweep` still runs for orphan-daemon cleanup; its states are no longer consumed). Clean `make mac-build`. (commit 09f03977)
- [x] Tests — Test target compiles + the affected suites pass (`HierarchyManagerTests`, `HierarchyClientTests`, `HierarchyManagerOpenPaneEnvForwardTests`, `HierarchyManagerWorktreeMgmtTests`, `ZmxAttachCommandTests`). Threaded `await` through ~22 `openPane`/`splitPane` call sites + their fixture helpers; deleted `ZmxClientTests`; added `ZmxAttachCommandTests`; fixed a pre-existing canonical-path test that resumed running and tripped the per-project uniqueness guard. (commits 5e41c51b, a10cdef9)
- [ ] Behavioural verification (owner: Gump) — run the app: new pane / split / worktree-switch renders at correct width with no reflow; resume across `cmd-Q` reattaches; foreground/agent indicator still lights; `tc pane read` works.
- [ ] Follow-up — `QuitAction.snapshot` now means "kill daemons" (resume off); rename the case + its Settings label for clarity.

## Surprises & Discoveries

- The render reflow is not inherent to using `zmx` for resume. The root cause is the daemon forking the shell at a default `160x24` (its stdout is `/dev/null`, so `ioctl(TIOCGWINSZ)` falls back to the hardcoded default in `ThirdParty/zmx/src/ipc.zig` `getTerminalSize`), then resizing on the first client `.Init`. In the `external_pty_fd` model the daemon's terminal is the rendered terminal, so that default size is on screen until the post-layout resize lands. Evidence: `ThirdParty/zmx/src/main.zig` `spawnPty` reads `getTerminalSize(STDOUT_FILENO)`; the daemon child redirects FD 0/1/2 to `/dev/null` before `spawnPty`.
- The `f2851da7` ghostty fork emits two headers with the same basename (`Headers/ghostty/vt/key/event.h` and `Headers/ghostty/vt/mouse/event.h`). Xcode 26's `builtin-process-xcframework` errors with `The file "event.h" doesn't exist.` on duplicate header basenames. The older ghostty in the primary checkout has only `vt/key/event.h`, which is why that checkout builds. This blocks any clean build of this worktree, independent of the Swift changes.

## Decision Log

- **Resume model: daemon-survives + live re-attach only; drop the disk-snapshot tier.** The existing design (`docs/design-docs/pane-resume.md`) defines two quit-time tiers: keep daemons alive (live), or serialize each daemon's terminal to `<paneID>.snap`, kill it, and replay into a fresh shell on launch (snapshot). The attach model makes live re-attach trivial (re-exec `zmx attach <same-session>`; the daemon upserts). We deliberately retire the disk-snapshot tier: it has no equivalent in the attach command surface (`zmx attach` has no `--restore-from`; only `zmx serve` does), and keeping it would re-introduce a bringup-ordering step the rest of this change removes. Net user-visible effect: the "Resume panes on launch" setting becomes "keep the daemon alive across quit" (on) vs "kill the daemon on quit" (off, fresh next launch). What is lost: restoring visible scrollback into a fresh shell when the daemon is *not* kept alive. `pane-resume.md` must be updated to reflect this.
- **Out-of-band daemon operations use a transient control-socket client, not the persistent I/O path.** `zmx attach` owns the live byte stream. The app still needs to ask the daemon three things — the shell PID (for foreground/agent detection), the scrollback (for `tc pane read`), and "serialize/exit" (quit-time, only if we keep a serialize option) — so a slim `ZmxControlClient` opens a short-lived connection, sends one framed command, reads the reply, and closes. This reuses `ZmxIPC`/`ZmxFraming` and replaces the heavyweight socketpair-bridging `ZmxClient`.
- **Reverses a `pane-resume.md` decision.** That doc chose `external_pty_fd` to "eliminate the in-process fork path entirely." The attach model re-introduces an in-process child — but a thin `zmx attach` client, not the shell — in exchange for libghostty owning terminal sizing. The doc will be amended with this rationale.

- **`QuitAction.snapshot` reinterpreted as "kill daemons."** With the disk-snapshot tier gone, the two quit modes are "keep daemons alive" (resume on) and "kill daemons" (resume off). The existing `.snapshot` case now drives the kill path; the enum + its Settings label should be renamed for clarity (tracked as a follow-up) rather than churned mid-refactor.

- **P3 + P4 folded into the P2 commit.** Bringup collapsed to a single `zmx attach` invocation (no spawn/reattach/restore branching), so P3 had no standalone surface; the out-of-band rewiring (P4) had to land with P2 or the build would regress (foreground PID, `tc pane read`, kill all referenced the removed live client). The legacy path is left as dead code and removed in P5 so the functional switch and the deletion stay reviewable as separate commits.

## Outcomes & Retrospective

(To be filled at milestone completion)

## Context and Orientation

Related documents:
- Design doc: `docs/design-docs/pane-resume.md` (the current external-PTY resume design; will be amended by this plan)
- Architecture: `docs/architecture.md`

Key source files (current model):
- `apps/mac/touch-code/Runtime/Ghostty/PaneSurface.swift` — builds the libghostty surface with `config.external_pty_fd = zmxClient.externalBackendFD`; owns the first-resize→`attach`, steady-state→`resize` handshake (`handleExternalPtyResize`), and learns the daemon shell PID via `requestInfo().pid` (`daemonShellPID` / `childProcessID()`).
- `apps/mac/touch-code/Runtime/Ghostty/ZmxClient.swift` — heavyweight client: a `socketpair` (one end is `externalBackendFD` for libghostty, the other bridges to the daemon control socket via two `DispatchSource` read loops), plus the full binary protocol (`.init/.resize/.snapshot/.info/.history/.detach/.kill/.input/.output`). Most of this is deleted in P5.
- `apps/mac/touch-code/Runtime/Ghostty/PaneDaemonBringup.swift` — spawns `zmx serve <id> --cwd <path> [--restore-from <snap>]`, parses the socket path + PID from stdout, connects a `ZmxClient`. Three tiers: reattach / restore / cold spawn.
- `apps/mac/touch-code/Runtime/Ghostty/GhosttyActionDecoder.swift` — decodes `GHOSTTY_ACTION_EXTERNAL_PTY_RESIZE` to `pane.handleExternalPtyResize`. This path is removed in P2.
- `apps/mac/touch-code/Runtime/SessionLifecycle.swift` — quit-time iterates live `ZmxClient`s and calls `snapshot()` (the disk-snapshot tier). Reworked in P4.
- `apps/mac/touch-code/Runtime/SessionReaper.swift` — launch-time scan that seeds reattach/restore tiers into the engine.
- `apps/mac/touch-code/Runtime/ForegroundJobReader.swift` — `foregroundProcessGroupID(childPID:)` reads `proc_pidinfo(PROC_PIDTBSDINFO).e_tpgid` from a PID. **Note: it needs only the shell PID, not a PTY fd** — so it keeps working as long as we can obtain the daemon's shell PID via `.info`.
- `apps/mac/touch-code/App/Features/Socket/handlers/HierarchyHandlers.swift` — `pane.read` wraps `ZmxClient.readHistory(format:)`.
- `apps/mac/touch-code/Runtime/TerminalEngine.swift` — `ensureSurface` picks the bringup tier and registers the surface; line ~660 threads `childPID:` into foreground-job polling.
- `apps/mac/ThirdParty/zmx/` — the daemon. `attach` (alias `a`), `serve`, `history` (`hi`), `kill` (`k`), `list` (`l`) subcommands exist; there is **no `info` subcommand** (so PID must come over the control socket), and `--restore-from` exists only on `serve`.

Orientation: today libghostty is a pure renderer over the daemon's PTY (External backend). We are turning libghostty back into a normal terminal whose child happens to be `zmx attach`, which forwards bytes to/from the daemon. The persistent Swift↔daemon socket goes away for I/O; a transient one remains for queries.

## Plan of Work

### T0 — Unblock the build (prerequisite)

`make mac-build` fails at `ProcessXCFramework` on `apps/mac/.build/ghostty/GhosttyKit.xcframework` with `The file "event.h" doesn't exist.` because the framework's `Headers` tree contains two `event.h` (under `vt/key/` and `vt/mouse/`) and Xcode 26's xcframework processor rejects duplicate header basenames. The Swift sources compile cleanly (the build log contains no Swift `error:` lines). Approach: post-process the generated xcframework in `apps/mac/scripts/build-ghostty.sh` `prepare_xcframework()` so the consumed framework has no duplicate header basenames, while keeping `ghostty.h` (the only header the rewritten `module.modulemap` exposes) and everything it transitively `#include`s resolvable. Verify a clean `make mac-build` reaches `BUILD SUCCEEDED`. This must be validated with a full rebuild cycle before P-work starts.

### T0b — Green-baseline the double-pane fix

The pending change (synchronous `createPaneRow` + async `ensurePaneSurface`, closing the auto-seed double-seed race) is already written. On the unblocked build, confirm it compiles and the app seeds exactly one pane per new worktree.

### P1 — `ZmxControlClient` + attach-command helper

In `apps/mac/touch-code/Runtime/Ghostty/`, add a small `ZmxControlClient` that connects to a daemon control socket, sends one `ZmxFrame`, reads the framed reply, and closes — exposing `info() -> ZmxInfoPayload`, `history(format:) -> Data`, and (if a serialize-on-quit option is retained) `snapshot() -> URL`. Add a helper (e.g. `ZmxAttachCommand`) that builds the `config.command` string `"<zmxPath> attach <session> [/bin/sh -c <userCommand>]"` with correct shell quoting; the session name is derived from the PaneID (stable across restart). No surface changes yet.

### P2 — Switch the surface to the exec backend

In `PaneSurface.init`, drop `config.external_pty_fd` and set `config.command`, `config.working_directory`, and `config.env_vars` (the M8 project env + builtins currently merged in `PaneDaemonBringup.spawn` move here). Delete `handleExternalPtyResize`, the `hasAttached`/`latestCols`/`latestRows` handshake, and the `externalPtyResize` case in `GhosttyActionDecoder`. libghostty's exec backend now sizes the PTY and forwards SIGWINCH; `zmx attach` propagates size to the daemon. Acceptance: a new pane renders at the correct width on the first frame (no jump).

### P3 — Bringup via attach

Rework `PaneDaemonBringup` so cold-start and live-reattach are the same operation: the surface command is `zmx attach <session>`, and the daemon is created-or-attached by zmx itself (upsert). Remove the `zmx serve` spawn + stdout-parse + socketpair handshake from the hot path. `SessionReaper`/`TerminalEngine` tier selection collapses to "does a persisted session exist for this PaneID" (used only for catalog/PID bookkeeping, not for choosing a spawn path).

### P4 — Reconnect out-of-band capabilities

- Foreground/agent detection: obtain the daemon shell PID via `ZmxControlClient.info()` once per pane after the surface comes up, feed it to `ForegroundJobReader` (unchanged downstream).
- `tc pane read`: `HierarchyHandlers` calls `ZmxControlClient.history(format:)` (or shells `zmx history <id>`).
- Quit-time: `SessionLifecycle` either leaves the daemon alive (default) or kills it (`zmx kill <id>` / control `.kill`) per the "Resume panes on launch" setting. No disk-snapshot step.
- Teardown of a deliberately-closed pane: `zmx kill <id>` (or control `.kill`).

### P5 — Remove legacy path; tests

Delete the socketpair/dual-read-loop body of `ZmxClient` (keep only what `ZmxControlClient` needs, or replace it entirely). Repair the touch-code test target, which has been non-compiling since `openPane`/`splitPane` became `async` (22 call sites across `HierarchyManagerTests`, `HierarchyManagerOpenPaneEnvForwardTests`, `HierarchyClientTests`, `HierarchyManagerWorktreeMgmtTests` missing `await`; `make test` is a no-op so it went unnoticed). Add coverage: attach-command construction, `ZmxControlClient` framing, and a guard that the surface is created with `config.command` set and `external_pty_fd` unset.

## Concrete Steps

Run from `apps/mac` unless noted. Each P-step ends with a build:

    make mac-build      # expect: ** BUILD SUCCEEDED **
    make mac-check      # swift-format + swiftlint

Behavioral check after P2/P3 (manual, via the running app or the `tc` CLI): create a new worktree, observe the pane renders at full width immediately; `tc tree` shows one pane; switch worktrees and back — no loading-then-jump.

## Validation and Acceptance

- New pane (worktree create / new tab / split): correct column width on first paint, no reflow. (Primary acceptance — this is the bug.)
- Worktree switch to a fresh pane: no width jump after the loading placeholder.
- Resume: with "Resume panes on launch" on, quit and relaunch — panes reconnect to their live daemons with shell + scrollback intact (`zmx attach <same-session>` upserts).
- Foreground detection: run a long command / coding agent in a pane; the worktree/tab busy indicator still lights (proves the shell PID is resolved via `.info`).
- `tc pane read <id>` still returns rendered output.
- `make mac-build` and `make mac-check` clean; the touch-code test target compiles and its suite passes.

## Idempotence and Recovery

T0 (xcframework post-process) is idempotent — re-running `build-ghostty.sh` reproduces the same pruned framework; the fingerprint cache short-circuits unchanged ghostty. The surface/bringup rework is behind the same `HierarchyClient`/`TerminalEngine` seams, so a partial landing can be reverted file-by-file. Keep `ZmxClient` until P5 so P2–P4 can be bisected against it.

## Interfaces and Dependencies

In `apps/mac/touch-code/Runtime/Ghostty/`, define approximately:

    enum ZmxAttachCommand {
      /// "<zmxPath> attach <session> [/bin/sh -c <quoted userCommand>]"
      static func build(zmxPath: String, session: String, userCommand: String?) -> String
    }

    @MainActor final class ZmxControlClient {
      init(socketPath: String) throws            // transient connect
      func info() async throws -> ZmxInfoPayload // shell PID, etc.
      func history(format: ZmxHistoryFormat) async throws -> Data
      // snapshot() retained only if a serialize-on-quit option survives the
      // resume-model decision above.
    }

`config.command` is consumed by libghostty's exec backend (`ghostty_surface_config_new` → `ghostty_surface_new`); on macOS libghostty wraps the value as `/bin/sh -c "<value>"`. The session name is derived from `PaneID` and must be stable across launches so re-exec re-attaches. The zmx binary path is resolved from the app bundle (`Bundle.main` `bin/zmx`, as today).
