# Product Spec: Pane Resume

**Status:** Approved
**Author:** Gump
**Date:** 2026-05-24

## Summary

Restore each Pane's terminal content (visible buffer, scrollback, cursor, modes) — and optionally the running shell itself — across codans app restarts. Today, when the app exits, every Pane's libghostty surface tears down its PTY; the user's running compilations, long-tail commands, and CLI-agent loops die with it, and only the working directory survives. This feature decouples PTY ownership from the rendering surface so that the in-memory terminal state is captured before exit and replayed (or actively re-attached) on next launch.

Persistence offers two tiers driven by a single user choice at quit time:

- **Live tier** — the PTY (and the shell / process it hosts) continues running in an out-of-process sidecar daemon after the app exits; on relaunch the surface re-attaches and the shell never knew the app was gone.
- **Snapshot tier** — at quit, the daemon serializes its `ghostty-vt` terminal state to disk and exits along with the shell; on relaunch the user sees a faithful visual replay of the pre-quit screen + scrollback, but the underlying shell is fresh.

Both tiers share the same daemon architecture, serialization format, and on-disk catalog. They differ only in what runs after the app closes.

## User Stories

- **As a CLI-agent power user**, I want my long-running agent loops (e.g. `claude --resume`, a build watch, `pnpm dev`) to keep running when I `cmd-Q` codans, so that I can quit/relaunch without interrupting in-flight work.
- **As a daily developer**, I want the visible terminal content (scrollback, last command output, prompt state) restored exactly as I left it after a quit-and-relaunch, so I don't lose context when the app dies or I restart for an update.
- **As a power user**, I want a clear signal at quit time of how many Panes have running shells that will continue, with an obvious way to opt out for a specific quit if I want a clean slate.
- **As a returning user after a long break**, I want stale persistent sessions cleaned up automatically (or surfaced clearly) so that orphan daemons don't accumulate forever.

## Requirements

### Must Have

- [ ] **R1** — Each Pane's PTY child is owned by an out-of-process sidecar daemon, not by the libghostty surface
- [ ] **R2** — On normal app quit (cmd-Q, menu Quit), if "keep panes running" is enabled (default), every Pane's daemon continues to run with its shell after the app exits
- [ ] **R3** — On app relaunch with a live daemon present, the Pane reattaches and the on-screen state matches what was running while the app was closed (scrollback grew, prompts updated, etc.)
- [ ] **R4** — When a daemon is asked to snapshot-and-exit at quit, it serializes its `ghostty-vt` terminal state to disk; on next launch with no live daemon but a snapshot present, the Pane opens with the snapshot replayed (visible buffer + scrollback + cursor + modes) ahead of a freshly-spawned shell
- [ ] **R5** — A global Setting "Resume panes on launch" (default: on) controls whether daemons are kept across quit; toggling off makes quit behave as snapshot-tier for all Panes
- [ ] **R6** — When the app force-quits or is `kill -9`'d by the user, every daemon already running independently continues to run (i.e. the daemon must be detached from the app's process group)
- [ ] **R7** — Daemons that have not been attached for N days (default 7) are reaped on next app launch, freeing their socket and on-disk state
- [ ] **R8** — Closing a Pane explicitly (Pane → Close, or `codans pane close`) kills its daemon and removes its catalog entry
- [ ] **R9** — A daemon serving an active Pane in v1 accepts exactly one client connection at a time; subsequent attach attempts are rejected (multi-client mirroring deferred to v2)

### Nice to Have

- [ ] **R10** — Quit-time confirmation banner / toast: "3 panes will keep running" with one-click "snapshot all instead" shortcut
- [ ] **R11** — Status-bar indicator on Panes whose daemon predates the current app session (i.e. survived a quit)
- [ ] **R12** — Command Palette entry: "Pane → Kill background session" to terminate a detached daemon without launching the app session
- [ ] **R13** — Pane-level override toggle ("this pane: snapshot only") for sensitive shells where keeping a process alive is undesirable

### Won't Have (v1)

