# Remote Projects

A Remote Project is a Project whose root is on another machine, a Host, that codans reaches over SSH. The user picks a Host and a path. From then on the Project has Worktrees, Tabs, and Panes like a local Project: git runs on the Host, and each Pane runs its shell on the Host. This page covers the model, how git and the Panes reach the Host, what happens when the connection drops, and which features a Remote Project has.

Availability: Available. Some features of local Projects are not present for a Remote Project; see [Feature availability](#feature-availability).

## Scope and ownership

This page owns the Host and Remote Project model, the Open Remote Project and Edit Remote Project sheets, git over SSH, the remote Pane command, and the shared SSH connection.

| Topic | Owner |
|---|---|
| Host rows and the Host level of the sidebar | [Main Window](main-window.md) |
| The Hosts pane in Settings and its storage | [Settings](settings.md) |
| How the app launches local commands and `ssh` | [Environment](environment.md) |
| The terminfo fallback of a remote Pane | [Pane shell integration](pane-shell-integration.md) |
| The plain Worktree lifecycle | [Worktree](worktree.md) |
| Opening a remote Worktree in an SSH editor | [Editor integration](editor-integration.md) |
| Pull Request data | [Git Platform](git-platform.md) |

Related records: [ADR 0002](../adrs/0002-sidebar-outline-with-host-level.md) (Host level of the sidebar), [ADR 0003](../adrs/0003-hosts-are-managed-records.md) (Hosts are managed records), [ADR 0006](../adrs/0006-project-identity-is-host-and-path.md) (Project identity is Host and path). The terms Host, Remote Project, This Mac, and Project identity are in the [glossary](../glossary.md).

## Model

- A **Host** is a record in `catalog.hosts`: address, optional username, port, name, and icon. This Mac has no record.
- A **Remote Project** is a Project with a `hostID`. The catalog stores only the ID. At load, the app resolves it to `Project.remoteHost`, a `RemoteHost` endpoint (alias, username, port) that runtime code reads without a lookup. `ProjectKind` is `.remote` when `remoteHost` is set.
- `rootPath`, `gitRoot`, and each `Worktree.path` of a Remote Project are **paths on the Host**, stored as entered strings. There is no separate remote hierarchy: every consumer of `Project` and `Worktree` works on the same types.
- **Identity** is `(hostID, rootPath)` (ADR 0006). A local Project and a Remote Project can have the same path.
- `remote-hosts.json` beside the catalog mirrors Project ID to endpoint on every save. At load, it restores the connection of a Remote Project whose host fields an older build dropped. It is a repair copy, not a second source of truth.

### Authentication

codans never asks for, stores, or sends a password or a key. All SSH authentication comes from the user's `~/.ssh/config` and `ssh-agent`. The sheet says so in its footnote. A Host field can be an SSH config alias.

- Background calls (git, probes, skill and history reads) use `BatchMode=yes` and a connect timeout: they fail at once and do not wait on a prompt.
- A Pane does not use `BatchMode`, so the first connection can show a host-key or password prompt in the terminal.

## Open and edit a Remote Project

"Open Remote Project…" in the Add Project menu, and "Open Remote Project on This Host…" on a Host row, open one sheet. The user picks a Host from the list or "New Host…", and enters a path. On Connect, the sheet checks in this order:

1. The Host answers (`ssh … true`). Else: "Cannot reach …".
2. The path exists on the Host. The Host expands `~` and returns the absolute path.
3. git: the Host returns the git root, or none (a folder Project).

Then:

- "New Host…" with fields equal to an existing Host uses that Host. Else it adds a Host record.
- If the Host and the resolved path already are a Project, the sheet closes and selects that Project. Nothing is added.
- Else a new Project is added, named by the last path component, and reconciled.

"Edit Remote Project…" in the menu of a Remote Project uses the same sheet and the same checks. It changes the Host choice and the path, never the fields of a Host (Settings owns them). A Host and path equal to another Project is an error in the sheet. A changed path closes the Panes of the Project and sets new Worktree rows. A change of the Host only keeps the rows.

## Git on the Host

Every git call for a Remote Project runs on the Host as `ssh <options> host '<login shell> -c "cd <dir> && exec git …"'`. A login shell is necessary so that a `git` in `/opt/homebrew/bin` or a similar directory resolves. The output parsers do not know the transport: status, the diff chip, the branch switcher, and the `origin` URL for Pull Requests work the same for both kinds.

Routing rule: `GitRemoteRoute` gives each live git client one resolver, bound to the catalog. A caller that acts on a Project builds the location with `Project.gitURL(_:)`:

- On This Mac: a file URL. git runs locally.
- On a Host: `codans-host://<host-id>/<path>`. git runs on that Host.
- A plain path: runs on This Mac when a local Project owns it, else on the Remote Project that owns it (exact string match).

Rules:

- **Do not use the local file system on a remote path.** `FileManager`, `URL(fileURLWithPath:)` resolution, and the local symlink canonicalizer give wrong answers for a path on a Host. Gate local file system calls on `remoteHost == nil`. Remote paths compare after only a trailing-slash trim (`normalizeRemotePath`).
- A local command runner refuses a working directory that is not a file URL. An unresolved Host location gives an error, not a crash.
- Use `Project.gitURL(_:)` for each git call that acts on a Project. A plain path is ambiguous when two Hosts have the same path.

### Worktree discovery

Reconcile of a Remote Project runs on the Host, not through the local `wt`:

1. The Host git gives its form of the root. When it is different from the stored root (a symlinked path, or a different letter case), the Project takes the Host form, and rows with the same path merge, Tabs included. When another Project on the same Host already has that root, the root stays and discovery stops for this Project.
2. When `gitRoot` is not set, the Host is asked for it.
3. `git worktree list --porcelain` on the Host gives the rows. The merge into the catalog is the same as for a local Project. A failed listing changes nothing.

Before the reconcile, the health check marks the Project `.failed` with "Cannot reach <host>" or "<path> was not found on <host>". A sweep (launch, window focus, Refresh All) keeps a failed Project failed until the check has a result. Only Retry or a new Project shows `.loading`, so that the sidebar row does not change shape two times.

There are no file watchers for a Host. A visible remote Worktree row polls its status about every 20 seconds over the shared connection. Edits made outside a codans Pane can show late by up to one poll interval.

## Remote Panes

A remote Pane does not run a local shell. libghostty starts this chain:

```
 This Mac                                          Host
 ------------------------------------------        ---------------------------------
 libghostty /bin/sh -c
  └─ zmx attach <pane UUID>   (local daemon)
      └─ reconnect loop (/bin/sh)
          └─ ssh -tt host ───── ControlMaster ───► login shell → /bin/sh script
                                    ▲                └─ zmx attach codans-<pane UUID>
 app: git / probes ─── ssh ─────────┘                    (if zmx is on the Host)
                                                          └─ "$SHELL" -il in the Worktree
```

- The **local zmx daemon** holds the reconnect loop. When the app quits, the daemon and the loop stay, and the next launch attaches again. Without a local zmx, the Pane runs the bare loop: reconnect works, quit persistence does not.
- A **zmx daemon on the Host**, when `zmx` is on the login `PATH`, holds the remote shell. The work in it survives a dropped connection. Without it, the Pane gets a new login shell in the Worktree after each reconnect, with a notice.
- The local working directory of the surface is the home directory. The remote `cd` sets the real directory.

### Connection drops

The loop measures how long each `ssh` run lived:

| Run | Exit | Result |
|---|---|---|
| 3 s or more | not 255 | The user's shell exited. The Pane closes, as a local Pane does. |
| 3 s or more | 255 (ssh connection error) | Connection dropped. Notice "Disconnected. Reconnecting…", then attach again. |
| less than 3 s | any | Failed start (auth, host key, no shell). Notice with the exit code, retry with backoff up to 15 s. |
| less than 3 s, after a drop | not 255 | The Host session ended while away. Notice, the Pane closes. |

Ctrl-C stops the loop. After each `ssh` run, the loop resets the terminal modes that a dropped program cannot turn off (mouse tracking, bracketed paste, alternate screen, keyboard modes). It does not clear the screen. A reattached Host zmx session sends back the modes its program still holds.

### Shared connection

All SSH traffic to one Host, git, probes, and Panes, goes through shared `ControlMaster` connections (`~/.ssh/codans-%C`, kept 10 minutes after the last client). This gives one authentication per Host.

- A guard serializes the creation of the master with a lock next to the control path. Without it, lines that start together each authenticate and keep private connections.
- sshd limits the sessions on one connection (`MaxSessions`). When a master is full, the line moves to the next of four shared masters per Host. When all four are full, it uses its own connection, and a Pane prints a notice.
- The guard never removes a socket, so a live master is never touched.

### macOS Host and the keychain

An SSH session on a macOS Host cannot read the login keychain, so git credential helpers, `gh`, and agent CLIs lose their tokens. When the keychain is locked for the SSH session, a Host zmx is present, and a user is logged in at the Host console, the connect script starts the Host zmx daemon in the GUI login session with `launchctl submit`. The shell then has the unlocked keychain. Else the Pane prints a locked-keychain notice.

Consequences: a keychain item that does not trust the calling binary shows its permission dialog on the display of the Host, and the command waits for it. The Pane reads the user's keychain items without the login password. To keep the SSH-session boundary, do not install `zmx` on the Host.

### Agent detection

The local foreground process of a remote Pane is always `ssh`. So the remote shell writes its tty to `~/.cache/codans/pane-ttys/<pane UUID>` on the Host, and one probe per Host per tick lists the foreground jobs of those ttys. The results go into the same pipeline as local samples (see [Agent state](agent-state.md)). A failed probe freezes the state of the Panes, so a short network failure does not release a bound agent.

## Feature availability

| Feature | Remote Project |
|---|---|
| Create a Worktree | Available. Runs `git worktree add` on the Host, next to the repository root (the local worktrees directory setting does not apply). "Fetch origin" fetches on the Host. git errors show in the pending row. |
| Remove a Worktree | Available. `git worktree remove` and branch cleanup run on the Host. The directory is not moved to a trash folder first, as it is on This Mac. |
| Copy ignored or untracked files on create | Not present. The toggles are not shown. |
| Setup script on create | Not present. Only the local `wt` create runs it. |
| Edit Remote Project | Available. |
| Pull Requests | Available. The `origin` URL comes from the Host; `gh` or `glab` runs on This Mac. |
| Diff viewer, branch switcher, status chip | Available, over SSH. |
| Open in Editor | Available for SSH-capable editors only; hidden when none is installed. See [Editor integration](editor-integration.md). |
| Reveal in Finder | Not present. |
| Skills in the New Agent dialog | Available. Read from the Host over SSH. |
| Skills in the Command Queue composer | Not present ("Skill suggestions are not available for remote projects"). |
| Workflows | Not present. Workflows run in local Worktrees only. |
| Handoff | Not present. The CLI returns `unsupported`. |
| Workspace membership | Not present. A Workspace takes Projects on This Mac only. See [Workspace](workspace.md). |

A Host row shows no connection state (ADR 0003). A failed Project row carries the reason.

## Traps

- The command line crosses three shell levels: libghostty's `/bin/sh -c`, the remote login shell, and the remote `/bin/sh -c`. Use `SSHCommand.shellQuote` at each level. Notice text contains no `'` for this reason.
- `pwd -P` keeps the typed letter case on APFS; `git worktree list` reports the on-disk case. The Host git, not `pwd`, decides the root.
- A login shell on the Host can print a banner before the output of a probe. The path probes of `RemoteGitService` read the last non-empty line.
- Changing only the Host of a Project keeps its open Panes on their current `ssh` command until they start again.

## Shape of the implementation

```
 CodansCore   HostRecord, RemoteHost, Catalog hosts and routing (no SSH knowledge)
 Process/     SSHCommand (options, quoting, shared master), RemoteGitService,
              RemoteReachabilityProbe, RemoteForegroundProbe
 Git/         GitRemoteRoute → LiveGitService and GitWorktreeClient pick local or SSH per call
 Runtime/     HierarchyManager (single writer of hosts and Projects), ProjectReconciler,
              TerminalEngine + RemoteSurfaceCommand (Pane command)
 App/         RemoteProjectFeature (sheet), sidebar guards, Hosts settings
```
