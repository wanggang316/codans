# Design Doc: Remote SSH "Server" Projects

**Status:** Implemented (discovery + terminal); worktree create/remove deferred
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

**Non-Goals**

- In-app credential management. Auth is `~/.ssh/config` + agent, full stop.
- Remote worktree **create / remove** through the UI (this pass). The streaming
  create path is coupled to the bundled local `wt` script; the SSH git service
  already exposes `addWorktree` / `removeWorktree`, but the UI wiring is a
  follow-up. Discovery, browsing, and terminals are complete.
- FSEvents-style *push* change detection for remote worktrees. Remote git
  status (`+N −M` chip, dirty flag, PR badge, branch switcher, diff inspector)
  runs over the SSH-routed `GitService` (see below), refreshed by polling and
  shell-integration markers rather than local file watchers.

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
`addWorktree`/`removeWorktree`, plus `expandRemotePath` / `remoteHomeDirectory` /
`directoryExists` for connect-time validation.

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
- **Deferred create/remove reads as "broken."** Mitigation: the affordances are
  hidden for remote (not left to fail), and this doc names the follow-up with the
  exact seams (`RemoteGitService.addWorktree` / `removeWorktree`).
- **Remote status is poll-based.** The FS watchers that make local chips
  instant never fire for remote paths; remote rows refresh on a ~20 s
  visible-row poll plus in-pane shell-integration markers. A burst of remote
  edits outside a codans pane can lag by up to one poll interval — accepted;
  the ControlMaster keeps each tick cheap.
