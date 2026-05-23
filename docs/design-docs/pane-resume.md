# Design Doc: Pane Resume

**Status:** Approved
**Author:** Gump
**Date:** 2026-05-24

## Context and Scope

[Product Spec: Pane Resume](../product-specs/pane-resume.md) requires that each Pane's terminal content (and optionally the underlying shell process) survives `cmd-Q` of touch-code. Today every Pane is a `ghostty_surface_t` whose `Exec` backend internally `forkpty()`s a shell child; when the app exits, the shell dies with the surface and only the cwd is persisted (commit `fa7eadb6`).

Phase 0 spike findings (already completed in conversation):

- libghostty's `termio.Backend = union(Kind) { exec }` (`ghostty/src/termio/backend.zig:24`) is internally extensible. No public C entry exposes an external-PTY backend, but the Zig union is shaped for one.
- `libghostty-vt` already ships its own C-ABI build target (`ghostty/build.zig:155-165`), independent of `GhosttyKit.xcframework`.
- `zmx` (`/Users/wanggang/dev/opensource/zmx`) is exactly the daemon we need: per-session unix socket, fork+setsid daemonization (`zmx/src/main.zig:780`), `ghostty_vt.Terminal` mirror of PTY output, multi-client fan-out, validated two-phase serializer (`zmx/src/util.zig:479`).
- Existing touch-code persistence is atomic-rename JSON with top-level `version: Int`; `CatalogStore.swift` is the reference pattern.
- IPC between app and CLI uses length-prefixed JSON envelopes over Unix socket. The daemon protocol is a different transport (binary, length-prefixed `ipc.Tag` envelopes from zmx) and must not be conflated.

This design specifies how to integrate zmx as an out-of-process sidecar, what patches it needs, how libghostty's surface adopts an external PTY backend, and how the catalog / snapshot files glue everything together.

## Goals and Non-Goals

**Goals**

- Pane PTY ownership lives in a per-Pane sidecar daemon, not in the libghostty surface
- A single user toggle ("Resume panes on launch") flips between live tier (daemon stays alive) and snapshot tier (daemon serializes & exits) at quit time
- Re-attaching to a live daemon restores the running shell + scrollback exactly; replaying a snapshot restores the visible buffer + scrollback faithfully into a fresh shell
- Daemon survives app `cmd-Q` and force-quit without external supervision (no LaunchAgent)
- Idle daemons reaped after 7 days
- Wire protocol and serialization stay byte-compatible with upstream zmx so we can pull in upstream fixes

**Non-Goals**

- Multi-client mirroring (one Pane = one daemon = one attached client in v1)
- macOS reboot survival
- Cross-machine session resume
- Replacing libghostty's renderer or VT — the surface continues to do all rendering and local VT processing
- Per-Project opt-out — a single global Setting suffices
- Custom wire protocol — zmx's binary IPC is adopted as-is

## Design

### Overview

Each Pane gets a long-lived `zmx` daemon process (one per Pane UUID). The daemon owns the PTY master and a `ghostty_vt.Terminal` mirror; it daemonizes on creation and outlives the app. The app's libghostty surface no longer `forkpty()`s — it uses a new `external` `termio.Backend` whose I/O is a Unix socketpair connected to the daemon. The daemon proxies between the real PTY and the socketpair, so the surface sees a continuous byte stream indistinguishable from an in-process PTY for rendering purposes.

At quit time the app consults the "Resume panes on launch" Setting:

- **On (default)** — app sends `.Detach` to each daemon and disconnects. Daemons keep running. App writes their PIDs + socket paths to `sessions.json`.
- **Off** — app sends a new `.Snapshot` command (small zmx patch). Daemon writes its `serializeTerminalState` output to `<paneID>.snap`, sends SIGHUP to its PTY child, and exits.

At launch, for each Pane in the catalog the app:

