# Design Doc: Remote Projects over SSH

**Status:** Implemented (discovery, terminal, status parity, worktree create/remove, edit remote project)
**Author:** Gump
**Date:** 2026-07-24

## Context and Scope

codans orchestrates *local* terminals into a Project → Worktree → Tab → Pane
hierarchy. Every git operation shells out to `/usr/bin/git` (or the bundled `wt`
script) with a local `cwd`, and every Pane spawns `zmx attach <uuid>` with a
local `working_directory` handed to libghostty.

A **Remote Project** adds a new source for that hierarchy: the user enters an SSH
host / port / username / remote path; codans connects over SSH, lands in that
path, and from then on Worktree/Tab/Pane management is the same as local — the
worktree list is discovered over SSH and each Pane's shell runs on the host.

Authentication is delegated entirely to the user's `~/.ssh/config` + `ssh-agent`.
codans never collects or stores a password or key.

## Goals and Non-Goals

**Goals**

- A Remote Project kind (`ProjectKind.remote`): connect over SSH, browse the remote git worktree
  list, and open persistent terminals that land in the remote worktree.
- Terminal persistence across app quit *and* connection drops: a local `zmx`
  session wraps an SSH reconnect loop, with an optional host-side `zmx` session
  for remote persistence.
- One multiplexed SSH connection shared by git probes and the terminal, so a
  many-worktree sidebar costs a single auth.
- Zero migration: existing local catalogs round-trip byte-identically.

**Goals (worktree management parity)**

- Remote worktree **create** through the same sheet as local: options (base
  refs, local branches, default remote branch, collision classification) load
  over SSH via the routed worktree client; creation runs `git worktree add -b
  <name> <path> <baseRef>` on the host (with an optional host-side `git fetch`
  when the base ref tracks a remote), landing beside the repo root. The wt-only
  copy-ignored / copy-untracked toggles are hidden for remote.
- Remote worktree **remove** through the same flow as local: the shared
  removal path routes `git worktree remove --force` + branch cleanup over SSH
  ("is not a working tree" still maps to idempotent success). No local trash
  relocation on a host.
- **Open Remote Project** picks a Host from the Host list, or "New Host…"
  (Host, Username, Port, Name, Icon), which always adds a record to the Host list.
  Fields equal to an existing Host use that Host. When the Host and the
  resolved path already are a Project, the sheet closes and selects that
  Project; nothing is added (ADR 0006). A local Project with the same path is
  not a conflict.
- **Edit Remote Project** on a Remote Project changes its Host choice and path,
  never the Host fields, re-validated like an add; a path change reseeds the
  worktree rows, a Host-only change keeps them. A Host and path equal to
  another Project is an error in the sheet, and the change is not applied.
  The Project's own Host and path always save.
- **Settings › Remote Hosts** adds, edits, and deletes Host records. An edit applies
  to all Projects on the Host; delete is disabled while Projects use it. Each
  row shows the Host's icon.
- **Host icon.** A record has an optional icon (`HostIcon`), picked from a menu
  in the shared Host form: Globe, Server, Cloud, MacBook, Mac mini, Mac Studio,
  Desktop. A record with no icon shows Server. This Mac has no record and shows
  the symbol of the machine model (`ThisMacIcon`); it is not editable.