- Multi-client mirroring (Master Terminal observing a Pane's stream via the same daemon) — deferred to v2
- macOS reboot survival — requires a per-user LaunchAgent, and the user's shell process is killed by `launchd` at logout/reboot anyway, so the value is marginal
- Cross-machine / cross-user resume
- Per-Project opt-out — the default-on global toggle is sufficient for v1
- Sharing a session across multiple codans app instances on the same machine

## Acceptance Criteria

- **AC1.** Given a Pane running an arbitrary command (e.g. `tail -f`), when the user `cmd-Q`'s codans with "Resume panes on launch" enabled and relaunches the app, then the same Pane re-opens with the live tail-output stream continuing where it was, and process inspection (`ps -ef` outside codans) shows the original shell PID is still running.

- **AC2.** Given the same scenario as AC1 but with "Resume panes on launch" disabled in Settings, when the user quits and relaunches, then the Pane re-opens with the visible buffer and scrollback identical to the pre-quit screen (text, colors, cursor position), but the shell PID has changed (the on-disk snapshot was replayed into a fresh shell).

- **AC3.** Given a Pane whose daemon has been detached for more than N days (default 7), when the app launches, then the daemon is killed, its socket file and snapshot are removed, and the Pane (if its parent Tab still resolves) opens a fresh shell at the last known cwd.

- **AC4.** Given a running Pane, when the user closes the Pane explicitly via UI or CLI, then within 2s the daemon process is gone, its socket file is removed, and its catalog entry is deleted.

- **AC5.** Given a Pane reattached after relaunch, when the user types and the program echoes / runs commands normally, then there is no perceptible input lag versus a freshly-created Pane (P99 keystroke-to-glyph < 50ms on M-series hardware).

- **AC6.** Given a second instance of codans starting up while the first is still running and holding daemons, when it attempts to attach to those sockets, then it sees the daemons as "in use" and either declines to attach or falls back to fresh shells (no double-attach corruption).

- **AC7.** Given a Pane with `ghostty-vt`-trackable state (custom keyboard mode, alternate screen, scrolling region, OSC 7 pwd, palette modifications) at quit time, when the user relaunches, then all those modes are present in the restored surface (verified via `codans pane read` or visual inspection).

- **AC8.** Given an app that force-quits or crashes, when the user relaunches, then any Pane whose daemon was running independently is restored as if it had been a normal quit; any Pane whose state was only in-memory (daemon hadn't started yet) opens as fresh.

## Design

Detailed engineering design will be produced by `/hs-design` in the next step. Key constraints already established from Phase 0 spikes:

- libghostty's `termio.Backend` is internally a `union(Kind)` with `exec` as the only current variant; adding an `external` variant (PTY fd owned by the daemon) is the minimum patch to support live-tier resume.
- `libghostty-vt` already ships its own C-ABI build target (xcframework available); no glue layer required for Swift consumption.
- Serialization format is the two-phase scrollback+viewport VT stream from `zmx`'s `serializeTerminalState` (`/Users/wanggang/dev/opensource/zmx/src/util.zig:479`); we will adopt it byte-for-byte rather than reinventing.
- The daemon implementation may be the upstream `zmx` binary vendored as a sidecar, or a Swift port — to be decided in `/hs-design`.

Reference projects: [`zmx`](https://github.com/neurosnap/zmx) (architectural model + serialization), `shpool` (mentioned in zmx prior-art), supacode / supaterm internal references.

## Open Questions

- **OQ1.** Does the daemon ship as a vendored `zmx` binary (Zig-built, signed alongside the app) or as a Swift sidecar speaking the same wire protocol? Tradeoffs in `/hs-design`.
- **OQ2.** Do we patch our local ghostty submodule (carry the external-PTY backend internally) or attempt upstream PR first? Carrying-then-PR-ing is fine, but version-skew handling needs a policy.
- **OQ3.** Where exactly does the "Resume panes on launch" Setting live — top-level Settings tab, or under an existing "Terminal" group?
- **OQ4.** How is the quit-time signal shown to the user (banner / toast / dialog / nothing) — UX is R10's nice-to-have, but if we surface it at all the design needs to land before launch.
- **OQ5.** Maximum scrollback per daemon (zmx defaults to 10K lines) — surface as Setting, or fixed in v1?

---

## Update — Hardening (2026-05-29)

After M0–M5 landed and the live + snapshot tiers shipped, a deeper review identified four areas where the current implementation can be made significantly more robust, discoverable, and complete. These additions are layered on top of R1–R13; the original behaviour is unchanged.

### Additional Requirements (Must Have)

- [ ] **R14** — The on-disk session catalog is updated continuously through the runtime (spawn / attach / detach / close), not only at quit. An app crash between two quits leaves the catalog in a state that accurately reflects the daemons that were spawned at crash time.
- [ ] **R15** — Launch-time orphan reaping has a defense-in-depth tier: when `sessions.json` is missing, corrupt, or stale, any surviving `zmx serve` daemon under the managed socket directory is detected by directory scan and killed if it cannot be claimed by either the session catalog or the hierarchy.
- [ ] **R16** — The Settings → General pane surfaces a "Resumable sessions: N" count plus a one-click "Forget all sessions" action that kills every recorded daemon, unlinks the sockets, and empties the catalog. This makes the otherwise-invisible resume mechanism debuggable and resettable without leaving the app.
- [ ] **R17** — Each pane's current agent kind + foreground PID + activity state is persisted alongside its session row and re-seeded into the Active Agents registry on relaunch, after a `kill(pid, 0)` liveness check. The Active Agents sidebar then reflects pre-quit state immediately on launch, without waiting for re-detection from terminal output.

### Additional Acceptance Criteria

- **AC9.** Given a Pane spawned and attached in the current session, when the app crashes (`kill -9 Codans`) and is relaunched, then `sessions.json` already contains the pane's row from before the crash, and the daemon reattaches as if a normal quit had occurred.

- **AC10.** Given a corrupted or empty `sessions.json` but two surviving `zmx serve` daemons running under the managed socket directory, when the app launches, then both daemons are detected by directory scan and killed (because no catalog row and no hierarchy entry claims them), their sockets are unlinked, and the launch completes with no resume.

- **AC11.** Given N live resumable sessions across all worktrees, when the user opens Settings → General, then the page shows `Resumable sessions: N` next to a `Forget all sessions` button; confirming the button kills every recorded daemon, removes every catalog row, and the count drops to 0 without app restart.

- **AC12.** Given a Pane was running a recognised agent (Claude Code, Codex, etc.) at quit time, when the app relaunches, then the Active Agents sidebar shows that pane's row with the same agent kind it had at quit. State is derived from a fresh liveness probe on the persisted foreground PID; rows whose PID is dead are dropped (not surfaced as `.finished`).

### Additional Open Questions

- **OQ6.** Should "Forget all sessions" use a confirmation dialog or an undo-toast? Leaning toward dialog because the operation kills running shells.
- **OQ7.** When the persisted agent's PID is no longer alive at relaunch, do we show the row in a `.finished` state or omit it entirely? Leaning toward omit — stale finished rows at launch are noise.

---

**Downstream artifacts:**
- `/hs-design` → engineering design (architecture, ghostty patch shape, daemon lifecycle, IPC)
- `/hs-test-spec` → `docs/user-tests/pane-resume.md` binding to AC1–AC8
- `/hs-planner` → execution plan with task breakdown