1. Looks up `sessions.json[paneID]`. If present and `connect(socketPath)` succeeds → live tier: send `.Init{cols, rows}`, daemon replays serialized state, normal flow resumes.
2. Else if `<paneID>.snap` exists → snapshot tier: spawn `zmx serve <paneID> --restore-from <snapshot>` (daemon prepopulates its VT from the file then starts a fresh shell), connect, send `.Init`.
3. Else → cold start: spawn `zmx serve <paneID> --cwd <cwd>`, connect, send `.Init`. (This becomes the default flow for *every* new Pane, not just resumed ones — eliminating the in-process fork path entirely.)

The key trade-off: we deliberately accept **one round-trip per PTY byte** (PTY → daemon → socketpair → surface) in exchange for clean process separation and a battle-tested daemon. Benchmarks elsewhere put a per-byte socketpair hop at ~1µs; for typical terminal rates (<1MB/s sustained) the latency increment is invisible. AC5 (P99 keystroke-to-glyph < 50ms) is comfortably achievable.

### System Context Diagram

```
                         touch-code.app process
   ┌──────────────────────────────────────────────────────────────────┐
   │                                                                  │
   │   Pane view (SwiftUI)                                            │
   │       │                                                          │
   │       ▼                                                          │
   │   PaneSurface (Swift) ──── ghostty_surface_t                     │
   │       │                       │                                  │
   │       │                       │ External backend (Zig patch)     │
   │       │                       │                                  │
   │       │              ┌────────┴───────┐                          │
   │       │              ▼                ▼                          │
   │       │           reads/writes   sends .Resize                   │
   │       │           bytes          on size change                  │
   │       │              │                │                          │
   │       │      ┌───────┴────────────────┴──┐                       │
   │       │      │   ZmxClient (Swift)       │  client socket fd     │
   │       │      └──────────────┬────────────┘                       │
   │       │                     │                                    │
   └───────┼─────────────────────┼────────────────────────────────────┘
           │                     │ unix socket (zmx wire format)
           │                     │ ~/Library/Caches/touch-code/zmx-sessions/<paneID>.sock
           │                     ▼
           │   ┌──────────────────────────────────────────────────────┐
           │   │  zmx daemon  (one per Pane, daemonized)              │
           │   │   • forkpty() → user $SHELL                          │
           │   │   • ghostty_vt.Terminal mirror (scrollback + state)  │
           │   │   • fan-out to single client                         │
           │   │   • on .Snapshot → write <paneID>.snap, exit         │
           │   └──────────────────────────────────────────────────────┘
           │                     ▲
           │                     │ owns PTY master, runs setsid'd
           │                     │
           └──────────────── reads sessions.json + snapshots/ on launch
                              ~/.config/touch-code/sessions.json (v1)
                              ~/Library/Caches/touch-code/snapshots/<paneID>.snap
```

### API Design

Four wire surfaces. The first three are byte-level; the fourth is in-process Swift.

**1. libghostty External backend (Zig patch)**

Adds a new `ghostty_surface_config_s` field:

```c
int external_pty_fd;   // -1 = use Exec backend (default); >= 0 = use External backend with this fd
```

When `external_pty_fd >= 0`, surface skips the `Exec.Subprocess.start()` path entirely. `External.zig` (new file) implements `Backend`:

- `threadEnter` spawns the read thread on the given fd; no `xev.Process`, no termios timer
- `queueWrite` `posix.write`s to the fd
- `resize(grid_size, screen_size)` does NOT call `ioctl(TIOCSWINSZ)` — instead it raises a new apprt action `external_resize { cols, rows }` so the embedder (us) can forward it to the daemon
- No process exit watcher; the embedder is responsible for noticing fd close and surfacing it via `ghostty_surface_request_close`

Patch surface: ~250 LoC Zig (External.zig + backend.zig union extension + embedded.zig config wiring + one new action variant).

**2. zmx wire protocol (unchanged, vendored as-is)**

Reused verbatim from upstream zmx. Length-prefixed messages with `ipc.Tag` enum + payload struct. Tags we exercise:

| Tag | Direction | Payload | Use |
|---|---|---|---|
| `Init` | client → daemon | `Resize{cols, rows}` | First message on attach; daemon replies with serialized state if `has_had_client` |
| `Resize` | client → daemon | `Resize{cols, rows}` | Subsequent size changes |
| `Stdin` | client → daemon | raw bytes | Keystrokes forwarded to PTY |
| `Output` | daemon → client | raw bytes | PTY output (live) or serialized state (on attach) |
| `Detach` | client → daemon | empty | Disconnect this client without killing daemon |
| `Kill` | client → daemon | empty | SIGHUP PTY child group, daemon exits |
| `Info` | client → daemon | empty | Returns `Info{pid, cmd, cwd, ...}` |

Two new tags (patch upstream):

| Tag | Direction | Payload | Use |
|---|---|---|---|
| `Snapshot` | client → daemon | empty | Daemon writes `serializeTerminalState()` to file at `$ZMX_DIR/snapshots/<session>.snap`, SIGHUPs PTY, exits cleanly |
| `RestoreAck` | daemon → client | empty | Sent once after `--restore-from` replay completes (for ordering) |

`RestoreAck` exists so the client can wait for prepopulation to finish before sending `.Init` — avoids interleaving.

**3. zmx CLI surface (new + minor changes)**

Upstream zmx today supports `attach` (interactive), `run`, `send`, etc. We need a non-interactive "ensure daemon exists" subcommand:

```
zmx serve <session> [--cwd <path>] [--command <prog> [args...]] [--restore-from <file>]
  Forks the daemon if no socket exists for <session>; exits 0 once daemon is reachable.
  Does NOT open a client connection. Prints socket_path to stdout.
```

Patch surface: ~80 LoC Zig (subcommand wiring + reuse of `Daemon.ensureSession`).

**4. ZmxClient (Swift, in `touch-code/Runtime/`)**

```swift
@MainActor
final class ZmxClient {
    init(paneID: PaneID, socketPath: String) async throws
    func attach(cols: UInt16, rows: UInt16) -> AsyncStream<Data>  // emits Output bytes; first chunk is serialized state if reattach
    func send(_ bytes: Data)                                       // forwards keystrokes
    func resize(cols: UInt16, rows: UInt16)
    func snapshot() async throws -> URL                            // returns path of written .snap; daemon exits after
    func detach()                                                  // disconnect, daemon survives
    func kill()                                                    // daemon dies
    var info: AsyncStream<DaemonInfo>                              // pid/cmd/cwd changes
}
```

Sits next to `PaneSurface.swift` in `Runtime/Ghostty/`. Owns the socket fd, the message framer, and the read coroutine. Connects the socket fd to the External backend via `ghostty_surface_config_s.external_pty_fd`.

Specifically: at Pane creation, `ZmxClient` opens **two** fds — the actual unix socket to the daemon (over which it sends control messages: `Init`, `Resize`, `Snapshot`, `Detach`, `Kill`) and a separate `socketpair()` pair where one end goes to the External backend (raw byte plumbing) and the other end is bridged to the unix socket by the `ZmxClient` read loop. Control messages and byte plumbing are thus separate fds, simplifying the External backend's job to "read/write raw bytes".

Actually — simpler design: one unix socket fd. App-side `ZmxClient` demultiplexes incoming `Output` payloads → forwards bytes to a `socketpair()` whose other end is the External backend's fd. Outgoing keystrokes from External backend appear on that same socketpair → `ZmxClient` wraps them in `.Stdin` envelopes and forwards over the unix socket. The socketpair is purely intra-process; the daemon never sees it. This keeps the External backend dead-simple (it just reads/writes bytes on its fd, oblivious to framing).

### Data Storage

Two new artifacts under existing roots; both follow the architecture's atomic-rename + versioned JSON pattern (or raw bytes for snapshots).

**`~/.config/touch-code/sessions.json`** (versioned, v1)