- **Remote Project marker.** Every place that marks a Project as remote uses
  the `wifi` symbol, the same symbol as the sidebar's Remote filter button:
  the sidebar Project row, the failed Project row, the worktree header, the
  Agent State row, and the menu items that act on Remote Projects ("Open
  Remote Project…", "Open Remote Project on This Host…", "Edit Remote
  Project…"). One shared constant holds the symbol name, so the marker and
  the filter cannot drift apart. The marker is not a Host icon: Host rows keep
  `HostIcon`, and a remote clone source in Create Workspace keeps `globe`.

**Non-Goals**

- In-app credential management. Auth is `~/.ssh/config` + agent, full stop.
- FSEvents-style *push* change detection for remote worktrees. Remote git
  status (`+N −M` chip, dirty flag, PR badge, branch switcher)
  runs over the SSH-routed `GitService` (see below), refreshed by polling and
  shell-integration markers rather than local file watchers.
- The `wt` streaming-create extras (copy ignored / untracked, in-stream setup
  script) on remote hosts — remote creation is plain `git worktree add`.

## Design

### Overview

Representation reuses the existing string-path plumbing rather than forking the
model:

- `Catalog.hosts: [HostRecord]` — the Host list (ADR 0003). A `HostRecord` is
  `{ id, address, username?, port?, name?, icon? }`; no two records share
  (address, username, port), with no port equal to 22.
- `Project.hostID: HostID?` — non-nil ⇒ a Remote Project, persisted in place of
  host fields. `Project.remoteHost: RemoteHost?` is the endpoint resolved from
  the Host record (`Catalog.resolveHostReferences`), so runtime code reads the
  connection without a lookup. `RemoteHost` is `{ alias, username?, port? }`
  and derives the `ssh` destination + option argv. It carries no secret.
- For a Remote Project, `rootPath` / `gitRoot` / each `Worktree.path` hold
  **remote** path strings. The existing `worktree.path → workingDirectory` flow
  is preserved; the SSH layer applies `cd` on the remote.
- `ProjectKind` derives `.remote` from `remoteHost != nil`.

The single hard rule: **local-filesystem operations are gated on
`remoteHost == nil`.** `FileManager.fileExists`, `URL(fileURLWithPath:)`, and
`resolvingSymlinksInPath` all resolve against the *local* FS and are meaningless
for a remote path — remote paths use a string-only normalization
(`HierarchyManager.normalizeRemotePath`) and an SSH probe instead. A string
compare cannot see that `/tmp/x` and `/private/tmp/x` (or a typed-case path on
a case-insensitive host) are one directory, so the host decides: each remote
reconcile first asks the host git for its form of the root
(`RemoteGitService.canonicalWorkTreeRoot`) and, when it differs, re-keys the
Project onto it (`HierarchyManager.adoptCanonicalRemoteRoot`). Rows that then
share a path merge into the first one, tabs included. When another Project on
the same Host already has that root (ADR 0006), the root stays, rows at
either form still merge under it, and the reconcile skips discovery for this
Project. `pwd -P` does not decide
this: it keeps the typed case, while `git worktree list` reports the on-disk
case.

### System Context Diagram

```
  ┌────────────┐   RemoteProjectSheet       ┌──────────────────┐
  │   User      │──────── host/path ───────→│  addRemoteProject │
  └────────────┘                            └────────┬─────────┘
                                                      │ Project(remoteHost:…)
                             reconcile                ▼
  ┌──────────────────┐   RemoteGitService    ┌──────────────────┐
  │ ProjectReconciler │──ssh git worktree ls─→│    remote host    │
  │  (reachability)   │←──── porcelain ───────│  /usr/bin/git     │
  └──────────────────┘                        └──────────────────┘
                             open tab                 ▲
  ┌──────────────────┐  RemoteSurfaceCommand         │ ssh (ControlMaster)
  │  TerminalEngine   │─ local zmx → ssh loop ────────┘
  │  .ensureSurface   │   → remote login shell (+ host-side zmx)
  └──────────────────┘
```

### API Design

Two pure, stateless SSH command builders (fully unit-tested, no side effects):

- `SSHCommand` — one place for the option sets and quoting:
  - `controlOptions()` — `ControlMaster=auto`, a hashed `ControlPath`,
    `ControlPersist=10m`, and `ServerAlive*` keepalives (these belong to the
    master, so every path that can create one carries them).
  - `backgroundProbeOptions` (`BatchMode`, `ConnectTimeout=10`) for git probes;
    `interactiveOptions` (`ConnectTimeout=30`) for the terminal.
  - `sharedMasterGuard(host,…)` — a POSIX `sh` fragment that runs before
    an ssh line uses a master: if `ssh -O check` finds no master, it creates
    one with a no-op `true` while it holds a `lockf` lock at
    `<ControlPath>.lock`.
  - `sharedMasterLine(host,…)` — the POSIX `sh` statement that runs every ssh
    line over one of `masterSlotCount` (4) shared masters per host
    (`masterControlPaths`: `codans-%C`, `codans-%C-1`, …). See Connection
    reuse below.
  - `invocation(host,executable,arguments,workingDirectory,…)` → argv for
    `Process`/`CommandRunner` (one remote-shell quoting level): `/bin/sh -c`
    runs `sharedMasterLine` with the ssh argv as `$@`.
  - `commandLine(host,remoteCommand,…)` → a single string for libghostty's
    `/bin/sh -c` surface command (two quoting levels), built by
    `sharedMasterLine`.
  - `loginShellWrapped` runs the remote command under `exec "$SHELL" -l -c …`
    so a macOS host's Homebrew-augmented PATH is restored.

- `RemoteSurfaceCommand` — the terminal command shape:
  - local `/bin/sh -c` (libghostty) → local `zmx attach <paneUUID>` →
    `/bin/sh -c "<reconnect loop>"` → `ssh <controlopts> host <remoteScript>` →
    remote login shell → `/bin/sh -c "<connect|reconnect>"`.
  - `SSHReconnectLoop` retries only on ssh exit 255 (its reserved
    connection-error code) with capped exponential backoff; every other exit
    passes through and closes the surface like a local shell exit. Ctrl-C during
    the backoff is the escape hatch.
  - After every ssh line returns, before any notice, the loop resets the
    terminal modes a dropped remote program cannot turn off (mouse tracking
    and encodings, focus reporting, bracketed paste, synchronized output, the
    alternate screen, cursor and keypad modes, kitty keyboard, modifyOtherKeys,
    SGR). Without it the fresh shell echoes mouse reports as typed input. It
    is a targeted reset, not RIS, so the output and the notices stay. A
    re-attached host `zmx` session replays the modes its program still holds.
  - With a host-side `zmx`, the worktree shell runs inside `zmx attach
    <codans-paneUUID>` so remote work survives disconnects; otherwise it falls
    back to a plain login shell in the worktree.

Git-over-SSH runs through `RemoteGitService` (built on `SSHCommand.invocation` +
`FoundationCommandRunner`): `discoverGitRoot`, `listWorktrees` (porcelain),
`addWorktree(baseRef:)` / `removeWorktree` / branch queries / fetch / prune /
status, plus `resolveAbsolutePath` — a single-round-trip probe (`~`-expand +
exists + `pwd -P`) used by connect-time validation and the reconciler's
path-vs-unreachable failure classification. `GitWorktreeClient.makeLive` takes
the same `remoteHostResolver` seam, so the worktree-management surface
(listing, create-sheet options, removal, prune) routes per call exactly like
`LiveGitService` does for status.

A reconciler sweep (launch, window focus, Refresh All) keeps a failed Project
`.failed` while it checks it again; only a request for one Project (Retry, a
new Project) shows it as `.loading`. A loading Project shows as a healthy
Project row with its saved worktrees, so the sidebar row would change shape
twice, and the focus sweep runs on the same click that starts a Host row's
expand or collapse animation.

**Transport seam (worktree status parity).** `LiveGitService` funnels every git
invocation through one `invoke(arguments:cwd:)`, parameterized by a
`resolveRemoteHost: (URL) async -> RemoteHost?` closure, backed by
`HierarchyManager.remoteHost(forGitURL:)` (`Catalog.gitRemoteHost`). A local
Project and a Remote Project can have the same path (ADR 0006), so a caller
that acts on a Project builds the URL with `Project.gitURL(_:)`: a file URL on
This Mac, a `codans-host://<host-id>/<path>` URL on a Host. A Host-form URL
runs on that Host. A plain path runs on This Mac when a Project on This Mac
owns it; otherwise it runs on the Remote Project that owns it (exact string
match, never the local symlink resolver). When the call runs on a Host, the
invocation becomes `ssh <controlopts> host 'cd <repo> &&
git …'` under the host's login shell (bare `git`, PATH-resolved); otherwise it
is the unchanged local `/usr/bin/git`. The parsers never see the transport, so
the current status consumers — sidebar `+N −M` chip, dirty flag, the PR
badge's `remote get-url` probe, and branch switcher — use the same git
transport for remote worktrees. In-app diff and history viewers have been
removed; external git clients have no SSH integration (see
[editor-integration.md](./editor-integration.md)). Freshness comes from the
sidebar's per-row poll (~20 s while a remote row is visible, riding the shared
ControlMaster) plus the shell-integration markers remote panes emit through the
terminal (commit/push in a pane refreshes the chip immediately).

