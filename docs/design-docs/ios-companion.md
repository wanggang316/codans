# Design Doc: iOS Companion (Codans Mobile)

**Status:** Draft — approved for implementation. M0 (multiplatform shared layer), M1 (Mac LAN gateway) and M2 (iOS MVP) are in scope; M3 (live terminal) and the relay/push path are design-only.
**Author:** Gump (with Claude)
**Date:** 2026-09-25

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
- **Access from outside the LAN in v1.** No relay, no port forwarding guidance, no cloud account. The relay is designed below as future work.
- **Push notifications in v1.** They require an always-reachable sender, which v1 does not have; the iOS app surfaces "needs input" only while connected.
- **A live, interactive terminal in v1.** Pane detail is a monospaced text snapshot refreshed on events. A byte-level live terminal is the M3 spike.
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
| `.readOnly` | `system.hello`, `system.ping`, `system.version`, `system.status`; `hierarchy.list*`, `hierarchy.describe*`, `hierarchy.resolveAlias`, `hierarchy.resolvePaneLabel`, `hierarchy.resolveWorktreeGlob`; `agent.listStates`, `agent.listProfiles`; `pane.read`, `pane.info`; `terminal.readText`; `workspace.describe`; `project.listScripts`; `events.subscribe` |
| `.interactive` | `terminal.sendInput`, `terminal.sendKey`, `terminal.retryPane`; `agent.launch`; `hierarchy.createWorktree` (branch name only: a remote caller passing `path` or `reuseExisting` is refused); `hierarchy.activateWorktree`, `hierarchy.activateTab`, `hierarchy.focusPane`, `hierarchy.createTab`, `hierarchy.openPane`, `hierarchy.splitPane`, `hierarchy.zoomPane`, `hierarchy.unzoomPane` |
| `.localOnly` — **never remote** (a security position, not a backlog) | `system.quit`; `editor.*`; `hierarchy.removeProject`, `hierarchy.removeWorktree`, `hierarchy.pruneWorktrees`; `project.addScript`, `project.updateScript`, `project.removeScript`; `workspace.remove`; `terminal.broadcastInput`; `terminal.sendRawBytes` |
| `.localOnly` — not remote in v1 (may be promoted later with a design change) | everything else: renames, tags and tag filter, `hierarchy.addProject`, `hierarchy.closeTab`, `hierarchy.closePane`, `pane.close`, `hierarchy.resizePane`, `hierarchy.setPaneLabels`, `hierarchy.setProjectEditor`, `terminal.resetPane`, `workspace.create` / `add` / `drop`, `handoff.*`, `agent.wait` |

Why the never-remote entries are never: they destroy data or history (`remove*`, `prune*`), persist commands that later run as the user (project script writes), act on the Mac outside codans' own window (`editor.*`, `system.quit`), or widen the blast radius of a single keystroke beyond the pane on screen (`broadcastInput`, `sendRawBytes` — raw bytes also bypass the named-key vocabulary that keeps input reviewable). `agent.wait` is excluded for a different reason: it blocks its connection, and the event stream already answers the same question.

New pairings default to `.readOnly`; `.interactive` is an explicit choice in the pairing sheet or the device list.

### Caller Context

`MethodRouter.route(_:peerPID:)` becomes `route(_:context:)`:

```
enum CallerContext { case local(peerPID: pid_t?), remote(deviceID: UUID, permission: RemotePermission) }
```

- `SocketServer` connections are `.local(peerPID:)`; behaviour is unchanged, including pane attribution for `hierarchy.resolveAlias`.
- Gateway connections are `.remote(...)` with `peerPID == nil`, so process-ancestry attribution never runs for them. The permission is read from `PairedDeviceStore` per request, not captured at connect time, so a downgrade takes effect on the next call without reconnecting.
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

Pipelining on the control connection still helps (requests queue without extra round-trips), but responses arrive in request order. Changing the server to serve frames concurrently was rejected for v1 (see Alternatives).

**Lifecycle.** `scenePhase` drives connection state: entering background closes both connections (iOS suspends sockets anyway); returning to active reconnects with exponential backoff (0.5 s doubling to a 30 s cap, reset on success) and resubscribes, which delivers a fresh snapshot. Network path changes (`NWPathMonitor`) trigger an immediate retry.

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

