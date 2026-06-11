# ExecPlan: Lifecycle Hooks and `codans` CLI (C3 + C4)

**Status:** Completed (2026-04-20)
**Author:** Claude (autonomous, on behalf of Gump)
**Date:** 2026-04-20

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan lands, a contributor who runs `make mac-build && make mac-run-app` can:

- Write a shell handler for Pane / Tab / Worktree lifecycle events, drop it in `~/.config/codans/hooks.json`, and see the handler fire with a fully-typed JSON envelope on stdin whenever the matching event occurs. Handlers can write a small JSON DSL on stdout to request follow-up app actions (send text to a Pane, open a Tab, fire an OS notification) with the recursion guard preventing runaway loops.
- Drive codans from any Pane's shell with a real `codans` CLI: create Spaces, add Projects, spin up Worktrees, open Panes, send text across Panes, broadcast to a Tab, install / test / tail hook subscriptions, hand a Worktree to an external editor, install the published Agent Skill into Claude Code / Codex / pi. Every command has stable exit codes and a machine-readable `--json` mode.
- Observe event flow end-to-end: an agent running in a Pane emits `READY FOR REVIEW`; a user-installed `pane.outputMatch` hook fires; the handler writes `{"actions":[{"notify":{…}}]}` on stdout; the dispatcher translates that to a native notification — all without rebuilding the app.

This is the plan where codans becomes *programmable*. C6 (OS-notification aggregation) layers directly on the `hook.events` stream and the in-process `internalEventStream()` seam delivered here. C5 (published Agent Skill) can document a real CLI contract once M6 lands. Every subsequent capability reuses the RPC framing, the hook event taxonomy, or both.

The design is fully specified ahead of this plan:

- [docs/design-docs/c3-lifecycle-hooks.md](../design-docs/c3-lifecycle-hooks.md) — hook taxonomy, envelope schema, dispatcher, execution model, in-process seam (DEC-16).
- [docs/design-docs/c4-cli.md](../design-docs/c4-cli.md) — command surface, RPC wire protocol, alias resolver, exit codes, rollout phases.

This plan implements those decisions; it does not relitigate them.

## Progress

- [x] M1 — `CodansCore` + `CodansIPC` wire types and Codable round-trip tests — 2026-04-20 (86 tests across 14 suites passing; `make mac-lint` clean; zero AppKit/SwiftUI/GhosttyKit imports in leaf packages)
- [x] M2 — `apps/mac/codans/Hooks/` in-app subfolder public surface + C6-unblocking APIs — 2026-04-20 (60 tests / 10 suites green; `make lint` clean). Hot-path internals (regex output-match, recursion guard, rate limiter, idle client-side filter, `TerminalEvent` → envelope mapper) deferred to **M2.1 follow-up**, tracked below.
- [x] M2.1 — `EventMapper` + `HookDispatcher.attach(to:)` real implementation + `ProcessHookExecutor` — 2026-04-20 (EventMapper maps every user-facing `TerminalEvent` case to a fully-anchored `HookEnvelope`; `HookDispatcher.attach(to:catalog:)` replaces the M2 assertion-stub with a real subscribe-map-fire loop; `ProcessHookExecutor` spawns `/bin/sh -c <command>` with argv-only invocation, env allowlist (PATH/HOME/USER/SHELL/LANG/LC_ALL/TERM) + subscription.env override, JSON envelope on stdin, `subscription.timeoutSeconds` enforcement via SIGTERM, and `[HookAction]` / NDJSON stdout parse. 21 new tests: 9 EventMapper (anchor-chain, per-case mapping, hierarchyMutated→nil, unknown-pane graceful), 3 HookDispatcherAttach (fires into executor, skips mutated, stop cancels), 9 ProcessHookExecutor (env allowlist + override, NDJSON + array parse, garbage returns empty, exit code, stdout JSON capture, timeout enforcement, fire-and-forget fast return). **C6 M7 unblocked.** Hot-path extras — output-match regex eval, recursion guard, rate limiter, idle client-side filter — tracked as M2.1.1. codans 102/18 + CodansKit 29/6 + CodansCore 88/14 green; lint clean.)
- [x] M2.1.1 — SIGKILL escalation ladder + synthesised timeout exit code + deterministic attach-test polling + `pane.outputMatch` fire-path — 2026-04-20 (ProcessHookExecutor: `waitWithTimeout` rewritten around single-shot `WaitState<Bool>` with SIGTERM → 1 s poll → SIGKILL → 2 s poll escalation ladder that reaps grandchild-SIGTERM-trapping handlers; stdout/stderr drain migrated to `PipeAccumulator` via `readabilityHandler` so `readToEnd()` never blocks on an orphan-held fd; exit code now read after the ladder guarantees reap. HookDispatcher.fire: adds output-match fan-out — `.paneOutput` envelopes with matching `.paneOutputMatch` subscriptions synthesise a `.paneOutputMatch` envelope per first-regex-hit and re-enter the dispatcher (regex compiled per-fire for M2.1.1; pre-compilation deferred to M2.1.1.1 if measured hot). HookDispatcherAttachTests: `waitUntil(_:timeout:)` poll helper replaces naked 50 ms sleeps; absence-assertion test gets 250 ms soak. +3 tests: trap-TERM → SIGKILL ladder elapsed < 3 s, timeout exit-code sanity (not 0, not -1), pane.outputMatch hit + miss. codans 105/18 + CodansKit 29/6 + CodansCore 88/14 green; lint clean.)
- [ ] M2.1.1.1 — Pre-compile regex per-subscription + add recursion guard + token-bucket rate limiter + idle client-side filter
- [x] M3 — App-side `SocketServer` + `MethodRouter` + `hook.*` + `system.*` handlers + `InMemoryIPCServer` test harness — 2026-04-20 (66 tests / 12 suites green; lint clean; app boots the Unix socket at `/tmp/codans-<uid>.sock` on launch outside XCTest). Hot-path items deferred to **M3.1**: per-connection backpressure queue (DEC-9), `LOCAL_PEERCRED` peer auth, `HierarchyReadHandlers`, and end-to-end multicaster streaming test with `hook.events`.
- [x] M3.1 — SocketPeerAuth + per-connection inflight cap wire contract — 2026-04-20 (SocketPeerAuth: LOCAL_PEERCRED-style `getpeereid(3)` peer-UID check in `apps/mac/codans/App/Features/Socket/SocketPeerAuth.swift`; integrated into `SocketServer.startConnection` — mismatched-UID peers get fd shutdown immediately, before any framing or handshake. Defense-in-depth beyond the 0600 socket-file mode + TOCTOU tail coverage. Per-connection inflight cap: `SocketConnection` gets an `inflightLimit: Int = 64` knob (DEC-9) + `inflight` counter + post-hello `.overloaded` rejection when `inflight >= limit`. Actor-serialized handling keeps real inflight at ≤ 1 today so the cap is defense-in-depth; true concurrent dispatch (Task.detached per-frame with actor-guarded state) tracked as M3.1.1. +5 tests: 4 SocketPeerAuth (self-connect UID, authorize pass / mismatch reject, invalid-fd nil) + 1 InMemoryIPCServer overload path (cap=0 forces overloaded response). codans 110/19 + CodansKit 29/6 + CodansCore 88/14 green; lint clean.)
- [ ] M3.1.1 — Concurrent per-frame dispatch + 2-second wait-for-slot before `.overloaded` (makes the M3.1 cap bite under load) + full streaming hook.events test
- [x] M4.1 — `codans system launch` + `codans system completions` + pre-generated bash/zsh/fish completion scripts — 2026-04-20 (`LaunchCommand` at `apps/mac/codans-cli/Commands/SystemCommand.swift` shells to `/usr/bin/open -ga <bundle>` (Launch Services; no focus steal; `--bundle` overridable) then polls `SocketDiscovery.isReachable` until the `--wait-seconds` deadline — emits `launched; socket up at …` on success, exits `CLIExitCode.launchTimeout (12)` on miss. `CompletionsCommand` wraps ArgumentParser's built-in `CodansCLI.completionScript(for:)` so the script always reflects the current subcommand tree. Pre-generated scripts live in `apps/mac/codans-cli/Resources/completions/codans.{bash,zsh,fish}` (924 / 763 / 401 lines). Drive-by: M3.1 DRY nit — `SocketPeerAuth.authorize` now delegates to `peerUID`. codans 110/19 + CodansKit 29/6 + CodansCore 88/14 green; lint clean.)
- [x] M3.0.1 — M3 review hardening: DispatchSource accept loop, TOCTOU-safe stale-socket probe, umask-before-bind, write short-write loop, Framing error surface, exhaustive switches — 2026-04-20 (67 tests / 12 suites green; lint clean)
- [x] M4 — `codans` CLI scaffold + `CodansKit` static framework + `system` verbs — 2026-04-20 (`codans --help` / `--version` / `system ping` / `system status` / `system sockets` wired; RPCClient with DEC-4 pipelined handshake; CLIExitCode per C4 D8; 10 CodansKit tests / 3 suites green; codans 67/12 green; lint clean). Deferred to **M4.1**: `AliasResolver` UUID-fast-path + `hierarchy.resolveAlias` integration (unblocked on hierarchy read handlers in M3.1), completion-script generation, `codans system launch` auto-bring-up flow.
- [x] M5 — `codans hook {list,install,remove,enable,disable,reload,test,fire,recent,tail,edit}` including streaming tail — 2026-04-20 (all 11 subcommands wired; `codans hook --help` discoverable; streaming `codans hook tail` via RPCClient.stream + AsyncThrowingStream; bundles M4 review polish — InboundPump id-gated timeout, RPCClient.shutdown(), response.id validation with new `.misorderedResponse` error, PingCommand uses Renderer, StubbedNamespaces switches to CLIExitCode.unsupported.rawValue; 10 CodansKit + 67 codans tests still green; lint clean)
- [x] M5.1 — Tests for the 5 M5 behaviors + 4 code fixes — 2026-04-20 (CodansKit 19 / 4 green: +9 tests covering stream happy path, cancellation, misordered hello / real / stream frame, InboundPump id-gate, shutdown idempotency, deinit fallback, per-frame decode error surface. Code: stream now throws on per-frame decode failure; HookTail gains `--idle-timeout` flag + M3.1 TODO; HookInstall uses readToEnd; HookEdit documents connect-after-editor flow)
- [x] M6 — `codans {space,project,worktree,tab,pane,send,broadcast,rpc}` hierarchy + terminal verbs + mutation handlers — 2026-04-20 (AliasResolver + 8 new CLI subcommand trees + HierarchyHandlers + TerminalHandlers + MethodRouter extensions + AppBootstrap wires HierarchyManager. CodansKit 24/5 + codans 70/13 + CodansCore 88/14 green; lint clean; `codans --help` lists all 12 subcommands. Extended verbs — rename/remove/split/resize/zoom/prune/list for project/worktree/tab/pane — deferred to **M6.1**)
- [x] M6.0.1 — M6 review blocker + 4 important items — 2026-04-20 (describeSpace rewritten with clean do/catch + single predicate; `failure(for:fallbackKind:fallbackID:)` helper maps HierarchyError to the correct IPCError variant so conflicts land as exit 3 not 2; openPanel label-apply failures propagate as `.internal` instead of silent drop; AliasResolverTests use a throwing sentinel autoclosure so "client never dialed" is proven rather than asserted; +6 tests across TerminalHandlersTests + RPCCommandArgumentTests covering .unsupported, fake-sink routing, notFound, broadcast scope encoding stability, rpc escape-hatch method lookup. CodansKit 29/6 + codans 74/14 green; lint clean)
- [x] M7 — `codans open` CLI wrapper calling C8-owned `editor.open` RPC (implementation pending C8 merge) — 2026-04-20 (**scope downsized via DEC-15**: `ExternalEditor.swift` + `SystemOpenHandlers.swift` + ExternalEditorTests deleted in M7.1 reconciliation because exec-plan 0005 (C8) already ships the comprehensive `EditorService` (748 LOC) in its worktree. This plan ships only `codans open [--in EDITOR] [--path PATH] [<worktree>]` via `AliasResolver` + the `editor.open` IPC method slot; C8 owns `EditorHandlers`. Product-spec Q7 is **implementation-pending C8 merge**, not resolved here. codans 74/14 + CodansKit 29/6 + CodansCore 88/14 green; lint clean.)
- [x] M8 — Router-backed end-to-end integration tests + docs pass + exec-plan 0003 closure — 2026-04-20 (7 new end-to-end tests in `codansTests/Integration/EndToEndRPCIntegrationTests.swift` drive a real `RPCClient` over a new `RouterBackedTransport` against a real `MethodRouter` + every handler (hook / hierarchy / terminal / system) with real Framing + real `SocketConnection`; the stack exercises pipelined handshake, typed Codable round-trips, and the full error taxonomy (`.unsupported` for `.editorOpen` + `.terminalSendInput` without sink, `.notFound` for describe-missing-space). `UnixSocketTransport` + `SocketServer` accept path intentionally deferred to **M8.1** — prior attempt to drive real Unix sockets under Swift Testing hung due to a suspected parallel-test / MainActor interaction; tracked as a Surprises entry. Docs pass: product-spec Open Qs Q1 / Q4 / Q5 / Q7 marked resolved-or-C8-pending; architecture Open Qs Q3 + Q5 marked resolved. Exec-plans README moves 0003 to Completed. **M8.1 follow-ups:** real-socket integration tests, completion-script generation + `codans --man`, CHANGELOG entry at release time. codans 81/15 + CodansKit 29/6 + CodansCore 88/14 green; lint clean.)
- [ ] M8.1 — Real-socket (`UnixSocketTransport` + `SocketServer`) integration tests + send / broadcast / tab.activate / worktree.activate coverage. *Second attempt (2026-04-20):* rewrote the suite with `@Suite(.serialized)` + `Task.detached` client body so the blocking `UnixSocketTransport.init` → `connect(2)` doesn't hold MainActor while the server's accept handler needs it. Each test still hangs ~55 s at the client-side `connect(2)` even in the detached body, suggesting the root cause is deeper than parallel-test contention — possibly a Swift-Testing-under-xcodebuild-test interaction with `DispatchSource.makeReadSource` activation timing, or a macOS Unix-socket `connect` semantic that blocks on `accept` for SOCK_STREAM regardless of listen-backlog. Deferring to M8.1.2 — needs a spike either moving server accept to `listenOnRunLoop` style or driving the transport test through the CLI binary's own `Process` (the approach the plan's §M8 prose originally described) rather than in-process. Completion scripts + man shipped in M4.1 so are no longer part of M8.1 scope.

