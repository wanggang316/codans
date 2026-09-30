# Design Doc: iOS Companion (Codans Mobile)

**Status:** Draft — approved for implementation. M0 (multiplatform shared layer), M1 (Mac LAN gateway) and M2 (iOS MVP) are built. Phase 2 — the live terminal (M3), a rebuilt connection layer, the terminal keyboard, and the new information architecture and visual system — is being implemented (see [Phase 2](#phase-2-live-terminal-robust-connection-real-design), D29–D54). Phase 3 — internet access through a relay (D55–D60) — is being implemented; push notifications are design-only.
**Author:** Gump (with Claude)
**Date:** 2026-09-25 (phase 2: 2026-09-26)

## Context and Scope

codans orchestrates terminals — and the coding agents running in them — on a Mac. The recurring pain it leaves open is *being away from the Mac*: an agent blocks on a yes/no question, a long task finishes, a build fails, and nobody sees it until the user walks back to the desk.

An iOS port of the app itself is impossible. The iOS sandbox forbids `fork`/`exec`, so the shell, `zmx`, `git`, `gh` and every agent CLI that codans drives cannot run on the device. The iOS app is therefore a **remote companion of a running Mac app**: it shows agent state, reads pane output, sends input, and navigates the Project → Worktree → Tab → Pane hierarchy, while every process keeps living on the Mac.

What already exists and shapes the design:

- **The IPC stack is almost transport-agnostic.** `SocketConnection` (`apps/mac/codans/App/Features/Socket/SocketConnection.swift`) consumes only `(reader: AsyncStream<Data>, write, close, peerPID)`; nothing in it knows about Unix sockets. The Unix-specific parts are `SocketServer`, `SocketPeerAuth` (authorization = `getpeereid` returns the same uid, no token) and `CallerPaneResolver` (attributes a call to a pane via the peer PID's process ancestry).
- **Streaming is plumbed but unused.** `MethodRouter.route(_:peerPID:)` has a `.streaming` outcome and `SocketConnection` drains it frame by frame, but no method streams today and there is no push/subscribe mechanism. Frames on one connection are served serially, so a long-lived stream monopolizes its connection.
- **Agent state is observable.** `AgentStateStore` is `@Observable`; `HierarchyManager` holds the Catalog. Both can feed an event stream via `withObservationTracking`.
- **The client library does not port.** `CodansKit`'s `Transport` protocol and `RPCClient` are transport-agnostic in shape but do "one connection + one `system.hello` per call" and depend on ArgumentParser and Unix sockets. It stays macOS-only.
- **The shared targets almost port.** `CodansIPC` is already platform-clean. `CodansCore` is blocked on iOS only by `ProjectColor`'s two `NSColor` conversions and by Carbon `kVK_*` key codes in `ScriptDefinition`, `ShortcutSchema` and `AppKitReservedDetector`.
- **Toolchain.** The build machine has Xcode 26.0.1 with the iOS 26.0 SDK; `apps/mac/Tuist.swift` pins `.upToNextMajor("26.0")`. There is no iOS 27.1 SDK and no iPhone Duo simulator. PRs get no CI.

Scope: the shared-layer changes in `apps/mac/`, the Mac-side gateway, the new `apps/ios/` Tuist project, and the wire additions (`events.subscribe`, the remote permission tiers). The Mac app's local IPC semantics do not change.

## Goals and Non-Goals

**Goals**

- From an iPhone, iPad or iPhone Duo on the same LAN as the Mac: see which agents need input, are working or are idle; read a pane's recent output; send text and named keys to a pane; navigate and activate Projects / Worktrees / Tabs / Panes; launch an agent profile.
- Pairing is explicit and revocable per device; an unpaired device on the LAN learns nothing beyond "a codans gateway exists here".
- The remote channel speaks the **same wire protocol** as the local CLI (framing, envelopes, method names, wire types). One `MethodRouter`, one set of handlers.
- The gateway is **off by default** and costs nothing when off.
- One iOS codebase adapts to iPhone, iPad and iPhone Duo (both displays, Split View, multiple windows) through size classes and standard containers only.

**Non-Goals**

- **Running anything on iOS.** No local shells, no local git, no on-device agents.
- **Access from outside the LAN in v1.** No relay, no port forwarding guidance, no cloud account in v1; Phase 3 adds an end-to-end encrypted relay ([Phase 3](#phase-3-internet-access-through-a-relay)), still with no port forwarding or account.
- **Push notifications in v1.** They require an always-reachable sender, which v1 does not have; the iOS app surfaces "needs input" only while connected.
- **A live, interactive terminal in v1.** v1's pane detail is a monospaced text snapshot refreshed on events. Phase 2 adds the byte-level live terminal ([Live Terminal](#live-terminal-m3)); from [terminal seats](#terminal-seats-the-size-follows-the-device-in-use) the pane takes the phone's size while the phone is the device in use.
- **Administrative or destructive remote operations.** Removing projects/worktrees, pruning, editing project scripts, quitting the app and opening editors on the Mac are never exposed remotely (see [Permission tiers](#permission-tiers)).
- **Multiple simultaneous Macs as one merged view.** The app can remember several paired Macs but shows one at a time.
- **Android, web, or watchOS clients.**

## Design

### Overview

```
iOS app (SwiftUI + TCA) ──NWConnection, TLS-PSK──▶ Mac RemoteGateway (NWListener, Bonjour _codans._tcp)
   CodansRemote (shared) ◀── same IPC framing / envelopes ──▶ SocketConnection → MethodRouter (+ CallerContext, permissions)
```

The Mac app gains a second listener next to the Unix socket. `RemoteGatewayServer` accepts TLS connections on the LAN with Network.framework, authenticates each peer with a **per-device pre-shared key**, and hands the decrypted byte stream to the existing `SocketConnection`. The only new concept on the server's request path is the **caller context**: the router learns *who* is calling (a local process, or a paired device with a permission tier) and rejects methods the tier does not allow before any handler runs.

The iOS app keeps two long-lived connections to its Mac: a **control** connection for request/response calls and an **events** connection that carries one `events.subscribe` stream (a snapshot, then debounced deltas of the hierarchy and agent states). UI state is derived from the event stream; pane text is pulled on demand with `pane.read`.

Why this shape:

- **Reuse over re-invention.** Keeping the wire protocol identical means every existing handler, wire type and test applies to remote callers, and the CLI can exercise the new streaming method locally. A separate REST/WebSocket API would duplicate the method surface and drift.
- **TLS-PSK is the platform's LAN peer-to-peer pattern.** Network.framework supports PSK cipher suites directly; it gives mutual authentication and encryption without certificates, a CA, or an account system, and a per-device key makes revocation a single Keychain delete.
- **Deny by default at one choke point.** Authorization lives in the router, keyed by a tier table defined next to the method enum in `CodansIPC`, so a newly added method cannot become remotely callable without someone deciding it should.

### System Context Diagram

```
┌──────────────────────────── Mac ─────────────────────────────┐
│                                                              │
│  codans CLI ──Unix socket──▶ SocketServer ─┐                 │
│  (same uid, peerPID)                       │                 │
│                                            ▼                 │
│                              SocketConnection (per conn)     │
│                                            │ CallerContext   │
│  RemoteGatewayServer ──NWFrameTransport────┘ .local(pid) /   │
│   NWListener + Bonjour                       .remote(dev,tier)│
│   TLS-PSK (per-device key                   ▼                │
│   selected by identity)             MethodRouter             │
│        ▲                             │ tier check            │
│        │                             ▼                       │
│  PairedDeviceStore                handlers ──▶ HierarchyManager│
│   remote-devices.json (metadata)            ──▶ AgentStateStore│
│   Keychain (PSKs)                           ──▶ TerminalEngine │
│                                   EventHub (events.subscribe)  │
└────────▲──────────────────────────────────────────────────────┘
         │ LAN: _codans._tcp, TXT channel=<slug>
         │ control conn (unary)  +  events conn (one stream)
┌────────┴─────────── iPhone / iPad / iPhone Duo ──────────────┐
│  CodansMobile: ConnectionStore ── RemoteRPCClient ×2         │
│  Features: Connection · Agents · Browser · PaneDetail · Settings│
│  Keychain (PSK, this-device-only)                            │
└──────────────────────────────────────────────────────────────┘
```

### Security Model

#### Threat model

The gateway turns a local-only control plane into a network service. Anything that can send `terminal.sendInput` to a shell pane can run arbitrary commands as the user, so the gateway is treated as a remote shell with a narrow door.

| Adversary | Capability | Mitigation |
|---|---|---|
| Passive observer on the LAN | Sniffs traffic | All traffic is TLS; no plaintext mode exists. |
| Active attacker on the LAN (hostile Wi-Fi, ARP spoofing) | Impersonates either side, replays, connects directly | TLS-PSK is mutual: without the device's key neither side can complete the handshake, so an attacker can neither read nor inject nor pose as the Mac. Replay is defeated by TLS. |
| Unpaired device on the LAN | Discovers the service, connects | Handshake fails before any application byte is read. Bonjour reveals only the service name and the channel slug. |
| Pre-auth flooding | Opens many connections | Bounded concurrent handshakes and a handshake timeout; failures cost no app-layer work. |
| Holder of a leaked pairing code | Has a valid key | The pairing payload *is* the credential. It is shown only on explicit request, expires if unused, and the device list shows last-seen time and allows revocation. |
| Stolen or lost phone | Has a valid key | Revoke from the Mac (deletes the key, drops live connections). On the phone the key is `ThisDeviceOnly`, never synced to iCloud or included in backups restored to another device. |
| Paired read-only device (compromised app, curious user) | Calls methods | Router rejects anything outside its tier; the never-remote list is not reachable at any tier. |
| Paired interactive device | Types into panes | Equivalent to shell access by design; the tier is opt-in per device and can be downgraded at any time. |

Out of scope: an attacker with code execution on the Mac as the user (already owns everything), and a malicious Mac the user deliberately paired with.

#### Transport security: TLS-PSK with per-device keys

- **Cipher suite.** TLS 1.2 with `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (RFC 7905): ECDHE for forward secrecy, authenticated by the PSK, with an AEAD record cipher. The SDK's `tls_ciphersuite_t` has no `ECDHE_PSK` AES-GCM suite, and `TLS_PSK_WITH_AES_128_GCM_SHA256` lacks forward secrecy, so this is the only suite offered (D4). TLS 1.3 PSK is not used because Network.framework's external-PSK API is exposed for the 1.2 suites.
- **Client side.** `sec_protocol_options_add_pre_shared_key(options, psk, identity)` with the key and identity from the pairing payload, and the chosen cipher suite appended explicitly.
- **Server side.** Network.framework has no server-side per-connection key lookup: `sec_protocol_options_set_pre_shared_key_selection_block` is the *client's* hook for choosing an identity from a server hint, and the negotiated identity is not reported in the connection's metadata. The listener therefore registers every paired device's key with `sec_protocol_options_add_pre_shared_key`; the TLS stack picks the key by the identity the client offers and rejects an unknown identity (`unknown_psk_identity`). The gateway rebuilds its listener whenever the paired set changes, and closes a revoked device's open connections itself.
- **Peer proof.** Because the server holds every key and cannot tell which one a handshake used, a device paired read-only could otherwise handshake with its own key and then *claim* an interactive device's ID. So the first frame after TLS, before any IPC traffic, is `RemotePeerProof`: `{ "v": 1, "identity", "mac": HMAC-SHA256(key, exporter) }`, where `exporter` is the RFC 5705 keying material of *this* TLS session (`sec_protocol_metadata_create_secret`, label `EXPORTER-codans-remote-peer-proof`, 32 bytes). The server looks up the named identity's key and verifies the MAC in constant time; the identity becomes the connection's device ID. A proof cannot be replayed on another session, and a missing or silent proof times out (10 s) so an idle peer cannot hold a slot.
- **Key material.** Each key is 32 random bytes from `SecRandomCopyBytes`, generated on the Mac at pairing time. Keys are never derived from anything a human types.
- **Proof first.** A loopback unit test (`NWListener` + `NWConnection` in-process, `CodansRemoteTests/RemoteTLSLoopbackTests`) proves on the installed SDK: the correct key handshakes on the chosen suite, a wrong key, an unknown identity and a revoked identity are rejected, a paired device cannot impersonate another, a proof from another session is rejected, and a silent peer times out. The self-signed-certificate fallback (see Alternatives) was not needed.

#### Key storage

| Side | Store | Attributes |
|---|---|---|
| Mac | Keychain generic password; service `com.gumpw.codans.remote.<channel-slug>`, account = device ID | `kSecAttrAccessibleAfterFirstUnlock`; not synchronizable |
| iOS | Keychain generic password; service `com.gumpw.codans.mobile.pairing`, account = gateway service name + device ID | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; not synchronizable |

The key never appears in `remote-devices.json`, logs, or crash reports.

#### Gateway lifecycle

- **Off by default.** Settings → Remote Access has a single switch. Off means no listener, no Bonjour advertisement, no open port.
- Turning it off cancels the listener, withdraws the Bonjour service and closes every remote connection immediately.
- `CODANS_REMOTE_DISABLED=1` forces the gateway off regardless of settings, so isolated test instances never advertise on the LAN. The variable is registered in `CodansEnvironment.Key` like every other codans variable.
- The listener serves on LAN interfaces (Wi-Fi, Ethernet) and prohibits cellular interfaces. It is not designed for exposure through port forwarding — PSK still protects it if the user does so, but that path is unsupported.
- Pre-auth limits: at most 8 concurrent unauthenticated handshakes and a 10 s handshake timeout. Per-connection backpressure is the existing 64-in-flight limit.

### Pairing

Pairing is initiated on the Mac and completed on the phone:

1. Settings → Remote Access → **Pair New Device…** (enabled while the gateway is on). The Mac generates a device ID and key, stores the key in the Keychain, and writes a *pending* device record (name "New device", tier `.readOnly`; the permission picker next to the code switches it to `.interactive`).
2. The pane shows, inline in its grouped form rather than in a custom sheet, a QR code (generated with CoreImage's QR filter) and a **Copy Pairing Code** button for the same payload. The section turns into "*name* is paired" once the phone's first handshake lands.
3. The phone scans the code (VisionKit `DataScannerViewController`), the user pastes it, or the system Camera opens it: the payload is a `codans-pair:` URL the app registers. A link opened from outside the app is never paired silently; the app names the Mac and asks first, because any web page or message can carry such a link and pairing with a stranger's Mac would send it everything typed into its panes.
4. The phone stores the key, browses for the gateway, connects and handshakes. The first successful handshake flips the record from pending to active and stamps `lastSeenAt`.
5. A pending record unused for 10 minutes is discarded along with its key, so an abandoned QR code on screen stops being a credential.

**Payload.** Versioned Codable, encoded as `codans-pair:` + base64url(JSON):

```json
{
  "v": 1,
  "serviceName": "Gump's MacBook Pro (codans)",
  "deviceID": "7C1E…-UUID",
  "pskIdentity": "7C1E…-UUID",
  "psk": "<base64url, 32 bytes>",
  "channel": "codans"
}
```

`deviceID` and `pskIdentity` are carried separately so the identity format can change without renaming devices. Decoding validates `v`, key length and channel; an unknown version is rejected with a "update the app" message rather than guessed at.

### Discovery

- Bonjour service type `_codans._tcp`, advertised by the `NWListener` itself; the port is picked by the system.
- TXT record: `channel=<BuildChannel.slug>` (`codans` or `codans-dev`) and `v=<protocol major>`. The phone only lists services whose channel matches the paired payload, so a Debug build on the same Mac never answers a phone paired with the Release build — the name is the channel, as everywhere else in codans (see [Environment](environment.md)).
- The service name includes the channel for Debug builds so the two are distinguishable in any Bonjour browser.
- iOS declares `NSBonjourServices = ["_codans._tcp"]` and `NSLocalNetworkUsageDescription`; the local-network privacy prompt is expected on first browse and the Connection feature explains a denial instead of spinning.

### Permission Tiers

Authorization is a property of the method, declared in `CodansIPC` as `IPC.Method.remoteTier`, an exhaustive `switch` with no `default`, so adding a method forces a decision. A unit test enumerates `IPC.Method.allCases` and asserts each case's tier against a fixture, so a silent change shows up in review.

```
enum RemoteTier { case readOnly, interactive, localOnly }
enum RemotePermission { case readOnly, interactive }   // per paired device
```

A remote call is allowed when the method's tier is `.readOnly`, or when it is `.interactive` and the device's permission is `.interactive`. `.localOnly` is never allowed remotely. Rejected calls return the existing IPC error shape with a dedicated `forbidden` code; they are logged with the device ID and method name.

| Tier | Methods |
|---|---|
| `.readOnly` | `system.hello`, `system.ping`, `system.version`, `system.status`; `hierarchy.list*`, `hierarchy.describe*`, `hierarchy.resolveAlias`, `hierarchy.resolvePaneLabel`, `hierarchy.resolveWorktreeGlob`; `agent.listStates`, `agent.listProfiles`; `pane.read`, `pane.info`, `pane.attachStream`; `terminal.readText`; `workspace.describe`; `project.listScripts`; `events.subscribe` |
| `.interactive` | `terminal.sendInput`, `terminal.sendKey`, `terminal.sendEvents`; `agent.launch`; `hierarchy.createWorktree` (branch name only: a remote caller passing `path` or `reuseExisting` is refused); `hierarchy.activateWorktree`, `hierarchy.activateTab`, `hierarchy.focusPane`, `hierarchy.createTab`, `hierarchy.openPane`, `hierarchy.splitPane`, `hierarchy.zoomPane`, `hierarchy.unzoomPane`; `hierarchy.renameTab`, `hierarchy.closeTab`, `hierarchy.closePane` |
| `.localOnly` — **never remote** (a security position, not a backlog) | `system.quit`; `editor.*`; `hierarchy.removeProject`, `hierarchy.removeWorktree`, `hierarchy.pruneWorktrees`; `project.addScript`, `project.updateScript`, `project.removeScript`; `workspace.remove`; `terminal.broadcastInput`; `terminal.sendRawBytes` |
| `.localOnly` — not remote yet (may be promoted later with a design change) | everything else: other renames, tags and tag filter, `hierarchy.addProject`, `pane.close`, `hierarchy.resizePane`, `hierarchy.setPaneLabels`, `hierarchy.setProjectEditor`, `terminal.resetPane`, `terminal.retryPane`, `workspace.create` / `add` / `drop`, `handoff.*`, `agent.wait` |

Why the never-remote entries are never: they destroy data or history (`remove*`, `prune*`), persist commands that later run as the user (project script writes), act on the Mac outside codans' own window (`editor.*`, `system.quit`), or widen the blast radius of a single keystroke beyond the pane on screen (`broadcastInput`, `sendRawBytes` — raw bytes also bypass the named-key vocabulary that keeps input reviewable). `agent.wait` is excluded for a different reason: it blocks its connection, and the event stream already answers the same question.

New pairings default to `.readOnly`; `.interactive` is an explicit choice in the pairing sheet or the device list.

Phase 2 promotions (D37, D38): managing tabs and panes from the phone is part of the interactive reach, so `hierarchy.renameTab`, `hierarchy.closeTab` and `hierarchy.closePane` move to `.interactive`. `hierarchy.closePane` **ends the pane's shell** (it is not a detach), so the phone always asks for confirmation and says the process will end; `hierarchy.closeTab` gets the same confirmation. `hierarchy.zoomPane` / `unzoomPane` were already `.interactive` and are now routed. `hierarchy.focusPane` stays `.interactive` but the phone never calls it just because the user selected a pane on the phone: it moves the Mac's keyboard focus, and viewing on the phone must not steal the desk. `pane.attachStream` is `.readOnly` (it shows what `pane.read` already shows); `terminal.sendEvents` is `.interactive` like every other input method. `terminal.retryPane` moved back to `.localOnly`: it was never routed, and the runtime's retry only clears crash-loop bookkeeping without restarting an exited shell, so the phone's exited-pane Retry needs a real restart capability first.

### Caller Context

`MethodRouter.route(_:peerPID:)` becomes `route(_:context:)`:

```
enum CallerContext { case local(peerPID: pid_t?), remote(deviceID: UUID, permission: RemotePermission) }
```

- `SocketServer` connections are `.local(peerPID:)`; behaviour is unchanged, including pane attribution for `hierarchy.resolveAlias`.
- Gateway connections are `.remote(...)` with `peerPID == nil`, so process-ancestry attribution never runs for them. The permission is read from `PairedDeviceStore` per request, not captured at connect time, so a downgrade takes effect on the next call. A change also closes the device's connections: the phone renders its input controls from the permission in its handshake, so it reconnects (0.5 s) to learn the new one.
- The tier check runs in `route` before any namespace adapter, so handlers stay unaware of remote callers.
- `SocketConnection` takes an optional context resolver instead of a fixed context; the gateway's resolver reads the device's current permission from `PairedDeviceStore` on every request. A device revoked while connected resolves to nil and is answered with `forbidden` even before the gateway finishes closing its connection.
- Refusals use a new `IPCError.forbidden(reason:)` (wire code `forbidden`). The CLI maps it to exit code 4 (unsupported); a local caller never receives it.

### Client Connection Model

`RemoteRPCClient` (an actor in `CodansRemote`) differs from the CLI's `RPCClient`: it holds **one long-lived connection**, sends `system.hello` once, assigns request IDs, and keeps an ID → continuation table so several requests can be in flight. Streaming responses are dispatched by ID to an `AsyncStream`.

The iOS app opens **two** such connections per Mac:

| Connection | Carries | Why separate |
|---|---|---|
| control | unary calls: `hierarchy.*`, `pane.read`, `terminal.send*`, `agent.launch`, … | `SocketConnection` serves frames serially; putting them behind an endless stream would starve them. |
| events | exactly one `events.subscribe` stream | The stream is the app's source of truth; its lifetime is the connection's lifetime. |
| stream (phase 2, 0–4) | exactly one `pane.attachStream` per connection, one per visible pane | A terminal stream is endless and chatty; sharing a connection would starve the control calls or another pane's stream (D33). |

Pipelining on the control connection still helps (requests queue without extra round-trips), but responses arrive in request order. Changing the server to serve frames concurrently was rejected for v1 (see Alternatives).

**Lifecycle.** `scenePhase` drives connection state: entering background closes both connections (iOS suspends sockets anyway); returning to active reconnects with exponential backoff (0.5 s doubling to a 30 s cap, reset on success) and resubscribes, which delivers a fresh snapshot. Network path changes (`NWPathMonitor`) trigger an immediate retry. Phase 2 replaces this with an explicit phase machine, a background grace period and a failure taxonomy; see [Connection Layer](#connection-layer).

### Event Stream: `events.subscribe`

A streaming method added to `IPC.Method`, with wire types in `CodansIPC/WireTypes/Events*.swift`. It is available to the local CLI as well, which is how it is tested end to end without a phone.

**Request.** `{"topics": ["hierarchy", "agents"]}`; omitting `topics` means all. Unknown topics are an `invalidParams` error so clients cannot silently subscribe to nothing.

**Frames** (each a `stream: true` response on the request's ID):

| `kind` | When | Payload |
|---|---|---|
| `snapshot` | First frame, always | Full hierarchy summary (projects → worktrees → tabs → panes: IDs, names, selection, pane titles and agent kind) and all current agent states |
| `hierarchyChanged` | Catalog changed | The full hierarchy summary again |
| `agentStatesChanged` | Any agent state changed | Upserted states keyed by pane ID, plus removed pane IDs |
| `heartbeat` | Every 30 s without other frames | Empty |

Every frame carries a monotonically increasing `seq`, for diagnostics and ordering assertions in tests.

**Semantics.**

- **Snapshot, then deltas.** The client replaces its model on `snapshot` and applies deltas afterwards. There is no resume token: any reconnect starts with a new snapshot, which keeps the server stateless per subscriber.
- **Coalesced.** The first change to a topic after a quiet period opens a ~250 ms window; when it closes the `EventHub` recomputes that topic's projection once (re-arming observation in the same step) and hands the value to every subscriber. A window anchored on the first change, rather than a trailing debounce, bounds latency even under a source that never goes quiet (agent viewport text changes continuously). Each subscriber keeps only the latest value per topic and builds its frame when the connection pulls it, so a slow reader costs bounded memory no matter how chatty the source is, and a value identical to what was already sent produces no frame.
- **Hierarchy deltas are whole-section replacements.** The summary is small (tens of kilobytes for large catalogs) and replacing it avoids a patch algebra and its bugs. Agent states change far more often, so they are sent as per-pane upserts.
- **Sources.** An `EventHub` on the main actor observes `HierarchyManager` and `AgentStateStore` with `withObservationTracking`, re-arming after each change, and fans out to subscribers. It projects into wire types; it never exposes live objects.
- **End of stream.** The server ends the stream (final `stream: false` frame, then close) when the gateway is turned off or the device is revoked. The heartbeat lets the client detect half-open connections after Wi-Fi hand-offs.

Pane text is deliberately *not* on the event stream: it is large, high-frequency, and only needed for the pane on screen. In v1 `PaneDetail` pulls `pane.read(tail: N)` when an event touches its pane and on a fallback timer while visible; from protocol minor 2 the terminal view uses its own `pane.attachStream` byte stream instead ([Live Terminal](#live-terminal-m3)).

**Phase 2 summary fields** (D39). The hierarchy summary grows additively; every new field is optional, so an older phone ignores them and a newer phone decodes an older Mac's summary:

| Field | Meaning |
|---|---|
| `TabSummary.layout` | The tab's split tree as a recursive node (split direction and ratio, or a pane leaf), so the phone can list panes in split order and the iPad can mirror the layout. The flat pane list stays. |
| `TabSummary.zoomedPaneID` | The pane zoomed on the Mac, if any. |
| `PaneSummary.cwd` | Working directory, for the pane menu. |
| `PaneSummary.isLive` | Whether the pane has a live surface on the Mac (input needs one, D36). Driven by an observable surface revision in `GhosttyRuntime` so a change is pushed, not polled. |
| `HierarchySummary.activePaneID` | The Mac's focused pane, used as the phone's landing pane when it has no remembered one. |

### Data Storage

- **Mac, `remote-devices.json`** under `AppDirectories.configDirectory` (so Debug and Release have separate device lists), written through `AtomicFileStore` with `version: 1`: per device `deviceID`, `name`, `permission`, `state` (pending/active), `createdAt`, `lastSeenAt`. Unknown versions are routed aside like every other codans file. `lastSeenAt` writes are throttled (once per connection, not per request).
- **Mac Keychain:** one PSK per device (above). Revocation deletes the Keychain item first, then the record, then closes live connections.
- **Mac settings:** the gateway on/off switch lives in `settings.json` (`remoteAccess.enabled`, default `false`), tolerant-decoded like other settings.
- **iOS:** paired gateways (service name, channel, device ID) in the app's `UserDefaults`; keys in the Keychain. Per-scene navigation state in `@SceneStorage`. From phase 2, an **offline cache** per gateway (D44): the last hierarchy summary and agent states as versioned JSON in Application Support, shown as stale on cold start until the first snapshot replaces it. The snapshot on connect stays authoritative; the cache is never written back to the Mac and an unknown cache version is discarded.

### Component Boundaries

| Component | Location | Responsible for | Not responsible for |
|---|---|---|---|
| `CodansCore`, `CodansIPC` | `apps/mac/` | Domain and wire types, now built for macOS and iOS | Any platform UI type; `NSColor` conversions move to the app, Carbon key codes are replaced by an in-module `KeyCode` table with identical values |
| `CodansRemote` (static framework, macOS + iOS) | `apps/mac/CodansRemote/` | `PairingPayload`, `RemoteTLS` (`NWParameters` builders), `NWFrameTransport` (`NWConnection` ⇄ reader/write/close), `RemoteRPCClient`, Bonjour constants | Pairing UI, device persistence, authorization decisions |
| `RemoteGateway` feature | `apps/mac/codans/App/Features/RemoteGateway/` | `RemoteGatewayServer` (listener, Bonjour, PSK selection), `PairedDeviceStore`, Settings → Remote Access panel | Method handling (delegates to `SocketConnection` / `MethodRouter`) |
| `MethodRouter` + `CallerContext` | `apps/mac/codans/App/Features/Socket/` | Tier enforcement, routing | Transport details |
| Terminal stream (phase 2) | `apps/mac/codans/Runtime/Ghostty/` (`ZmxSocket`, `ZmxStreamClient`, `ZmxStreamDecoder`), `apps/mac/codans/App/Features/Socket/TerminalStream/` (`PaneStreamSession`, `TerminalStreamRegistry`), `CodansIPC/WireTypes/TerminalStreamWireTypes.swift`, `TerminalInputEvent.swift` | Observing a pane's zmx daemon, coalescing and resync, stream limits, input event encoding via `PaneSurface` | PTY size (the Mac surface owns it), rendering |
| `CodansMobile` (iOS app) | `apps/ios/CodansMobile/` | Connection, pairing UI, Agents / Browser / PaneDetail / Terminal / Settings features, design system | Anything that needs a process |

Dependency direction: `CodansCore` ← `CodansIPC` ← `CodansRemote` ← {`codans` app, `CodansMobile`}. `CodansRemote` imports Network and Security but no UI framework. `CodansMobile` depends on the three shared targets through Tuist cross-project references (`.project(target:path: "../mac")`) plus TCA at the same version as the Mac app; it does **not** link GhosttyKit, `CodansKit` or ArgumentParser.

### iOS App Structure

- **Project.** `apps/ios/Project.swift`: target `CodansMobile`, `PRODUCT_NAME = Codans`, bundle ID `com.gumpw.codans.mobile`, destinations iPhone + iPad, iOS 26.0, Swift 6 with MainActor default isolation. `apps/ios/Tuist.swift`, `apps/ios/Tuist/Package.swift` (TCA pinned to the Mac app's version), `apps/ios/Makefile`, and `ios-*` delegators in the root `Makefile`.
- **Info.plist.** `NSLocalNetworkUsageDescription`, `NSBonjourServices`, `NSCameraUsageDescription`, `UIApplicationSupportsMultipleScenes = YES`; no orientation lock.
- **Features** (TCA reducers end in `Feature`, views in `View`): `Connection` (browse, pair, reconnect), `Browser` (the home screen: Project → Worktree, then the worktree's Tab → Pane), `Agents` (event-driven list grouped as *needs input* / *working* / *idle*, presented as a sheet; picking an agent navigates the workspace to its pane), `PaneDetail` (text snapshot, input bar, key row Enter / Esc / Ctrl-C / Tab / ↑ / ↓, hidden for read-only devices; iPad hardware-keyboard shortcuts via `.keyboardShortcut`), `Composer` (the "Ask <agent>" card at the bottom of the workspace, for interactive devices: pick a worktree or a new one, pick an agent profile, send a first message; the Mac creates the worktree when asked and runs `agent.launch` with the message as its prompt, without taking focus on the Mac), `Settings` (paired Macs, forget; a sheet).
- **App-level state.** One `ConnectionStore` per process, shared by all scenes: two windows showing the same Mac share one control and one events connection.
- **Phase 2** reshapes these features — `Features/Terminal` (`TerminalStreamFeature`, `MirrorTerminalView`, `TerminalInputView`, `TerminalKeyBar`) replaces the text snapshot for minor-2 Macs, a worktree opens straight into its terminal, and `App/DesignSystem/` holds the visual system. See [Phase 2](#phase-2-live-terminal-robust-connection-real-design).

### iPhone, iPad and iPhone Duo Adaptation

iPhone Duo (announced 2026-09-09, on sale 2026-10-23) has a 5.4″ outer display and a 7.6″ inner display, runs iOS 27 / 27.1, and supports two-app Split View and multiple windows of one app. The rules below make one layout serve every device; they follow Apple's guidance for the device and are ordinary good practice on iPad.

1. **Size classes only, never orientation.** The inner display does not honour an app's supported orientations, and compact/regular is what actually varies. The outer display is compact width; the inner display is regular × regular. No code branches on `UIDevice.orientation` or interface orientation.
2. **Standard containers.** The root is one three-column `NavigationSplitView`: projects with their worktrees in the sidebar, the selected worktree's tabs and panes, then the pane. Agents and Settings are toolbar buttons that present sheets, not top-level tabs, so the home screen is the workspace itself; agent state also shows as badges on worktree and pane rows, and the Agents button turns orange with a count while agents need input. From iOS 27.1 standard navigation bars and toolbars move to the side on the Duo inner display automatically; custom bars would need the 27.1 `ReservedRegion` API, which v1 does not use because it draws no custom bars.
3. **No `UIScreen.main`.** It is being deprecated and is wrong on a device with two displays. Scale comes from `@Environment(\.displayScale)` / `traitCollection.displayScale`; sizes come from layout, not the screen.
4. **Safe areas per edge.** Insets are not assumed symmetric or bottom-heavy. Views use `.safeAreaInset(edge:)` and `.ignoresSafeArea(_:edges:)` with explicit edges; the PaneDetail input bar is a bottom safe-area inset, not a fixed offset.
5. **Multiple scenes.** `WindowGroup` with `UIApplicationSupportsMultipleScenes`; each scene owns its navigation store, all scenes share `ConnectionStore`.
6. **Continuity across fold/unfold and window changes.** Selected tab, selected project/worktree/pane IDs and the PaneDetail scroll anchor are kept in `@SceneStorage`, so folding (inner → outer display), unfolding and Split View resizes restore the same place. Anything not in scene storage must be re-derivable from the event snapshot.
7. **Toolchain.** Built with the iOS 26 SDK the app runs on iPhone Duo, but the inner display gets a compatibility (non-full-screen) presentation. The full Duo experience requires building with **Xcode 27.1** and validating in the DeviceHub Duo simulator (fold/unfold, rotation, Split View). That is an environment prerequisite: once Xcode 27.1 is installed, `apps/ios/Tuist.swift`'s Xcode constraint is widened and the Duo checks in the testing plan run. Until then the deliverable is "adapted per the rules above, pending 27.1 verification".

## Phase 2: Live Terminal, Robust Connection, Real Design

> **In progress.** v1 proved the gateway, pairing, browsing, polled pane text and the composer, but read as a demo: the system-blue look, no designed waiting or error states, a connection that retried revoked devices forever and could not tell "Remote Access is off" from "not on this network", no way to see or manage split panes, and a text field standing in for a terminal keyboard. Phase 2 replaces the 3 s `pane.read` polling with a live byte stream, rebuilds the connection layer, designs the terminal keyboard, and gives the app its own monochrome visual system. Decisions are D29–D54.

```
iPhone / iPad                                          Mac
TerminalScreen (SwiftTerm, render only) ◀─stream conn── pane.attachStream ─ PaneStreamSession ─ ZmxStreamClient ─(Observe)─▶ zmx daemon
TerminalInputView (UITextInput, hardware keys) ─control─▶ terminal.sendEvents ─ PaneSurface.sendKeyEvent (libghostty encoding)
Workspace / Composer ◀─events conn─ events.subscribe (+ layout, zoomedPaneID, cwd, isLive, activePaneID)
```

### Live Terminal (M3)

Goal: an interactive terminal view of a pane on iOS that shows exactly what the Mac shows, without ever changing the pane's size.

#### zmx observer protocol

A zmx daemon already broadcasts PTY output to every attached client, but a client that sends `Init`, `Input` or `Resize` can become the *leader* and resize the PTY, and `History vt` misplaces the cursor when there is scrollback. The phone must never own the size — fighting the desktop layout would reflow the Mac's view, and resize reflow is where zmx has crashed before. The zmx fork (`apps/mac/ThirdParty/zmx`) therefore gains a read-only **observer** role (D29):

| Tag | Direction | Payload |
|---|---|---|
| `Observe = 15` | client → daemon | `u32 scrollbackRows`: how much scrollback the initial state may carry |
| `ObserveState = 16` | daemon → observer | `rows`, `cols`, `flags`, then the serialized terminal state: a two-phase clear, synchronized-output markers stripped, scrollback capped at the requested rows |
| `ObserveResize = 17` | daemon → every observer | The new `rows` / `cols`, emitted at the point in the byte stream where the leader resized, so output before and after it is rendered at the right width |

- An observer never becomes leader: `handleInput`, `handleInit` and `handleResize` return early for it, and it does not set `has_terminal_client`, so attaching a phone changes neither the PTY size nor the daemon's idea of whether a terminal is attached.
- The fork's `ipc.zig` wire-freeze test covers the new tags; `observer.bats` asserts that an observer's `Input` / `Init` / `Resize` are ignored and that a leader resize reaches observers as `ObserveResize`.
- **Mac client.** `ZmxSocket` (extracted from `ZmxControlClient`) plus `ZmxStreamClient`, a `nonisolated` reader driven by a `DispatchSourceRead` that drains the socket continuously, so a slow phone backs up in codans' bounded buffer (below), never in the daemon. Decoding is a pure state machine, `ZmxStreamDecoder`: *syncing* until `ObserveState` arrives, then *live*. `Output` frames that arrive before the state are dropped because the state already contains them, which gives neither a gap nor a duplicate. Unknown tags are skipped (`ZmxFraming.decodeSkippingUnknown`).
- **Old daemons** (D30). Panes started before the upgrade run a daemon that does not know `Observe`. If no `ObserveState` arrives within 300 ms, the client falls back to `History vt` at the grid size from `PaneSurface.gridSize()`, sends the result as a `reset` marked `fidelity: "approximate"` with `ESC[?2026l` appended (so a truncated synchronized-output block cannot freeze the phone's renderer), and takes a fresh snapshot on the next geometry push. The observer connection still never sends `Init`, `Input` or `Resize`; sizing belongs to the separate terminal seat. Restarting the pane upgrades it to the exact path.

#### Stream method: `pane.attachStream`

A streaming method (D31) that names a pane and returns `TerminalStreamFrame`s, Codable in the same style as `EventFrame`:

```
TerminalStreamFrame { v, seq, epoch, kind }
kind: reset     { rows, cols, data(base64), fidelity? }   // replace the whole screen
      output    { data(base64) }                          // raw PTY bytes, in order
      resized   { rows, cols }                            // at its position in the byte stream
      heartbeat {}                                        // every 30 s without other frames
      exited    {}                                        // the daemon closed (EOF)
      unknown                                             // a newer Mac's kind; ignored, never fatal
```

- `seq` increases by one per frame on a stream; `epoch` increases on every resync. The client drops its screen on `reset` and ignores any frame whose `epoch` is older than the last `reset` it applied, so resync is idempotent.
- **Coalescing and backpressure** (D32), in the per-stream `PaneStreamSession` actor: output is merged into one frame per 16 ms window, or sooner when 64 KiB accumulate; a snapshot larger than 256 KiB is sent in chunks. The backlog waiting for the connection is capped at 1 MiB. On overflow the session discards it, bumps `epoch`, sends `Observe` again, and the phone receives a fresh `reset` — a slow or stalled phone loses intermediate frames, never correctness, and never stalls the daemon or the Mac.
- **Limits and errors** (D33). `TerminalStreamRegistry` allows 4 streams per caller and 16 in total; a missing pane, or a pane without a zmx session, is a clear error rather than an empty stream. Each stream rides its **own** `RemoteRPCClient` connection because the server serves one connection's frames serially (D10). Revoking the device or turning the gateway off ends every stream like `events.subscribe`. A stream is its connection's last request, so the Mac watches that connection's read side while streaming: the peer hanging up ends the session (and frees its slot and daemon connection) at once rather than at the next failed write, and a stream the Mac ends closes its connection after the final frame. Once `exited` is queued nothing more is taken from the daemon, so it cannot be dropped by an overflow.

#### Input: `terminal.sendEvents`

`terminal.sendInput` / `sendKey` stay for the CLI and older phones, but 29 named keys without modifiers cannot drive an agent's TUI. `terminal.sendEvents` (D34) takes an ordered batch:

| Event | Payload | Notes |
|---|---|---|
| `key` | `code` (W3C `KeyboardEvent.code`, e.g. `KeyC`, `ArrowUp`), optional `text`, `mods` (shift / ctrl / alt / super) | A key as a keyboard would press it |
| `text` | committed text, ≤ 64 KiB | IME output, dictation, typed characters; a `key`'s own `text` has the same cap |
| `paste` | text, ≤ 64 KiB | Goes through the pane's paste path, so bracketed paste applies |
| `delay` | milliseconds, ≤ 500 | Lets a TUI settle between a paste and its Enter |
| `unknown` | — | A newer phone's event; decoding it does not fail the batch |

- **Encoding lives in libghostty** (D35). `PaneSurface.sendKeyEvent(spec:)` maps a pure `KeyEventSpec` (W3C code → Mac keycode, text, unshifted codepoint) to a ghostty key event, so the bytes honour the pane's current modes (application cursor keys, Kitty keyboard protocol) exactly as a Mac keypress would. Committed `text` is sent as an unidentified key carrying text, not as a paste, or the shell would see it wrapped in bracketed-paste markers. `paste` reuses `sendText`.
- **Binding filter.** libghostty's C API says whether a key is bound but not what the binding does, and several default bindings are terminal input a phone needs (`alt+←` types `esc:b`; `shift+←` adjusts a selection only when one exists, else reaches the pane). So a bound key with ⌘ (⌘V, ⌘W, ⌘K, …) is refused without being pressed, and any other bound key is pressed under a `RemoteKeyGuard`: libghostty performs bindings synchronously on the main thread, so every app, window, tab or split action raised meanwhile (`ctrl+tab` → next tab, …) is swallowed and the key is reported as `binding`; clipboard reads for the pane are refused too. Bindings that act inside the terminal (scrolling the Mac's viewport, adjusting a selection) still run, as for a Mac keypress.
- **Encoding details.** Printable keys carry their produced text with shift marked consumed, as AppKit reports it, so Kitty-mode panes get `A` rather than shift+a; ctrl / ⌘ chords carry no text. Committed `text` splits line breaks and tabs into real Enter / Tab presses and drops other control characters. Alt on a printable key is sent as ESC + the character (the xterm meta convention) through libghostty's `esc:` action, because libghostty treats a Mac's Option as a composing key unless `macos-option-as-alt` is set.
- **Wire shape and limits.** Events are flat objects discriminated by `kind` (`{"kind": "key", "code": "KeyC", "mods": {"ctrl": true}}`, `{"kind": "delay", "ms": 30}`). A call carries at most 256 events and 2 s of total delay. The result is `{delivered, rejected: [{index, reason}]}` with reasons `binding`, `unknownKey`, `unknownEvent`, `tooLarge`, `outOfRange` and `paneGone`; one rejected event never fails the batch.
- **Needs a live surface** (D36). Encoding needs the pane's surface, so a pane that is not open on the Mac answers `unsupported("pane not open on the Mac")`; the phone offers **Open on Mac** (`hierarchy.activateTab`). `PaneSummary.isLive` lets the phone show that state before the first key.

#### Negotiation

`system.hello` reports **protocol minor 2** (D40). The phone uses `pane.attachStream`, `terminal.sendEvents` and the tab/pane management methods only when `serverHello.protocolMinor >= 2`; against a minor-1 Mac it falls back to v1's polled pane text and `sendInput` / `sendKey`.

### Connection Layer

`ConnectionFeature` becomes an explicit phase machine (D41):

```
idle ─▶ discovering ─▶ handshaking ─▶ syncing ─▶ live
             ▲               │            │         │
             └── reconnecting(attempt, nextAttemptAt) ◀┘

offline (background, grace over)      failed(rejected | localNetworkDenied | incompatible | missingKey)
```

- **Live means data.** `syncing` waits for the first `events.subscribe` snapshot; the UI reports "connected" only in `live`. `lastContact` is refreshed by every frame, including heartbeats; an events stream silent for 60 s (two missed heartbeats) is treated as half-open and reconnected.
- **Deadlines.** Each phase has its own timeout — discovering 9 s (just past Bonjour's own not-found answer, which carries the better message), handshaking 12 s (room for two stale candidates at 5 s each), syncing 8 s — and a whole attempt has a 20 s deadline. Backoff starts at 0.5 s, doubles to a 30 s cap, and jitter only shortens it (by up to a quarter), so the cap holds. While in the foreground any network path change, including a change of interface with the path still satisfied, reconnects immediately; an unsatisfied path does not start an attempt.
- **Control calls.** A control call that times out triggers one `system.ping` (3 s); if that fails too the session is closed, which ends the events stream and reconnects. Idempotent reads (`pane.read`, `agent.profiles`) retry once after a timeout whose ping succeeded; writes are never retried.
- **Background grace.** Going to the background keeps the connections for 25 s under a UIKit background task (ended early if iOS takes the time back), so a quick app switch resumes instantly; after that they close and the phase is `offline` until a scene is active again. `.inactive` (app switcher, Control Center, a sheet) keeps everything. A backoff in progress when the app leaves becomes `offline` at once.
- **One view model.** Views read a derived `ConnectionHealth` (phase, Mac name, `lastContact`, `lastSyncedAt`, failure, attempt, `nextAttemptAt`, `canRetryNow`, `needsMacUpdate`) with its title, explanation, checklist and recovery action, so the banner, placeholders and Settings tell the same story.
- **Streams follow the session.** Terminal streams attach only while `live`; when the session drops they dim and show "Reconnecting…", and resync (a fresh `reset`) once it is live again.

**Failure taxonomy** (D42), each with its own state and copy instead of one generic error:

| Failure | Detection | Behaviour |
|---|---|---|
| `macNotFound` | No matching Bonjour service within the discovery timeout | Explains the causes — the Mac is asleep, Remote Access is off, or the phone is on another network — with a checklist and Try Again; retries with backoff |
| `localNetworkDenied` | Local-network privacy denial | `failed`, no retry; Open Settings. Retried when a scene becomes active again, since that is how a trip to Settings ends |
| `rejected` | 3 TLS handshake refusals from a resolved gateway with no successful handshake in between (a refusal is kept over a later stale candidate's timeout) | `failed`, stops retrying; "This device was removed" with **Pair Again**. Resolves the v1 risk of a revoked phone retrying forever |
| `incompatible` | Protocol **major** mismatch, or an app version the Mac refuses | `failed`: "Update Codans on your Mac" (or this app) |
| older Mac (not a failure) | `system.hello` reports protocol minor < 2 | Stays `live`: browsing, agents and the composer work; panes use the text fallback (`pane.read` polling, one read in flight, stale text kept and marked) under an "Update Codans on your Mac" notice |
| `timeout` | A phase timeout or the attempt deadline passed | Retries with backoff |
| `missingKey` | The Keychain lost the pairing key | `failed`: Pair Again |

**Offline cache** (D44). `AppFeature` writes the hierarchy, agent states and the Mac's protocol minor per gateway to `Application Support/WorkspaceCache/<gateway-id>.json` (versioned JSON, atomic write, 2 s after a burst of changes, only while `live` so reconnect-time data is never saved as fresh). Choosing or launching with a Mac loads its file; a file that fails to decode, or has another version, reads as no cache. The cached workspace is shown until the first snapshot replaces it, marked stale with "Updated N minutes ago"; a snapshot that beats the disk read wins. Forgetting a Mac deletes its file.

**Input reliability** (D43). Terminal keys go through one ordered queue, batched about every 8 ms into a `terminal.sendEvents`. While disconnected, keys are **not** queued — replaying stale keystrokes into a shell that has moved on is dangerous — so the input is disabled with the reason shown. A failed send restores the draft. `RemoteClient` retries idempotent reads once.

**Composer** (D54). The composer remembers the worktree it already created, so a retried "start agent" does not create a second one; Send requires `live`; and a send no longer navigates to the previous launch's result.

### Terminal on the Phone

**Renderer** (D45). SwiftTerm renders the stream; it is pure Swift, already runs on iOS and accepts externally fed bytes, whereas libghostty on iOS would need a new external-IO build and embedding path. `MirrorTerminalView` is a render-only SwiftTerm subclass: its frame is exactly `cols × cellWidth` by `rows × cellHeight` of the Mac's grid, inside a `UIScrollView` that fits the width by default and pinch-zooms (resetting `contentScaleFactor` when zoom ends so text stays sharp). It ignores `sizeChanged`, is never first responder, and drops everything SwiftTerm wants to `send` — the Mac's surface already answers DA/CPR queries, and answering twice would corrupt the shell's input. It is always dark, whatever the app's appearance. The spike confirmed the fixed grid without a fork: SwiftTerm derives its grid in `layoutSubviews` from `bounds / cellSize`, so the view's `bounds` are pinned to `cols × cellWidth` by `rows × cellHeight` plus a quarter-cell slack (float truncation would otherwise drop a column), the cell size comes from `getOptimalFrameSize()` divided by the grid, and zoom scales a plain container around the view (a transform never changes `bounds`), capping `contentScaleFactor` at 6. `TerminalView.resize(cols:rows:)` and font changes are never used while streaming — both soft-reset the terminal. A stream `reset` feeds `ESC c` plus `ESC [3J` (a full reset, then clear scrollback) before re-pinning the grid. SwiftTerm is an Xcode package pinned to 1.20.0 in `apps/ios/Project.swift` rather than a Tuist external (Tuist's generated target for it does not build); its build-info plugin makes every command-line `xcodebuild` pass `-skipPackagePluginValidation`.

**Input view** (D46). `TerminalInputView` implements `UITextInput` with autocorrect, smart quotes and auto-capitalization off. IME marked text (Chinese, Japanese, …) stays **local** in a floating bubble and is sent as `text` only when committed; `deleteBackward` sends Backspace; `pressesBegan` handles hardware keys and modifiers.

**Key bar** (D47–D49), `TerminalKeyBar`, above the software keyboard:

- Layout: a fixed left group `Esc` `Ctrl` `Alt` `Tab`; a horizontally scrolling middle with a D-pad, `~ | / \ - _`, `Home` `End` `PgUp` `PgDn`, `⇧Tab`, `F1`–`F12`; a fixed right group with Paste, Compose and show/hide keyboard.
- **Modifiers.** A tap arms the modifier for the next key only (one-shot); a double tap within 400 ms locks it, shown by a bar under the key; another tap unlocks.
- **Context panel.** Long-pressing `Ctrl` opens a shortcut panel whose default page follows the pane's agent kind: Claude Code (`/clear` `/compact` `/resume` `/help`, `⇧Tab` to cycle modes, `Esc Esc`), Codex, a tmux prefix page, and a Ctrl-letter page (C D Z L A E R W).
- **D-pad and repeat.** Dragging on the D-pad sends arrow keys continuously with acceleration; arrows and Backspace auto-repeat on long press. A repeat — the D-pad's, a held key bar key's or a held hardware key's — also stops when its gesture is cancelled, its view goes away or the input view loses focus, since none of those report a release. Light impact haptics on key presses.
- **Hardware keyboard.** When a `GCKeyboard` is connected the bar hides. Hardware shortcuts: `⌘[` / `⌘]` switch pane, `⌘1…9` switch tab, `⌘T` new tab, `⌘D` / `⌘⇧D` split, `⌘K` clears the pane (sent to the pane as Ctrl+L, never as the Mac's ⌘K binding), `⌘+` / `⌘-` zoom the view (the scroll view's zoom, never the font, which would soft-reset the grid).

**Compose card** (D50). Typing on the keyboard sends key by key, like a desktop terminal. The Compose button opens a multi-line card for what key-by-key input handles badly — long prompts, IME, dictation, pasting: it grows to six lines, sends `[paste, delay 30, key Enter]` (or inserts without Enter), and keeps the last 20 entries as history, reached by swiping up. This replaces v1's `sendInput` + `sendKey(enter)` pair (D25) on minor-2 Macs.

### Information Architecture and Visual System

**Home** (D51). The navigation title is the Mac's name with a menu (▾): switch Mac, connection details, reconnect now, Settings. Under it one status line: a status dot and "Connected" / "Reconnecting…" / "Offline · 3 min ago". Projects are sections with a folder icon and a new-agent button; worktree rows show the worktree name, then the branch and an agent-state chip. Agents is a toolbar icon with an amber badge while an agent needs input, presented as a sheet. The composer is a floating "Ask Claude Code" capsule that expands into a full-screen card: a context row (Mac / project / new or existing worktree / branch / agent profile), then multi-line input, `+`, dictation and a black circular send button. As built: the branch row is omitted when it only repeats the worktree name; dictation is left to the keyboard's own microphone rather than a second button; the capsule opens a full-screen cover on iPhone and a form sheet in regular width. Opening a worktree lands on the pane last viewed there (remembered per scene), else the Mac's selected tab's focused pane, else the first pane.

**Worktree → terminal.** Opening a worktree lands directly in the terminal of the last pane viewed there (else the Mac's selected tab's focused pane), with no pane list in between.

**Tab menu** (D52). The terminal's title is the tab name with a menu, grouped as: all tabs (with agent-state dots); the current tab's split panes in split order with name, cwd and agent state — this is how splits map to the phone; actions: new tab, split right / down, rename tab, open on the Mac, and close pane / close tab behind a confirmation that says the process will end. `hierarchy.createTab` makes an empty tab, as it does for the CLI, so New Tab follows it with `hierarchy.openPane` in the current pane's cwd; an empty `workingDirectory` asks the Mac for the worktree root, since the phone's hierarchy carries no worktree paths. A tab with several panes shows page dots under the title, and swiping on the strip above the terminal switches panes. On iPad (regular width) the detail area mirrors the tab's real split `layout`, one stream per visible pane (at most 4; the rest show a placeholder), with the pane on screen highlighted; tapping another pane focuses it on the phone only, and one key bar under the whole layout types into the focused pane. Zoom and unzoom are routed on the Mac but not offered on the phone until the Mac draws a zoomed pane. Picking a pane never calls `hierarchy.focusPane`. iPhone Duo keeps the size-class rule: the inner display gets the iPad layout.

**States.** Every waiting and error state is designed rather than a spinner: skeleton rows on first load; "Syncing…" under the title; a non-blocking reconnect strip ("Reconnecting to {Mac}… attempt n · {countdown}" with Retry Now) that dims the content and overlays the terminal; stale badges and a disabled, explained input while offline; the failure-taxonomy pages above; "Open on Mac" for a pane without a live surface; an exited-process banner with Close Pane (`terminal.retryPane` stays local-only); inline send errors that keep the draft; a light haptic and fading strip on reconnect. Animations are 0.25 s ease and respect Reduce Motion. As built: the status line keeps to "Reconnecting…" and the strip carries the attempt and countdown, so the two never repeat each other; the strip names the phase ("Looking for…", "Connecting to…", "Reconnecting to…"); before the first snapshot the regular-width detail column shows the connection's progress as a full page (with Retry while waiting between attempts) instead of an empty terminal page. In regular width the strip sits over the detail column only, not also atop the sidebar. Over the always-dark terminal, the exited banner and the "not open on your Mac" notice use a dark card with the inline banner's shape and type. The terminal exposes its visible text as its accessibility value, which VoiceOver reads and the end-to-end UI test asserts on.

**Visual system** (D53), in `App/DesignSystem/`: monochrome. The accent is **ink** (black in light mode, white in dark), set as the AccentColor asset and a global `.tint`, so no system blue remains. Surfaces are surface / elevated with hairline separators; colour is reserved for meaning — amber *needs input*, green *working* (pulsing), red *error*, grey *offline*. Type: large title, 17 pt semibold row titles, 13 pt secondary, monospaced terminal. Spacing 4 / 8 / 12 / 16 / 24; radii 12 / 20 / pill. Shared components: `StatusDot`, `AgentChip`, `InlineBanner`, `SkeletonRow`, `StateView` (full-page empty / error states), `PrimaryCircleButton` and the ink / quiet / terminal button styles. Stale data is shown dimmed under the status line's "updated … ago" rather than with a separate badge.

### Terminal seats: the size follows the device in use

A mirror of the Mac's grid cannot fit a phone: a 170-column pane is either 4 pt text or text that pans sideways. What a phone needs is the program itself laying out for the phone — the PTY at the phone's size, so a shell wraps and a TUI redraws for it. zmx already sizes the PTY for its **leader**, the client that last typed, like tmux's `window-size latest`; the phone was simply never a client (its observer can never lead, and its keys reached the pane through the Mac's surface, so zmx saw the Mac typing).

- **Seat.** An interactive device that attaches with its grid (`pane.attachStream` `seat: {cols, rows}`, protocol minor 4) gets a terminal seat: a normal zmx client the Mac opens on its behalf (`ZmxParticipantClient`) that sends `.Init` with the device's size, answers the daemon's size request (sent to a new leader) with it, and closes with the stream. Its PTY output is dropped; the device watches through the observer as before.
- **Leading.** Keys typed on the device go through the seat (`pane.input`, bytes the device encodes from its own emulator's modes — application cursor, bracketed paste — the way xterm does), so typing makes the seat the leader and the pane takes the device's size. Typing on the Mac makes the Mac's `zmx attach` the leader again and the pane returns to the Mac's size. `pane.claimSize` takes (or gives back) the lead without typing; the attach asks `claim: auto`, which the Mac grants at once only when nobody can see the pane there — it has no surface, its surface is in no window (another tab), or its window is not visible (hidden, covered, or behind a locked or sleeping display) — so a pane nobody is looking at on the Mac is laid out for the phone straight away, while one on the Mac's screen waits for the phone's user to type. The phone gives the size back when it goes to the background.
- **Hand-back.** zmx (fork) gains `Claim` (18) and `Release` (19), and when the leader disconnects or releases it promotes the most recently active remaining terminal client, asking it for its size; an `ObserveState` flag tells the Mac a daemon has all this. Older daemons ignore the new tags: typing still moves the lead, but a departing phone leaves the pane at its size until someone types on the Mac.
- **Phone.** The grid is what fills the screen at the user's text size; rotation, the keyboard and a pinch change it, and it reaches the Mac after 250 ms of quiet (`pane.setStreamSize`). While the pane is at the device's size (the stream's grid equals the seat) the pane strip shows a device glyph and the tab menu offers "Give Size Back to Mac"; otherwise "Fit to This iPhone". A Mac without seats, or a pane without one, keeps the Phase 2 behaviour: a zoomable mirror and keys through the Mac's surface.
- **On the Mac.** While a device leads, the Mac's surface draws the device's smaller grid in its top-left corner over stale cells. The registry learns the PTY's grid from the observer (`ObserveState`, `ObserveResize`) and records a pane as device-sized when that grid equals one of its seats' grids and differs from the surface's (`RemotePaneSizing`); matching a seat keeps the Mac's own resizing from reading as a device's. The pane then frosts the cells outside the device's grid and shows "Sized for <device> · cols×rows" with "Use Mac Size", which releases every seat at the pane; typing in the pane does the same through zmx.
- **Trade-off.** Someone at the Mac while the phone leads sees the pane laid out narrow until they type or click "Use Mac Size" — the price of `latest`, bounded by the visibility rule and the hand-back. Keys typed through the seat also no longer need the pane open on the Mac.

## Phase 3: Internet Access Through a Relay

Goal: reach the Mac from outside the LAN — cellular, another Wi-Fi — without port forwarding, a VPN or an account, and without trusting the relay with anything but routing.

### Shape

```
iPhone                                  relay.codans.dev                          Mac
NWConnection TLS-PSK ─▶ loopback bridge ─wss─▶ Caddy ─▶ relay ◀─wss─ loopback bridge ─▶ gateway NWListener
                     └──────────────────── one TLS-PSK session, end to end ─────────────────────────┘
```

The relay is a dumb pipe. The phone's TLS-PSK session (D3) runs end to end *inside* the relayed byte stream and terminates at the Mac's existing gateway listener, so the gateway's security model, peer proof, permission tiers and every method are unchanged, and the relay (and Caddy in front of it) only ever sees TLS ciphertext and routing IDs. Each end bridges the relay to a loopback TCP socket rather than running TLS over the WebSocket itself, because Network.framework cannot layer the PSK handshake over a custom byte stream, and a loopback hop lets both ends keep using the unchanged `NWConnection` code.

### Relay protocol (v1)

All endpoints are WebSocket upgrades on `wss://relay.codans.dev` (Caddy on the nanops VM on 443, with a Let's Encrypt certificate; the Cloudflare record is DNS only). Credentials travel in `Authorization: Bearer <token>`; failures are plain HTTP statuses before the upgrade.

| Endpoint | Who | Purpose |
|---|---|---|
| `GET /v1/mac/{macID}/control` | Mac | Registers the Mac and receives `incoming` notices. One per `macID`; a new one replaces the old. |
| `GET /v1/mac/{macID}/session/{sessionID}` | Mac | The Mac's side of one phone session. |
| `GET /v1/connect/{macID}` | Phone | Opens a session to a Mac. |
| `GET /healthz` | Anyone | Liveness. |

- **Identifiers.** The Mac holds a 32-byte random `macSecret` per channel (Keychain) and authenticates with it as a base64url bearer. Its `macID` is derived from the secret — the first 16 bytes of `SHA-256("codans-relay-mac-id-v1" ‖ secret)`, base64url — so only the secret is stored, and the ID reveals nothing about it. The relay stores only `SHA-256(macSecret)`, registered on first use (trust on first use): a later control connection for the same `macID` with another secret gets `403`.
- **Phone tokens.** A phone's token is `HMAC-SHA256(psk, "codans-relay-token-v1")`, base64url, so a paired phone can derive it from the key it already holds and needs no new secret. The Mac sends the relay the SHA-256 of every paired device's token over the control connection (`{"type":"tokens","hashes":[…]}` text frames), and again whenever a device is paired or revoked. The relay admits a phone only if the hash of its bearer token is in the Mac's current list. A leaked token lets someone open sessions but never complete the TLS-PSK handshake.
- **Session.** On `GET /v1/connect/{macID}` the relay checks the token (`403`), that the Mac's control connection is up (`404`, "Mac offline"), and rate limits (`429`); it upgrades, sends `{"type":"incoming","session":"<id>"}` on the control connection, and waits up to 10 s for the Mac's session connection (`504`-equivalent close otherwise). Once both halves are up it forwards binary messages verbatim both ways; either side closing closes the other.
- **Keepalive.** WebSocket pings every 25 s on every connection, well inside the idle cut-offs of mobile carriers' NATs and of Cloudflare's proxy (100 s), should the record ever be proxied.
- **Limits.** 32 concurrent sessions per Mac, 1 MiB per message, 60 phone connects per minute per Mac and per client IP, 10 new Mac registrations per client IP per hour and 10 000 registrations in total (registering costs nothing, so it is bounded). Registrations and token lists are persisted so a relay restart does not lock out Macs. Status codes: `400` malformed ID, `401` no bearer, `403` wrong secret or unknown token, `404` Mac offline or unknown session, `429` rate or session limit, `503` registrations full; close codes `4000` control replaced, `4502` Mac unreachable, `4504` Mac did not answer in time.

### Mac

- **Setting.** Remote Access gains "Allow access from outside this network", off by default and only available while Remote Access is on. `CODANS_RELAY_URL` overrides the relay for tests; `CODANS_REMOTE_DISABLED` still forces everything off.
- **Connector.** While allowed, a `RelayConnector` keeps the control connection (jittered backoff reconnect) and publishes the paired devices' token hashes. For each `incoming` it opens the session WebSocket and a plain TCP connection to `127.0.0.1:<gateway port>` and pumps bytes both ways. The gateway sees an ordinary TLS-PSK client.
- **Telling the phone.** `HelloResponse` gains an optional `relay` (`url`, `macID`) while the relay is allowed (protocol minor 3), and new pairing codes carry it too, so a phone paired earlier learns it on its next LAN connection without pairing again. Turning outside access on or off drops the gateway's connections, as a permission change does, so a phone that is connected when the switch flips re-handshakes and learns it at once. A phone updates what it knows only from a minor-3 Mac on the LAN: an older build has no answer, and must not erase a relay learned from a newer one.

### Phone

- **Where to connect.** Bonjour first; if no same-channel gateway appears within 1.5 s and the pairing knows a relay, connect through it. A path change re-runs the choice, so walking back into the house returns to the LAN on the next reconnect.
- **Bridge.** A loopback `NWListener` whose accepted connections each open one `URLSessionWebSocketTask` to `/v1/connect/{macID}`; the connection layer is handed `127.0.0.1:<port>` as the endpoint. Control, events and every terminal stream are separate relay sessions, exactly as they are separate TCP connections on the LAN.
- **Failures.** `404` maps to "Mac offline" (not "not found on this network"), `403` to "not allowed" (the Mac turned outside access off or removed the device), network errors to the existing retry path. The status line says "via relay".

### Push notifications (not built)

The Mac notices "needs input" (the same agent-state transitions `Notifications` already uses) and asks the relay to send an APNs push. The push body carries no pane content — only an opaque reference the app resolves after connecting — so neither Apple nor the relay learns what the agent asked. It needs an APNs key and device-token registration; it is the next step after the relay.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| **A separate HTTP/REST or WebSocket API for mobile** | Duplicates the method surface and its wire types, and the two would drift. Reusing framing and envelopes means one router, one set of handlers and tests, and a streaming method the CLI can use too. |
| **Self-signed certificate + pinning (TLS 1.3)** | Viable and the fallback if PSK proves unworkable. Heavier: certificate generation and rotation, pinning a hash in the payload, and still a per-device secret for client authentication. PSK gives mutual authentication with one secret per device and trivial revocation. |
| **Plain TCP + app-level token** | The token and all pane text would cross the LAN in cleartext; building our own encryption is worse than using TLS. |
| **SSH to the Mac from the phone** | Requires Remote Login enabled system-wide, gives full shell access with no tiering, and the phone would have to reimplement codans' view of the hierarchy from shell output. |
| **Sharing one server-side connection for control and events by making `SocketConnection` concurrent** | Changes the concurrency model of every local connection (ordering guarantees the CLI relies on, the in-flight accounting) to save one socket per phone. Two connections isolate the change to the client. |
| **Polling instead of an event stream** | Wastes battery and radio, adds latency to "needs input", and scales badly with pane count. The stream sends only changes and the heartbeat is cheap. |
| **Diff/patch deltas for the hierarchy** | Saves bytes on an already small payload at the cost of a patch format and ordering bugs; whole-section replacement is idempotent. |
| **A Mac-side allow-list per device instead of per-method tiers** | Too fine-grained to configure correctly and easy to get wrong; two tiers plus a fixed never-remote list are auditable in one table. |
| **Porting `CodansKit`/`RPCClient` to iOS** | It is built around one connection per call and depends on ArgumentParser and Unix sockets; a separate long-lived multiplexed client is smaller than untangling it. |
| **Orientation- or screen-size-based layout** | Breaks on the Duo inner display (which ignores supported orientations) and in Split View; size classes are what actually vary. |
| **Attaching the phone as an ordinary zmx client** | `Init`, `Input` and `Resize` can make it leader and resize the PTY under the Mac; the observer role is the only way to watch without side effects. |
| **Faster `pane.read` / `History vt` polling instead of a stream** | Still latency plus redundant bytes, and `History vt` misplaces the cursor with scrollback; kept only as the old-daemon fallback. |
| **Sending phone keys as raw bytes (`terminal.sendRawBytes`)** | Never-remote by design, and the phone cannot know the pane's keyboard modes; libghostty encoding on the Mac gets them right. |
| **Queueing keystrokes while disconnected** | Replaying them into a shell whose state has moved on can run the wrong command; disabling input with a reason is safer. |

## Decisions

| ID | Decision | Rationale |
|---|---|---|
| D1 | The iOS app is a remote companion; nothing runs on the device. | iOS forbids `fork`/`exec`. |
| D2 | v1 network reach is the LAN only (Bonjour + TLS); relay and push are design-only. | Smallest trust surface; no hosted infrastructure. |
| D3 | Remote transport reuses the IPC framing, envelopes and `MethodRouter`. | One protocol, one router, shared tests. |
| D4 | TLS 1.2 `ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` with a random 32-byte key per device. The listener holds every paired key (the TLS stack selects by identity) and is rebuilt when the paired set changes; a `RemotePeerProof` (HMAC over the TLS exporter) binds the device ID to the session. | Mutual auth without certificates; per-device revocation. The SDK has no `ECDHE_PSK` AES-GCM suite and no server-side identity callback, so the suite and the peer proof replace the originally planned `AES_128_GCM` suite and selection block. |
| D5 | PSKs live only in the Keychain (Mac: not synchronizable; iOS: `ThisDeviceOnly`). | Keep secrets out of JSON, logs and backups. |
| D6 | Gateway off by default; `CODANS_REMOTE_DISABLED` forces it off. | No new attack surface for users who don't opt in; test isolation. |
| D7 | Authorization is per method (`IPC.Method.remoteTier`, exhaustive switch), enforced once in the router; new pairings default to `.readOnly`. | Deny by default; a new method cannot become remote by accident. |
| D8 | A fixed never-remote list (destructive, persistent-command, outside-window, blast-radius methods). | Some operations are unsafe regardless of who holds the phone. |
| D9 | `route(_:context:)` with `CallerContext.local/.remote`; permission read per request. | Downgrades apply immediately; local behaviour unchanged. |
| D10 | Two client connections per Mac: control (unary) + events (one stream). | Server serves frames serially per connection. |
| D11 | `events.subscribe`: snapshot first, then ~250 ms debounced deltas; hierarchy as whole-section replacement, agent states as upserts; 30 s heartbeat; no resume token. | Bounded memory per subscriber, idempotent client model, half-open detection. |
| D12 | Pairing payload is a versioned `codans-pair:` base64url JSON shown as QR + text; pending pairings expire after 10 minutes. | The payload is a credential; limit its lifetime. |
| D13 | Bonjour `_codans._tcp` with TXT `channel` and `v`; phones match on channel. | Dev and release gateways never cross. |
| D14 | iOS layout uses size classes and standard containers only; no `UIScreen.main`, per-edge safe areas, multi-scene, `@SceneStorage`. | Correct on iPhone, iPad, Split View and both Duo displays. |
| D15 | Full iPhone Duo validation waits for Xcode 27.1 + DeviceHub; v1 ships built with the iOS 26 SDK. | The installed toolchain is Xcode 26.0.1. |
| D16 | `CodansCore` replaces Carbon `kVK_*` with its own `KeyCode` table (identical numeric values) and moves `NSColor` conversions to the app. | Unblocks iOS builds without changing persisted `shortcuts.json`. |
| D17 | Tier refusals are a new `IPCError.forbidden`; `system.hello` reports protocol minor 1 (`events.subscribe`). | A dedicated code lets the phone tell "not allowed" from "not supported"; the minor bump is additive. |
| D18 | Event coalescing is a per-topic window opened by the first change and computed once by the hub for all subscribers; frames are built on pull. | Bounded latency under continuously changing sources, one projection per window regardless of subscriber count, one pending value per topic per subscriber. |
| D19 | A failed write cancels the connection's serve task (Unix socket and gateway alike). | A streaming response never reads again, so a vanished peer is only noticed on write; without this a dead subscriber would stream heartbeats forever. |
| D20 | The pairing flow is inline in the Remote Access pane's grouped form, not a sheet. | Settings panes use native grouped forms without custom chrome. |
| D21 | Pending (not yet used) pairings are included in the listener's key set until they expire; `RemoteGatewayServer` has a `.loopback` scope used only by tests. | The phone's first handshake must succeed against a pending key; loopback tests exercise the real TLS-PSK path without listening on the LAN or advertising over Bonjour. |
| D22 | `HelloResponse` carries an optional `remotePermission`, filled only for gateway callers. | The phone must hide input controls for a read-only device before the first refused call; the router stays the authority, and a `forbidden` reply downgrades the phone's view immediately. Local callers never see the field. |
| D23 | `apps/ios/Tuist/Package.swift` is a symlink to `apps/mac/Tuist/Package.swift`, and `make -C apps/ios generate` copies `apps/mac`'s `Package.resolved` before `tuist install`. | A `.project(target:path:)` reference makes Tuist resolve the referenced project's external dependencies (ArgumentParser, Sparkle, Sentry, …) from the *root* project's manifest, so both apps must declare and pin the same packages. A symlinked lockfile breaks the second `tuist install` (Tuist re-links it under `.build`), so the lockfile is a synced copy. |
| D24 | The iOS app keeps one TCA store per process, created in the `App`; each scene renders from it and keeps only navigation (selected tab, project, pane) in `@SceneStorage`. `PaneDetailFeature` gets its own store per displayed pane. The connection follows the aggregate `scenePhase`: `.background` tears both connections down, `.active` reconnects, `.inactive` is ignored. | Several windows share one control + events connection; per-scene selection survives fold/unfold and multi-window. The PaneDetail scroll anchor is not persisted in v1 — the view always opens at the bottom of the tail, which is where a terminal's news is. |
| D25 | PaneDetail sends a line as `terminal.sendInput` followed by `terminal.sendKey(enter)`; key-row shortcuts use Control (⌃Tab, ⌃C, ⌃↑/⌃↓, ⌃Return) plus Esc and ⌘R. | The Mac's text path drops control bytes, so a trailing newline would not submit; plain arrows and Tab belong to the text field. |
| D26 | Pairing expiry is one gateway timer armed for the earliest pending deadline on every listener reconcile (launch, pair, revoke, prune), and the post-handshake check rejects a pending device past its lifetime. | The listener's key set is rebuilt only on reconcile, so an expired code's key can outlive its deadline; a timer tied to the newest code, or not armed for codes loaded at launch, left abandoned codes valid indefinitely. |
| D27 | The phone treats an events stream silent for 60 s (two missed heartbeats, sampled every 15 s) as half-open and reconnects; a control call failing with `connectionClosed`/`writeFailed` closes the session too. | TCP keepalive alone takes minutes after a Wi-Fi hand-off or a sleeping Mac, during which the Agents list freezes while the banner says connected. |
| D28 | `hierarchy.createWorktree` is `.interactive` so the phone can start an agent in a new worktree, but `CallerContext` refuses a remote call that sets `path` or `reuseExisting`: the Mac derives the path from its own worktree settings. | Creating a worktree only adds a branch and a directory, the same reach as `agent.launch`; letting the caller pick the path would let a phone register any directory on the Mac. |
| D29 | The zmx fork adds a read-only observer role: `Observe = 15` (`u32 scrollbackRows`), `ObserveState = 16` (`rows`, `cols`, `flags` + serialized state), `ObserveResize = 17` (in-stream resize). An observer's `Input` / `Init` / `Resize` are ignored and it never sets `has_terminal_client`. | Any ordinary client can become leader and resize the PTY; `History vt` misplaces the cursor with scrollback. An observer can see everything and change nothing. |
| D30 | With no `ObserveState` within 300 ms the Mac falls back to `History vt` at `PaneSurface.gridSize()`, marks the `reset` `fidelity: "approximate"`, appends `ESC[?2026l`, and re-snapshots on the next geometry push. | Panes started before the upgrade keep an old daemon; an approximate screen beats no screen, and restarting the pane upgrades it. |
| D31 | `pane.attachStream` streams `TerminalStreamFrame { v, seq, epoch, kind }` with kinds `reset`, `output` (base64), `resized`, `heartbeat`, `exited`, `unknown`; `epoch` bumps on every resync. | Raw bytes plus in-band resizes reproduce the Mac's screen exactly; `epoch` makes resync idempotent; `unknown` keeps older phones decoding newer Macs. |
| D32 | Output coalesces per 16 ms (or 64 KiB); snapshots split at 256 KiB; the per-stream backlog is capped at 1 MiB and overflow resyncs (`epoch + 1`, re-`Observe`, new `reset`); 30 s heartbeat. | One frame per display refresh keeps agent-heavy output cheap on Wi-Fi; the cap bounds Mac memory and means a slow phone loses frames, never correctness, and never stalls the daemon. |
| D33 | At most 4 streams per caller and 16 in total; each stream uses its own client connection. Extends D10. | The server serves one connection serially; bounded fan-out per phone and per Mac. |
| D34 | `terminal.sendEvents` takes ordered `key` (W3C `code` + `text?` + `mods`), `text`, `paste` (≤ 64 KiB) and `delay` (≤ 500 ms) events; unknown events do not fail the batch. `sendInput` / `sendKey` stay. | Named keys without modifiers cannot drive agent TUIs; W3C codes are the platform-neutral key vocabulary; the limits bound what one call can inject. |
| D35 | Key events are encoded by libghostty through `PaneSurface.sendKeyEvent`; committed text is an unidentified key with text, not a paste; keys that `ghostty_surface_key_is_binding` reports as Mac bindings are refused. | The pane's modes (application cursor, Kitty keyboard) must shape the bytes as a Mac keypress would; paste-wrapping typed text breaks shells; a phone must not trigger the Mac app's shortcuts. |
| D36 | `terminal.sendEvents` needs a live surface: otherwise `unsupported("pane not open on the Mac")`, and the phone offers Open on Mac (`hierarchy.activateTab`). | libghostty encoding needs the surface; saying so beats silently dropping keys. |
| D37 | `hierarchy.renameTab`, `hierarchy.closeTab` and `hierarchy.closePane` become `.interactive`. `closePane` ends the shell, so the phone confirms both closes and says the process will end. | Managing tabs and panes is part of driving the Mac from the phone; none of these touches data outside the window. The confirmation carries the destructiveness the method name hides. |
| D38 | `hierarchy.zoomPane` / `unzoomPane` are routed; the phone never calls `hierarchy.focusPane` when the user selects a pane on the phone. | Zoom was tiered but unrouted. `focusPane` moves the Mac's keyboard focus, and looking at a pane on the phone must not disturb someone at the desk. |
| D39 | The hierarchy summary gains optional `TabSummary.layout`, `TabSummary.zoomedPaneID`, `PaneSummary.cwd`, `PaneSummary.isLive` and `HierarchySummary.activePaneID`. | Additive and optional, so neither side breaks on version skew; the phone needs the split tree, liveness and landing pane without extra calls. |
| D40 | `system.hello` reports protocol minor 2; the phone uses the phase-2 methods only when `protocolMinor >= 2`. A minor-1 Mac is not `incompatible`: it stays live with the text fallback and an update notice on panes. | A minor-1 Mac keeps working with v1 behaviour. |
| D41 | The phone's connection is an explicit phase machine — discovering → handshaking → syncing → live, plus reconnecting(attempt, next) and offline — with per-phase timeouts, a 20 s overall deadline, jittered backoff capped at 30 s, reconnect on any foreground path change, ping after a control timeout, and a 25 s background grace. "Live" requires the first snapshot. | v1 reported connected before any data, never timed out as a whole, missed interface changes and dropped the connection on every app switch. |
| D42 | Failures are classified as macNotFound, localNetworkDenied, rejected, incompatible and timeout; three consecutive handshake refusals end in `rejected` with Pair Again, and localNetworkDenied never retries. When the revoked device was connected, the Mac keeps its listener up for 90 s even with no key left, refusing every handshake, so revoking the last device still reaches the phone as `rejected` rather than macNotFound. | Each cause has a different fix the user must be told; a revoked phone retrying forever was an open v1 risk. |
| D43 | Terminal keys are batched in one ordered queue (~8 ms); while disconnected keys are not queued and input is disabled with a reason; failed sends restore the draft. | Replaying stale keystrokes into a shell that has moved on is dangerous; losing typed text is not acceptable. |
| D44 | The phone caches the last hierarchy and agent states per gateway (versioned JSON, Application Support) and shows them as stale on cold start. | The app opens to something useful instead of a spinner; the snapshot stays authoritative. |
| D45 | The iOS renderer is a render-only SwiftTerm view at the Mac's fixed grid, zoomed by a scroll view; it never answers terminal queries and never resizes. Fallback: a SwiftTerm fork with a fixed-grid mode. | SwiftTerm already runs on iOS with fed bytes; libghostty on iOS would need a new build path. The Mac surface already answers DA/CPR, and the Mac owns the size. |
| D46 | IME marked text stays local in a bubble and is sent only on commit. | Sending uncommitted composition would type half-formed input into the shell. |
| D47 | Key-bar modifiers are one-shot on tap and locked on a double tap within 400 ms, with a visible lock bar. | The consensus of established iOS terminals; one-shot matches how Ctrl-C is typed, locking covers runs of shortcuts. |
| D48 | Long-pressing Ctrl opens a context shortcut panel defaulting to the pane's agent kind (Claude Code, Codex, tmux, Ctrl letters); the D-pad sends arrows while dragged with acceleration; arrows and Backspace auto-repeat. | The common agent and TUI commands become one gesture; dragging is faster than tapping arrows. |
| D49 | A connected hardware keyboard hides the key bar and enables ⌘-shortcuts for panes, tabs, splits, clear and view zoom; ⌘K goes to the pane as Ctrl+L. | The bar duplicates a physical keyboard; the shortcuts mirror the Mac app. |
| D50 | Direct typing sends key by key; a separate compose card (≤ 6 lines, paste, dictation, 20-entry history) sends `[paste, delay 30, key Enter]` or inserts without Enter. Supersedes D25 on minor-2 Macs. | Key-by-key keeps terminal semantics; long prompts, IME and dictation need a real text editor. |
| D51 | The home title is the Mac's name with a menu (switch Mac, details, reconnect, Settings) and a status line; opening a worktree lands straight in its terminal. | The connection state is always visible where the user looks; the pane list was a step with no information of its own. |
| D52 | Tabs and split panes are reached from the tab-name menu (split panes in split order as a dropdown) with page dots and swipe; iPad mirrors the split layout with one stream per visible pane. | A phone cannot show splits side by side; a menu keeps them one tap away, while the iPad has room for the real layout. |
| D53 | A monochrome visual system: ink accent (black / white), colour only for agent and connection state, fixed type, spacing and radius scales, shared components. | The system blue made the app look like a demo; state colours stand out only when nothing else is coloured. |
| D54 | The composer remembers the worktree it created, requires `live` to send, and no longer navigates to a previous result. | A retried send created a second worktree. |
| D55 | Internet access goes through a dumb WebSocket relay on `relay.codans.dev`; TLS-PSK runs end to end inside it and terminates at the unchanged gateway. | No port forwarding, VPN or account; the relay sees only ciphertext, and no second security model exists. |
| D56 | Both ends bridge the relay through a loopback TCP socket. | Network.framework cannot run the PSK handshake over a custom byte stream; the bridge keeps every `NWConnection` path unchanged. |
| D57 | A phone's relay token is `HMAC-SHA256(psk, "codans-relay-token-v1")`; the relay holds only SHA-256 hashes of tokens and of the Mac's secret (trust on first use). | Paired phones need no new secret; revoking a device removes its hash; a relay compromise yields nothing that opens a session to the Mac. |
| D58 | The relay runs on the nanops VM behind Caddy on 443 (Cloudflare record DNS only), WebSocket pings every 25 s. | 443 passes every network; a DNS-only record keeps Caddy's certificate issuance and renewal direct; pings stay under NAT and proxy idle cut-offs. |
| D59 | Outside access is one Mac-wide switch, off by default; a device's permission is the same on and off the LAN. | Gump's call: the tier already bounds what a device can do. |
| D60 | The phone tries Bonjour for 1.5 s, then the relay; `HelloResponse.relay` and new pairing codes carry the relay coordinates. | The LAN stays the fast path; phones paired before the relay existed learn it without pairing again. |
| D61 | A device that may type gets a terminal seat, a zmx client of its own; the pane's size follows the leader, the client that last typed (tmux `window-size latest`). Supersedes "the phone never resizes" (D45's sizing half). | Mirroring the Mac's grid cannot fit a phone; letting the program lay out for the phone is the only real fit, and zmx already sizes the PTY for its leader. |
| D62 | Keys typed through a seat are encoded on the device (xterm legacy encoding, modes from its own emulator) and sent as bytes (`pane.input`). | Encoding on the Mac's surface writes to the Mac's client, which would keep the lead on the Mac; the device's emulator already tracks the modes. |
| D63 | `claim: auto` takes the lead at once only when nobody can see the pane on the Mac (no surface, not in a window, or its window not visible); otherwise the device leads once its user types. `pane.claimSize` lets the user decide, and the phone gives the size back when it goes to the background. | A pane on the Mac's screen is never re-laid-out just by opening it on the phone; one nobody sees fits the phone at once. An idle timer guessed at presence and resized panes someone was reading. |
| D65 | The Mac frosts the cells a device-sized pane leaves unused and offers "Use Mac Size". | The narrow grid over stale cells looked broken; the notice says why and undoes it in one click. |
| D64 | zmx hands the lead back to the most recently active terminal client when the leader leaves or releases (`Claim` 18, `Release` 19, an `ObserveState` capability flag). | Without it a phone that closed would leave the pane at its size until someone typed on the Mac. |

## Cross-Cutting Concerns

**Security.** Covered in [Security Model](#security-model) and [Permission Tiers](#permission-tiers). Review focus for every change on this track: the tier table, key storage attributes, the default-off switch, and that rejected calls never reach a handler.

**Privacy.** Pane text crosses the LAN only inside TLS and only on request. Logs record device IDs and method names, never pane text, input text or keys. The Mac's Settings shows each device's last-seen time.

**Observability.** `os.Logger` subsystem `com.gumpw.codans.remote` on the Mac (categories `gateway`, `pairing`, `events`): listener state, handshake accept/reject with reason (unknown identity, timeout), tier rejections, subscriber count. The iOS app logs connection state transitions under `com.gumpw.codans.mobile`.

**Compatibility.** `system.hello` already negotiates protocol major/minor; `events.subscribe` bumps the minor to 1 and the phase-2 methods to 2, and the phone gates each feature on the minor it needs. New summary and frame fields are optional and unknown frame kinds or input events decode as `unknown`, so version skew in either direction degrades instead of failing. The iOS app refuses a Mac whose major differs and shows "update codans on your Mac" (or the reverse). Local CLI behaviour is unchanged.

**Rollback.** The gateway is behind a default-off switch; disabling it removes every remote code path from runtime. The shared-layer changes (multiplatform `CodansCore`/`CodansIPC`, `KeyCode`) are behaviour-preserving and covered by existing tests.

### Testing Plan

Targeted suites run with `xcodebuild test -workspace codans.xcworkspace -scheme <Scheme> -only-testing:<Target>/<Suite>`, always naming a suite and checking the executed test count and each "Suite X passed" line (a hung `TestStore` test can still report success).

| Area | Test |
|---|---|
| Shared layer | `KeyCode` values equal the former Carbon constants; `CodansCoreTests` pass on macOS; `CodansCore` and `CodansIPC` build for `generic/platform=iOS Simulator`; `make mac-build` has no regression. |
| Permission tiers | Exhaustive test over `IPC.Method.allCases` against a tier fixture; the never-remote set is asserted explicitly. |
| Pairing | `PairingPayload` round-trip; rejects unknown version, short key, wrong prefix, channel mismatch. |
| TLS-PSK | Loopback `NWListener`/`NWConnection`: correct key succeeds; wrong key, unknown identity and revoked identity fail. |
| Router | `.readOnly` device gets `forbidden` for `terminal.sendInput`; `.interactive` device gets `forbidden` for every never-remote method; `.local` context unchanged. |
| Events | Snapshot is first; bursts within the debounce window coalesce into one frame; a slow reader keeps at most one pending frame per topic; stream ends on revoke/disable. |
| iOS reducers | `TestStore` for the connection state machine (connect, background, backoff, resubscribe), agent grouping, PaneDetail input visibility per tier. |
| zmx observer | `observer.bats`: an observer's `Input` / `Init` / `Resize` are ignored; a leader resize applies and reaches observers as `ObserveResize`. A slow test checks the PTY size is unchanged while observed. |
| Terminal stream (Mac) | `ZmxStreamDecoderTests` (pre-state output dropped, unknown tags skipped, 300 ms fallback); a fake daemon asserts the client only ever sends `Observe` / `History`; `PaneStreamSessionTests` on a virtual clock (coalescing, 1 MiB overflow → `reset` with `epoch + 1`, `resized` ordering, EOF → `exited`, fd closed on cancel); wire round-trips including unknown kinds and old `TabSummary`; tier and router tests (zoom routed, read-only refused `sendEvents` but allowed `attachStream`); table-driven `KeyEventSpec`. |
| iOS phase 2 | `TestStore`: phase machine (`rejected` after 3 refusals, not live before the snapshot, path change reconnects, deadline), offline cache, `TerminalStreamFeature`, modifier latch/lock, IME marked text not sent before commit, composer retry reuses its worktree. |
| End to end (phase 2) | The harness adds live output, live input, Ctrl-latch interrupt, no leader steal (resizing the Mac window while a phone streams keeps `stty size` equal to the Mac's), tab operations, read-only streaming without a keyboard, and `rejected` after revocation. |
| Build | `make mac-build`; `make ios-build` (iOS Simulator). |
| End to end | [`docs/user-tests/ios-companion/harness.sh`](../user-tests/ios-companion/README.md): an isolated Debug instance (private socket, config and a short cache path; never the user's running app) with Remote Access on issues pairing codes from its Settings pane over the accessibility API, and the `CodansMobileUITests` target on a simulator opens the `codans-pair:` link, confirms, browses to the fixture pane and sends a line that the Mac reads back. A view-only pairing must not show the input bar; revoking removes the records and their Keychain keys. The UI test skips without the harness's `TEST_RUNNER_CODANS_E2E_*` variables. |
| iPhone Duo (after Xcode 27.1) | DeviceHub simulator: fold/unfold keeps selection and scroll position, rotation on the inner display, Split View with another app, two windows of Codans side by side. |

## Risks

| Risk | Mitigation |
|---|---|
| PSK cipher suites unavailable or deprecated in the installed SDK | The loopback test is the first M1 task; fallback to pinned self-signed certificates is designed (Alternatives). |
| A leaked pairing code grants access | Short-lived pending pairings, explicit reveal, `.readOnly` default, last-seen display, one-step revoke. |
| The local-network privacy prompt is denied | Connection feature detects the denial and explains how to re-enable it in iOS Settings. |
| Bonjour service name changes (Mac renamed, or mDNS renames the relaunched app to "Name (2)" because a crashed or killed instance left its record cached for up to an hour) and the phone can no longer find its paired Mac | Discovery returns every same-channel candidate, ordered: the paired name, its conflict renames, then (only if neither exists) the rest of the channel; the phone tries each with a short handshake budget until one connects. A stable gateway ID in the TXT record can be added without a protocol change. |
| Event stream floods on large catalogs or chatty agents | Debounce + one pending frame per topic; pane text is never on the event stream (polled in v1, its own per-pane stream from minor 2). |
| Serial per-connection processing makes the control connection feel slow when one call is slow | Keep slow calls (`agent.wait`) off the remote surface; measure `pane.read` latency on large scrollback and cap `tail`. |
| Shared targets regress on macOS when made multiplatform | Behaviour-preserving changes, identical `KeyCode` values, full `CodansCoreTests` and `make mac-build` before commit. |
| Duo behaviour differs from expectations built without the 27.1 SDK | Standard containers only; validation scheduled as soon as Xcode 27.1 is available; the gap is stated in the deliverable. |
| Interactive tier is effectively shell access | Opt-in per device, visible in the device list, downgradable instantly (enforced on the next call; the phone reconnects to pick it up). Phase 2 widens it to closing tabs and panes (which ends processes): confirmation on the phone, and the never-remote list is unchanged. |
| A revoked or expired device only sees a handshake timeout over Bonjour (the server logs `unknown PSK identity`, but the client's connection keeps racing the other resolved endpoints until the deadline), so the phone retries with "Your Mac did not answer in time" instead of asking to pair again | Phase 2: three consecutive handshake refusals from a resolved gateway end in the terminal `rejected` phase with Pair Again (D42). Residual: if the LAN path reports only timeouts, never refusals, the phone stays in `timeout`; the E2E `rejected` case checks the real path. |
| The SwiftTerm fixed-grid spike fails (the view insists on sizing the grid from its frame) | The spike runs before any terminal UI work and reports early; the fallback is a SwiftTerm fork with a fixed-grid mode. |
| The observer protocol lives only in the zmx fork | Tags are additive, wire-frozen by the fork's test, and ignored-by-design on the leader path; codans falls back to `History vt` for daemons without them. |
| Panes started before the upgrade run old daemons, so their stream is approximate (cursor may be misplaced with scrollback) | `reset` carries `fidelity: "approximate"`; re-snapshot on geometry change; restarting the pane gives the exact path. |
| An old daemon reacts badly to an unknown `Observe` tag (e.g. closes the connection) | The fallback opens its own `History` request; the stream socket is separate from the session's leader, so the Mac's view is unaffected. To be verified against a pre-upgrade daemon in the slow test. |
| A slow phone or weak Wi-Fi backs up agent-heavy output | 16 ms coalescing, 1 MiB backlog cap with resync; the daemon is drained continuously and never blocked by the phone. |
| A phone key triggers a Mac app shortcut, or typed text arrives paste-wrapped | Binding filter before encoding; committed text sent as key text, only `paste` uses bracketed paste; table-driven `KeyEventSpec` tests. |
| Input to a pane without a live surface silently disappears | `unsupported("pane not open on the Mac")`, `PaneSummary.isLive`, and Open on Mac on the phone. |
| Replayed keystrokes after a reconnect do something unintended | Keys are never queued while disconnected; the input is disabled with a reason. |