### Data Storage

`catalog.json` v5 stores the Host list as `hosts`, and each Remote Project
stores only `hostID`. `HierarchyManager` is the single writer: Open
Remote Project and Edit Remote Project reuse the Host whose fields equal the entered ones,
else add a record (`Catalog.hostID(for:)`). Edit and delete of a Host go
through `HierarchyClient`; delete is refused while a Project refers to it.

`CatalogMigrationV4ToV5` moves the `remoteHost` fields of a v4 catalog into
the Host list: each distinct (address, username, port) becomes one record, in
Project order. A Remote Project without a valid `hostID` (a connection restored
from the sidecar) gets a record the same way on every load
(`Catalog.adoptHostReferences`). A Remote Project's
`rootPath`/`gitRoot`/worktree paths are stored verbatim (remote strings), never
passed through the local canonicalizer.

A small sibling file lives beside the catalog:

- `remote-hosts.json` (`RemoteHostSidecar`) — project-id → host mirror written on
  every save; heals `remoteHost` fields stripped by older builds sharing the
  catalog.

The old `saved-server-hosts.json` recent-hosts list is no longer read or
written; the Host list replaces it (ADR 0003).

### Agent Detection Parity

Local panes identify coding agents from the pane's foreground process group
(local sysctl walk → `AgentKindPatterns` → `AgentBinder`), so a remote pane —
whose local foreground is permanently the `ssh` tunnel — was invisible to the
Agents View. Parity is restored with a host-side foreground probe:

- The remote worktree shell records its controlling tty under
  `~/.cache/codans/pane-ttys/<paneUUID>` on the host at connect.
- `RemoteForegroundProbe` runs one SSH exec per host per tick (3s idle, 1s
  while an agent is bound) that `ps -t`'s every recorded tty and prints
  `<paneUUID> <pid> <pgid> <stat> <args>` rows; rows carrying the `+`
  foreground flag are grouped into the same `ForegroundJob` shape the local
  reader produces. Records whose tty vanished are pruned host-side.
- The samples feed the SAME snapshot / hysteresis / `AgentBinder` / viewport
  pipeline as local panes, so bind, working/blocked classification (rendered
  text), busy spinners for plain commands, and 6-miss release all behave
  identically. A failed probe (unreachable host) freezes pane state instead
  of emitting empty jobs, so a network blip cannot release a live binding.

### Open in Editor

A remote worktree cannot be a local file URL, so `EditorService.openRemote`
routes through the editor's own SSH remoting CLI instead of `NSWorkspace`:

- **Zed**: bundled `Contents/MacOS/cli` with an `ssh://[user@]host[:port]/path`
  URL (path percent-encoded; custom ports supported).
- **VS Code family** (VS Code / Insiders / VSCodium / Cursor / Trae / Windsurf /
  Antigravity): bundled `Contents/Resources/app/bin/<cli>` with
  `--remote ssh-remote+user@host <path>`. The CLI has no inline port syntax, so
  a non-default port is inexpressible — the menu row disables with a tooltip
  pointing at `~/.ssh/config`.
- Everything else (Finder, Xcode, JetBrains, terminals, git clients) has no SSH
  story and is not offered for remote worktrees. `$EDITOR` needs no special
  handling: its Pane already runs the remote shell.

Resolution mirrors the local cascade (project override → global default →
priority walk) but filtered to editors that can express the host, and is
lenient on a preference that cannot — the open lands on a capable editor
whenever one is installed; the header button hides when none is.

### Component Boundaries

- `CodansCore` — `RemoteHost`, `HostRecord`, `Catalog.hosts` operations,
  `Project.hostID` / `remoteHost`, `ProjectKind.remote`
  (pure domain, no SSH knowledge).
- `Process/` — `SSHCommand`, `RemoteGitService`, `RemoteReachabilityProbe`
  (pure builders + git-over-SSH; no UI, no catalog).
- `Runtime/` — `HierarchyClient.reconcileRemote` (discovery), `ProjectReconciler`
  (reachability), `TerminalEngine.ensureSurface` (remote surface),
  `HierarchyManager.addRemoteProject` / `normalizeRemotePath`.
- `App/Features/HierarchySidebar/` — `RemoteProjectFeature` + Sheet, the
  Add Project menu item, and the local-affordance guards.

## Alternatives Considered

- **A dedicated `RemoteProject` type / parallel hierarchy.** Rejected: it would
  fork every consumer of `Project`/`Worktree`/`Pane` and double the surface. The
  `remoteHost?` overlay reuses the string-path plumbing and keeps the diff to
  the edges (reconcile, surface, guards).
- **Mounting the remote FS (SSHFS) and treating it as local.** Rejected:
  external dependency, fragile under disconnects, and it would make every local
  git call silently slow. Native `git` on the host is faster and is what the
  user already has configured.