```jsonc
{
  "version": 1,
  "sessions": {
    "<paneID-uuid>": {
      "socketPath": "/Users/.../zmx-sessions/<paneID>.sock",
      "pid": 12345,
      "createdAt": "2026-05-24T10:00:00Z",
      "lastAttachedAt": "2026-05-24T11:30:00Z",
      "command": ["/bin/zsh", "-l"],
      "cwd": "/Users/wanggang/dev/touch-code",
      "zmxVersion": "0.6.0+tc1"
    }
  }
}
```

Written by app:
- on Pane creation (after daemon confirmed reachable)
- on attach (`lastAttachedAt` bumped)
- on detach (no fields change; presence implies "live tier expected")
- entry removed on Pane close, daemon kill, or reaper

Read by app:
- once at launch, to enumerate resumable Panes
- never re-read after that (in-memory truth)

**`~/Library/Caches/touch-code/snapshots/<paneID>.snap`**

Raw bytes from `serializeTerminalState`. No header, no framing, no version field — the bytes ARE the VT replay stream. Format version is implicitly tied to the `zmx_version` recorded in `sessions.json`; mismatched versions cause snapshot tier to fall back to cold start (R7 cleanup also handles this).

Written by daemon on `.Snapshot`. Read by daemon (not app) when launched with `--restore-from`. App never parses these bytes; it just confirms file existence.

**`~/Library/Caches/touch-code/zmx-sessions/<paneID>.sock`** (Unix socket)

The daemon's listening socket. zmx's `$ZMX_DIR` env var points the daemon at this directory. The dir lives under `Caches/` not `Application Support/` because it's transient runtime state (sockets are unlinked on shutdown, recreated on next launch).

**Migration**: none needed — these files don't exist today.

**Reaper sweep on launch**:

```
for each entry in sessions.json:
    if connect(socketPath) succeeds:
        if now - lastAttachedAt > 7 days:
            send .Kill, unlink socket, unlink snap, drop entry
        else:
            mark as resumable
    else:
        if pid alive:
            kill -SIGHUP -pid; sleep 0.5s; kill -SIGKILL -pid
        unlink socketPath; drop entry
```

### Component Boundaries

| Component | Location | Owns | Doesn't own |
|---|---|---|---|
| `External` backend | `apps/mac/ThirdParty/ghostty/src/termio/External.zig` (patch) | fd-based read/write loop, external_resize action emission | PTY ioctl, process lifetime, fork |
| `zmx` binary | `apps/mac/ThirdParty/zmx/` (new submodule) → `TouchCode.app/Contents/Resources/bin/zmx` | PTY ownership, ghostty-vt mirror, serializer, wire protocol, daemonization | catalog format, snapshot file location policy (driven by `$ZMX_DIR`) |
| `ZmxClient` | `apps/mac/touch-code/Runtime/Ghostty/ZmxClient.swift` (new) | socket fd, message framing, control-fd ↔ socketpair bridge, lifecycle on this Pane's daemon | daemon process management (spawn / kill — that's `PaneSurface`'s job) |
| `PaneSurface` | `apps/mac/touch-code/Runtime/Ghostty/PaneSurface.swift` (modified) | daemon spawn via `CommandRunner`, `ZmxClient` lifecycle, surface config (always external_pty_fd ≥ 0) | wire protocol, serialization |
| `SessionStore` | `apps/mac/TouchCodeCore/SessionStore.swift` (new) | sessions.json read/write, atomic rename, reaper | runtime state, IPC |
| `SessionReaper` | `apps/mac/touch-code/Runtime/SessionReaper.swift` (new) | startup sweep of stale sessions and snapshots | normal-flow session lifetime |
| `Resume` Setting | `apps/mac/touch-code/App/Features/Settings/` (modified) | the on/off toggle, persistence into `settings.json` general section | runtime application of the toggle (`PaneSurface` reads at quit time) |

**Dependency direction additions** (extending architecture.md):

```
TouchCodeCore     (existing) + SessionStore
    │
    └── TouchCodeIPC (existing — unchanged)
            │
            └── touch-code (app)
                    │
                    └── Runtime
                          ├── Ghostty/ZmxClient   (new)
                          ├── Ghostty/PaneSurface (rewired)
                          └── SessionReaper       (new)
```