Pane text is deliberately *not* on the event stream: it is large, high-frequency, and only needed for the pane on screen. `PaneDetail` pulls `pane.read(tail: N)` when an event touches its pane and on a fallback timer while visible.

### Data Storage

- **Mac, `remote-devices.json`** under `AppDirectories.configDirectory` (so Debug and Release have separate device lists), written through `AtomicFileStore` with `version: 1`: per device `deviceID`, `name`, `permission`, `state` (pending/active), `createdAt`, `lastSeenAt`. Unknown versions are routed aside like every other codans file. `lastSeenAt` writes are throttled (once per connection, not per request).
- **Mac Keychain:** one PSK per device (above). Revocation deletes the Keychain item first, then the record, then closes live connections.
- **Mac settings:** the gateway on/off switch lives in `settings.json` (`remoteAccess.enabled`, default `false`), tolerant-decoded like other settings.
- **iOS:** paired gateways (service name, channel, device ID) in the app's `UserDefaults`; keys in the Keychain. Per-scene navigation state in `@SceneStorage`. No catalog cache on disk: the snapshot on connect is authoritative.

### Component Boundaries

| Component | Location | Responsible for | Not responsible for |
|---|---|---|---|
| `CodansCore`, `CodansIPC` | `apps/mac/` | Domain and wire types, now built for macOS and iOS | Any platform UI type; `NSColor` conversions move to the app, Carbon key codes are replaced by an in-module `KeyCode` table with identical values |
| `CodansRemote` (static framework, macOS + iOS) | `apps/mac/CodansRemote/` | `PairingPayload`, `RemoteTLS` (`NWParameters` builders), `NWFrameTransport` (`NWConnection` ⇄ reader/write/close), `RemoteRPCClient`, Bonjour constants | Pairing UI, device persistence, authorization decisions |
| `RemoteGateway` feature | `apps/mac/codans/App/Features/RemoteGateway/` | `RemoteGatewayServer` (listener, Bonjour, PSK selection), `PairedDeviceStore`, Settings → Remote Access panel | Method handling (delegates to `SocketConnection` / `MethodRouter`) |
| `MethodRouter` + `CallerContext` | `apps/mac/codans/App/Features/Socket/` | Tier enforcement, routing | Transport details |
| `CodansMobile` (iOS app) | `apps/ios/CodansMobile/` | Connection, pairing UI, Agents / Browser / PaneDetail / Settings features | Anything that needs a process |

Dependency direction: `CodansCore` ← `CodansIPC` ← `CodansRemote` ← {`codans` app, `CodansMobile`}. `CodansRemote` imports Network and Security but no UI framework. `CodansMobile` depends on the three shared targets through Tuist cross-project references (`.project(target:path: "../mac")`) plus TCA at the same version as the Mac app; it does **not** link GhosttyKit, `CodansKit` or ArgumentParser.

### iOS App Structure

