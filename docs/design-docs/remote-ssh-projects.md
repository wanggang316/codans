# Design Doc: Remote SSH "Server" Projects

**Status:** Implemented (discovery, terminal, status parity, worktree create/remove, edit connection)
**Author:** Gump
**Date:** 2026-07-24

## Context and Scope

codans orchestrates *local* terminals into a Project → Worktree → Tab → Pane
hierarchy. Every git operation shells out to `/usr/bin/git` (or the bundled `wt`
script) with a local `cwd`, and every Pane spawns `zmx attach <uuid>` with a
local `working_directory` handed to libghostty.

A **Server** project adds a new source for that hierarchy: the user enters an SSH
host / port / username / remote path; codans connects over SSH, lands in that
path, and from then on Worktree/Tab/Pane management is the same as local — the
worktree list is discovered over SSH and each Pane's shell runs on the host.

Authentication is delegated entirely to the user's `~/.ssh/config` + `ssh-agent`.
codans never collects or stores a password or key.

## Goals and Non-Goals

**Goals**

- A `.server` project type: connect over SSH, browse the remote git worktree
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
- **Edit Connection** on a Server project (host / port / user / path),
  re-validated like an add; a path change reseeds the worktree rows, a
  host-only change keeps them.

**Non-Goals**

- In-app credential management. Auth is `~/.ssh/config` + agent, full stop.
- FSEvents-style *push* change detection for remote worktrees. Remote git
  status (`+N −M` chip, dirty flag, PR badge, branch switcher, diff inspector)
  runs over the SSH-routed `GitService` (see below), refreshed by polling and
  shell-integration markers rather than local file watchers.
- The `wt` streaming-create extras (copy ignored / untracked, in-stream setup
  script) on remote hosts — remote creation is plain `git worktree add`.

## Design

### Overview

Representation reuses the existing string-path plumbing rather than forking the
model:

- `Project.remoteHost: RemoteHost?` — non-nil ⇒ a Server project. `RemoteHost`
  is `{ alias, username?, port? }` and derives the `ssh` destination + option
  argv. It carries no secret.
- For a Server project, `rootPath` / `gitRoot` / each `Worktree.path` hold
  **remote** path strings. The existing `worktree.path → workingDirectory` flow
  is preserved; the SSH layer applies `cd` on the remote.
- `ProjectKind` derives `.server` from `remoteHost != nil`.

The single hard rule: **local-filesystem operations are gated on
`remoteHost == nil`.** `FileManager.fileExists`, `URL(fileURLWithPath:)`, and
`resolvingSymlinksInPath` all resolve against the *local* FS and are meaningless
for a remote path — remote paths use a string-only normalization
(`HierarchyManager.normalizeRemotePath`) and an SSH probe instead.

### System Context Diagram

```
  ┌────────────┐   RemoteConnectionSheet    ┌──────────────────┐
  │   User      │──────── host/path ───────→│  addServerProject │
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
  - `invocation(host,executable,arguments,workingDirectory,…)` → argv for
    `Process`/`CommandRunner` (one remote-shell quoting level).
  - `commandLine(host,remoteCommand,…)` → a single string for libghostty's
    `/bin/sh -c` surface command (two quoting levels).
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

**Transport seam (worktree status parity).** `LiveGitService` funnels every git
invocation through one `invoke(arguments:cwd:)`, parameterized by a
`resolveRemoteHost: (URL) async -> RemoteHost?` closure. When the repository
path belongs to a Server project (resolved live against the catalog via
`HierarchyManager.remoteHost(forPath:)` — exact string match, never the local
symlink resolver), the invocation becomes `ssh <controlopts> host 'cd <repo> &&
git …'` under the host's login shell (bare `git`, PATH-resolved); otherwise it
is the unchanged local `/usr/bin/git`. The parsers never see the transport, so
every `GitService` consumer — sidebar `+N −M` chip, dirty flag, the PR badge's
`remote get-url` probe, branch switcher, diff inspector, commit log — works
against remote worktrees with no per-feature changes. Freshness comes from the
sidebar's per-row poll (~20 s while a remote row is visible, riding the shared
ControlMaster) plus the shell-integration markers remote panes emit through the
terminal (commit/push in a pane refreshes the chip immediately).

### Data Storage

`RemoteHost` is `Codable`, and `Project.remoteHost` is `encodeIfPresent` — it is
omitted from the encoded form when nil, so existing local catalogs are
byte-identical on round-trip and need no migration. A Server project's
`rootPath`/`gitRoot`/worktree paths are stored verbatim (remote strings), never
passed through the local canonicalizer.

Two small sibling files live beside the catalog:

- `remote-hosts.json` (`RemoteHostSidecar`) — project-id → host mirror written on
  every save; heals `remoteHost` fields stripped by older builds sharing the
  catalog.
- `saved-server-hosts.json` (`SavedServerHosts`) — MRU list of successfully
  validated hosts (address + username + port, capped) feeding the Connect to
  Server sheet's host-field picker. Connection info only; auth never leaves the
  user's SSH config + agent.

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

- `CodansCore` — `RemoteHost`, `Project.remoteHost`, `ProjectKind.server`
  (pure domain, no SSH knowledge).
- `Process/` — `SSHCommand`, `RemoteGitService`, `RemoteReachabilityProbe`
  (pure builders + git-over-SSH; no UI, no catalog).
- `Runtime/` — `HierarchyClient.reconcileRemote` (discovery), `ProjectReconciler`
  (reachability), `TerminalEngine.ensureSurface` (remote surface),
  `HierarchyManager.addServerProject` / `normalizeRemotePath`.
- `App/Features/HierarchySidebar/` — `RemoteConnectionFeature` + Sheet, the
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
  `RemoteConnectionSheet` states auth uses the SSH config + agent. Probes use
  `BatchMode=yes` so they fail fast rather than hanging on a prompt; the
  interactive terminal allows a first-connect prompt (no BatchMode).
- **Connection reuse.** A shared `ControlMaster` multiplexes N git probes plus
  the terminal onto one connection — one auth per host, no per-call handshake.
- **Testing.** `SSHCommand`, `RemoteSurfaceCommand`, and `RemoteGitService`'s
  parser/normalization are pure and unit-tested; `RemoteConnectionFeature`'s
  validation paths are covered by reducer tests. The live SSH path requires a
  reachable host and is verified manually.
- **Guards.** Reveal-in-Finder, Open-in-editor, and worktree create/remove are
  hidden *and* no-op'd at the reducer for remote projects, so keyboard chords
  can't bypass the hidden menu items.

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