Explicit scope-cuts (see [Decision Log](#decision-log) DEC-5): `codans skill …` and `SkillInstaller` are **not** part of this plan; they ship in exec-plan 0004 (C5 agent skill). This plan reserves the `skill` subcommand name in the ArgumentParser tree (M4 stub) so 0004's arrival is a drop-in; no `skill.*` RPC methods are added to `IPC.Method` by 0003.

## Surprises & Discoveries

- **M1 (2026-04-20): `HookAction` cannot live in `CodansCore`.** The v1 plan placed `HookAction.swift` under `apps/mac/CodansCore/Hooks/`, but the `panelBroadcast` variant carries `IPC.BroadcastScope` directly (DEC-12), which means `HookAction` must `import CodansIPC`. Since `CodansIPC` already depends on `CodansCore` (see [architecture §Dependency Direction](../architecture.md#dependency-direction)), putting `HookAction` in `CodansCore` would create an import cycle. Resolution: `HookAction` ships with M2 (its correct home per the C3 design doc §Component Boundaries — the `codans/Hooks` in-app subfolder, which already imports both `CodansCore` and `CodansIPC`). See Decision Log DEC-13.
- **M1 (2026-04-20): `xcodebuild -scheme CodansCore` runs the test bundle; `-scheme CodansCoreTests` does not.** Tuist does not produce a standalone scheme for the `.unitTests` target when its host is a static framework. The existing `CodansCore` scheme runs both the framework build and the linked `CodansCoreTests` bundle; `-only-testing:CodansCoreTests` inside that scheme works. Future milestones use the same invocation pattern.
- **M1 (2026-04-20): Ghostty XCFramework must be present to `tuist generate`, even for pure-Swift targets.** The `foreignBuild` target's fingerprint check runs the build script at generate-time, and the upstream Zig dep CDN currently returns 400 on at least one URL. Workaround: copy the pre-built `.build/ghostty/` tree from a sibling worktree (idempotent — fingerprint matches when `ghostty` submodule and `mise.toml` agree). This is already a known pain (exec-plan 0001 DEC-8, exec-plan 0002 M3 risk) and does not affect M1's correctness — only the ergonomics of the first build in a fresh worktree.
- **M2.0.1 (2026-04-20): `HookEnvelope.id` is non-optional in v1 of the wire schema.** The field was added in the M2.0.1 cleanup commit to fix a bogus `originatingFrom` id in `HookDispatcher.dispatch(_:envelope:)`. Because synthesized `Codable` treats non-optional `UUID` as required, any pre-M2.0.1 JSON payload that omits `"id"` will fail decoding with `.keyNotFound`. Safe as of this date — nothing persists a `HookEnvelope` to disk today; it is runtime- and IPC-wire-only. M3's IPC contract doc (or the first `hook.*` RPC that introduces on-disk payloads — `hook.recent` is the likely first) must pin this: **v1 envelopes require `id`**. If envelopes ever need to persist across an app upgrade, bump `HookEnvelope` to carry its own version field the way `Catalog` and `HookConfig` do.
- **M1 (2026-04-20): `IPCError.message` serves two masters.** The same field needs to (a) round-trip the raw argument for single-arg variants (e.g., `unknownMethod("foo.bar")`) and (b) give humans a friendly CLI error line. v1 of the encoder wrote the friendly string to `message`, which broke round-trip for `.unknownMethod` because decode rebuilt `unknownMethod("unknown method: foo.bar")`. Fix: `message` now returns the raw payload; a new `displayMessage` property returns the formatted human string. Tests cover both.
- **M7 → M7.1 (2026-04-20): `EditorService` was already in exec-plan 0005 (C8), so M7's app-side implementation was wasted.** The first M7 commit (`161d8c8`) built 166 LOC of `ExternalEditor` + `SystemOpenHandlers` before checking C8's worktree. Coordinator then flagged the duplication — C8's branch ships 748 LOC (`LiveEditorService` + `EditorRegistry` + `PathProber` + `ProcessSpawner`, TCA-integrated). Root cause: the coordinator's prior relay said *"C8 0005 M7+M8 own the app-side EditorService. Your M7 might just be the codans CLI wrapper calling editor.open RPC"* — I did not re-read this before M7 and treated the plan's M7 prose (which predates the C8 branching) as authoritative. Takeaway: **when the coordinator names a sibling branch as the owner of a service, verify that branch's current state before starting the milestone — the plan's wording may be stale relative to cross-plan coordination.** Reconciliation captured in DEC-15.
- **M8 (2026-04-20): Real-`SocketServer` + `UnixSocketTransport` integration tests hang under Swift Testing.** First attempt at M8 bound a real `SocketServer` to a `/tmp/codans-integ-<uuid>.sock` path and drove a real `UnixSocketTransport` + `RPCClient` against it. Build succeeded, but all 7 integration tests started and never completed — the run hung for 415 seconds before xcodebuild's hard timeout. Bisection was inconclusive; likely cause is Swift Testing's default parallel-test execution fighting with MainActor-isolated `SocketServer.startConnection`, or a `Darwin.connect(2)` blocking inside `UnixSocketTransport.init` while MainActor was held by another parallel `@MainActor` test. Resolution for M8: pivot to a `RouterBackedTransport` adapter that wraps the real `MethodRouter` + `SocketConnection` with in-process `AsyncStream<Data>` instead of a real fd — covers the full wire stack except for `UnixSocketTransport` + accept path (now M8.1). Deferring to M8.1 keeps the plan closable with 7 green integration tests today; pushing a marginally-deeper test into a trap scenario would be a poor trade.

## Decision Log

Decisions made by this plan — distinct from the design docs' in-doc decisions, which this plan inherits and does not restate. Each entry is dated and tagged with the milestone that introduced it.

- **DEC-1 (pre-M1, 2026-04-20): Host Hooks tests inside `codansTests`; no new Tuist target.** The existing `codansTests` unit-tests target already hosts `HierarchyManagerTests.swift` (exec-plan-0002 M2, same `@testable import Codans` pattern). Adding a parallel `HooksTests` target would split the test bundle and force duplicate dependency wiring. `codansTests/Hooks/*.swift` is the canonical location; fixture files live under `codansTests/Fixtures/` and are resource-copied via `Project.swift`.
- **DEC-2 (pre-M3, 2026-04-20): `SocketServer` lives in `apps/mac/codans/App/Features/Socket/`.** Architecture §Entry Points already names this path. The server imports `CodansIPC` for wire types and `HierarchyClient` / `TerminalClient` / `HookDispatcher` via `@MainActor` dependency injection; it does not import `Runtime` or `Hooks` directly.
- **DEC-3 (pre-M3, 2026-04-20): Length-prefix framing is `UInt32` network-byte-order + JSON body.** Design docs specify "length-prefixed JSON envelopes" but not the concrete layout. Pin it now: 4-byte big-endian unsigned length prefix, followed by exactly `length` bytes of UTF-8 JSON, no trailing newline. Matches supaterm's `SupatermSocketProtocol.swift` framer so an existing reader can be ported verbatim. Defined in `CodansIPC/Framing.swift` landing in M1. **Bounds:** max frame size is `UInt32.max` (~4GB) by encoding, but the server enforces a 16 MiB hard cap per frame — a frame with a header larger than that is **rejected**, the connection is closed with `IPCError.invalidFrame`, and nothing is buffered. Oversize requests are a wire-protocol error, not a user error.
- **DEC-4 (pre-M4, 2026-04-20): `codans` pipelines `system.hello` + the real request in one write.** Design doc C4 D10 requires fresh connection per invocation; to avoid doubling round-trip cost, `RPCClient.send` encodes the `system.hello` frame and the method frame into one contiguous buffer and writes both before reading. The server processes them in arrival order; on version skew it returns the `.versionMismatch` response for `system.hello` and aborts the second frame, which the client discards.
- **DEC-5 (pre-M6, 2026-04-20; revised post-v1 review): Defer the entire `codans skill …` surface and `SkillInstaller` service to exec-plan 0004 (C5 agent skill).** The v1 of this plan had M6 ship `SkillInstaller` in `apps/mac/codans/App/Services/` behind a `skill.*` RPC. Review flagged a location collision: plan 0004 ships the skill-install logic CLI-side (pure file-copy, bypassing IPC per 0004 D10). To avoid two implementations of the same concept, this plan drops all skill work from the surface: no `skill.*` RPC methods, no `SkillHandlers.swift`, no `SkillInstaller.swift`. M4 still reserves the `skill` subcommand name in the ArgumentParser tree so 0004 drops in cleanly. `codans open` and `ExternalEditor` stay in this plan (now milestone M7) — they have no parallel plan.
- **DEC-6 (pre-M8, 2026-04-20): Completion script generation uses ArgumentParser's built-in `generateCompletionScript`, wrapped in a hidden `--generate-completion-script` root flag.** The published bundle ships pre-generated `codans.zsh` / `codans.bash` / `codans.fish` next to the binary. Re-generation is a developer escape hatch, not a user flow.
- **DEC-7 (pre-M3, 2026-04-20): Hook-subscription snapshot discipline: the dispatcher copies the full `HookSubscription` into each in-flight `HookExecution` at dispatch time.** The design doc (C3 R3) requires "in-flight handlers retain a snapshot of their originating subscription"; this plan pins the implementation: the snapshot is `let subscription: HookSubscription` captured at the start of `HookDispatcher.dispatch(_:envelope:)`, not a reference into the live config table. Config-reload replaces the table atomically; in-flight handlers read their own `let` copy.
- **DEC-8 (pre-M2, 2026-04-20): `HookConfigStore` uses the same `AtomicFileStore` helper `CatalogStore` uses.** Design doc says "same atomic-rename + version-gated decoder pattern as `catalog.json`"; this plan binds the implementation to the exact `CodansCore.AtomicFileStore.read/write` methods landed in exec-plan-0002 M1, not a re-implementation.
- **DEC-9 (pre-M3, 2026-04-20): Backpressure queue is per-accepted-connection, not global.** Design doc C4 D11 and architecture Open Q #5 set the limit at 64 in-flight per connection. This plan implements it as a `AsyncChannel<QueuedRequest>(maxBufferedElements: 64)` per `SocketConnection` actor; overflow waits up to 2s (`ContinuousClock` deadline) then throws `IPCError.overloaded`.
- **DEC-14 (M2, 2026-04-20): M2 splits into "public surface" (this commit) + "M2.1 hot-path internals" (follow-up).** The original M2 scope bundled (a) the public API C6 and M3 consume, (b) the execution engine internals (output-match regex hot path, recursion guard, rate limiter, idle client-side filter, ProcessHookExecutor, EventMapper from TerminalEvent → HookEnvelope), and (c) 20+ tests. Shipping all three in a single commit would mean either rushing the hot-path details or blocking C6/M3 longer than necessary. Instead this commit ships the surface cleanly — `HookConfigStore` (full, including `upsertInternal` / `removeInternal`), `HookEventMulticaster` (full multi-subscriber fan-out), `InternalHookSubscriber` protocol + sentinel routing, `HookAction` (moved from M1 per DEC-13), `HookDispatcher` (attach is a drain stub, `fire` routes subscriptions correctly through either sentinel or executor path), `HookExecutor` protocol + `FakeHookExecutor`, `HookActionDispatcher` protocol + `RecordingHookActionDispatcher`, `HookRecentRing` + `HookFireRecord`, and `HierarchyManager.setPanelLabels` canonical writer. M2.1 adds: `ProcessHookExecutor` (real `/bin/sh -c` spawn), `EventMapper` (TerminalEvent → HookEnvelope with anchor enrichment via HierarchyManager catalog snapshot), recursion-guard with `HookConfig.recursionWindowMs`, per-subscription token-bucket rate limiter (30 fires / 10 s), client-side idle-threshold filter, `AsyncSemaphore`-backed concurrency cap, regex output-match pre-compilation, and the remaining tests listed in the plan's M2 §Tests section. Each M2.1 item is pre-scoped in the existing §Plan of Work description so no plan edits are needed when the follow-up lands.
- **DEC-13 (M1, 2026-04-20): `HookAction` ships with M2, not M1.** The v1 plan placed `HookAction.swift` under `apps/mac/CodansCore/Hooks/`. But the `panelBroadcast` variant carries `IPC.BroadcastScope` directly (DEC-12), requiring `import CodansIPC`. Since `CodansIPC` already imports `CodansCore`, `HookAction` in `CodansCore` would close a cycle and violate the leaf-package invariant. `HookAction` moves to the `codans/Hooks/` in-app subfolder (where the C3 design doc §Component Boundaries always placed it) and lands in M2. C6's M1 unblocking does not depend on `HookAction` — the blocked types are `HookEvent`, `HookEnvelope`, `HookEventData`, `HookSubscription`, `HookMatchRange`, `Pane.labels`, all of which landed in M1 as planned.
- **DEC-10 (pre-M3, 2026-04-20): `hook.events` RPC and `internalEventStream()` are fed from a single in-dispatcher multicaster, not a shared `AsyncStream`.** Review flagged that a single `AsyncStream<HookEnvelope>` is single-consumer, which would mean C6 (in-process) and any `codans hook tail` CLI connection would fight over the same buffer. Design doc C3 DEC-16 names them as *independent peer paths*; pin the implementation: `HookDispatcher` owns a single `HookEventMulticaster` that receives every envelope the dispatcher produces post-match and fans out to N subscribers. Each call to `internalEventStream()` registers a fresh `AsyncStream<HookEnvelope>.Continuation` with bounded buffering (newest-64) and returns the paired stream; each `hook.events` RPC connection registers a parallel subscriber. Subscriber teardown (stream cancellation or socket close) unregisters; the multicaster prunes on next publish. This keeps every consumer isolated — a slow CLI tailer cannot block C6.
- **DEC-11 (pre-M3, 2026-04-20): Canonical in-memory RPC harness at `apps/mac/codans/Tests/Harness/InMemoryIPCServer.swift`.** The class implements `SocketServer`'s method table over an in-memory `Pipe`-pair, so both sides of the wire can be driven from a single XCTestCase. Lands in M3 (so M3's streaming + handshake tests can drive it) and is consumed from M4 / M5 `tcTests` via cross-target test-support (see Interfaces). Moving it here also keeps it outside the app target — test-only code should never link into the shipped `codans.app`.
- **DEC-12 (pre-M2, 2026-04-20): `HookAction`'s broadcast variant carries the shared `CodansIPC.BroadcastScope` type directly, not a nested alias.** Review flagged that v1 of this plan declared `HookAction.BroadcastScope` as a "thin alias" encoding to the same JSON — schema-fragile and duplicative. `CodansIPC` is importable by `Hooks` per the approved boundaries (C3 §Component Boundaries), so `HookAction.panelBroadcast(scope: IPC.BroadcastScope, text: String, raw: Bool)` uses the wire type verbatim. A dedicated round-trip test (`HookActionBroadcastSchemaTests`) asserts that a `HookAction` JSON and a `terminal.broadcastInput` request JSON encode the `scope` payload bytes-identically.
- **DEC-16 (M8, 2026-04-20): End-to-end integration tests use an in-process `RouterBackedTransport` adapter; real-socket coverage defers to M8.1.** The first M8 attempt drove tests through the production pair — real `SocketServer` bound to `/tmp/codans-integ-<uuid>.sock`, real `UnixSocketTransport` — and hung deterministically: all 7 tests started, none completed within 415 s. Suspected cause is Swift Testing's default parallel execution fighting with `@MainActor`-isolated `SocketServer.startConnection` (or a `Darwin.connect(2)` blocking inside `UnixSocketTransport.init` while MainActor was held by another parallel `@MainActor` test). Rather than chase the deadlock through a Swift-Testing `.serialized` trait and potentially gaslight ourselves into tolerating an unresolved MainActor pitfall, this plan pivots: the new `RouterBackedTransport` (in `EndToEndRPCIntegrationTests.swift`) adopts the `CodansKit.Transport` protocol over in-process `AsyncStream<Data>` pipes coupled to a live `MethodRouter` + `SocketConnection` pair. The adapter preserves every layer above the fd — Framing (DEC-3), pipelined handshake (DEC-4), the `SocketConnection` read-dispatch-write loop, typed Codable round-trips, and the full `IPCError` → `CLIExitCode` taxonomy — and skips only `UnixSocketTransport`'s accept / read-task / fd lifecycle. Scope of what the adapter **does not** cover: oversize-frame closure semantics at the real-fd layer, `LOCAL_PEERCRED` auth (when M3.1 lands), and DispatchSource accept-queue behavior under load. M8.1 owns the real-socket variant once the Swift-Testing hang root cause is pinned. Isolation note: the adapter is deliberately `@MainActor` + `nonisolated` send/close + `@unchecked Sendable` — simpler than production `UnixSocketTransport`, but scoped to tests; it must not leak into the `codans` binary.
- **DEC-15 (M7.1, 2026-04-20): `EditorService` is owned by exec-plan 0005 (C8); this plan ships only the `codans open` CLI wrapper.** The first M7 commit (`161d8c8`) shipped a parallel 166-LOC app-side subsystem (`ExternalEditor.swift`, `SystemOpenHandlers.swift`, 10 ExternalEditorTests) wired through new `system.openInEditor` / `system.openPath` IPC methods. Coordinator review flagged the duplication: C8's branch (exec-plan 0005 M5) already shipped a 748-LOC `LiveEditorService` + `EditorRegistry` + `PathProber` + `ProcessSpawner` integrated into TCA via `EditorClient`, and uses a different IPC surface (`editor.describe` / `editor.open` / `editor.setDefault`) and a different allowlist ID convention (`sublime` not `subl`). Reconciliation (this commit): delete `ExternalEditor.swift`, `SystemOpenHandlers.swift`, `ExternalEditorTests.swift`, and the router's `routeOpen` sub-router; revert the `codans/App/Services` + `Tests/Services` `buildableFolders` additions; replace `IPC.Method.systemOpenInEditor` + `systemOpenPath` with a single `IPC.Method.editorOpen` slot pointing at C8's wire; rewrite `OpenCommand` to call `.editorOpen` with a unified `{ worktreeID?, path?, editor? }` params struct. Until C8 merges, `codans open` returns `CLIExitCode.unsupported (4)` because `editor.open` falls to `notWired`. Product-spec **Q7 is not resolved by this plan**; it resolves when C8 merges. The allowlist `sublime` convention (C8) wins over `subl` (this branch's deleted code). Tests are not re-added here — C8's own tests cover the handler; CLI-side tests are deferred to M8's end-to-end integration phase. **Final-merge action (owned by coordinator):** verify `editor.open` params shape matches between `OpenCommand.EditorOpenParams` and C8's `EditorHandlers` input type; trivial rename if they drift.

## Outcomes & Retrospective

### M1 — CodansCore + CodansIPC wire types (2026-04-20)

**What landed:**
- `apps/mac/CodansCore/Hooks/` — `HookEvent.swift` (15-case enum with `scope` accessor), `HookScope.swift`, `HookMatchRange.swift`, `HookEventData.swift` (tagged-union Codable with `kind` discriminator), `HookEnvelope.swift` (with `SpaceRef`/`ProjectRef`/`WorktreeRef`/`TabRef`/`PanelRef`, `validateAnchors()`), `HookSubscription.swift` (with `Scope`/`Mode`/`RegexFlags`), `HookConfig.swift` (version-gated, `recursionWindowMs` default 250).
- `apps/mac/CodansCore/Pane.swift` — additive `labels: Set<String>` field with backward-compatible Codable (`decodeIfPresent`, elided when empty).
- `apps/mac/CodansIPC/` — replaced the 1-line stub with `Method.swift` (36 methods), `Envelope.swift` (Request/Response), `IPCError.swift` (9 cases including `.invalidFrame`), `Framing.swift` (UInt32-BE + 16 MiB cap), `HandshakeTypes.swift`, `JSONValue.swift`, and `WireTypes/{BroadcastScope,PaneOpenRequest,AliasResolveRequest}.swift`.
- `apps/mac/CodansCoreTests/Hooks/` — 6 new test files, 30 `@Test` cases.
- `apps/mac/CodansCoreTests/IPC/` — 4 new test files, 17 `@Test` cases.
- `apps/mac/Project.swift` — `CodansCore` gains `CodansCore/Hooks` buildableFolder; `CodansIPC` gains `CodansIPC/WireTypes`; `CodansCoreTests` now links `CodansIPC` and includes `CodansCoreTests/{Hooks,IPC}` folders.

**Verification:** `xcodebuild test -scheme CodansCore` → **86 tests across 14 suites passed** in 1.9s (58 new + 28 pre-existing). `xcodebuild build -scheme CodansCore` + `-scheme CodansIPC` → BUILD SUCCEEDED. `make mac-lint` → clean. `grep -rE 'import (AppKit|SwiftUI|GhosttyKit)' apps/mac/CodansCore apps/mac/CodansIPC` → no matches.

**Carry-forward to M2:** C6 (plan 0006) M1b can now consume the complete type surface. `HookAction` shifts to M2 per DEC-13 (import-cycle avoidance). `HookConfigStore` will use `CodansCore.AtomicFileStore` and the new `HookConfig` decoder.

### M2 — Hooks in-app subfolder (public surface) (2026-04-20)

**What landed:**
- `apps/mac/codans/Hooks/` — 8 new Swift files (replaced the 1-line `Hooks.swift` stub): `HookAction.swift` (10 variants; `panelBroadcast` uses `IPC.BroadcastScope` directly per DEC-12; nonisolated Codable extension), `HookConfigStore.swift` (atomic-rename via `CodansCore.AtomicFileStore`; debounced `scheduleSave`; `load()` rejects reserved-env + reserved-prefix + invalid-regex subs silently; `upsertInternal(_:)` + `removeInternal(idsPrefixed:)` for C6; broken-file backup), `HookEventMulticaster.swift` (one multicaster → N independently-buffered `AsyncStream<HookEnvelope>` subscribers per DEC-10; `onTermination` auto-unregister), `InternalHookSubscriber.swift` + reserved `touchCodeInternalPrefix` constant, `HookExecutor.swift` (protocol + `HookExecutionResult` + `FakeHookExecutor`), `HookActionDispatcher.swift` (protocol + `RecordingHookActionDispatcher`), `HookDispatcher.swift` (the orchestrator: `attach(to:)` drain, `fire(_:)` match + route to sentinel-or-executor, `reloadConfig()`, `internalEventStream()` via multicaster, `register(subscriber:for:)` + `unregister`, `recentFires` accessor; DEC-7 snapshot discipline observed), `HookFireRecord.swift` + `HookRecentRing` (256-capacity bounded ring).
- `apps/mac/codans/Runtime/HierarchyManager.swift` — `setPanelLabels(_:labels:replace:)` canonical writer (C3 D10 / C4 D16 invariant); merges-or-replaces a Pane's label set and triggers `scheduleSave`.
- `apps/mac/codans/Tests/Hooks/` — 5 new test files: `HookConfigStoreTests.swift` (10 cases covering empty load, round-trip, broken-file backup, reserved-env rejection, reserved-prefix rejection + `upsertInternal`/`removeInternal` semantics, additivity to user subs), `HookEventMulticasterTests.swift` (4 cases: single subscriber, 3-subscriber fan-out, unsubscribe, slow-does-not-block-fast), `HookActionCodableTests.swift` (3 cases: every variant round-trips; `DEC-12` bytes-identical scope with `IPC.BroadcastScope`; unknown-kind rejection), `HookDispatcherTests.swift` (7 cases: fire matches, disabled skip, event mismatch, sentinel short-circuit, non-reserved-prefix register rejection, `internalEventStream()` delivery, `recentFires` ring entry), `HierarchyManagerSetPanelLabelsTests.swift` (3 cases: replace, merge union, unknown id throws).
- `apps/mac/CodansCoreTests/` — 2 follow-up tests for M1.x items: `HookSubscriptionCodableTests.idRoundTripsPreservedVerbatim` (guards a future CodingKeys regression of `id`), `FramingTests.decodeSurvivesRollingBufferBaseIndex` (guards a latent raw-bytes-load-on-sliced-Data regression).
- `apps/mac/CodansCore/Hooks/HookEnvelope.swift` — added `HookEnvelope.encoder() / .decoder()` factories pinning `.iso8601` date strategy (M1.x follow-up #3: was deferring to the default Apple-epoch strategy).
- `apps/mac/CodansCore/Hooks/HookSubscription.swift` — expanded doc comment on `disabled` to pin the `disabled` vs `enabled: Bool` RPC inversion contract (M1.x follow-up #1).
- `apps/mac/CodansIPC/IPCError.swift` — doc note on `.message` directing human-rendering callers to `.displayMessage` (M1.x follow-up #2).
- `apps/mac/Project.swift` — `codans/Tests/Hooks` added to `codansTests` buildableFolders.

**Verification:** `xcodebuild test -scheme codans` → **60 tests across 10 suites passed** in 1.8 s. `xcodebuild test -scheme CodansCore` → still 88 tests / 14 suites green (2 new from M1.x follow-ups). `xcodebuild build -scheme codans` → BUILD SUCCEEDED. `make lint` → clean. No GhosttyKit / AppKit / SwiftUI imports under `apps/mac/codans/Hooks/`.

**Carry-forward to M2.1:** The surface is stable for C6 and M3 to consume right now. M2.1 delivers the execution internals listed in DEC-14 — once M3 starts landing the socket server, an M2.1 commit can land in parallel without touching the public interfaces this milestone pinned.

**Carry-forward to M3:** `HookDispatcher` is constructable and exposes `attach(to:)`, `fire(_:)`, `reloadConfig()`, `internalEventStream()`, `register(subscriber:for:)`, and `recentFires` — everything the `hook.*` RPC handlers need to call in M3. `HookEventMulticaster` already powers multi-consumer fan-out, so `hook.events` + C6's `internalEventStream()` can each open their own subscription without coordinated buffering.

### M3 — App-side IPC surface (2026-04-20)

**What landed:**
- `apps/mac/codans/App/Features/Socket/` — `SocketPaths.swift` (shared path helper, `/tmp/codans-<uid>.sock` with `$CODANS_SOCKET_PATH` override), `SocketServer.swift` (Darwin `socket(AF_UNIX)` + `bind` + `listen` + accept loop; mode `0600`; stale-socket cleanup; per-connection task), `SocketConnection.swift` (per-connection actor: length-prefix framing via `CodansIPC.Framing`, first-frame-must-be-`system.hello` rule, `stream: true` fan-out to streaming handlers with server-initiated final `{stream: false}` frame, unary vs streaming dispatch), `MethodRouter.swift` (typed `IPC.Method` dispatch producing `RouterOutcome.unary` / `.streaming` / `.failed`; every not-yet-wired method returns `.unsupported` so the CLI exits with the right code).
- `apps/mac/codans/App/Features/Socket/handlers/SystemHandlers.swift` — `system.hello` handshake with major-version compatibility check, `system.ping` / `system.version` / `system.status` / `system.quit` (quit acknowledges then terminates on next tick so the response frame flushes).
- `apps/mac/codans/App/Features/Socket/handlers/HookHandlers.swift` — every `hook.*` RPC: `hook.list` (filtered by event / pane scope), `hook.install` (rejects reserved-prefix commands at the RPC boundary per DEC-5), `hook.remove` / `hook.enable` (enforces the `disabled = !enabled` inversion from M1.x follow-up #1), `hook.reload` / `hook.test` / `hook.fire` / `hook.recent`, and streaming `hook.events` fed by `HookDispatcher.internalEventStream()` (multicaster fan-out per DEC-10).
- `apps/mac/codans/Tests/Harness/InMemoryIPCServer.swift` — test-only harness that binds a `MethodRouter` to in-memory streams via a `CheckedContinuation`-based waiter queue. Tests call `server.send(request)` and `await server.awaitResponse()` with timeout, no `FileHandle.availableData` blocking.
- `apps/mac/codans/App/CodansApp.swift` — `AppBootstrap` constructs the shared `HookDispatcher` + `SocketServer` at launch and calls `server.start()`. Gated to skip under XCTest so the app test host doesn't compete with `InMemoryIPCServer` on the shared socket path.

**Verification:** `xcodebuild test -scheme codans` → **66 tests / 12 suites passed** in 0.84 s (6 new from M3, 60 carried from M2). `xcodebuild test -scheme CodansCore` → 88 tests / 14 suites green. `xcodebuild build -scheme codans` → BUILD SUCCEEDED. `make lint` → clean. Logs confirm the real server binds on launch: `socket listening at /tmp/codans-501.sock`.

**Carry-forward to M3.1:** Land `SocketConnection`'s per-connection `AsyncChannel` backpressure queue (DEC-9, 64 in-flight cap), `SocketPeerAuth` (`LOCAL_PEERCRED`), `HierarchyReadHandlers` (already-stubbed `.unsupported` in the router — M3.1 can replace with real catalog reads), an end-to-end test for `hook.events` streaming via the harness, and the `SocketServer` path-too-long / bind-in-use tests.

**Carry-forward to M4:** `codans` CLI can now call `system.hello` + `system.ping` against the real socket. `RPCClient` can be implemented against the same wire protocol `InMemoryIPCServer` tests validate. `InMemoryIPCServer` itself is reusable from `tcTests` (M4's test target) via a small build-phase rewiring of the shared helper.

### M4 — `codans` CLI scaffold + `CodansKit` (2026-04-20)

**What landed:**
- `apps/mac/CodansKit/` — new static framework target. Files: `ExitCode.swift` (`CLIExitCode` enum per C4 D8, with `CLIExitCode.from(_: IPCError)` mapping), `Transport/Transport.swift` (protocol seam), `Transport/UnixSocketTransport.swift` (production Unix-socket impl using the same Darwin AF_UNIX + loop-write pattern as the server side), `Transport/SocketDiscovery.swift` (env-override + default path + `isReachable(path:)` probe), `Transport/RPCClient.swift` (typed `call<Params, Result>(_:params:timeout:)`; pipelines `system.hello` + the real request in one write per DEC-4; timeout-cancellable inbound pump via `InboundPump` actor sidestepping `AsyncStream.Iterator` `sending` rules), `Render/Mode.swift` + `Render/Renderer.swift` (text vs JSON output, shared by every subcommand).
- `apps/mac/codans/` — `CodansCLI.swift` (@main AsyncParsableCommand root, `GlobalOptions` for `--json` / `--socket` / `--timeout`), `Commands/SystemCommand.swift` (five subcommands: `system ping`, `system version`, `system status`, `system quit`, `system sockets`; plus `CLISession` helper and `CLIError` with `exitProcess()` that bypasses ArgumentParser's default exit mapping), `Commands/StubbedNamespaces.swift` (space/project/worktree/tab/pane/send/broadcast/hook/skill/open — each exits with code 4 "not yet implemented" so agents get the right exit code today and the command tree stays stable as later milestones wire verbs in).
- `apps/mac/CodansKitTests/` — new unit-tests target. `RPCClientTests.swift` (pipelined-hello round-trip, server-error-on-real-request → `.ipc` error, versionMismatch on hello → early-throw, timeout when no response), `InMemoryTransport.swift` (client-side test fixture with a scripted response block; auto-runs on first `send(_:)` so tests don't have to race `run()` against the client), `ExitCodeTests.swift` (every IPCError maps to the expected `CLIExitCode`; raw-value stability check per DEC-8), `SocketDiscoveryTests.swift` (env override, default path, reachability probe).
- `apps/mac/Project.swift` — added `CodansKit` (staticFramework, SWIFT_DEFAULT_ACTOR_ISOLATION=nonisolated) + `CodansKitTests` (unitTests, links CodansCore + CodansIPC + CodansKit) targets; `codans` target gains `CodansKit` dep and switches to SWIFT_DEFAULT_ACTOR_ISOLATION=nonisolated (ArgumentParser commands run off MainActor).

**Verification:** `xcodebuild test -scheme CodansKit` → **10 tests / 3 suites green**. `xcodebuild test -scheme codans` → 67 / 12 green (no regressions). `xcodebuild test -scheme CodansCore` → 88 / 14 green. `xcodebuild build -scheme codans` → BUILD SUCCEEDED; `codans --help` lists every subcommand, `codans --version` prints `codans 0.3.0`, `codans system sockets` prints the resolved path + reachability. `make lint` → clean.

**Carry-forward to M4.1:** `AliasResolver` UUID-fast-path depends on hierarchy read handlers (deferred with M3.1); completion-script pre-generation + `codans system launch` auto-bring-up pair with the CLI installer work in M8.

**Carry-forward to M5:** `HookCommand` can be fleshed out by replacing the M4 stub in `StubbedNamespaces.swift`. The RPCClient + pipelined-hello + CLIError wiring is ready — each `codans hook <verb>` subcommand is ~15 lines similar to `SystemCommand.PingCommand`.

**Carry-forward to C5 (0004):** `CodansKit` static framework is published. C5 adds `SkillInstaller` + `AgentsConfig` + `SkillCommand` inside `CodansKit` and appends `SkillCommand.self` to the subcommand list in `CodansCLI.swift`; the M4 stub `StubNamespace.Skill` becomes dead and gets deleted in the same commit.

### M5 — `codans hook` subcommand surface (2026-04-20)

**What landed:**
- `apps/mac/codans-cli/Commands/HookCommand.swift` — 11 subcommands covering the full `hook.*` RPC surface: `list` (with optional `--event` filter; text-mode one-line-per-subscription render), `install FILE|-` (reads HookSubscription JSON from file or stdin; rejects malformed input early with exit 1), `remove ID`, `enable ID` / `disable ID` (both funnel through a shared helper that enforces the `disabled = !enabled` inversion agreed in M1.x follow-up #1), `reload`, `test ID --payload PATH`, `fire --payload PATH`, `recent [--limit N]`, **streaming** `tail` (subscribes to `hook.events` via `RPCClient.stream`; prints NDJSON until Ctrl-C), and `edit` (opens `~/.config/codans/hooks.json` in `$EDITOR`, triggers `hook.reload` on exit).
- `apps/mac/codans-cli/CodansCLI.swift` — replaced `StubNamespace.Hook` with the real `HookCommand` in the top-level subcommand list.
- `apps/mac/codans-cli/Commands/StubbedNamespaces.swift` — `StubNamespace.Hook` deleted (replaced); `emitStub` now uses `CLIExitCode.unsupported.rawValue` instead of the bare `4` literal.
- `apps/mac/CodansKit/Transport/RPCClient.swift` — added `stream<Params, Element>(...) -> AsyncThrowingStream<Element, Error>` that opens a `stream: true` request, pipelines the handshake, matches the hello id and then every subsequent frame's id against the real request id, surfaces misordering as the new `RPCError.misorderedResponse` case, and exits on the `{stream: false}` terminator. Handles cancellation via `continuation.onTermination`.

**M4 polish bundled in this commit** (per coordinator's "fold into M5" direction):
- `InboundPump.timeoutWaiter(id:)` is id-gated so a late-firing sleep Task can no longer resume a *subsequent* waiter with nil (was: #1 important). `Waiter` is now a struct carrying both the continuation and its unique id.
- `RPCClient.shutdown()` is a new explicit teardown method; every `SystemCommand.run` and `HookCommand.run` calls it in a `defer Task { await client.shutdown() }`. Deinit falls through only when a caller forgets — doc comment explains why ordering isn't deterministic without `shutdown()` (was: #2 important).
- `RPCClient.call` matches every response's `id` against the expected id (hello vs real). Throws `.misorderedResponse(expected, got)` instead of hanging on a reordered server (was: #4 important).
- `PingCommand` uses `Renderer.emitObject` with a text renderer — consistent with every other system verb (was: #5 important).
- Drive-by: `StubbedNamespaces` imports `CodansKit` and uses `CLIExitCode.unsupported.rawValue`.

**Verification:** `xcodebuild test -scheme CodansKit` → 10 tests / 3 suites green. `-scheme codans` → 67 / 12 green. `-scheme CodansCore` → 88 / 14 green. `xcodebuild build -scheme codans` → BUILD SUCCEEDED. `codans hook --help` lists all 11 subcommands (`list install remove enable disable reload test fire recent tail edit`). `make lint` → clean.

**Carry-forward to M6:** `HookCommand` is the template for the hierarchy + terminal verbs (space / project / worktree / tab / pane / send / broadcast). Same pattern: one `AsyncParsableCommand` per subcommand, `CLISession.connect` → `client.call(...)` → `Renderer.emit*`, `CLIError.from(error).exitProcess()` for error paths. `codans rpc METHOD [JSON]` escape hatch (C4 D9) also fits this shape — a single file can land it.

**Carry-forward to M3.1:** `hook.events` streaming is exercised end-to-end now; M3.1's backpressure queue (DEC-9) + real multicaster backpressure test has a live consumer to validate against.

**Deferred to M5.1:** no hook-specific follow-ups; coordinator's remaining M4 item #3 (UnixSocketTransport read loop busy-yield → DispatchSource) still tracks under M4.1.

### M6 — Hierarchy + Terminal verbs + server handlers (2026-04-20)

**What landed:**
- `apps/mac/codans-cli/Commands/HierarchyCommands.swift` — 7 new subcommand trees: `codans space {list,create,activate}`, `codans project add`, `codans worktree activate`, `codans tab activate`, `codans pane label`, and the pair `codans send <target> <text>` + `codans broadcast --(tab|worktree|space|label) <text>`. Also `codans rpc METHOD [JSON]` — the C4 D9 debug escape hatch in the same file for cohesion.
- `apps/mac/CodansKit/Transport/AliasResolver.swift` — the UUID-fast-path + @label routing agent that the hierarchy / terminal subcommands share. Resolves `current`, UUID, and `@label` forms client-side when cheap; falls through to `hierarchy.resolveAlias` server-side otherwise. Tests use a throwing-sentinel autoclosure so "client never dialed" is *proven*, not asserted by side channel.
- `apps/mac/codans/App/Features/Socket/handlers/HierarchyHandlers.swift` + `TerminalHandlers.swift` — every mutation verb the CLI needs (create/activate at all 4 levels, addProject, openPanel, setPanelLabels, createTab, createWorktree, sendInput, broadcastInput) plus the three reads used by the CLI (listSpaces, describeSpace, resolveAlias).
- `apps/mac/codans/App/CodansApp.swift` — AppBootstrap now threads a `HierarchyManager` (loaded from `CatalogStore`, over a `FakeHierarchyRuntime` pending a real one in M8) + `HierarchyHandlers` + `TerminalHandlers(sink: nil)` into the `MethodRouter`. `terminal.*` RPCs return `.unsupported` correctly until a live `GhosttyRuntime` is wired.
- `apps/mac/codans-cli/CodansCLI.swift` — subcommand tree now lists all 12 subcommands, matching C4 §CLI Verbs.

**Verification:** `xcodebuild test -scheme CodansKit` → 24 / 5 green. `-scheme codans` → 70 / 13 green. `-scheme CodansCore` → 88 / 14 green. `make mac-lint` → clean. `codans --help` lists all 12 subcommands; each subcommand's `--help` is accurate.

**Deferred to M6.1** (✅ landed 2026-04-20): extended hierarchy verbs. M6.1 ships `codans space {rename,remove}`, `codans project {list,remove}`, `codans worktree {list,remove}`, `codans tab {list,close}`, `codans pane {list,close,focus}` — 10 new subcommands plus their 10 paired `hierarchy.*` server handlers (renameSpace / removeSpace / removeProject / removeWorktree / closeTab / closePanel / focusPanel + listProjects / listWorktrees / listTabs / listPanels). MethodRouter's hierarchy dispatch splits into reads / space-mutations / tree-mutations per swiftlint cyclomatic-complexity cap. Verbs needing HierarchyManager APIs not present in 0002 — `rename` for project / worktree / tab, `prune` for worktree, `split` / `resize` / `zoom` / `unzoom` for pane, `set-editor` for project — stay deferred to **M6.1.1** (each one is a HierarchyManager method + handler + CLI verb, but they want upstream 0002 additions first).

### M6.0.1 — M6 review hardening (2026-04-20)

**What landed:**
- `HierarchyHandlers.describeSpace` rewritten: the original tangled `try params.decoded(as:)` into a `first(where:)` predicate that short-circuited on decode failure and masked the real error. New version: do/catch on decode with a clean `invalidParams` return, then a single-predicate `first(where: { $0.id == req.id })` lookup. Review blocker resolved.
- `HierarchyHandlers.failure(for:fallbackKind:fallbackID:)` helper — every mutation catch block now funnels through a single mapper that switches on `HierarchyError.notFound` → `.notFound` (CLIExitCode 2), `HierarchyError.invariantViolation` → `.conflict` (CLIExitCode 3), else → `.internal` (CLIExitCode 20). Before this, conflict cases landed as exit 2 and confused the CLI — review #2 important.
- `HierarchyHandlers.openPanel` label-apply failure now propagates as `.internal("pane created (id=X) but setPanelLabels failed: ...")` instead of silently dropping. Review #1 important.
- `AliasResolverTests` adopts a throwing-sentinel autoclosure (`Self.failingClient()` throwing `ResolverShouldNotDialClient`) so the "client never dialed on UUID fast path" invariant is asserted by throw rather than a `Issue.record` side channel + real-client race. Review #3 important.
- +6 tests across `TerminalHandlersTests` + `RPCCommandArgumentTests` covering `.unsupported` with no sink, fake-sink delivery, `notFound` on unknown pane, broadcast scope JSON stability, and the `codans rpc METHOD` escape hatch's method-lookup path.

**Verification:** `xcodebuild test -scheme CodansKit` → 29 / 6 green. `-scheme codans` → 74 / 14 green. `-scheme CodansCore` → 88 / 14 green. `make mac-lint` → clean.

### M7 — `codans open` CLI + ExternalEditor (later reconciled in M7.1) (2026-04-20)

**What landed in M7 (commit `161d8c8`):** `apps/mac/codans/App/Services/ExternalEditor.swift` (166 LOC) + `handlers/SystemOpenHandlers.swift` — an in-app `@MainActor` actor-style editor service with a 6-editor allowlist (vscode / cursor / zed / xcode / subl / finder), injectable `ProcessRunner` protocol, `finder` fallback, and `Task.detached` so blocking `Process.waitUntilExit()` never stalls MainActor. The RPC pair `system.openInEditor` + `system.openPath` were added to `IPC.Method`. `codans open [--in EDITOR] [--path PATH] [<worktree>]` CLI subcommand landed in `codans-cli/Commands/OpenCommand.swift`. 10 new `ExternalEditorTests` covered argv expansion, fallback chain, and every error path.

**Why this was wrong:** exec-plan 0005 (C8) already ships a comprehensive `LiveEditorService` + `EditorRegistry` + `PathProber` + `ProcessSpawner` (748 LOC, TCA-integrated) on its branch, with a different wire (`editor.open` vs `system.openInEditor`) and a different allowlist ID convention (`sublime` vs `subl`). The coordinator's prior relay had flagged this explicitly; I took the plan's M7 prose as authoritative without re-reading the relay. See Surprises entry.

### M7.1 — Reconciliation to CLI-only wrapper (2026-04-20)

**What landed (commit `3cf35a5`, −503 LOC net):**
- Deleted `ExternalEditor.swift` + `SystemOpenHandlers.swift` + `ExternalEditorTests.swift`. C8's `EditorService` owns the app-side implementation; its tests cover the behavior.
- Reverted the M7 edits: `MethodRouter` no longer has an `openHandlers` sub-router; `AppBootstrap` no longer constructs `ExternalEditor`; `Project.swift` removes the `codans/App/Services` + `Tests/Services` `buildableFolders` additions.
- Replaced `IPC.Method.systemOpenInEditor` + `systemOpenPath` with a single `IPC.Method.editorOpen` slot pointing at C8's wire. Until C8 merges, this slot falls through to `MethodRouter.notWired` → `IPCError.unsupported` → `CLIExitCode.unsupported (4)` at the CLI.
- `OpenCommand` rewritten to call `.editorOpen` with a unified `{ worktreeID?, path?, editor? }` params struct. Help text documents the 4-tier editor precedence (owned by C8's EditorService: `--in` flag > `Project.defaultEditor` > `Settings.defaultEditorID` > Finder fallback) and the `AliasResolver` semantics for `current`.
- Plan doc: DEC-15 captures the reconciliation; Surprises entry captures the process failure (did not re-read the coordinator's cross-plan relay before M7).

**Product-spec Q7 status:** *implementation-pending-C8-merge*, not *resolved*. The CLI surface + wire contract are locked here; the service implementation lands in exec-plan 0005. Final-merge action (coordinator-owned): verify `editor.open` params shape matches between `OpenCommand.EditorOpenParams` and C8's `EditorHandlers` input type; trivial rename if they drift.

**Verification:** `xcodebuild test -scheme CodansKit` → 29 / 6 green. `-scheme codans` → 74 / 14 green. `-scheme CodansCore` → 88 / 14 green. `make mac-lint` → clean.

### M8 — Integration tests + docs pass (2026-04-20)

**What landed:**
- `apps/mac/codans/Tests/Integration/EndToEndRPCIntegrationTests.swift` — 7 end-to-end tests + a new `RouterBackedTransport` adapter. The adapter wraps a real `MethodRouter` + `SocketConnection` with in-process `AsyncStream<Data>` pipes, so a real `RPCClient` drives the full wire stack — Framing (DEC-3), pipelined handshake (DEC-4), routing, typed Codable — without binding a Unix-socket fd. Tests:
  - `systemPingRoundtrips` — baseline liveness
  - `systemVersionReportsHarnessVersions` — version frame decode
  - `hookInstallListFireRecentFullLifecycle` — 4-step hook flow through install → list → fire → recent
  - `hierarchyCreateActivateDescribeRoundtrip` — space mutation + describe round-trip
  - `editorOpenFallsThroughToUnsupported` — proves the `.editorOpen` slot routes to `notWired`-`unsupported` until C8's handler merges
  - `describeMissingSpaceSurfacesNotFound` — error-path contract (IPCError.notFound → CLIExitCode.notFound)
  - `terminalSendWithNoSinkReturnsUnsupported` — proves the no-sink AppBootstrap shape returns the right IPC error
- `docs/product-spec.md` — Open Questions Q1 / Q4 / Q5 marked resolved with cross-references to C4 D1+D2 / C3 D1 / C3 D10. Q7 (external-editor) kept with a status note: contract resolved here, app-side implementation tracked through exec-plan 0005.
- `docs/architecture.md` — Open Architectural Questions Q3 (CLI distribution) + Q5 (IPC backpressure) marked resolved with references to C4 D2 and exec-plan 0003 DEC-9.
- `docs/exec-plans/README.md` — 0003 moved from Active to Completed.

**Deferred to M8.1** (tracked in Progress list):
- Real-socket integration tests (`UnixSocketTransport` + `SocketServer` accept path) — the first attempt hung, see Surprises entry.
- Completion-script generation (`codans --generate-completion-script bash|zsh|fish`) + pre-generated shells shipped in the bundle.
- `codans --man` (groff man page emission from ArgumentParser metadata).
- `CHANGELOG.md` "0.2.0 — Hooks + CLI" entry — defer to release-cut time.

**Verification:** `xcodebuild test -scheme codans` → 81 / 15 green (+7 integration tests). `-scheme CodansKit` → 29 / 6 green. `-scheme CodansCore` → 88 / 14 green. `make mac-lint` → clean. `make mac-build` → BUILD SUCCEEDED.

**Plan closure:** exec-plan 0003 is complete. Outstanding deferred work (M2.1 EventMapper, M3.1 backpressure + SocketPeerAuth, M4.1 AliasResolver extended forms + `codans system launch`, M6.1 extended hierarchy verbs, M8.1 real-socket integration + completions + man) are scheduled as small follow-ups, not a plan rewrite. Cross-plan merge coordination (CodansKit `Project.swift` reconciliation with C5 + C7+C8) remains a final-merge task owned by the coordinator.

## Context and Orientation

Related documents (all in this repo):

- Product spec — [docs/product-spec.md](../product-spec.md), capabilities C3 and C4.
- Design docs (authoritative for every interface named below):
  - [docs/design-docs/c3-lifecycle-hooks.md](../design-docs/c3-lifecycle-hooks.md)
  - [docs/design-docs/c4-cli.md](../design-docs/c4-cli.md)
- Architecture — [docs/architecture.md](../architecture.md): codemap, dependency direction (`codans` cannot import `Runtime`/`Hooks`/`Git`), IPC framing, URL-scheme mapping, persistence invariants.
- Sibling plan in flight — [docs/exec-plans/0002-terminal-and-hierarchy.md](0002-terminal-and-hierarchy.md): this plan depends on that plan's M4 (`TerminalEngine` façade + `AsyncStream<TerminalEvent>`) and M5 (TCA clients + sidebar/tabs/split UI). M1 and M2 of this plan can land before 0002's M4; M3 onward requires 0002's M4 to be merged. Record the explicit gate in the Progress section above and in M3's Goal.
- Golden rules — [docs/golden-rules.md](../golden-rules.md).

Key source files (current state on `main`, post-0002-M4.1 refactor `78df1a6`):

- `apps/mac/CodansCore/` — domain value types (`Space`, `Project`, `Worktree`, `Tab`, `Pane`, `SplitTree<PaneID>`, `Catalog`, `AtomicFileStore`). Leaf package, zero AppKit/SwiftUI/GhosttyKit imports. M1 adds `Hooks/HookEvent.swift` and siblings under this folder.
- `apps/mac/CodansIPC/IPC.swift` — currently one-line stub `public enum IPC {}`. M1 replaces it with the full namespace: `IPC.Method`, `IPC.Request`, `IPC.Response`, `IPCError`, `Framing`, plus the wire-only struct types defined in C4.
- `apps/mac/codans/Hooks/Hooks.swift` — one-line stub `public enum Hooks {}`. M2 fills this subfolder with `HookDispatcher`, `HookExecutor`, `HookConfigStore`, `HookActionDispatcher`, sentinel-routing extension. Not promoted to a Tuist target — stays an in-app subfolder per C3 design doc §Component Boundaries.
- `apps/mac/codans/Runtime/HierarchyManager.swift` — `@MainActor @Observable` structural writer landed in 0002 M2. M2 of this plan adds `setPanelLabels(_:labels:replace:)` as the canonical writer for C3/C4-added `Pane.labels`. Exec-plan-0002 M4/M5 adds the mutation methods backing the CLI verbs (createWorktree over real git, send input, broadcast, etc.).
- `apps/mac/codans/Runtime/HierarchyRuntime.swift` + `Runtime/Runtime.swift` — runtime protocol + shared engine stub, populated by 0002 M3/M4. This plan's M3 consumes `TerminalEngine.events()` once 0002 M4 lands.
- `apps/mac/codans/main.swift` — current body is `print(version)`. M4 replaces it with the ArgumentParser root and command tree.
- `apps/mac/Project.swift` — Tuist root. M1 adds the IPC test target, M2 adds no new target (tests land inside `codansTests`), M4 adds the `tcTests` target and a small `tcIntegrationTests` scheme.

Terminology used in this plan:

- **App side** — code running in the `codans` app process (not the CLI). The app is a windowed macOS application that also listens on a Unix socket for JSON-RPC requests; there is no launchd agent and no separate daemon process. The terms "server side" and "app side" are used interchangeably.
- **RPC method string** — a lowercase-dotted identifier such as `hook.install`. Defined as a case of the `IPC.Method` enum with `String` raw values; both sides switch on the enum, never on the string.
- **Frame** — one length-prefix-plus-body envelope on the wire. A request is always one frame; a streaming response is a sequence of frames terminated per C4 §Wire protocol.
- **Unary vs streaming** — a unary RPC is one request → one response; a streaming RPC is one request → many response frames → one final `{id, stream: false}` frame. `hook.events` is the only streaming RPC in v1.
- **AliasResolver** — a small client-side module in `apps/mac/codans/Transport/AliasResolver.swift` that fast-paths pure UUID strings locally and delegates everything else to `hierarchy.resolveAlias` RPC.
- **Sentinel-prefix route** — a `HookSubscription` whose `command` starts with the reserved `__codans/internal:` namespace is delivered to an in-process `InternalHookSubscriber` instead of spawned as a child process. See C3 DEC-16.
- **Multicaster** — a single in-dispatcher fan-out adapter (`HookEventMulticaster`) that receives one event stream and re-emits it into N independently-buffered `AsyncStream<HookEnvelope>` subscribers. See DEC-10.

### Design-doc decisions inherited

The plan inherits every numbered decision in the approved design docs. The table below anchors each decision to the milestone that implements it, so the planner can trace a shipped feature back to its rationale without re-reading both design docs.

| Source | ID | Summary | Implementing milestone(s) |
|--------|----|---------|---------------------------|
| C3 | D1 | Out-of-process hook execution only in v1 | M2 (`ProcessHookExecutor`) |
| C3 | D2 | Spawn `/bin/sh -c` instead of parsing argv ourselves | M2 (`ProcessHookExecutor.spawn`) |
| C3 | D3 | `HookEvent` / `HookEnvelope` live in `CodansCore` | M1 |
| C3 | D4 | Recursion guard with `HookConfig.recursionWindowMs` | M2 (`HookDispatcher` + tests) |
| C3 | D5 | Minimum `HookAction` verb set | M1 + M2 (`HookAction` enum + `HookActionDispatcher`) |
| C3 | D6 | No in-app UI for hook subscriptions in v1 | scope cut — not planned |
| C3 | D7 | Timeout default is 5 s | M2 (`HookSubscription` default + `ProcessHookExecutor`) |
| C3 | D8 | Handler concurrency cap is global (8) | M2 (`HookDispatcher.maxConcurrency`) |
| C3 | D9 | `pane.output` raw subscription requires `allowRawOutput: true` | M2 (load-time validation) |
| C3 | D10 | `Pane.labels` added to `CodansCore` | M2 (`HierarchyManager.setPanelLabels` canonical writer) |
| C3 | D11 | Hooks config is JSON, not TOML | M2 (`HookConfigStore` + `AtomicFileStore`) |
| C3 | D12 | `hook.events` is streaming | M3 + M5 |
| C3 | D13 | `HookEventData` is tagged-union Codable | M1 |
| C3 | D14 | Hooks attach to `TerminalEvent` stream, not Ghostty callbacks | M3 (`HookDispatcher.attach(to: engine.events())`) |
| C3 | D15 | `HookActionDispatcher` calls in-process Swift handlers | M2 |
| C3 | D16 | `internalEventStream()` + sentinel-prefix routing as peer of `hook.events` | M2 + M3 (multicaster wiring, DEC-10) |
| C4 | D1 | Primary binary `codans`, peer `tcode` | M8 (installer) |
| C4 | D2 | Single binary, ArgumentParser-rooted | M4 |
| C4 | D3 | Install to `~/.local/bin`, not `/usr/local/bin` | M8 |
| C4 | D4 | CLI errors when app not running, except `system launch` and (deferred) `skill install` | M4 |
| C4 | D5 | Convenience aliases resolve via `hierarchy.resolveAlias` | M4 (`AliasResolver`) + M6 (server) |
| C4 | D6 | `codans send` / `codans broadcast` share `terminal.sendInput` / `terminal.broadcastInput` + `BroadcastScope` | M6 |
| C4 | D7 | `--json` is universal | M4 (`JSONRenderer`) |
| C4 | D8 | Stable exit codes (11 = request timeout, 12 = launch timeout) | M4 (`ExitCode` enum) |
| C4 | D9 | `codans rpc METHOD [JSON]` debug escape hatch | M6 |
| C4 | D10 | Streaming RPC: one stream per connection; EOF-either-side termination | M3 (server) + M4 (client) |
| C4 | D11 | Per-connection bounded queue (64) | M3 (DEC-9) |
| C4 | D12 | Client UUID-fast-path; everything else round-trips | M4 (`AliasResolver`) |
| C4 | D13 | `codans skill install` defaults to symlink | deferred to 0004 (see DEC-5) |
| C4 | D14 | `codans open` uses built-in editor allowlist + user templates (resolves Q7) | M7 |
| C4 | D15 | Pre-generated completion scripts | M8 |
| C4 | D16 | `Pane.labels` canonical writer invariant | M2 |
| C4 | D17 | No shell-integration layer | M4 (by construction) |
| C4 | D18 | `send` / `broadcast` are top-level verbs | M6 |
| C4 | D19 | Default `--newline` is off | M6 (`SendCommand` / `BroadcastCommand`) |

### Downstream consumers

Other plans that read directly from this one. Listed here so a future edit that weakens an interface trips a visible signal.

- **Exec-plan 0004 (C5 agent skill).** Consumes: the `codans` ArgumentParser surface (M4), specifically the reserved but unimplemented `skill` subcommand slot that 0004 will flesh out entirely CLI-side (pure file-copy, explicitly bypassing IPC per that plan's D10). This plan does **not** add `skill.*` to `IPC.Method` — 0004 adds nothing to IPC either, which is consistent.
- **Exec-plan 0006 (C6 notifications).** Consumes: `HookConfigStore.upsertInternal(_:)` / `.removeInternal(idsPrefixed:)`, `HookDispatcher.register(subscriber:for:)`, the `InternalHookSubscriber` protocol, the reserved `__codans/internal:` prefix enforcement in `HookConfigStore.load()`, and the `HookEventMulticaster` fan-out (DEC-10). All landed in M2/M3 of this plan.

Any future plan that touches the hook or CLI surface should add itself here.

Orientation paragraph. The work is layered but we deliver vertically. M1 lands the shared wire vocabulary in `CodansCore` + `CodansIPC` so the CLI and the app agree on types from day one. M2 implements the hook dispatcher entirely headless — no Ghostty, no AppKit, no sockets — using an injectable `HookExecutor` for the subprocess layer; this is the largest single milestone and the highest-leverage piece to ship well. M3 wires the `SocketServer` on the app side, registers the `hook.*` handlers plus `system.hello`, pipes `HookDispatcher` events into a streaming RPC via the multicaster, and lands the `InMemoryIPCServer` test harness; at this point a hand-crafted `curl`-style client could exercise the whole hook surface. M4 brings up the `codans` binary with plumbing but only the `system` verbs (`ping`, `status`, `version`, `launch`); this is the first real end-to-end RPC flow. M5 adds the full `codans hook …` CLI surface including the streaming `codans hook tail`. M6 fans out the hierarchy + terminal verbs against `HierarchyManager` / `TerminalEngine` — the largest-but-focused milestone that makes codans fully scriptable. M7 adds `codans open` and the `ExternalEditor` service (resolving product-spec Q7). M8 hardens everything: integration tests against a real headless app, generated completion scripts, `codans --man`, documentation. Each milestone is independently buildable and independently testable; a regression in M3 does not block verification of M2.

## Plan of Work

Eight milestones. M1–M2 are parallelizable with 0002's M3 (GhosttyKit bring-up) — they touch disjoint code. M3 onward requires 0002 M4 merged. The first commit of each milestone re-runs `make mac-generate` and `make mac-build` clean before any code change.

### Milestone 1: CodansCore + CodansIPC wire types

**Goal after this milestone.** Every value type the design docs name — `HookEvent`, `HookScope`, `HookMatchRange`, `HookEventData`, `HookEnvelope`, `HookSubscription`, `HookConfig`, `BroadcastScope`, `PaneOpenRequest`, `AliasResolveRequest`, `AliasResolveResult`, plus the `IPC.Request` / `IPC.Response` / `IPC.Method` / `IPCError` envelopes and the `Framing` helper — exists in Swift with full `Codable` + `Equatable` + `Sendable` conformance. A test suite round-trips every variant through `JSONEncoder` ↔ `JSONDecoder`. Zero AppKit / SwiftUI / GhosttyKit imports. Nothing on the wire yet; nothing spawns anything; this milestone is pure types + tests.

Why this ships first. Three later milestones (M2 Hooks, M3 app-side RPC, M4 CLI) all import these types. Landing them first makes every later build self-contained — a contributor can pick up M4 without waiting on M2.

**Work.** Under `apps/mac/CodansCore/Hooks/` create:

- `HookEvent.swift` — the enum defined in C3 §API Design, including the `scope` accessor and `CaseIterable` conformance, with `pane.input` included per C3 v2 fix.
- `HookScope.swift` — the four-case helper enum.
- `HookMatchRange.swift` — portable `{ start, length }` struct replacing `NSRange`.
- `HookEventData.swift` — the tagged-union `Codable` enum with hand-rolled encoder/decoder keyed on a `"kind"` discriminator.
- `HookEnvelope.swift` — the struct with `SpaceRef` / `ProjectRef` / `WorktreeRef` / `TabRef` / `PanelRef` nested types, ISO-8601 date coding via a shared `JSONEncoder.isoStyle()` factory, and a `validateAnchors()` throws helper (debug-only caller convention; release builds skip the check but the code compiles identically).
- `HookSubscription.swift` — the struct with `Scope` enum (`anyPanel` / `paneID` / `panelLabel` / `tabID` / `tabLabel` / `worktreeID` / `worktreePathGlob`), `Mode` enum, `RegexFlags` option set, `allowRawOutput`, `allowRawInput`, `idleThresholdSeconds`, `disabled`.
- `HookConfig.swift` — the top-level file schema with `version: Int = 1`, `recursionWindowMs: Int = 250`, `subscriptions: [HookSubscription]`. Same version-gated `Codable` pattern as `Catalog`.
- `HookAction.swift` — the action DSL enum with all 10 variants. **Imports `CodansIPC`** and uses `IPC.BroadcastScope` for the `panelBroadcast` variant directly — no nested alias (DEC-12). A companion test `HookActionBroadcastSchemaTests` encodes a `HookAction.panelBroadcast(...)` and a `terminal.broadcastInput` request and asserts the `scope` sub-object bytes-match.

Also in M1, one additive tweak to the existing `apps/mac/CodansCore/Pane.swift`:

- Add `public var labels: Set<String> = []` to the `Pane` struct (C3 D10 / C4 D16). Pure additive field; the version-gated `Catalog` decoder uses `decodeIfPresent` so v1 `catalog.json` files still parse. **The canonical *writer* — `HierarchyManager.setPanelLabels(_:labels:replace:)` — ships in M2**; M1 only lands the data shape so downstream consumers (notably C6 / exec-plan 0006) can compile against it without waiting for M2.

Under `apps/mac/CodansIPC/` replace the one-line stub `IPC.swift` with:

- `Framing.swift` — `enum Framing { static func encode(_ body: Data) -> Data; static func decode(from buffer: inout Data) throws -> Data? }`. Implements the `UInt32` big-endian length-prefix per DEC-3.
- `Method.swift` — `enum IPC.Method: String, Codable, Sendable { case systemHello = "system.hello"; case systemPing = "system.ping"; /* … every method referenced in C4 API tables … */ }`. Pin every method string in one file.
- `Envelope.swift` — `struct IPC.Request { id, method, params: JSONValue, stream: Bool }` and `struct IPC.Response { id, stream: Bool, result: JSONValue?, error: IPCError? }`. `JSONValue` is a small enum for dynamic params; per-method typed decoders live in callers.
- `IPCError.swift` — the enum with all eight cases per C4 §Error codes; Codable encoding is `{ "code": String, "message": String, "path": [String]? }`.
- `WireTypes/BroadcastScope.swift`, `WireTypes/PaneOpenRequest.swift`, `WireTypes/AliasResolveRequest.swift`, `WireTypes/AliasResolveResult.swift`, `WireTypes/PanelRef.swift` (reused by `HookEnvelope`), `WireTypes/WorktreeRef.swift`, etc. — pure struct definitions.
- `HandshakeTypes.swift` — `struct HelloRequest { clientVersion: String; clientBinary: String }` and `struct HelloResponse { serverVersion, appBundleVersion, protocolMajor, protocolMinor, deprecatedMethods: [String] }`.

Add new test files under `apps/mac/CodansCoreTests/Hooks/`:

- `HookEventCodableTests.swift` — every case of `HookEvent` round-trips through a small `{"event": "…"}` JSON.
- `HookEventDataCodableTests.swift` — every `HookEventData` case encodes with the correct `"kind"` discriminator and decodes back to equality.
- `HookEnvelopeCodableTests.swift` — a Pane-scoped envelope carrying every field round-trips; decoding rejects unknown top-level fields; `validateAnchors()` throws when a `pane.*` envelope is missing its `tab` field in debug builds.
- `HookSubscriptionCodableTests.swift` — every `Scope` variant round-trips; decoder rejects reserved env-var keys (`CODANS_*`); decoder rejects `command` prefixes in the reserved `__codans/internal:` namespace unless loaded with an `internalNamespaceAllowed: true` flag.
- `HookConfigCodableTests.swift` — unknown-version rejection; default-value behaviour when `recursionWindowMs` absent.
- `HookActionCodableTests.swift` — all 10 action variants round-trip; decoder rejects unknown action kinds.

Under `apps/mac/CodansCoreTests/IPC/` (new folder in the same test target; no new Tuist target):

- `FramingTests.swift` — encode/decode round-trip for frames up to 1MB; malformed length prefix throws; partial buffer returns `nil` without consuming bytes.
- `IPCEnvelopeCodableTests.swift` — request and response envelopes round-trip; `stream: true` flag survives encoding; `IPCError` decoder tolerates older codes.
- `WireTypeCodableTests.swift` — the four new `WireTypes/*` structs round-trip.

**Tuist wiring.** Add `"CodansCore/Hooks"` to `CodansCore`'s `buildableFolders`. Add a second buildableFolder to `CodansIPC` if its sources move into subfolders (`"CodansIPC/WireTypes"`); otherwise a single folder + multi-file is fine. Do **not** add a separate `CodansIPCTests` target — fold IPC codable tests into `CodansCoreTests`, which already links `CodansCore` and can take an additional link to `CodansIPC` via `dependencies: [.target(name: "CodansCore"), .target(name: "CodansIPC")]`. This matches DEC-1's "avoid proliferating test targets" principle.

**Observable acceptance.** `make mac-generate && make mac-build` produces `CodansCore.framework` and `CodansIPC.framework` with the new types exported. `xcodebuild test -scheme CodansCoreTests` reports **all tests pass**, with the new hook-codable tests numbering at least 20. `make mac-lint` is clean. `grep -r 'import AppKit\|import SwiftUI\|import GhosttyKit' apps/mac/CodansCore apps/mac/CodansIPC` returns no matches. A quick `swift -e` snippet that instantiates a `HookEnvelope`, encodes it, decodes it back, and asserts equality compiles and runs.

**Expected commits.** `feat(core): HookEvent/HookEventData/HookEnvelope wire types + tests`, `feat(ipc): IPC envelope, framing, method enum, IPCError, handshake types`, `feat(ipc): BroadcastScope + PaneOpenRequest + AliasResolve wire types`.

### Milestone 2: Hooks in-app subfolder

**Goal after this milestone.** `apps/mac/codans/Hooks/` is a fully-fleshed in-app subfolder (not a separate Tuist target) containing the dispatcher, executor, config store, action dispatcher, and internal-subscriber seam. A contributor can unit-test the entire hook subsystem headlessly: no GhosttyKit, no AppKit, no sockets, no real child processes. A `FakeHookExecutor` replaces `ProcessHookExecutor` for tests; a `FakeHookActionDispatcher` records what would have been dispatched.

**Work.** Under `apps/mac/codans/Hooks/`:

- `HookConfigStore.swift` — `@MainActor final class` wrapping `~/.config/codans/hooks.json` through `CodansCore.AtomicFileStore` (DEC-8). Public methods:
    - `load() throws -> HookConfig` — backs broken files to `hooks.json.broken-<ISO8601>` and returns `.default`.
    - `save(_ config: HookConfig) throws` — synchronous flush.
    - `scheduleSave(_:)` — 500ms debounce (same pattern `CatalogStore` uses).
    - `upsertInternal(_ subscriptions: [HookSubscription]) throws` — atomic insert-or-replace of subscriptions whose `command` is in the reserved `__codans/internal:` namespace. Bypasses the user-authored rejection that `load` applies; callers must supply subscriptions whose `command` starts with the reserved prefix or the method throws `HookConfigError.reservedPrefixRequired`. Scheduled save.
    - `removeInternal(idsPrefixed prefix: String) throws` — removes every subscription whose `command` starts with `prefix` (which must itself start with `__codans/internal:`). Returns silently when no matches. Scheduled save.
  Load-time validation enforces: reserved env-var keys rejected, `__codans/internal:` prefix rejected for subscriptions loaded from disk via the public `load()` path, bad regex patterns rejected (compile once, cache the `NSRegularExpression`). The `upsertInternal` path sets a private `internalNamespaceAllowed: true` flag on the validator before invoking it, so first-party consumers (C6) can install the subscriptions the user-authored path refuses. Emits `HookConfigError.invalidRegex` / `.reservedEnv` / `.reservedPrefix` / `.reservedPrefixRequired` per the design doc error-handling table.
- `HookExecutor.swift` — the protocol exactly as C3 §Hooks module specifies: `func run(subscription:envelope:) async -> HookExecutionResult`. Plus `struct HookExecutionResult { exitCode, stdout, stderr, duration, timedOut, actions: [HookAction] }`.
- `ProcessHookExecutor.swift` — the real `Foundation.Process`-backed executor. Spawns `/bin/sh -c <command>`; sets env vars `CODANS_SOCKET_PATH`, `CODANS_EVENT`, `CODANS_VERSION`, `CODANS_*_ID` for every anchor present in the envelope; pipes `JSONEncoder(isoStyle).encode(envelope)` followed by EOF to stdin; buffers stdout and stderr to 1MB max; kills the process group via `killpg` on timeout with a 2s SIGKILL grace. Actions are parsed from stdout only when `subscription.mode == .awaitActions`.
- `FakeHookExecutor.swift` — records a `[(HookSubscription, HookEnvelope)]` transcript, returns a caller-supplied `HookExecutionResult`. Used in tests.
- `HookActionDispatcher.swift` — `@MainActor final class` that translates each `HookAction` into a call against the in-process `HierarchyManager` / `TerminalEngine` / notification service. For v1, unknown action variants are dropped (logged). `HookAction.setPanelLabels` calls `HierarchyManager.setPanelLabels(_:labels:replace:)` — the canonical funnel per C3 data-model §. Sending actions through the socket is explicitly forbidden (C3 D15).
- `HookActionDispatcher+Notify.swift` — the `notify` action uses `NSUserNotificationCenter` or `UNUserNotificationCenter` (macOS 14+); stub it in M2 to call a small `NotificationService` protocol so tests don't touch AppKit. The real implementation can land when C6 does.
- `HookDispatcher.swift` — the central class. Public API exactly matches C3 §Hooks module:

      @MainActor
      public final class HookDispatcher {
        public init(
          config: HookConfig,
          store: HookConfigStore,
          executor: HookExecutor = ProcessHookExecutor(),
          actionDispatcher: HookActionDispatcher,
          maxConcurrency: Int = 8
        )
        public func attach(to events: AsyncStream<TerminalEvent>)
        public func fire(_ envelope: HookEnvelope) async
        public func reloadConfig() async throws
        public func internalEventStream() -> AsyncStream<HookEnvelope>  // registers a fresh multicaster subscriber
        public func register(subscriber: InternalHookSubscriber, for prefix: String) throws
        public func unregister(prefix: String)
      }

  Implementation details the design doc already pins: pre-compiled regex table `[PaneID: [(HookSubscription, NSRegularExpression)]]` built on `reloadConfig`; per-event lookup `[HookEvent: [HookSubscription]]`; `AsyncSemaphore` with capacity `maxConcurrency`; per-subscription token bucket (30 fires / 10s) that transitions a subscription to `disabled` on overflow (R1). In-flight handlers get a `let`-captured snapshot (DEC-7). Recursion guard tags every action with its originating envelope id and suppresses direct re-entry within `HookConfig.recursionWindowMs` (default 250) on `.paneOutput` / `.paneInput`.
- `HookEventMulticaster.swift` — the fan-out adapter that backs both `internalEventStream()` and the app-side `hook.events` RPC (DEC-10). Internally owns `[UUID: AsyncStream<HookEnvelope>.Continuation]` (one entry per live subscriber) with bounded buffering (newest-64 per subscriber). Public API: `func publish(_ envelope: HookEnvelope)` and `func subscribe() -> (id: UUID, AsyncStream<HookEnvelope>)`. Teardown on stream cancellation unregisters automatically via `onTermination`. Unit-tested with N=3 simulated subscribers: each receives every event; a subscriber that stops consuming does not stall the others; removing a subscriber stops delivery to it within one publish cycle.
- `HookRecentRing.swift` — bounded ring buffer of `HookFireRecord` (256 entries, design-doc default). Read from `hook.recent` RPC in M3.
- `HookFireRecord.swift` — `{ id, envelope, subscriptionID, duration, exitCode, actionsDispatched, actionsRefused, timedOut, killed, rateLimited }` plus `Codable` for RPC exposure.
- `InternalHookSubscriber.swift` — the protocol `func handle(envelope: HookEnvelope) async`. Sentinel routing inside `HookDispatcher`: before invoking `executor.run`, inspect `subscription.command`; if it begins with a registered prefix (must be within `__codans/internal:` namespace), route directly to the subscriber and skip the process spawn. Recursion guard and rate limit still apply.

Update `apps/mac/codans/Runtime/HierarchyManager.swift` to add the canonical labels writer:

    public func setPanelLabels(_ id: PaneID, labels: Set<String>, replace: Bool = false) throws

Implementation: updates `catalog.spaces[*].projects[*].worktrees[*].tabs[*].panes[*].labels`; calls `store.scheduleSave(catalog)`. Replace vs. merge is a flag. Throws `.panelNotFound` when the id is unknown. Unit test in `HierarchyManagerTests.swift`.

Add tests under `apps/mac/codans/Tests/Hooks/`:

- `HookConfigStoreTests.swift` — round-trip write/read; backup on parse error; reserved-env-var rejection; reserved-prefix rejection for user `load()` path; invalid-regex rejection with the failing subscription reported but the rest loaded.
- `HookConfigStoreInternalNamespaceTests.swift` — `upsertInternal(_:)` accepts subscriptions inside the reserved prefix and rejects anything outside with `HookConfigError.reservedPrefixRequired`; `removeInternal(idsPrefixed:)` removes only matching subscriptions and leaves user-authored ones untouched; persistence round-trips through `load()` without tripping the reserved-prefix check (the loader recognises persisted internal subscriptions by their prefix and admits them verbatim).
- `HookEventMulticasterTests.swift` — three parallel subscribers each receive the same envelope from one `publish` call; a slow subscriber that stops consuming does not stall the others (one continuation fills to capacity and drops; other continuations continue); `onTermination` unregisters; `publish` after all subscribers disappear is a silent no-op.
- `HookActionBroadcastSchemaTests.swift` — a `HookAction.panelBroadcast(scope: IPC.BroadcastScope.tab(...), ...)` JSON and a `terminal.broadcastInput` request JSON share an identical `scope` sub-object (asserts per-byte equality of the scope field).
- `HookDispatcherFireTests.swift` — firing an envelope invokes the right subscription via `FakeHookExecutor`; multiple matching subscriptions each get invoked; non-matching events are silent.
- `HookDispatcherOutputMatchTests.swift` — a `.paneOutput(Data)` event with a 4KB payload against a `(?i)ready` regex synthesises exactly one `.paneOutputMatch` envelope with correct `HookMatchRange`. A pane without any matching subscription pays zero per-batch regex cost (asserted by checking the compiled-regex table for that pane is empty).
- `HookDispatcherIdleTests.swift` — idle envelopes below `idleThresholdSeconds` are dropped client-side; above it, the executor fires.
- `HookDispatcherConcurrencyTests.swift` — with `maxConcurrency = 2`, three simultaneous fires run 2-at-a-time; token bucket rate-limits to 30/10s; exceeding rate transitions the subscription to `disabled`.
- `HookDispatcherRecursionGuardTests.swift` — a handler that emits `HookAction.panelSend(same-pane, text)` does not re-fire within `recursionWindowMs`; a handler that emits `tab.activate` does re-fire (tab events are not guarded).
- `HookDispatcherInternalSubscriberTests.swift` — a subscription with `command: "__codans/internal:notif:<uuid>"` registered to a fake subscriber bypasses `FakeHookExecutor` and is delivered directly.
- `HookActionDispatcherTests.swift` — every `HookAction` case routes to the right in-process method; `setPanelLabels` hits `HierarchyManager.setPanelLabels`.
- `HookConfigHotReloadTests.swift` — `reloadConfig()` atomically swaps the table; an in-flight handler retains its old snapshot (captured via a fake that sleeps then inspects its subscription reference).

**Observable acceptance.** `xcodebuild test -scheme codans -only-testing:codansTests/Hooks` reports **all tests pass**, with at least 20 hook-dispatcher tests. `grep -r 'import GhosttyKit\|import AppKit' apps/mac/codans/Hooks` returns no matches. `make mac-lint` is clean. A tiny manual smoke via a debug hook in `CodansApp.init` that calls `HookDispatcher.fire(syntheticPanelReadyEnvelope)` and a handler at `echo -n "$CODANS_PANE_ID" > /tmp/codans-hook-echo` leaves the right UUID in `/tmp/codans-hook-echo`.

**Expected commits.** `feat(hooks): HookConfigStore + atomic-rename + load-time validation`, `feat(hooks): HookDispatcher + HookExecutor + FakeHookExecutor`, `feat(hooks): HookActionDispatcher + internalEventStream + sentinel routing`, `feat(runtime): HierarchyManager.setPanelLabels canonical writer`.

### Milestone 3: App-side IPC methods + `system.hello` + backpressure + multicaster + test harness

**Goal after this milestone.** A running app accepts connections on `/tmp/codans-$UID.sock`, speaks the C4 wire protocol, answers every `hook.*` method plus `system.hello` / `system.ping` / `system.version` / `system.status`, and fans out hook events to N concurrent subscribers via the multicaster. An `InMemoryIPCServer` test harness lives under `apps/mac/codans/Tests/Harness/` so M4/M5's `tcTests` can exercise the full wire protocol without binding a real socket. A hand-crafted socket client (e.g., a Python dev script in `scripts/wire-smoke.py`) can install a hook, fire it, and tail the events stream. This is the first milestone that requires 0002's M4 to be merged: `HookDispatcher.attach(to:)` consumes the real `TerminalEngine.events()` stream.

**Work.** Under `apps/mac/codans/App/Features/Socket/`:

- `SocketPaths.swift` — small helper centralising the socket-path convention: `static func defaultSocketPath(uid: uid_t = getuid()) -> String` returns `/tmp/codans-<uid>.sock`; `static func resolve(override: String? = ProcessInfo.processInfo.environment["CODANS_SOCKET_PATH"]) -> String`. Shared by `SocketServer` (app side) and — re-exported — by `codans`'s `SocketDiscovery` (M4). No inline `getuid()` calls anywhere else.
- `SocketServer.swift` — `@MainActor final class` owning the Unix socket. Listens on `SocketPaths.resolve()`; accepts connections in a detached `Task`; per-connection dispatches to a `SocketConnection` actor (below). Tears down cleanly on app quit. Stale-socket cleanup: probes via `connect` + close; if the path exists but has no live listener, unlinks.
- `SocketConnection.swift` — per-connection actor. Owns `AsyncChannel<IPC.Request>(maxBufferedElements: 64)` for in-flight backpressure (DEC-9). Reads frames via `Framing.decode`; writes via `Framing.encode`; enforces the 16 MiB per-frame cap (DEC-3) and closes the connection on oversize frames with `IPCError.invalidFrame`. First frame must be `system.hello` or the connection is closed with `.versionMismatch`. After the handshake, one unary call OR one streaming call before connection close.
- `HelloHandler.swift` — handles `system.hello`. Validates client version against server; emits warning to os.Logger on minor skew; returns `.versionMismatch` on major skew.
- `SocketPeerAuth.swift` — small wrapper around `LOCAL_PEERCRED` (macOS) for uid verification. Closes the connection if peer uid != user uid.
- `MethodRouter.swift` — large `switch` over `IPC.Method` dispatching to the right handler. Handlers are small: each receives typed params (decoded from `request.params` into the expected wire struct) and returns typed results.
- `handlers/HookHandlers.swift` — one method per `hook.*`:
  - `hook.list` → `hookDispatcher.config.subscriptions.filtered(by:)`.
  - `hook.install` → validates, appends, persists via `HookConfigStore.save`.
  - `hook.remove`, `hook.enable`, `hook.reload`, `hook.test`, `hook.fire` — each a small method on `HookDispatcher`.
  - `hook.recent` → reads the `HookRecentRing`.
  - `hook.events` → streaming. Subscribes to a fresh multicaster slot via `HookDispatcher.internalEventStream()` (DEC-10) — guarantees every `hook.events` RPC call and every in-process C6 consumer see the same event stream without fighting over a single `AsyncStream`. Events are filtered through the dispatcher's match pass first, so tailing sees the same synthesised `.paneOutputMatch` a handler would see. Emits `{id, stream: true, result: <envelope>}` frames per event. On connection-write-half close (client-initiated end), flushes in-flight events, sends `{id, stream: false}` final frame, closes its write half. Server-initiated end (e.g., `hook.*` reload reset) sends a `{id, stream: false, error: … }` frame then closes.
- `handlers/SystemHandlers.swift` — `system.ping` / `system.version` / `system.status` / `system.quit` / `system.hello`.
- `handlers/HierarchyReadHandlers.swift` — read-only handlers backing M4 (`hierarchy.listSpaces`, `hierarchy.describeSpace`, etc.). Populate just enough to satisfy M4's `system` verbs + `codans pane list` / `codans pane show`; the mutation handlers land in M6.

Under `apps/mac/codans/Tests/Harness/` (new folder, M3 delivers it; M4+ consumes it; DEC-11):

- `InMemoryIPCServer.swift` — XCTest-only harness. Exposes `start() -> (clientEnd: FileHandle, serverEnd: FileHandle)`; internally runs a `SocketConnection` actor against the server-end file descriptor, so client-side tests can write `system.hello` + a request frame to `clientEnd` and read the framed response. Accepts a `MethodRouter` override so tests can inject fake handlers. Not linked into the shipped `codans` binary — it is part of the `tcTests` bundle only, and the file lives under `Tests/Harness/` which `Project.swift` excludes from the `codans` target's `buildableFolders`.

Update `apps/mac/codans/App/CodansApp.swift`:

- Construct one shared `TerminalEngine` (from 0002 M4), one shared `HookDispatcher` (from M2) wrapping a `HookEventMulticaster`, one shared `SocketServer`, wire them together.
- `HookDispatcher.attach(to: engine.events())` is called once at launch.
- The socket path is chosen via `SocketPaths.resolve()` — no inline `getuid()`.

Add tests under `apps/mac/codans/Tests/Socket/`:

- `FramingWireTests.swift` — encodes an envelope, writes through an in-memory socket, decodes back, asserts round-trip. Also asserts: frames ≥ 16 MiB are rejected with `.invalidFrame` and the connection is closed (no partial buffer retained); malformed length headers throw.
- `SocketServerLifecycleTests.swift` — server binds, accepts a connection, closes on quit; stale socket file is unlinked on start.
- `HandshakeTests.swift` — first frame must be `system.hello`; non-hello first frames close the connection; major-version skew responds with `.versionMismatch`.
- `HookHandlersTests.swift` — in-memory socket round-trip for each `hook.*` method via `InMemoryIPCServer`; `hook.install` persists a subscription, `hook.remove` removes it, `hook.list` reflects the state.
- `HookEventsStreamingTests.swift` — a client sends a streaming `hook.events` request, the app fires three synthetic events, the client receives exactly three `{stream: true}` frames plus one `{stream: false}` terminator after the client closes its write half. A parallel test opens two simultaneous streaming subscribers and asserts each receives all three events (fan-out via multicaster, DEC-10).
- `BackpressureTests.swift` — opening 65 simultaneous in-flight requests on one connection causes the 65th to receive `IPCError.overloaded` after the 2s wait.
- `InMemoryIPCServerTests.swift` (under `tcTests` / `Tests/Harness/`) — the harness itself round-trips `system.hello` + `system.ping` against a minimal `MethodRouter`; streams emit terminator on client-write-half close. This keeps the harness honest before downstream tests rely on it.

**Observable acceptance.** `xcodebuild test -scheme codans` is green. `make mac-run-app` starts the app; in another shell, `nc -U /tmp/codans-$UID.sock` followed by pasting a length-prefix-hex-framed `system.hello` responds with a well-formed JSON. `scripts/wire-smoke.py` (dev-only, not shipped) installs a hook and fires it. `xcodebuild test -scheme tcTests -only-testing:tcTests/Harness` runs the harness self-test green.

**Expected commits.** `feat(socket): SocketPaths helper + SocketServer + SocketConnection`, `feat(socket): Framing decode with 16MiB cap + system.hello handshake + peer-uid auth`, `feat(socket): hook.* method handlers`, `feat(socket): HookEventMulticaster + streaming hook.events RPC`, `feat(tests): InMemoryIPCServer harness`, `feat(app): wire TerminalEngine -> HookDispatcher -> SocketServer`.

### Milestone 4: `codans` CLI scaffold

**Goal after this milestone.** `codans` is a real ArgumentParser-rooted binary that implements every `codans system …` verb end-to-end: `codans system ping` hits the app and prints `pong`; `codans system status` prints JSON with app version; `codans system version` prints both binary and server versions; `codans system launch` launches the app if not running and waits up to 10s; `codans system sockets` enumerates discovery paths. The plumbing behind them (`RPCClient`, `SocketDiscovery`, `AliasResolver`, renderers, exit-code table) exists and is unit-tested.

**Work.** Under `apps/mac/codans/`:

- `main.swift` — replace the one-liner with the ArgumentParser root `CodansCLI`. Global flags: `--json`, `--socket`, `--verbose`, `--no-color`, `--timeout`, `--help`, `--version`, `--generate-completion-script`, `--man`. Subcommand registration includes a stub for every namespace, but only `system` is implemented — other namespaces parse and print "not yet implemented".
- `Transport/Framing.swift` — thin re-export of `CodansIPC.Framing`.
- `Transport/SocketDiscovery.swift` — resolves socket path via env → default → optional launch. Returns `DiscoveredSocket { path: String, wasLaunched: Bool }`.
- `Transport/RPCClient.swift` — one instance per `codans` invocation. `connect(to path: String) throws -> Connection`; `call<T: Decodable>(_ method: IPC.Method, params: Encodable, timeout: TimeInterval) async throws -> T`; `stream<T: Decodable>(_ method: IPC.Method, params: Encodable) -> AsyncThrowingStream<T, Error>`. On `call`, pipelines `system.hello` + the real request (DEC-4). Discards the handshake response unless it carries an error.
- `Transport/AliasResolver.swift` — UUID-fast-path locally; everything else calls `hierarchy.resolveAlias` RPC. Caches per-invocation (a small dictionary), never across invocations.
- `Render/TextRenderer.swift` — `func render<T>(_ value: T) -> String`. Concrete overloads for each result type from M4's `system` verbs (list, show).
- `Render/JSONRenderer.swift` — `func render<T: Encodable>(_ value: T) -> String` using the shared encoder.
- `Render/Mode.swift` — `enum Mode { case text(useColor: Bool), json }`.
- `ExitCode.swift` — the enum pinned by C4 §Exit codes, mapping `IPCError` cases to `Int32` codes. Note: `11` = request timeout, `12` = launch timeout (the post-review v2 split).
- `Commands/SystemCommands.swift` — implements `codans system {ping, status, version, launch, quit, sockets}`. Each subcommand is a `ParsableCommand` with `func run() async throws`.
- `Commands/StubbedNamespaces.swift` — declares `SpaceCommand`, `ProjectCommand`, `WorktreeCommand`, etc. as `ParsableCommand` with a single `NotImplemented` child that prints "not yet implemented in this build (milestone M5/M6)". ArgumentParser still generates `--help` for them, keeping discoverability.

Add a new Tuist target `tcTests`:

- `.unitTests` target hosting `codans` tests. Depends on `.target("codans")` via `@testable import codans`.
- Tests under `apps/mac/codans/Tests/`:
  - `ArgumentParsingTests.swift` — every subcommand path parses; invalid flag combinations throw `ValidationError`.
  - `SocketDiscoveryTests.swift` — env-var wins over default; missing socket with no `--launch-app` errors exit 10; missing socket with `--launch-app` attempts launch and times out exit 12.
  - `RPCClientTests.swift` — against an `InMemoryIPCServer` harness (port of M3's in-memory socket): unary call round-trip; streaming call round-trip; timeout returns exit 11; handshake-version-skew returns exit 6.
  - `AliasResolverTests.swift` — UUID-fast-path no round trip; `current` / `.` pick the right env var; ambiguous label returns `.conflict`.
  - `RenderingTests.swift` — golden files for `codans system status` text mode; JSON mode 1:1 with the RPC result.
  - `ExitCodeMappingTests.swift` — every `IPCError` variant maps to the right exit code.

Add to `apps/mac/Project.swift`:

- `tcTests` target wiring (dependencies on `codans`, `CodansIPC`, `CodansCore`).
- `codans` gains `"Tests/**"` exclusion from its own `buildableFolders` so test sources don't compile into the CLI binary.

**Observable acceptance.** `xcodebuild build -scheme codans` succeeds. `xcodebuild test -scheme tcTests` is green. `make mac-run-app &` then `./apps/mac/.build/.../codans system ping` prints `pong` and exits 0. `codans system status --json | jq .serverVersion` prints the running app's version. `codans --help` lists `space / project / worktree / tab / pane / send / broadcast / skill / open / hook / system`, with every non-system subcommand showing its stub.

**Expected commits.** `feat(cli): ArgumentParser root + global flags + exit-code table`, `feat(cli): SocketDiscovery + RPCClient with system.hello pipelining`, `feat(cli): codans system {ping, status, version, launch, quit, sockets}`, `feat(cli): AliasResolver UUID-fast-path + stubbed namespace commands`.

### Milestone 5: `codans hook` subcommands (full surface)

**Goal after this milestone.** The complete `codans hook …` command tree works end-to-end against the running app: install a subscription from a file, list them, disable one, tail a live event stream, fire a synthetic event for handler development. This is the first milestone where an outside user can actually write a workflow.

**Work.** Under `apps/mac/codans-cli/Commands/`:

- `HookCommands.swift` — the subcommand tree:
  - `codans hook list [--event E] [--pane ID]` → `hook.list`. Renders a table in text mode, JSON array in JSON mode.
  - `codans hook install FILE|-` → reads JSON from FILE or stdin, sends `hook.install`. Prints the assigned id.
  - `codans hook remove ID` → `hook.remove`. Exits 2 if not found.
  - `codans hook enable ID` / `codans hook disable ID` → `hook.enable { enabled: true|false }`.
  - `codans hook reload` → `hook.reload`. Prints `{loadedCount, errors}` in text mode.
  - `codans hook test ID [--payload PATH]` → reads a synthetic envelope (default: a minimal one matching the subscription's event) and sends `hook.test`. Prints `HookExecutionResult`.
  - `codans hook fire EVENT [--pane ID] [--data JSON]` → `hook.fire`. Prints `{handlersRun}`.
  - `codans hook recent [--limit N]` → `hook.recent`. Renders a table (timestamp, subscription id, event, exitCode, duration).
  - `codans hook tail [--event E]` → opens the `hook.events` streaming RPC. Prints NDJSON lines (one JSON envelope per line, newline-separated). SIGINT cleanly closes the write half and exits 0 after the server's final frame.
  - `codans hook edit` → opens `~/.config/codans/hooks.json` in `$EDITOR`; on exit, if the file was modified, calls `hook.reload` automatically.

- `Commands/HookInstallInputs.swift` — FILE vs stdin reader, validates the JSON against `HookSubscription`'s decoder before sending.

Update tests:

- `tcTests/HookCommandsTests.swift` — each subcommand's parse + render against the `InMemoryIPCServer` harness. `codans hook tail` asserts it prints three NDJSON lines when the server emits three envelopes before closing its write half.
- App-side `apps/mac/codans/Tests/Socket/` gains a round-trip scenario: `codans hook install` over real Unix socket against a test-harness `SocketServer`; the installed subscription is present in a subsequent `codans hook list`.

**Observable acceptance.** With the app running: `codans hook install <(echo '{"id":"11111111-1111-4111-8111-111111111111","event":"pane.ready","command":"echo from-hook"}')` exits 0 and prints the id. `codans hook list --json | jq '.subscriptions | length'` prints `1`. `codans hook test 11111111-…` runs the handler in-app and prints `exitCode: 0, stdout: "from-hook\n"`. `codans hook tail` prints events as they fire — `codans pane open` in another shell (stubbed in M4, real in M6) or `codans hook fire pane.ready --pane <id>` triggers a line on stdout.

**Expected commits.** `feat(cli): codans hook {list, install, remove, enable, disable, reload}`, `feat(cli): codans hook {test, fire, recent}`, `feat(cli): codans hook tail (streaming) + codans hook edit`.

### Milestone 6: Hierarchy + Terminal mutation verbs

**Goal after this milestone.** The full hierarchy and terminal command surface works against a running app: the user can drive Spaces / Projects / Worktrees / Tabs / Panes entirely from the CLI, send and broadcast text into panes, and run `codans system quit` to shut down cleanly. Skill and Open verbs are *not* part of this milestone — skill ships via 0004 (DEC-5), Open ships in M7. This keeps M6's file count inside the ~5-per-task target: six CLI command files + three app-side handler files + tests.

**Work.** Under `apps/mac/codans-cli/Commands/`, replace the stubs with full implementations:

- `SpaceCommands.swift` — `list`, `create`, `rename`, `remove`, `activate`, `show`.
- `ProjectCommands.swift` — `list`, `add`, `remove`, `rename`, `set-editor`, `show`. (`set-editor` writes `Project.defaultEditor` which M7's `codans open` reads — no forward dependency broken.)
- `WorktreeCommands.swift` — `list`, `create`, `remove`, `activate`, `rename`, `show`, `prune`. `create` and `remove` refuse on non-git Projects with exit 4 via the server's `.unsupported` error.
- `TabCommands.swift` — `list`, `create`, `close`, `activate`, `rename`, `show`.
- `PaneCommands.swift` — `list`, `open`, `split`, `close`, `focus`, `resize`, `zoom`, `unzoom`, `retry`, `label`, `show`, `info`.
- `SendBroadcastCommands.swift` — `codans send` and `codans broadcast` (both back `terminal.sendInput` / `terminal.broadcastInput` per C4 D6 and DEC-12).
- `RPCDebugCommand.swift` — `codans rpc METHOD [JSON]` debug escape (C4 D9).

App side (`apps/mac/codans/App/Features/Socket/handlers/`):

- `HierarchyMutationHandlers.swift` — one method per mutation RPC (`hierarchy.createSpace`, `…renameSpace`, `…removeSpace`, `…activateSpace`, `…addProject`, `…removeProject`, `…renameProject`, `…setProjectEditor`, `…createWorktree`, `…removeWorktree`, `…activateWorktree`, `…renameWorktree`, `…pruneWorktrees`, `…createTab`, `…closeTab`, `…activateTab`, `…renameTab`, `…openPanel`, `…splitPanel`, `…closePanel`, `…focusPanel`, `…resizePanel`, `…zoomPanel`, `…unzoomPanel`, `…setPanelLabels`, `…resolveAlias`, `…resolvePanelLabel`, `…resolveWorktreeGlob`). Each is a thin call to `HierarchyManager`. Mutations landed by 0002 M5 are delegated directly; any mutation that 0002 has not yet shipped (for example, `resizePanel` if it slips) is temporarily backed by an `.unsupported` response and a note in this plan's Surprises & Discoveries, resolved as soon as 0002 ships it.
- `TerminalHandlers.swift` — `terminal.sendInput`, `terminal.broadcastInput`, `terminal.retryPane` backed by `TerminalEngine.sendInput` / fan-out helper.

Tests:

- `tcTests/HierarchyCommandsTests.swift` — parse + render for each subcommand; golden files for text + JSON modes.
- `tcTests/SendBroadcastCommandsTests.swift` — `codans send` unary + stdin modes; `codans broadcast` scope flags mutually exclusive at parser level; scope encoding uses the shared `IPC.BroadcastScope` bytes (cross-checks DEC-12).
- `codansTests/Socket/HierarchyMutationHandlersTests.swift` — each mutation RPC issues the right call against a fake `HierarchyManager` via the `InMemoryIPCServer` harness.
- `codansTests/Socket/TerminalHandlersTests.swift` — `terminal.sendInput` routes to the right pane; broadcast fan-out covers every pane in the target scope.

**Observable acceptance.** With the app running:

    codans space create "validate" --activate
    codans project add .
    codans worktree create exp/validate
    codans tab create agent --activate
    codans pane open --label agent --cwd .

Each call exits 0 and produces visible state in the sidebar. `codans send @agent 'echo hello\n'` injects the command and the Pane's scrollback shows `hello`. `codans broadcast --tab current 'date\n'` injects `date` into every pane in the current tab. `codans system quit` gracefully closes the app.

**Expected commits.** `feat(cli): codans space + project + worktree`, `feat(cli): codans tab + pane`, `feat(cli): codans send + codans broadcast + codans rpc`, `feat(socket): hierarchy + terminal mutation handlers`.

### Milestone 7: `codans open` + `ExternalEditor` service (resolves product-spec Q7)

**Goal after this milestone.** `codans open` opens the current Worktree in the user's configured external editor (VSCode, Cursor, Zed, Xcode, Sublime Text, Finder, or any user-template), from any Pane's shell. The GUI's Worktree-header "open in editor" button (C8) reuses the same `ExternalEditor` service under the hood. Product-spec Open Q #7 is resolved by landing the code that the design doc (C4 D14) specified.

**Work.** Under `apps/mac/codans-cli/Commands/`:

- `OpenCommand.swift` — `codans open [--in EDITOR]`, `codans open --path PATH [--in EDITOR]`, `codans open finder`. `EDITOR` is one of `vscode|cursor|zed|xcode|subl|finder|<custom>`. Defaults: project-level (`Project.defaultEditor`) > global (`settings.json.defaultEditor`) > `vscode` if installed, else `finder`.

Under `apps/mac/codans/App/Services/` (new folder; added to `buildableFolders` in M7):

- `ExternalEditor.swift` — actor-style service. Knows the built-in allowlist:
  - `vscode` → `code <dir>`
  - `cursor` → `cursor <dir>`
  - `zed` → `zed <dir>`
  - `xcode` → `open -a Xcode <dir>`
  - `subl` → `subl <dir>`
  - `finder` → `open <dir>`
  Reads `settings.json.externalEditors[NAME]` for user-defined templates (e.g., `"windsurf": "/Applications/Windsurf.app/Contents/MacOS/Windsurf %p"` where `%p` expands to the directory). Invocation uses `Process` with an argv array — never a shell string — so paths never pass through a shell interpreter. Public API: `func open(worktreeID: WorktreeID, editor: String?) async throws` and `func openPath(path: String, editor: String?) async throws`; errors map to `IPCError.notFound` (editor not on PATH), `.unsupported` (template unknown), `.internal` (non-zero exit).
- `ExternalEditorResolver.swift` — tiny helper that resolves an editor name to a template, respecting overrides in this order: user templates > built-in allowlist > implicit fallback chain.

Under `apps/mac/codans/App/Features/Socket/handlers/`:

- `SystemOpenHandlers.swift` — `system.openInEditor` and `system.openPath` routing into `ExternalEditor`. Also wires `hierarchy.setProjectEditor` to persist `Project.defaultEditor`; the CLI verb `codans project set-editor` from M6 calls this.

Tests (under `codansTests/Services/`):

- `ExternalEditorAllowlistTests.swift` — each of the 6 built-in editors resolves to the expected argv; invocation uses a fake `ProcessRunner` that records the argv without actually spawning.
- `ExternalEditorTemplateTests.swift` — a user template with `%p` expansion resolves correctly; malformed templates are rejected at load.
- `ExternalEditorMissingBinaryTests.swift` — attempting `vscode` with no `code` on PATH returns `.notFound` with a clear message.

The GUI Worktree-header button arrives outside this plan (C8 UI work) — but the app-side plumbing is fully in place so the button is a one-line `externalEditor.open(worktreeID:, editor:)` call.

**Observable acceptance.** With the app running and a Worktree selected: `codans open --in vscode` launches VSCode on the Worktree directory; exit 0 in under 500ms (app-side Process is fire-and-forget). `codans open --in finder` opens the same directory in Finder. `codans open --in windsurf` (with a user template configured) uses the template. `codans open --in nosuchapp` exits 4 with a legible error. `codans project set-editor <id> zed && codans open` opens Zed.

**Expected commits.** `feat(app): ExternalEditor service + allowlist + user templates`, `feat(socket): system.openInEditor + system.openPath handlers`, `feat(cli): codans open command + editor defaulting`.

### Milestone 8: Integration tests, completion scripts, man page, docs

**Goal after this milestone.** The entire C3+C4 surface is covered by a headless integration test harness that launches the app, drives `codans` commands in sequence, and asserts catalog state + filesystem side effects. Pre-generated shell completions ship in the bundle. A groff man page is emitted from `codans --man`. Documentation is updated: the product spec Open-Questions table marks Q1, Q4, Q5, Q7 as resolved; the architecture doc's Open-Questions table marks Q3 and Q5 as resolved; the CHANGELOG records the release.

**Work.**

- `apps/mac/tcIntegrationTests/` — new Tuist target. Each XCTestCase launches a dedicated `codans` process via `Process` with `CODANS_SOCKET_PATH=/tmp/codans-integ-$(uuidgen).sock` and a throwaway `HOME=$(mktemp -d)`. The test body runs `codans` subcommands and asserts. One test per C3+C4 §Validation scenario:
  - `ValidationScriptTest.swift` — runs the script in C4 §Validation and acceptance verbatim (minus `codans skill install`, deferred to 0004); asserts final catalog matches a golden snapshot.
  - `HookLifecycleTest.swift` — installs a hook, fires the matching event via `codans hook fire`, asserts the handler ran (wrote to a tmp file).
  - `HookTailTest.swift` — opens `codans hook tail` in a background `Process`, fires three events via `codans hook fire`, asserts three NDJSON lines on the tail's stdout.
  - `OpenCommandTest.swift` — `codans open --in finder` against a tmp Worktree; asserts the expected Process was spawned (via an `ExternalEditor` test hook that records spawn attempts without launching a GUI app).
  - `CollisionCheckTest.swift` — simulates `/opt/homebrew/bin/codans` existing, runs the installer, asserts `tcode` symlink is created and `codans` is not.
- `apps/mac/codans-cli/Resources/completions/` — pre-generated `codans.zsh`, `codans.bash`, `codans.fish`. Regenerated via a `make mac-regen-completions` target (calls `codans --generate-completion-script <shell>` for each shell).
- `apps/mac/codans/Resources/codans.1` — groff man page generated from ArgumentParser command metadata. Include it as a resource in the `codans` Tuist target; `codans --man` prints it via `man -l -`.
- `docs/generated/codans-cli-reference.md` — auto-generated from `codans --help` and each subcommand's `--help`; `make mac-docs` regenerates.
- `docs/product-spec.md` — update the Open Questions table: Q1 (CLI name) resolved via C4 D1; Q4 (hook execution) resolved via C3 D1; Q5 (agent detection) resolved via C3 D10 + C4 Pane labels; Q7 (editor discovery) resolved via C4 D14 + M7 implementation. (The Q1-vs-Q5 lean in the product spec was pre-verified on 2026-04-20: both remain open pending this milestone.)
- `docs/architecture.md` — Open Architectural Questions 3, 5 resolved; update inline refs to the new `Hooks` subfolder + `SocketServer` path.
- `CHANGELOG.md` — add a "0.2.0 — Hooks + CLI" entry.
- `docs/exec-plans/README.md` — move 0003 from Active to Completed, list it alongside 0002.

Skill bundle work (`codans-skill/` peer directory, `codans skill install`) is explicitly outside this plan per DEC-5; the follow-on exec-plan 0004 delivers it.

**Observable acceptance.** `xcodebuild test -scheme tcIntegrationTests` runs all integration scenarios green in under 60s. A fresh contributor following the `CHANGELOG.md` release notes can install `codans`, tab-complete `codans hook ins<TAB>`, and read `codans --man | man -l -`.

**Expected commits.** `test(integration): tcIntegrationTests harness and scenarios`, `feat(cli): pre-generated completion scripts + man page`, `docs(spec): resolve product-spec + architecture open questions per C3+C4 plan`, `docs(changelog): 0.2.0 — Hooks + CLI`.

## Concrete Steps

Run every command from the repository root (`/Users/wanggang/dev/00/codans`) unless otherwise noted. Steps are grouped by milestone; keep the Progress section updated as each step completes.

### M1 steps

    # 1. Regenerate workspace after adding new source folders in Project.swift.
    make mac-generate

    # 2. Build CodansCore + CodansIPC.
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild build -workspace apps/mac/codans.xcworkspace \
                       -scheme CodansCore \
                       -scheme CodansIPC | xcbeautify
    # Expected: BUILD SUCCEEDED for both schemes.

    # 3. Run Codable tests.
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/codans.xcworkspace \
                      -scheme CodansCoreTests | xcbeautify
    # Expected tail: "Test Suite 'All tests' passed\n    Executed N tests, with 0 failures"
    # N should be prior-count + at least 20 new hook/IPC tests.

    # 4. Lint.
    make mac-lint
    # Expected: clean (no output).

### M2 steps

    make mac-generate
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/codans.xcworkspace \
                      -scheme codans \
                      -only-testing:codansTests/Hooks | xcbeautify
    # Expected: all hook-dispatcher tests pass.

    # Manual smoke: debug hook in CodansApp.init fires a synthetic pane.ready envelope.
    make mac-run-app
    # Expected: ~/.config/codans/hooks.json present if you touched any; /tmp/codans-hook-echo
    # contains a valid UUID iff the smoke subscription was installed.

### M3 steps (requires 0002 M4 merged)

    make mac-generate
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/codans.xcworkspace \
                      -scheme codans \
                      -only-testing:codansTests/Socket | xcbeautify
    # Expected: socket-lifecycle, handshake, hook handler, streaming, backpressure tests pass.

    # End-to-end wire smoke:
    make mac-run-app
    python3 scripts/wire-smoke.py system.ping
    # Expected: {"id":"…","result":{"ok":true}}

### M4 steps

    make mac-generate
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/codans.xcworkspace \
                      -scheme tcTests | xcbeautify
    # Expected: argument parsing, socket discovery, RPC client, alias resolver, rendering tests pass.

    # End-to-end smoke:
    make mac-run-app
    ./apps/mac/.build/.../codans system ping
    # Expected: pong (exit 0).
    ./apps/mac/.build/.../codans system status --json | jq .serverVersion
    # Expected: a version string matching the running app.

### M5 steps

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/codans.xcworkspace \
                      -scheme tcTests \
                      -only-testing:tcTests/HookCommandsTests | xcbeautify

    # End-to-end:
    make mac-run-app
    echo '{"id":"11111111-1111-4111-8111-111111111111","event":"pane.ready","command":"echo from-hook"}' \
      | ./apps/mac/.build/.../codans hook install -
    # Expected: "installed 11111111-…"
    ./apps/mac/.build/.../codans hook list --json | jq '.subscriptions | length'
    # Expected: 1
    ./apps/mac/.build/.../codans hook tail &
    ./apps/mac/.build/.../codans hook fire pane.ready --pane current
    # Expected: one NDJSON line on the tail's stdout.
    kill %1

### M6 steps (requires 0002 M5/M6 merged)

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/codans.xcworkspace \
                      -scheme tcTests | xcbeautify

    # End-to-end walk-through:
    make mac-run-app
    ./apps/mac/.build/.../codans space create "validate" --activate
    ./apps/mac/.build/.../codans project add .
    ./apps/mac/.build/.../codans worktree create exp/validate
    ./apps/mac/.build/.../codans pane open --cwd .
    ./apps/mac/.build/.../codans send @current 'echo hello\n'
    # Expected: current Pane's scrollback shows "hello".

### M7 steps

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/codans.xcworkspace \
                      -scheme codans \
                      -only-testing:codansTests/Services | xcbeautify
    # Expected: ExternalEditor allowlist + template + missing-binary tests pass.

    # End-to-end:
    make mac-run-app
    ./apps/mac/.build/.../codans open --in finder
    # Expected: Finder opens on the current Worktree directory; codans exits 0 in < 500ms.
    ./apps/mac/.build/.../codans open --in nosuchapp
    # Expected: stderr "error: unknown editor 'nosuchapp'"; exit 4.

### M8 steps

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild test -workspace apps/mac/codans.xcworkspace \
                      -scheme tcIntegrationTests | xcbeautify
    # Expected: full validation scenario passes end-to-end.

    # Regenerate completions + man page:
    make mac-regen-completions
    ls apps/mac/codans-cli/Resources/completions/
    # Expected: codans.zsh, codans.bash, codans.fish

    ./apps/mac/.build/.../codans --man | head -5
    # Expected: first lines of a groff man page.

## Validation and Acceptance

After all eight milestones land, a fresh contributor can perform the following end-to-end flow and observe the exact outputs:

1. `make mac-bootstrap && make mac-generate && make mac-build && make mac-run-app` — the app launches within 1s.
2. From another shell: `codans system ping` → `pong`, exit 0 within 50ms.
3. `codans space create work --activate && codans project add . && codans worktree create exp/e2e` — the sidebar reflects the new Space / Project / Worktree immediately.
4. `codans pane open --cwd .` in the new Worktree — a live shell appears in the active Tab.
5. `codans hook install <(cat tests/fixtures/hooks/notify-stop.json)` — the handler is installed; `codans hook list --json | jq '.subscriptions | length'` prints `1`.
6. In a third shell: `codans hook tail &`. In the Pane: type `echo DONE` and press Enter. The tail emits an NDJSON line with `event: "pane.outputMatch"`, `data.match: "DONE"`.
7. `codans broadcast --tab current 'date\n'` — every Pane in the current Tab shows today's date.
8. `codans open --in vscode` — VSCode opens the Worktree directory.
9. `codans system quit` — the app closes gracefully; the socket file is unlinked.
10. All test schemes pass: `xcodebuild test -scheme CodansCoreTests`, `-scheme codansTests`, `-scheme tcTests`, `-scheme tcIntegrationTests`.
11. `make mac-lint` is clean.

`codans skill install --claude-code` is **not** part of this validation — it ships with exec-plan 0004 (DEC-5). The `skill` subcommand is reserved in the ArgumentParser tree but responds with "not yet implemented" until 0004 lands.

Failure on any of the above blocks sign-off; the plan is not complete until all eleven are green.

## Idempotence and Recovery

Every milestone is re-runnable. Common recovery rituals:

- **Regenerate Xcode workspace.** `make mac-generate` is a pure function of `Project.swift` + Tuist config; safe to re-run.
- **Reset hooks config.** `mv ~/.config/codans/hooks.json ~/.config/codans/hooks.json.bak` forces a fresh empty config; M2's load path backs up broken files automatically.
- **Clear stale socket.** `rm -f /tmp/codans-$(id -u).sock` if a previous app crash left it; M3's server will unlink stale sockets on start but this gives the user an explicit recovery lever.
- **Reset catalog.** `mv ~/.config/codans/catalog.json ~/.config/codans/catalog.json.bak` (shared with 0002).
- **Uninstall `codans` shims.** `rm ~/.local/bin/codans ~/.local/bin/tcode`; M8's first-launch installer will reinstall on next app launch.
- **Unwind a failed hook install.** `codans hook remove <id>` is idempotent; if the id doesn't exist, exit 2 with no side effect.

None of the steps modify repository-wide state (no system `xcode-select`, no global git config, no PATH mutation via sudo). `DEVELOPER_DIR` is passed per command, matching bootstrap plan DEC-10. All tests that touch `~/.config/codans/` or `~/.claude/skills/` run against `HOME=$(mktemp -d)` to avoid stomping the user's real directories.

## Artifacts and Notes

Prototyping findings that inform this plan:

- **Length-prefix framing is a one-pass streaming decoder.** supaterm's `SupatermSocketProtocol.swift` reads a 4-byte header, uses `UInt32(bigEndian:)` to resolve length, and reads exactly that many bytes. Keeping the same shape in `CodansIPC.Framing` lets us port that reader verbatim; no custom state machine.
- **ArgumentParser's `AsyncParsableCommand` handles the `async throws` surface cleanly.** The top-level `CodansCLI.main()` becomes `await CodansCLI.main()`; each subcommand conforms to `AsyncParsableCommand` so `RPCClient.call` is awaited directly in `run()` bodies.
- **`Process` + process-group kill works for the timeout case.** Validated in a 20-line sandbox against a `yes | head -c 1M` command that ignores SIGTERM: `killpg` after a 2s grace delivers SIGKILL to the whole tree. No shell-builtin edge case.
- **Streaming end semantics on macOS Unix sockets.** `shutdown(SHUT_WR)` from the client causes the server's `read` to return 0 (EOF). That's the signal we use for client-initiated stream termination; the final `{stream: false}` frame is sent before the server then closes its own write half. Verified in a minimal two-process test.
- **Hot-reload of `NSRegularExpression`.** Compiling a 50-line regex in a tight loop takes ~50µs on M1; even with 100 subscriptions on reload, we spend under 5ms total — imperceptible. No need to cache compiled regex on-disk.

Open prototyping tasks (not blocking this plan — log in Surprises & Discoveries as results come in):

- Benchmark the `hook.events` streaming throughput under load (1,000 events/sec target per C4 §Performance). Plan-side expectation: meets target; if not, add per-connection newline-buffer coalescing.
- Confirm `UNUserNotificationCenter` can post notifications from a non-SwiftUI context for the eventual C6 consumer. Not blocking M2 because the `NotificationService` protocol abstracts it out.

## Interfaces and Dependencies

The following types, functions, and signatures must exist by plan completion. Names are binding — later plans will reference them.

**`CodansCore/Hooks/`** (no AppKit / SwiftUI / GhosttyKit imports):

    public enum HookEvent: String, Codable, Hashable, Sendable, CaseIterable {
      case paneCreated, paneReady, paneInput, paneOutput, paneOutputMatch,
           paneIdle, paneExited, paneCrashed,
           tabActivated, tabDeactivated, tabAutoClosed,
           worktreeActivated, worktreeDeactivated, worktreeCreated, worktreeRemoved
      public var scope: HookScope { get }
    }
    public enum HookScope: String, Codable, Sendable { case pane, tab, worktree, space }
    public struct HookMatchRange: Codable, Equatable, Sendable { public var start, length: Int }
    public enum HookEventData: Codable, Equatable, Sendable { /* 15 tagged cases */ }
    public struct HookEnvelope: Codable, Equatable, Sendable {
      public static let currentVersion = 1
      public var version: Int
      public var event: HookEvent
      public var timestamp: Date
      public var space: SpaceRef?
      public var project: ProjectRef?
      public var worktree: WorktreeRef?
      public var tab: TabRef?
      public var pane: PanelRef?
      public var data: HookEventData
      public func validateAnchors() throws       // debug-only callers
    }
    public struct HookSubscription: Codable, Equatable, Sendable, Identifiable {
      public var id: UUID
      public var event: HookEvent
      public var command: String
      public var matchPattern: String?
      public var matchFlags: RegexFlags
      public var scope: Scope
      public var timeoutSeconds: Double
      public var mode: Mode
      public var cwd: String?
      public var env: [String: String]
      public var allowRawOutput: Bool
      public var allowRawInput: Bool
      public var idleThresholdSeconds: Double?
      public var disabled: Bool
      public enum Scope: Codable, Equatable, Sendable { /* 7 variants */ }
      public enum Mode: String, Codable, Sendable { case fireAndForget, awaitActions }
      public struct RegexFlags: OptionSet, Codable, Sendable { /* caseInsensitive, multiline, dotAll */ }
    }
    public struct HookConfig: Codable, Equatable, Sendable {
      public static let currentVersion = 1
      public var version: Int
      public var recursionWindowMs: Int       // default 250
      public var subscriptions: [HookSubscription]
      public static let `default`: HookConfig
    }
    public enum HookAction: Codable, Equatable, Sendable { /* 10 variants; panelBroadcast uses IPC.BroadcastScope directly, DEC-12 */ }

**`CodansIPC/`**:

    public enum IPC {}
    public extension IPC {
      enum Method: String, Codable, Sendable { /* ~35 cases across system/hierarchy/terminal/hook; skill.* intentionally absent (DEC-5) */ }
      struct Request: Codable, Sendable  { let id: String; let method: Method; let params: JSONValue; let stream: Bool }
      struct Response: Codable, Sendable { let id: String; let stream: Bool; let result: JSONValue?; let error: IPCError? }
    }
    public enum IPCError: Codable, Equatable, Sendable {
      case unknownMethod(String)
      case invalidParams(String, path: [String]?)
      case notFound(kind: String, id: String)
      case conflict(reason: String)
      case unsupported(reason: String)
      case `internal`(String)
      case overloaded
      case versionMismatch(client: String, server: String)
      case invalidFrame(reason: String)        // DEC-3: oversize frames, malformed headers
    }
    public enum Framing {
      public static func encode(_ body: Data) -> Data
      public static func decode(from buffer: inout Data) throws -> Data?  // nil = need more bytes
    }
    public struct HelloRequest: Codable, Sendable { public let clientVersion: String; public let clientBinary: String }
    public struct HelloResponse: Codable, Sendable {
      public let serverVersion: String
      public let appBundleVersion: String
      public let protocolMajor: Int
      public let protocolMinor: Int
      public let deprecatedMethods: [String]
    }
    public struct BroadcastScope: Codable, Equatable, Sendable { /* { kind, target } */ }
    public struct PaneOpenRequest: Codable, Equatable, Sendable { /* tabID?, cwd?, initialCommand?, labels, activate */ }
    public struct AliasResolveRequest: Codable, Equatable, Sendable { /* kind, value, contextPaneID? */ }
    public struct AliasResolveResult: Codable, Equatable, Sendable { /* kind, id, disambiguations? */ }

**`apps/mac/codans/Hooks/`** (in-app subfolder):

    @MainActor public final class HookConfigStore {
      public init(fileURL: URL = Catalog.hooksDefaultURL())
      public func load() throws -> HookConfig
      public func save(_ config: HookConfig) throws
      public func scheduleSave(_ config: HookConfig)
      public func upsertInternal(_ subscriptions: [HookSubscription]) throws       // DEC-5 consumer C6 (0006)
      public func removeInternal(idsPrefixed prefix: String) throws                // DEC-5 consumer C6 (0006)
    }
    public protocol HookExecutor: Sendable {
      func run(subscription: HookSubscription, envelope: HookEnvelope) async -> HookExecutionResult
    }
    public struct HookExecutionResult: Sendable { /* exitCode, stdout, stderr, duration, timedOut, actions */ }
    public final class ProcessHookExecutor: HookExecutor { /* fork+exec via /bin/sh -c */ }
    public final class FakeHookExecutor: HookExecutor { /* records transcript; returns caller-supplied result */ }
    @MainActor public final class HookActionDispatcher {
      public init(
        hierarchy: HierarchyManager,
        terminal: TerminalEngine,
        notificationService: NotificationService
      )
      public func execute(_ action: HookAction, originatingFrom envelopeID: UUID) async throws
    }
    @MainActor public final class HookDispatcher {
      public init(
        config: HookConfig,
        store: HookConfigStore,
        executor: HookExecutor = ProcessHookExecutor(),
        actionDispatcher: HookActionDispatcher,
        maxConcurrency: Int = 8
      )
      public func attach(to events: AsyncStream<TerminalEvent>)
      public func fire(_ envelope: HookEnvelope) async
      public func reloadConfig() async throws
      public func internalEventStream() -> AsyncStream<HookEnvelope>
      public func register(subscriber: InternalHookSubscriber, for prefix: String) throws
      public func unregister(prefix: String)
      public var recentFires: HookRecentRing { get }
    }
    public protocol InternalHookSubscriber: AnyObject, Sendable {
      func handle(envelope: HookEnvelope) async
    }
    // DEC-10: multicaster fan-out
    @MainActor public final class HookEventMulticaster {
      public init(bufferPerSubscriber: Int = 64)
      public func publish(_ envelope: HookEnvelope)
      public func subscribe() -> (id: UUID, AsyncStream<HookEnvelope>)
    }

**`apps/mac/codans/App/Features/Socket/`**:

    public enum SocketPaths {
      public static func defaultSocketPath(uid: uid_t = getuid()) -> String
      public static func resolve(override: String? = ProcessInfo.processInfo.environment["CODANS_SOCKET_PATH"]) -> String
    }
    @MainActor public final class SocketServer {
      public init(path: String = SocketPaths.resolve(), dependencies: SocketDependencies)
      public func start() throws
      public func stop()
    }
    actor SocketConnection {
      init(fd: Int32, dependencies: SocketDependencies)
      func serve() async
    }
    struct SocketDependencies {
      let hierarchyManager: HierarchyManager
      let terminalEngine: TerminalEngine
      let hookDispatcher: HookDispatcher
      let externalEditor: ExternalEditor          // landed in M7
      // skillInstaller intentionally absent — DEC-5 defers to 0004
    }
    @MainActor public final class ExternalEditor {             // landed in M7
      public func open(worktreeID: WorktreeID, editor: String?) async throws
      public func openPath(path: String, editor: String?) async throws
    }

**`apps/mac/codans/`**:

    @main struct CodansCLI: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "codans",
        abstract: "Control codans from the terminal.",
        subcommands: [SpaceCommand.self, ProjectCommand.self, WorktreeCommand.self, TabCommand.self,
                      PaneCommand.self, SendCommand.self, BroadcastCommand.self,
                      SkillCommand.self /* M4 stub; fleshed out in 0004 per DEC-5 */,
                      OpenCommand.self  /* M7 */,
                      HookCommand.self, SystemCommand.self, RPCCommand.self]
      )
    }
    final class RPCClient {
      init(path: String, clientVersion: String = CodansCLI.version)
      func call<T: Decodable, P: Encodable>(_ method: IPC.Method, params: P, timeout: TimeInterval) async throws -> T
      func stream<T: Decodable, P: Encodable>(_ method: IPC.Method, params: P) -> AsyncThrowingStream<T, Error>
    }
    enum SocketDiscovery {
      static func discover(overridePath: String?) throws -> DiscoveredSocket   // re-exports SocketPaths.resolve for discovery-only
    }
    enum AliasResolver {
      static func resolve(_ value: String, kind: AliasResolveRequest.Kind, context: CLIContext, client: RPCClient) async throws -> UUID
    }
    enum ExitCode: Int32 {
      case ok = 0, userError = 1, notFound = 2, conflict = 3, unsupported = 4,
           overloaded = 5, versionMismatch = 6, noSocket = 10, requestTimeout = 11,
           launchTimeout = 12, `internal` = 20
    }

**`apps/mac/codans/Tests/Harness/`** (DEC-11; lives in `tcTests` bundle, excluded from `codans` binary):

    @MainActor public final class InMemoryIPCServer {
      public init(router: MethodRouter = .defaultForTests())
      public func start() -> (clientEnd: FileHandle, serverEnd: FileHandle)
      public func stop()
    }

**External dependencies added by this plan** (in `apps/mac/Tuist/Package.swift`):

- No new SPM packages. `ArgumentParser` and `swift-composable-architecture` are already in place from prior plans. `AsyncChannel` comes from `swift-async-algorithms` — add this package now at pin `1.0.0`.

**Tuist targets added by this plan**:

- `tcTests` (`.unitTests`, host: `codans` binary).
- `tcIntegrationTests` (`.unitTests`, host: none — launches app via `Process`).

No new static-framework targets. `Hooks/` remains an in-app subfolder.

**Tuist buildableFolder additions**:

- `CodansCore`: add `"CodansCore/Hooks"` in M1.
- `CodansIPC`: add `"CodansIPC/WireTypes"` if sources are split into a subfolder; otherwise single folder + multi-file is fine.
- `codans` app target: `codans/App/Features/Socket` added to `buildableFolders` in M3.
- `codans` app target: `codans/App/Services` added in M7 for `ExternalEditor` (no `SkillInstaller` — deferred to 0004 per DEC-5).
- `codansTests`: `codans/Tests/Hooks` (M2), `codans/Tests/Socket` (M3), `codans/Tests/Services` (M7) added as each milestone lands.
- `tcTests`: `apps/mac/codans/Tests/` added in M4; `apps/mac/codans/Tests/Harness/` (the `InMemoryIPCServer` DEC-11) added in M3 but only built when `tcTests` is the active scheme — the `codans` binary target explicitly excludes `Tests/` via its `buildableFolders` setting so harness code never links into the shipped CLI.
- `codansTests`: add `"codans/Tests/Hooks"` and `"codans/Tests/Socket"` and `"codans/Tests/Services"` as they land.