zmx binary is a sibling of `tc` under `Contents/Resources/bin/`. Build flow extends the existing `build-ghostty.sh` pattern: a new `apps/mac/scripts/build-zmx.sh` produces a fingerprint-cached `.build/zmx/zmx` binary, embedded via Tuist post-script (mirroring `embed-tc.sh`).

**Architectural invariants extended**:

- *PTY ownership lives in the daemon, never in-process.* The Exec backend path becomes dead code at runtime (we always pass `external_pty_fd`); we don't remove it from the patched ghostty to keep upstream merge small.
- *Snapshot file format is opaque bytes.* App must not parse it. Schema versioning is via `zmxVersion` in sessions.json, not in the snapshot itself.
- *Daemon and CLI socket are completely separate transports.* One is binary `ipc.Tag` framing for daemon I/O; the other is JSON-RPC for tc ↔ app. Never bridge them.

## Alternatives Considered

**A. Swift port of zmx daemon (rejected for v1)**

Rewrite the zmx daemon in Swift, link `libghostty-vt.xcframework`, share the JSON-RPC framing already used by tc ↔ app.

Pros:
- Single transport across the app (JSON-RPC everywhere)
- Easier to debug from Xcode (single language, attached debugger)
- No Zig toolchain dependency for the sidecar (we still need it for ghostty itself, but cleaner separation)

