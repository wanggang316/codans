# Environment

The environment domain keeps a Debug build and a Release build apart on one machine. It defines the build channel and the resources that follow from it, the names of all environment variables, the environment of a Pane, and how the app starts background commands.

## Scope and ownership

This page owns the build channel, the catalog of variable names (`CodansEnvironment.Key`), socket resolution in the app and the CLI, the assembly of the Pane environment, and the launch mode of background commands.

Neighbor topics:

- CLI verbs, exit codes, and the `current` pronoun: [CLI](cli.md).
- zmx daemons and the contents of the runtime root: [Terminal runtime](terminal-runtime.md).
- The Pane shell and its integration: [Pane shell integration](pane-shell-integration.md).
- The environment of `gh` and `glab`: [Git Platform](git-platform.md).
- The Workspace variables of a Pane: [Workspace](workspace.md).
- Stores and file formats in the config and state roots: [Architecture › Persistence](../architecture.md#persistence).

## Build channel

The channel is `development` in a Debug build and `release` in a Release build. It is a compile-time constant in `CodansCore`, not a property of the bundle, so the CLI and the app of one build compute the same names. The channel slug (`codans-dev` or `codans`) names every resource that must not be shared:

```
                     BuildChannel (slug: codans-dev | codans)
                                      |
     +-------------+-------------+----+---------+--------------+-------------+
     |             |             |              |              |             |
 config root   state root   runtime root    cache root     IPC socket    CLI name
 ~/.<slug>/    ~/.<slug>/   ~/.<slug>/run   ~/Library/     /tmp/<slug>-  codans-dev
 config/       state/       (ZMX_DIR)       Caches/<slug>  <uid>.sock    | codans
```

The roots have different roles: config holds files the user can edit, state holds files only the app writes, cache holds data the app can fetch again, and the runtime root holds the zmx daemon sockets, snapshots, and logs.

Rules:

- Derive each new channel-scoped resource from `BuildChannel.current`. Do not add a `#if DEBUG` that changes a path or a name.
- Do not put a socket in the cache root. Cache cleaners delete `~/Library/Caches/<slug>` as a whole; the daemons continue to run but cannot be reached, and the next attach creates a new session. See [Cache cleaner wiped zmx sockets](../lessons-learned/2026-10-20-cache-cleaner-wiped-zmx-sockets.md).
- Keep the runtime root path short. `<root>/<pane UUID>` must fit in the 104 bytes of an AF_UNIX socket path.
- The `CODANS_CLI_NAME` build setting, which names the CLI in the bundle, must be equal to the channel slug. No check enforces this. If they differ, the app does not find its bundled CLI.

### What the channel does not separate

- **Debug builds among themselves.** All Debug builds share the `codans-dev` resources, also builds from different branches or worktrees. An isolated instance needs a private config root, a private cache or runtime root, and a private socket. With only some of them, it uses the catalog, the daemons, or the socket of the developer's own `codans-dev` instance. `CodansEnvironment.Key` lists the override variables and what each one moves.
- **User content.** `~/.codans/` is the user-level root in both channels. `workflows/` and the worktree checkouts in `repos/` are the same for both builds.
- **Bundle-id resources.** Both builds have the bundle id `com.gumpw.codans`, so `UserDefaults.standard` and system notifications are common. A Debug build must not write state that the installed app reads: it does not start Sparkle or Sentry.

## Socket resolution

`BuildChannel.socketPath(uid:)` is the only place that spells the socket path. Two resolvers use it, with different rules on purpose, because `CODANS_SOCKET_PATH` is both an override and a value that every Pane inherits:

```
 App (SocketPaths)                        CLI (SocketDiscovery)
 socket to bind and give to Panes         socket to connect to
 -------------------------------          ---------------------------------
                                          1. --socket flag (always wins)
 1. $CODANS_SOCKET_PATH                   2. $CODANS_SOCKET_PATH
    - other channel's default: ignore        - other channel's default:
      (inherited from a host Pane,             codans     -> refuse, exit 15
      not an override)                         codans-dev -> ignore it
    - any other value: use                   - any other value: use
 2. this channel's default                3. this channel's default
```

Why the rules differ:

- **App.** An app started from a Pane of the other build inherits its host's socket. If it used that value, the bind would fail with `alreadyInUse` and its Panes would get the wrong socket.
- **CLI.** The name of the CLI is its channel. `codans` in a development Pane refuses, so a command in a dev Pane cannot reach the release app by accident. `codans-dev` in a release Pane is the normal developer case, so it falls back to the dev socket.

A resolver that takes an optional override must read the environment in its body, not through a default argument: a caller that passes `nil` replaces the default and skips the environment.

`codans doctor` does not exit on the refusal. It reports `socketStatus wrong-channel`, the client name, the channel, and the resolved socket. Start with it when a different app answers a command. The incident behind these rules: [Dev pane commands answered by release app](../lessons-learned/2026-09-05-dev-pane-commands-answered-by-release-app.md).

## Pane environment

`PaneEnvironment` is the only builder of a Pane environment. Every surface uses it. Each layer writes over the one before it:

1. The environment of the app process, without the inherited terminal variables (`TERM`, `TERM_PROGRAM`, and related), so that the values libghostty sets for the PTY apply.
2. The Project `envVars` from Settings.
3. Product variables: `CODANS_SOCKET_PATH`, `CODANS_CLI`, `TERM_PROGRAM`, the bundle `bin/` first on `PATH`, `CODANS_WORKTREE_PATH`, `CODANS_ROOT_PATH`, and in a Workspace the Workspace variables.
4. Surface variables: `ZMX_DIR`, an empty `ZMX_SESSION`, and `CODANS_PANE_ID`.

Rules:

- Product and surface variables come after the Project `envVars`. A Project cannot replace them, also not `PATH`, because the CLI, the socket, and zmx depend on them.
- `ZMX_SESSION` is empty in each Pane. Otherwise an app started in a zmx Pane inherits its parent's session name, and `zmx attach` fails across runtime roots.
- `CODANS_PANE_ID` is the only hierarchy id the app writes. A Pane id does not change; its Tab, Worktree, and Project change when it moves, so the server finds them from the calling Pane.
- Register each new variable in `CodansEnvironment.Key` first. Typed holders take their names from it.

All spawn paths use one builder because of [CLI panes lacked project env and current context](../lessons-learned/2026-09-10-cli-panes-lacked-project-env-and-current-context.md).

### The CLI in a Pane

A command in a Pane must reach the CLI of the app that started the Pane. The unique channel name makes this work; `PATH` order cannot, because the login shell's `path_helper` moves `/usr/local/bin` in front of the bundle directory. A name that only one build has is found at any position, and if it is missing the result is `command not found`, not a command to the other app. Scripts that must be sure of the binary use `"$CODANS_CLI"`, the absolute path of the bundled CLI.

## Background command launch

Feature modules start subprocesses only through the shared `CommandRunner`. Each call selects one launch mode:

| Mode | Behavior |
|---|---|
| `.direct` | Starts the executable with the environment the caller gives. |
| `.loginShell` | Starts the executable through the user's login shell. |
| `.directThenLoginShell` | Starts it directly; if the run reports a missing command, runs it once more through the login shell. |

An app started from the Dock or Finder has only the launchd `PATH`. Tools the user installed, for example a Homebrew credential helper that git starts, are not on it. The login shell supplies the `PATH` a Pane has, but each launch costs one shell start and one run of the user's rc. The principle:

- `.loginShell` for commands that start user tools: git that contacts a remote, `gh`, `glab`, and the lookups that find those tools.
- `.directThenLoginShell` for frequent local commands: status, diff, and other local git, and the bundled `wt`.
- `.direct` when something else already sets the environment: setup scripts and workflow steps start their own shell, and `ssh` needs the app's `SSH_AUTH_SOCK` while the remote shell sets the remote side.

Terminals are not background commands. libghostty starts the Pane shell as a login shell.

### Login-shell contract

- **Environment.** The command gets exactly the caller's environment plus only `PATH` from the login shell. A variable the rc exports does not reach the command. So each caller's environment rules stay true, for example the git variables that the git callers remove and `GIT_TERMINAL_PROMPT=0`. Each git caller must therefore set the git environment itself.
- **Shell.** The shell comes from the user database on each launch, not `$SHELL`. zsh, bash, and fish are supported; any other shell becomes `/bin/zsh`. The profile files and the interactive rc are loaded.
- **Isolation from the rc.** Output from the profile and the rc does not reach the caller, and the rc does not get the caller's pipes, so a daemon it starts cannot hold them open. The rc cannot see or change the command.
- **Failure.** A missing executable fails before any shell starts. If the shell cannot enter the working directory, the exit status is 125 and the command did not start.
- **Process.** The pid stays the same through the chain, so timeout and cancel stop the command and every helper in its process group.

## Implementation shape

`CodansCore/Environment/` holds the channel and the variable catalog; `AppDirectories` derives every root and applies the overrides. Socket resolution has one function on each side: `SocketDiscovery` in `CodansKit` for the CLI and `SocketPaths` in the app. `Runtime/PaneEnvironment.swift` plus `HierarchyManager` build the Pane environment. `Process/` holds `CommandRunner` and the login-shell launch; `Git/GitLaunch.swift` selects the mode for each git command. Each of these has a unit test suite, and the login-shell launch also has integration tests that run real zsh and bash in a temporary `HOME`.