- **Project.** `apps/ios/Project.swift`: target `CodansMobile`, `PRODUCT_NAME = Codans`, bundle ID `com.gumpw.codans.mobile`, destinations iPhone + iPad, iOS 26.0, Swift 6 with MainActor default isolation. `apps/ios/Tuist.swift`, `apps/ios/Tuist/Package.swift` (TCA pinned to the Mac app's version), `apps/ios/Makefile`, and `ios-*` delegators in the root `Makefile`.
- **Info.plist.** `NSLocalNetworkUsageDescription`, `NSBonjourServices`, `NSCameraUsageDescription`, `UIApplicationSupportsMultipleScenes = YES`; no orientation lock.
- **Features** (TCA reducers end in `Feature`, views in `View`): `Connection` (browse, pair, reconnect), `Browser` (the home screen: Project → Worktree, then the worktree's Tab → Pane), `Agents` (event-driven list grouped as *needs input* / *working* / *idle*, presented as a sheet; picking an agent navigates the workspace to its pane), `PaneDetail` (text snapshot, input bar, key row Enter / Esc / Ctrl-C / Tab / ↑ / ↓, hidden for read-only devices; iPad hardware-keyboard shortcuts via `.keyboardShortcut`), `Settings` (paired Macs, forget; a sheet).
- **App-level state.** One `ConnectionStore` per process, shared by all scenes: two windows showing the same Mac share one control and one events connection.

### iPhone, iPad and iPhone Duo Adaptation

iPhone Duo (announced 2026-09-09, on sale 2026-10-23) has a 5.4″ outer display and a 7.6″ inner display, runs iOS 27 / 27.1, and supports two-app Split View and multiple windows of one app. The rules below make one layout serve every device; they follow Apple's guidance for the device and are ordinary good practice on iPad.

1. **Size classes only, never orientation.** The inner display does not honour an app's supported orientations, and compact/regular is what actually varies. The outer display is compact width; the inner display is regular × regular. No code branches on `UIDevice.orientation` or interface orientation.
2. **Standard containers.** The root is one three-column `NavigationSplitView`: projects with their worktrees in the sidebar, the selected worktree's tabs and panes, then the pane. Agents and Settings are toolbar buttons that present sheets, not top-level tabs, so the home screen is the workspace itself; agent state also shows as badges on worktree and pane rows, and the Agents button turns orange with a count while agents need input. From iOS 27.1 standard navigation bars and toolbars move to the side on the Duo inner display automatically; custom bars would need the 27.1 `ReservedRegion` API, which v1 does not use because it draws no custom bars.
3. **No `UIScreen.main`.** It is being deprecated and is wrong on a device with two displays. Scale comes from `@Environment(\.displayScale)` / `traitCollection.displayScale`; sizes come from layout, not the screen.
4. **Safe areas per edge.** Insets are not assumed symmetric or bottom-heavy. Views use `.safeAreaInset(edge:)` and `.ignoresSafeArea(_:edges:)` with explicit edges; the PaneDetail input bar is a bottom safe-area inset, not a fixed offset.
5. **Multiple scenes.** `WindowGroup` with `UIApplicationSupportsMultipleScenes`; each scene owns its navigation store, all scenes share `ConnectionStore`.
6. **Continuity across fold/unfold and window changes.** Selected tab, selected project/worktree/pane IDs and the PaneDetail scroll anchor are kept in `@SceneStorage`, so folding (inner → outer display), unfolding and Split View resizes restore the same place. Anything not in scene storage must be re-derivable from the event snapshot.
7. **Toolchain.** Built with the iOS 26 SDK the app runs on iPhone Duo, but the inner display gets a compatibility (non-full-screen) presentation. The full Duo experience requires building with **Xcode 27.1** and validating in the DeviceHub Duo simulator (fold/unfold, rotation, Split View). That is an environment prerequisite: once Xcode 27.1 is installed, `apps/ios/Tuist.swift`'s Xcode constraint is widened and the Duo checks in the testing plan run. Until then the deliverable is "adapted per the rules above, pending 27.1 verification".

## Future Work (design only, not built in this track)

### M3: Live terminal (spike)

> **Future.** Nothing in this section is implemented; it defines what a spike must answer.

Goal: an interactive terminal view of one pane on iOS, not a text snapshot.

- **Renderer.** First choice is libghostty on iOS in an external-IO mode (the surface renders bytes it is fed, with no PTY or child process on the device). The spike must confirm libghostty builds for iOS in that mode and that GhosttyKit's size stays acceptable. Fallback: SwiftTerm, a pure-Swift terminal emulator that already supports iOS and externally fed bytes.
- **Byte source.** A new streaming method `pane.attachStream` that attaches as an additional `zmx` client and forwards the raw output bytes (plus an initial serialized screen state). Input goes back through the existing `terminal.sendInput` / `sendKey`.
- **Size authority.** The phone attaches **read-only in size**: it never resizes the PTY, the Mac's surface remains the size owner, and the phone renders at the Mac's grid (scaling or scrolling). This avoids fighting the desktop layout and the known `zmx` reflow crash on resize.
- **Questions for the spike.** zmx multi-client attach semantics and backpressure; whether a slow phone can stall the daemon; bandwidth for agent-heavy output on Wi-Fi; the permission tier (`.interactive` for input, `.readOnly` for viewing).

### Relay and push notifications

> **Future.** Nothing in this section is implemented.

Goal: reach the Mac from outside the LAN and notify the phone when an agent needs input while the app is closed.

- **End-to-end encrypted relay.** Mac and phone each hold an outbound connection to a relay; the relay forwards opaque frames between them. The session is authenticated and encrypted end to end with keys established at pairing (the same per-device key, or a Noise-style handshake keyed from it), so the relay sees only ciphertext and routing IDs and cannot issue commands.
- **APNs.** The Mac notices "needs input" (the same agent-state transitions `Notifications` already uses), and asks the relay to send a push. The push body carries no pane content — only an opaque reference the app resolves after connecting — so neither Apple nor the relay learns what the agent asked.
- **Open questions.** Who operates the relay and what it costs; account-less device registration; rate limits; whether the permission tiers should be stricter off-LAN.

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

## Cross-Cutting Concerns

**Security.** Covered in [Security Model](#security-model) and [Permission Tiers](#permission-tiers). Review focus for every change on this track: the tier table, key storage attributes, the default-off switch, and that rejected calls never reach a handler.

**Privacy.** Pane text crosses the LAN only inside TLS and only on request. Logs record device IDs and method names, never pane text, input text or keys. The Mac's Settings shows each device's last-seen time.

**Observability.** `os.Logger` subsystem `com.gumpw.codans.remote` on the Mac (categories `gateway`, `pairing`, `events`): listener state, handshake accept/reject with reason (unknown identity, timeout), tier rejections, subscriber count. The iOS app logs connection state transitions under `com.gumpw.codans.mobile`.

**Compatibility.** `system.hello` already negotiates protocol major/minor; `events.subscribe` bumps the minor. The iOS app refuses a Mac whose major differs and shows "update codans on your Mac" (or the reverse). Local CLI behaviour is unchanged.

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
| Build | `make mac-build`; `make ios-build` (iOS Simulator). |
| End to end | [`docs/user-tests/ios-companion/harness.sh`](../user-tests/ios-companion/README.md): an isolated Debug instance (private socket, config and a short cache path; never the user's running app) with Remote Access on issues pairing codes from its Settings pane over the accessibility API, and the `CodansMobileUITests` target on a simulator opens the `codans-pair:` link, confirms, browses to the fixture pane and sends a line that the Mac reads back. A view-only pairing must not show the input bar; revoking removes the records and their Keychain keys. The UI test skips without the harness's `TEST_RUNNER_CODANS_E2E_*` variables. |
| iPhone Duo (after Xcode 27.1) | DeviceHub simulator: fold/unfold keeps selection and scroll position, rotation on the inner display, Split View with another app, two windows of Codans side by side. |

## Risks

| Risk | Mitigation |
|---|---|
| PSK cipher suites unavailable or deprecated in the installed SDK | The loopback test is the first M1 task; fallback to pinned self-signed certificates is designed (Alternatives). |
| A leaked pairing code grants access | Short-lived pending pairings, explicit reveal, `.readOnly` default, last-seen display, one-step revoke. |
| The local-network privacy prompt is denied | Connection feature detects the denial and explains how to re-enable it in iOS Settings. |
| Bonjour service name changes (Mac renamed) and the phone can no longer find its paired Mac | Match on channel and fall back to listing every same-channel gateway; re-pairing is cheap. A stable gateway ID in the TXT record can be added without a protocol change. |
| Event stream floods on large catalogs or chatty agents | Debounce + one pending frame per topic; pane text is pull-only. |
| Serial per-connection processing makes the control connection feel slow when one call is slow | Keep slow calls (`agent.wait`) off the remote surface; measure `pane.read` latency on large scrollback and cap `tail`. |
| Shared targets regress on macOS when made multiplatform | Behaviour-preserving changes, identical `KeyCode` values, full `CodansCoreTests` and `make mac-build` before commit. |
| Duo behaviour differs from expectations built without the 27.1 SDK | Standard containers only; validation scheduled as soon as Xcode 27.1 is available; the gap is stated in the deliverable. |
| Interactive tier is effectively shell access | Opt-in per device, visible in the device list, downgradable instantly without reconnect. |
| A revoked or expired device only sees a handshake timeout over Bonjour (the server logs `unknown PSK identity`, but the client's connection keeps racing the other resolved endpoints until the deadline), so the phone retries with "Your Mac did not answer in time" instead of asking to pair again | Open. Loopback connections do surface the TLS failure; the LAN path needs the rejection made terminal on the client, or a client-side "pair again" hint after repeated handshake failures against a reachable Mac. |