Cons:
- ~1500 LoC of careful Swift to handle non-blocking IO, signal handling, terminal serialization, fan-out, fork+setsid
- zmx encodes hard-won corner cases (issue #31 two-phase serializer, fish DA1 timeout, OSC 133 redraw rewrite). Reimplementing means re-discovering them
- Drift from upstream — every zmx fix becomes a manual port

**Decision**: vendor the zmx binary for v1. Reconsider Swift port in v2 only if zmx upstream stalls or diverges from our needs. The ~2 min added build time and one extra signed binary in the bundle are cheap compared to weeks of porting.

**B. In-process `ghostty-vt` snapshot tier only (no daemon for live tier)**

Embed `libghostty-vt.xcframework` in the app and tee every byte from the libghostty surface into an in-process `Terminal` instance. On quit, serialize to disk; on launch, daemon-free visual replay via a new `ghostty_surface_write_vt` C entry.

Pros:
- Smaller libghostty patch (one C entry, no External backend)
- No process management, no signing of additional binary
- Single-tier (no live shell across restart)

Cons:
- Misses the marquee value of the feature: long-running compiles, agent loops, `tail -f` survive
- AC1 unmet
- The serialization tee inside the app is duplicate work that the daemon already does

**Decision**: rejected. The spec explicitly requires the live tier; cutting it removes 70% of the user value.

**C. SCM_RIGHTS fd passing instead of socketpair proxy**

Daemon `sendmsg`s the PTY master fd to the app over the control socket. App's External backend uses the dup'd fd directly. Daemon also reads the same fd for VT mirroring.

Pros:
- Zero proxy hop — surface talks to PTY master directly
- Slightly lower latency (theoretical)

Cons:
- Two consumers on the same fd race for reads — bytes go to whichever called `read` first. Mitigations exist (TIOCNOTTY tricks, fd-per-consumer via socketpair anyway) but add complexity
- ioctl(TIOCSWINSZ) issued by surface would conflict with daemon's resize handling unless we add a "who-resizes" coordinator
- macOS sandbox future-proofing: fd passing across signed-binary boundaries can be flagged

**Decision**: rejected. socketpair proxy adds ~1µs/byte hop, invisible at terminal rates; vastly simpler ownership model.

**D. LaunchAgent supervisor for daemons**

Install `~/Library/LaunchAgents/com.touch-code.zmx-<paneID>.plist` per daemon so launchd brings the process back if it crashes and starts it at login.

Pros:
- Daemons survive `kill -9`
- Daemons survive macOS reboot (but user's shell child still dies at logout, so dubious)

Cons:
- One plist per Pane → potentially hundreds of LaunchAgent entries, all churn-y
- Codesigning + first-launch permission popup ("touch-code wants to add LaunchAgent") creates a worse UX than the gain
- Reboot survival isn't actually delivered (shell process dies at logout regardless)

**Decision**: rejected. Spec ruled out reboot survival (Won't Have list); without that gain, LaunchAgents are net-negative complexity.

**E. Single shared daemon for all Panes**

One zmx daemon process multiplexes all Panes, each as a "session" within it.

Pros:
- One process to manage, one socket, simpler reaper
- Slightly lower memory (shared ghostty-vt code)

Cons:
- A daemon crash kills every Pane simultaneously
- Doesn't match zmx's "daemon per session" architecture — would require substantial rewrite
- AC8 (app crash recovery) becomes "either all-survive or none-survive" instead of per-Pane

**Decision**: rejected. Per-Pane isolation is worth the slight overhead.

## Cross-Cutting Concerns

**Security / Privacy**
- Daemon sockets live under `~/Library/Caches/` owned by the user (mode 0700). zmx already sets `ZMX_DIR_MODE` to 0750 (we'll override to 0700 since we're never sharing across users).
- Snapshot files contain terminal scrollback — may include sensitive output (tokens, secrets). They're plain bytes in `~/Library/Caches/`, readable only by the user. We do NOT encrypt at rest in v1; macOS FileVault is the assumed safety net.
- The reaper deletes snapshot files >7 days old, bounding accidental retention.

**Observability**
- All daemon spawn / attach / detach / snapshot / reap events log to `com.touch-code.runtime` os.Logger category
- `tc session list` (new RPC) enumerates sessions.json for debugging
- zmx daemon writes its own logs to `$ZMX_DIR/logs/<session>.log` (already implemented upstream); accessible via Console.app

**Error handling**
- Daemon refuses connection (socket dead but file exists) → reaper path
- Daemon connects but `.Init` reply times out (> 2s) → tear down ZmxClient, fall back to cold start, log warning
- Daemon process disappears mid-session → External backend's read returns EOF → surface emits `process_exited` action → app surfaces "shell exited" placeholder per the existing crash recovery design (architecture.md OQ6)
- Snapshot file present but daemon `--restore-from` fails to parse → daemon logs warning, starts cold; user sees fresh shell instead of restored state (graceful degradation)
- `zmxVersion` mismatch on sessions.json entry → reaper-style cleanup of that entry

**Testing strategy**
- Unit tests: SessionStore round-trip + migration (mirrors `CatalogCodableTests`)
- Unit tests: ZmxClient message framing against a recorded socket transcript (no daemon needed)
- Integration test: spawn a real zmx, do `attach → write bytes → snapshot → restart → reattach`, assert byte equality of buffer. Add to `TouchCodeRuntimeTests`.
- User tests: AC1–AC8 mapped 1:1 in `docs/user-tests/pane-resume.md` by `/hs-test-spec`.

**Migration / rollback**
- First release: no migration. Users without sessions.json get cold-start behavior identical to today.
- Rollback strategy: if Resume causes regressions, ship a hotfix that defaults the Setting OFF and short-circuits to cold start; existing daemons are reaped by the next launch.
- Architecture invariant: app must continue to function correctly if every daemon refuses to start (worst case: every Pane cold-starts).

**Performance**
- Per-byte latency: socketpair hop ~1µs, plus zmx's poll loop wake. Negligible vs. 1-frame (16ms) render budget.
- Throughput: `cat /dev/zero` style stress is bounded by the OS pipe buffer + scheduler; expect comparable behavior to today's in-process fork.
- Memory per daemon: ~3-5MB resident (Zig binary + ghostty-vt scrollback ring). 30 Panes ≈ 100MB total background residence — acceptable.
- App launch time: enumerate sessions.json + parallel `connect()` to all sockets. Bounded by slowest connect (target < 200ms for 30 sessions). Cold paths (no sessions.json) unaffected.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| libghostty External backend has hidden assumptions on PTY-only behavior (termios state polling, ioctl quirks, signal handling) that don't translate to socketpair | Medium | High | Build the External backend on a fork; run touch-code's existing terminal smoke tests + ghostty-vt's own test corpus; iterate before upstream-PRing. Have a clean Exec-backend fallback per-Pane via env var override (`TC_FORCE_EXEC=1`) |
| zmx upstream introduces protocol-breaking changes between releases (README explicitly warns about this) | High | Medium | Pin zmx to a specific submodule commit; treat upgrades as design-doc-bumping events. `zmxVersion` in sessions.json forces reaping on bump. |
| Daemon fails to detach properly on some macOS versions (signed/notarized binary subtleties with `setsid`) | Low | High | Verify in a smoke test on every macOS minor we support. zmx already daemonizes correctly per code inspection; risk is environmental, not code. |
| Snapshot file corruption (partial write on power loss) causes daemon to refuse `--restore-from` | Medium | Low | Daemon falls back to cold start on parse failure (graceful). For extra safety, daemon can write `.snap.tmp` + rename atomically — small zmx patch |
| Per-user disk fills up with stale snapshots if app never relaunches (reaper never runs) | Low | Low | Snapshots are bounded by scrollback cap (10K lines × 30 panes ≈ <100MB total). Reaper runs on every launch. Manual cleanup via `tc session prune` (nice-to-have). |
| User has system-wide `zmx` installed and `ZMX_DIR` collides | Medium | Medium | Always set `ZMX_DIR=~/Library/Caches/touch-code/zmx-sessions` via env when spawning our zmx binary; user's separate zmx instance keeps its own dir. Document the convention. |
| Two touch-code instances running simultaneously fight over the same Pane's daemon | Low | High | sessions.json has no app-instance ID, so the second instance would attempt to attach. Daemon rejects second attach (single-client v1). UI shows error → user closes the second instance. Document; revisit if multi-instance becomes a goal. |
| External backend's `external_resize` action is missed by Swift code → daemon's PTY size never matches surface size → garbled rendering | Low | High | Cover with an integration test that drives surface resize and asserts zmx daemon's `ws_col`/`ws_row` (via `.Info` IPC reply). |

---

**Open Questions** (carried forward to implementation, not blocking spec/design approval)

- **OQ1.** Submodule strategy for zmx: add new submodule pointing at upstream, or vendor by copy-paste? Submodule is preferred (matches ghostty pattern) but it brings Zig build at first-clone overhead. *Leaning:* submodule.
- **OQ2.** Should the daemon spawn the shell with `$SHELL -l` (login) like zmx default, or inherit the current Pane.command convention? *Leaning:* mirror the current Pane fork behavior exactly to avoid regressions.
- **OQ3.** Where exactly does the `external_resize` action surface in Swift? Reuse `GhosttyActionDecoder` machinery or add a parallel callback? *Leaning:* extend the decoder — keep one action-routing path.
- **OQ4.** When `--restore-from` is supplied, do we also pass `--cwd`? The snapshot encodes pwd via OSC 7, but the shell child still needs a starting cwd. *Leaning:* yes, pass `--cwd` always; OSC 7 affects display state only.
- **OQ5.** Pane was running a TUI (e.g. nvim) at snapshot time. On replay (snapshot tier), the buffer shows the TUI frame but the fresh shell is at $ prompt. UX: confusing. Should we annotate snapshot-tier replays with a banner / first line of fresh output ("─── new shell ───")? *Leaning:* yes, daemon injects a divider line after `--restore-from` and before shell's first byte.

---

**Downstream artifacts:**
- `/hs-test-spec` → `docs/user-tests/pane-resume.md` binding to AC1–AC8 from the spec
- `/hs-planner` → execution plan covering: ghostty patch, zmx vendor + patch, External backend wiring in Swift, SessionStore, reaper, Settings toggle, end-to-end integration test
