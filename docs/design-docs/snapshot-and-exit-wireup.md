# Design Doc: Wire up "Snapshot and exit" quit action end-to-end

**Status:** Approved
**Author:** Gump
**Date:** 2026-06-15

## Context and Scope

codans offers two "On quit" actions (`QuitAction`, `CodansCore/Settings/GeneralSettings.swift`):

- **Keep session running** (`keepRunning`) — the *live tier*: daemons stay alive, next launch re-attaches to the running shell.
- **Snapshot and exit** (`snapshot`) — the *snapshot tier*: quit serialises each pane's VT state, tears the daemons down, and the next launch restores the visible buffer into a fresh shell.

The live tier works. **The snapshot tier is a no-op today** — it serialises nothing and restores nothing. The original [pane-resume](pane-resume.md) design specified the snapshot tier in full, but the runtime later moved from a two-fd `ZmxClient` (`zmx serve --restore-from`) model to a single-invocation **`zmx attach`** model (libghostty's exec backend forks `zmx attach <session>`; see `ZmxAttachCommand`, `TerminalEngine.ensureSurface`). The snapshot tier was never re-wired onto that new model, leaving disconnected scaffolding on both ends.

The heavy lifting already exists and is exercised in the `zmx` submodule:

- **Write:** `Daemon.handleSnapshot` (`ThirdParty/zmx/src/main.zig:1258`) — on `.Snapshot` (IPC tag 14) it serialises the terminal mirror, atomically renames it to `<ZMX_DIR>/snapshots/<session>.snap`, SIGHUPs the shell, and shuts the daemon down. One message does "snapshot **and** exit".
- **Restore:** the daemon's shared `daemonLoop` pre-fills the VT mirror from `daemon.restore_from` before any PTY bytes (`main.zig:2638`), "beneath whatever the shell echoes on startup".

What is missing is entirely on the codans (Swift) side, plus one small `zmx` gap.

**The two breaks:**

1. **Producer (quit).** `SessionLifecycle.detachAllForQuit(.snapshot)` sends `.kill` (tag 5), not `.snapshot` (tag 14). No `.snap` file is ever written.
2. **Consumer (launch).** `CodansApp` discards `reaper.sweep()`'s result (`CodansApp.swift:1026`, `_ = try reaper.sweep(...)`), so the `.snapshot(url)` states the reaper computes go nowhere. And `zmx attach` does **not** parse `--restore-from` (only `serve` does, `main.zig:194`), so even an auto-spawned daemon never restores.

Scope: reconnect the snapshot tier to the live-only `zmx attach` runtime. Out of scope: redesigning the live tier, the catalog, or the reaper's stale/orphan logic.

## Goals and Non-Goals

**Goals**

- "Snapshot and exit" actually writes one `.snap` per live pane at quit, and the next launch restores each pane's visible buffer + scrollback into a fresh shell.
- Preserve the runtime's **unified-invocation invariant**: cold start, live re-attach, and snapshot restore are all the same `zmx attach <session> …` spawn — no second spawn code path.
- Bounded, non-blocking quit: snapshotting N panes must not hang `applicationShouldTerminate` on a wedged daemon.
- Restore is idempotent and self-cleaning: a consumed snapshot is not re-applied on a later relaunch.

**Non-Goals**

- Re-running anything. Snapshot tier restores a **static frame**; the fresh shell starts at a clean prompt below it. (Use the live tier to keep processes running.)
- Faithful TUI continuation (a pane in `nvim` at snapshot shows the last frame, not a live editor). A "new shell" divider is a nice-to-have, not a goal.
- Encrypting snapshot files at rest (unchanged from pane-resume: plaintext in `~/Library/Caches/`, FileVault assumed).
- A `RestoreAck` control handshake (the original design needed it for Init-ordering; the attach model does not — see Design).

## Design

### Overview

Reconnect the existing producer and consumer through the current `zmx attach` path, with the smallest change that keeps one spawn invocation.

- **Quit:** swap the per-pane `.kill` for a new `ZmxControlClient.snapshot(for:)` that sends tag 14 and waits (bounded) for the daemon to write-and-exit. The daemon already does snapshot-then-shutdown in one step, so no separate kill is needed.
- **Launch:** stop discarding the sweep result. Turn its `.snapshot(url)` entries into a consume-once `[PaneID: URL]` map handed to `TerminalEngine`. When `ensureSurface` brings a pane up, if a restore path is pending it appends `--restore-from <url>` to the attach command.
- **zmx:** teach the `attach` arm to parse `--restore-from <file>` and set `daemon.restore_from`. The consume side (`daemonLoop` pre-fill) already exists, so this is the only daemon change.

The key trade-off — **teach `attach` the flag** vs. **special-case `serve --restore-from`** — is resolved in favour of `attach` to keep the unified-invocation invariant the current runtime is built around. The cost is a ~10-line Zig change to a vendored submodule; the benefit is that `ensureSurface` keeps exactly one bring-up path with an optional flag, rather than branching spawn-vs-restore.

### System Context Diagram

```
   QUIT (CodansApp.applicationShouldTerminate → SessionLifecycle.detachAllForQuit(.snapshot))
         │  for each live surface, bounded concurrency + timeout
         ▼
   ZmxControlClient.snapshot(paneID)  ──tag 14 (.snapshot)──►  zmx daemon
         │  wait for socket EOF (daemon exits)                    │ handleSnapshot:
         │                                                        │  serialize VT → atomic rename
         ▼                                                        │  <ZMX_DIR>/snapshots/<paneID>.snap
   (app exits)                                                    │  SIGHUP shell, shutdown
                                                                  ▼
   ── next launch ───────────────────────────────────────────────────────────────────────
   CodansApp.bootstrap
         │  states = reaper.sweep()           (no longer discarded)
         │  pendingRestores = { paneID: url | states[paneID] == .snapshot(url) }
         ▼
   TerminalEngine.ensureSurface(pane)
         │  restorePath = pendingRestores.removeValue(forKey: pane.id)   (consume-once)
         ▼
   ZmxAttachCommand.build(..., restoreFrom: restorePath)
         │  "zmx attach <session> --restore-from <url> [/bin/sh -c <cmd>]"
         ▼
   libghostty exec backend forks zmx attach ──► auto-spawn daemon
                                                  │ daemonLoop pre-fills VT from restore_from
                                                  │ (restored frame), then fresh shell runs
                                                  ▼  surface renders restored buffer + new prompt
```

### Producer — quit-time snapshot (Swift)

New `ZmxControlClient.snapshot(for:)`, shaped like the existing `kill(for:)` but **synchronising on the daemon's exit**:

- Open the pane's control socket, send `ZmxFraming.encode(ZmxFrame(tag: .snapshot))`.
- Wait for socket EOF (daemon closes on shutdown) with a short deadline — reuse the `sendOneShotKill` EOF-poll pattern (`SessionReaper.swift:388`), which already proves the "write a frame, poll for EOF, bounded" shape.
- EOF is the de-facto ack: `handleSnapshot` writes the file *before* `self.shutdown()`, so EOF implies the `.snap` is on disk. No new wire message needed.

`SessionLifecycle.detachAllForQuit(.snapshot)` replaces its `ZmxControlClient.kill` loop with bounded-concurrency `snapshot(for:)` calls (e.g. a small task group, per-pane timeout ~1–2 s). On timeout it falls back to `.kill` for that pane so a wedged daemon can't strand the quit. The empty-`sessions.json` write is unchanged.

Why EOF-wait rather than fire-and-forget: the daemon is `setsid` and would finish writing even if the app died first, but waiting bounds the common case and lets us fall back to kill deterministically when a daemon is unresponsive.

### Consumer — launch-time restore (Swift + zmx)

**zmx (`attach` arm, `main.zig:136`).** Today the arm reads `session_name` then sweeps *all* remaining args into `command_args` (the command to run). Add: while collecting, if an arg equals `--restore-from`, consume the next arg into a local `restore_from` instead of appending it; set `.restore_from = restore_from` on the `Daemon` literal. The shared `daemonLoop` already honours it. (~10 lines.) Optionally `unlink` the snap after a successful read so the daemon owns its lifecycle.

**CodansApp (`bootstrap`, `CodansApp.swift:1026`).** Capture the sweep result instead of discarding it; build `pendingRestores: [PaneID: URL]` from `.snapshot(url)` states; hand it to `TerminalEngine`. The existing `sweepFilesystemOrphans` call is unaffected.

**TerminalEngine.** Add a `pendingRestores: [PaneID: URL]` property. In `ensureSurface`, `removeValue(forKey: pane.id)` (consume-once) and pass the path to `ZmxAttachCommand.build`. Consume-once guarantees a pane re-spawned later in the *same* session (e.g. close+reopen) does not re-restore a stale frame.

**ZmxAttachCommand.build.** Add an optional `restoreFrom: String?`; when present, emit `zmx attach <session> --restore-from <quoted path> [/bin/sh -c <cmd>]`. Path is shell-quoted via the existing `shellQuote`.

No app-side Init/restore handshake is required: the daemon pre-fills the VT mirror before the shell's first byte, so restore→shell ordering is the daemon's responsibility, and the surface simply renders the resulting byte stream. This is why the original design's `RestoreAck` is dropped.

### Component Boundaries

| Component | File | Change | Stays out of |
|---|---|---|---|
| zmx daemon | `ThirdParty/zmx/src/main.zig` | `attach` parses `--restore-from`; (opt) unlink snap after read | snapshot file location policy (driven by `$ZMX_DIR`) |
| Control client | `Runtime/Ghostty/ZmxControlClient.swift` | add `snapshot(for:)` (tag 14, EOF-wait, timeout) | session lifetime, catalog |
| Quit lifecycle | `Runtime/SessionLifecycle.swift` | `.snapshot` branch calls `snapshot(for:)` (bounded) not `kill`, kill-fallback on timeout | which action to apply (CodansApp decides) |
| Launch wiring | `App/CodansApp.swift` | keep sweep result; derive `pendingRestores`; inject into engine | reaper internals |
| Bring-up | `Runtime/TerminalEngine.swift` | `pendingRestores` map; consume-once in `ensureSurface` | command string syntax |
| Command builder | `Runtime/Ghostty/ZmxAttachCommand.swift` | optional `restoreFrom` → `--restore-from` flag | spawn mechanics |
| Settings copy | `QuitConfirmationDialog.swift`, `Panes/SettingsGeneralView.swift` | none needed — existing copy already describes the intended behaviour, which now becomes true | — |

Dependency direction is unchanged: `CodansApp → SessionLifecycle/TerminalEngine → ZmxControlClient/ZmxAttachCommand → zmx`. The reaper already owns `.snapshot(url)` production and stale-snap cleanup; this design only adds a *consumer* for what it produces.

## Alternatives Considered

**A. Special-case `zmx serve <session> --restore-from <snap>` for snapshot panes (the original pane-resume path).**
Trade-off: zero zmx change (the flag already exists on `serve`), but introduces a second spawn path divorced from the `attach` upsert the current runtime standardised on, and `serve` is a foreground/blocking daemon that doesn't match how libghostty's exec backend drives `attach`. Rejected: it reintroduces the spawn-vs-restore branching that `TerminalEngine.ensureSurface` deliberately removed, for a worse fit with the live tier.

**B. App-side restore — read the `.snap` bytes in Swift and feed them to the ghostty surface parser directly.**
Trade-off: avoids any zmx change, but duplicates the VT replay the daemon already performs, races the shell's first output (the daemon guarantees restore lands *beneath* the shell echo; the app cannot), and violates pane-resume's invariant that "the app never parses these bytes". Rejected: strictly more complex and more fragile than letting the daemon restore.

**C. Leave the mechanism as "kill, start fresh" and just rename the UI** (e.g. "Exit fresh").
Trade-off: trivial, honest, but abandons a feature with real user value (context recall across restarts without keeping processes alive). Rejected by product decision — the user explicitly wants the snapshot to work.

## Cross-Cutting Concerns

- **Security/privacy:** `.snap` files contain scrollback that may include secrets. Unchanged from pane-resume §Security: plaintext in `~/Library/Caches/codans/snapshots/`, user-readable only, FileVault assumed, reaper reaps files >7 days. No new exposure — we only start *writing* files the design already accounted for.
- **Observability:** log snapshot-send (producer) and restore-flag-applied (consumer) to the existing `com.gumpw.codans.runtime` os.Logger categories; the daemon already logs `snapshot requested` and `restore-from` warnings.
- **Error handling / graceful degradation:** snapshot send timeout → fall back to `.kill` (pane starts cold next launch). Corrupt/unreadable `.snap` → daemon logs a warning and starts cold (`main.zig:2650`). Missing flag support in an older zmx → not possible: the app embeds its own co-versioned `zmx` binary, so app and daemon never skew across this change.
- **Testing:**
  - Unit: `snapshot(for:)` encodes tag 14; `ZmxAttachCommand.build(restoreFrom:)` emits the flag and quotes the path; `ensureSurface` consumes `pendingRestores` once; `CodansApp` maps `.snapshot(url)` states into `pendingRestores`.
  - zmx Zig: `attach --restore-from <file>` sets `restore_from` and pre-fills the VT (extend the existing attach→snapshot→reattach integration test in pane-resume §Testing to assert restored-buffer byte equality).
- **Migration:** none. The snapshot directory, `ZmxTag.snapshot`, `SessionState.snapshot`, and the reaper merge already exist; this is additive wiring. No on-disk schema change.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Quit latency with many panes (N socket round-trips + serialise + write) | Medium | Medium | Bounded concurrency (task group) + per-pane timeout; kill-fallback on timeout so quit never blocks on a wedged daemon. `handleSnapshot` is in-memory serialise + one atomic write — fast in practice. |
| Stale snapshot re-applied after a mid-session crash/relaunch | Low | Low | Consume-once `pendingRestores` map (same session) + reaper deletes a snap once its paneID is `.alive` next launch; optional zmx unlink-after-read closes the window entirely. |
| Restored frame confuses the user when the pane held a TUI (last frame shown, fresh prompt below) | Medium | Low | Non-goal for v1; optional daemon-injected "─── new shell ───" divider after restore (pane-resume OQ5) deferred. |
| `--restore-from` placed where `attach` mis-parses it as the command | Low | Medium | zmx change special-cases the flag in the arg loop before command collection; covered by a Zig parse test. Builder emits the flag immediately after the session name. |
| Snapshot serialise fails / returns empty for a huge buffer | Low | Low | Daemon already caps at `max_scrollback`; empty serialise → `error.SerializeFailed`, daemon falls back to plain shutdown; pane starts cold. |

## Resolved Decisions

- **D1 — snap cleanup owner (was OQ1).** **Resolved:** reaper-backstop + consume-once `pendingRestores`. No `unlink`-after-read patch in zmx — cleanup stays out of the vendored submodule. Revisit only if a same-session re-restore window is ever observed in practice.
- **D2 — `--cwd` alongside restore (was OQ2).** **Resolved:** do NOT pass `--cwd`; rely on libghostty setting the child's working directory from `pane.workingDirectory` in the attach model. This is **verified empirically, not assumed**: the end-to-end restore integration test asserts the restored pane's fresh shell starts in the pane's expected working directory (e.g. `pwd` matches `pane.workingDirectory`). `--cwd` is added only if that assertion fails.