- **A `CommandRunner` decorator that rewrites every git call to SSH.** Attractive
  (zero change to `LiveGitService`), but the git surface uses `-C <path>` and the
  bundled `wt`, and the env needed by `ssh` (agent socket) differs from git's
  hardened allowlist. A focused `RemoteGitService` for the discovery subset is
  smaller and clearer than a runner that has to special-case all of that.
- **Host-side `zmx` only (no local zmx).** Rejected: it wouldn't survive an app
  quit that also drops the tunnel. The local `zmx` holds the reconnect loop, so
  quit + relaunch re-attaches and re-establishes SSH.

## Cross-Cutting Concerns

- **Security / auth.** No secret is ever collected or stored. The
  `RemoteProjectSheet` states auth uses the SSH config + agent. Probes use
  `BatchMode=yes` so they fail fast rather than hanging on a prompt; the
  interactive terminal allows a first-connect prompt (no BatchMode).
- **Connection reuse.** A shared `ControlMaster` multiplexes N git probes plus
  the terminal onto one connection — one auth per host, no per-call handshake.
  `ControlMaster=auto` alone does not coordinate the creation of the master:
  when none listens (it ended, or a killed one left a socket that ssh unlinks
  as stale), every line that starts in that window connects and authenticates
  on its own, the first one takes the `ControlPath`, and each other one prints
  `ControlSocket … already exists, disabling multiplexing` and keeps a private
  connection (a terminal keeps it for the whole session). This occurs on each
  reconnect, when panes and probes start together. `sharedMasterGuard`
  serializes the creation per `ControlPath`, so one line creates the master and
  the others wait and then multiplex. The guard never removes a socket, so a
  live master is never touched.
- **Full master (sshd `MaxSessions`).** sshd caps the sessions on one
  connection (`MaxSessions`, default 10). A master that is full refuses a new
  session, and with `ControlMaster=auto` ssh then connects and authenticates
  on its own and prints the same "already exists" warning. So
  `sharedMasterLine` runs each line with `ControlMaster=no` and a sentinel
  `ProxyCommand`: ssh runs it only when it cannot use the master, before
  anything runs on the host. When the sentinel fires and the master is live,
  the line moves to the next shared master (created by the guard, one auth);
  when no master could be created, the line runs with `ControlMaster=auto` as
  before, so auth prompts and errors stay visible. When all 4 masters are
  full, the line uses its own connection (`ControlPath=none`, with the
  `ServerAlive*` keepalives, because it owns its transport) and a terminal
  prints a notice. Trade-off: each overflow master costs one auth, and a
  probe that holds a session for a moment can make a new pane open the next
  master instead of waiting.
- **Testing.** `SSHCommand`, `RemoteSurfaceCommand`, and `RemoteGitService`'s
  parser/normalization are pure and unit-tested; `RemoteProjectFeature`'s
  validation paths are covered by reducer tests. The live SSH path requires a
  reachable host and is verified manually.
- **Guards.** Reveal in Finder is hidden from remote worktree context menus,
  and their Open in submenu lists only SSH-capable editors. External git
  clients have no SSH integration. Open in Editor uses the SSH-capable editor
  path described above. Worktree creation and removal are
  enabled and route over SSH; local `wt` copy options remain hidden.

## Risks

- **Nested shell quoting.** The command crosses three shell levels (libghostty's
  `/bin/sh -c`, ssh's login-shell wrapper, the remote `/bin/sh -c`). Mitigation:
  a single `SSHCommand.shellQuote` at each boundary, exercised by the
  command-shape tests.
- **`SSH_AUTH_SOCK` absent from the GUI app env.** libghostty's exec child and
  the git probes inherit the app process environment; on a launchd session the
  agent socket is present. If it is missing, the interactive terminal still
  prompts (no BatchMode) — only background probes fail fast.
- **Remote creation lacks the wt extras.** Copy-ignored / copy-untracked and
  the in-stream setup script are local streaming-create capabilities; remote
  creation is plain `git worktree add` and hides those toggles. Mitigation: the
  sheet communicates the reduced surface by omission, and git's own errors
  (branch exists, bad ref) surface verbatim in the pending row.
- **Remote status is poll-based.** The FS watchers that make local chips
  instant never fire for remote paths; remote rows refresh on a ~20 s
  visible-row poll plus in-pane shell-integration markers. A burst of remote
  edits outside a codans pane can lag by up to one poll interval — accepted;
  the ControlMaster keeps each tick cheap.
