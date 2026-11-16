# Environment

The environment domain is the contract that keeps a Debug build and a Release build apart on one machine: the build channel, the directories and the IPC socket that follow from it, the names of all environment variables, the environment of a Pane, and the way the app starts background commands.

## Scope and ownership

This page owns:

- The build channel and each resource that the channel names.
- The catalog of environment variable names (`CodansEnvironment.Key`).
- The resolution of the IPC socket path, in the app and in the CLI.
- The assembly of the environment that a Pane shell starts with.
- The launch mode of background commands (`CommandLaunch`): direct, or through the login shell.

Neighbor topics:

- CLI verbs, exit codes, and the `current` pronoun: [CLI](cli.md).
- zmx daemons, sessions, and the contents of the runtime root: [Terminal runtime](terminal-runtime.md).
- The shell that a Pane runs and its integration: [Pane shell integration](pane-shell-integration.md).
- The contents of the environment that `gh` and `glab` get: [Git Platform](git-platform.md).
- The Workspace variables of a Pane: [Workspace](workspace.md).
- Stores and file formats in the config and state roots: [Architecture › Persistence](../architecture.md#persistence).

## Build channel

`BuildChannel.current` is `development` in a Debug build and `release` in a Release build. Its `slug` names each channel-scoped resource:

| Resource | Debug | Release |
|---|---|---|
| Config root | `~/.codans-dev/config/` | `~/.codans/config/` |
| State root | `~/.codans-dev/state/` | `~/.codans/state/` |
| Runtime root (`ZMX_DIR`) | `~/.codans-dev/run/` | `~/.codans/run/` |
| Cache root | `~/Library/Caches/codans-dev/` | `~/Library/Caches/codans/` |
| IPC socket | `/tmp/codans-dev-<uid>.sock` | `/tmp/codans-<uid>.sock` |
| CLI name | `codans-dev` | `codans` |
| CLI in the bundle | `Contents/Resources/bin/codans-dev` | `Contents/Resources/bin/codans` |
| Installed CLI link | `/usr/local/bin/codans-dev` | `/usr/local/bin/codans` |

Invariants:

- The channel is a compile-time constant, not a property of the bundle. The CLI links the same `CodansCore`, so a Debug CLI and a Debug app compute the same paths. `Bundle.main` would give the CLI a different answer, because the bundle of the CLI is the CLI.
- Derive each new channel-scoped resource from `BuildChannel.current`. Do not add a `#if DEBUG` that changes a path or a name.
- All Debug builds share the `codans-dev` resources, also builds from different branches or worktrees. To isolate one instance, set the directory and socket variables in [Overrides](#overrides).
- The CLI uses its channel name in help text, in error hints, and as `clientBinary` in the handshake.
- The file name of the CLI in the bundle comes from the `CODANS_CLI_NAME` build setting in `apps/mac/Project.swift`. `apps/mac/scripts/embed-codans.sh` writes that name, and `CLIBundleLocator` looks for `CLIInvocation.commandName`. The build setting must be equal to `BuildChannel.slug`. No check enforces this. If the two differ, `CLIBundleLocator` does not find the bundled binary.
- The config root holds files that the user can edit. The state root holds files that only the app writes. The cache root holds data that the app can fetch again. The runtime root holds the zmx daemon sockets, snapshots, and logs.
- Do not put a socket in the cache root. Cache cleaners delete `~/Library/Caches/<slug>` as a whole. The daemons then continue to run but cannot be reached, and the next attach creates a new session in place of the old one. See [Cache cleaner wiped zmx sockets](../lessons-learned/2026-10-20-cache-cleaner-wiped-zmx-sockets.md). At launch, `SessionReaper.migrateLegacySocketDirectory` moves the sockets of live daemons from the cache root to the runtime root.
- Keep the runtime root path short. `<root>/<pane UUID>` must fit in the 104 bytes of an AF_UNIX socket path.

### What the channel does not separate

- `~/.codans/` is the user-level root in both channels. User content in it, for example `workflows/` and the worktree checkouts in `repos/`, is the same for a Debug build and a Release build.
- Both builds have the bundle id `com.gumpw.codans`. Each system resource that the bundle id addresses is common to the two builds: `UserDefaults.standard` and the system notifications.
- The app does not register the `codans://` URL scheme. The app parses a `codans://focus` link from the payload of its own notification, so the link does not go through LaunchServices.
- Because `UserDefaults` is common, a Debug build must not write state that the installed app reads. `UpdatesEnvironment.isEnabled` is `true` only in the release channel: a Debug build does not start Sparkle, and `UpdatesClient` does nothing.
- A Debug build does not start Sentry. `CrashReporting.bootstrap` has its own `#if DEBUG`.

## Socket resolution

`BuildChannel.socketPath(uid:)` is the only place that spells the socket path. Two resolvers use it, and their rules are different on purpose.

**App (`SocketPaths.resolve`)**, for the socket that the app binds and gives to its Panes:

1. `$CODANS_SOCKET_PATH`, if it is set and is not the default socket of the other channel.
2. The default socket of this channel.

The app ignores the default socket of the other channel because that value is inherited, not an override. An app that starts from a Pane of the other build gets the socket of its host in its environment. If the app used that value, the bind would fail with `alreadyInUse`, and the app would give the wrong socket to its own Panes.

**CLI (`SocketDiscovery.resolve`)**:

1. The `--socket` flag. It always wins. Use it to drive one channel from a Pane of the other channel.
2. `$CODANS_SOCKET_PATH`, with one exception. If the value is the default socket of the other channel, the Pane belongs to the other build:
   - `codans` (release) in a development Pane refuses. The command exits with `CLIExitCode.wrongChannel` (15) and a hint to use `codans-dev`. A command in a development Pane must not reach the release app by accident.
   - `codans-dev` (development) in a release Pane ignores the value and uses the development socket. A developer usually runs `codans-dev` from a release Pane.
3. The default socket of this channel.

Each other value of `$CODANS_SOCKET_PATH` is a custom socket. Both channels use it.

Invariants:

- The name of the CLI is its channel. `$CODANS_SOCKET_PATH` selects a target only in that channel.
- `SocketDiscovery.resolve` reads the environment in the function body. A resolver that gets an optional override from its caller must not read the environment through a default argument: a caller that passes `nil` replaces the default, and the resolver then skips the environment.
- `codans doctor` (`codans-dev doctor`) does not exit on the refusal. It reports `socketStatus wrong-channel` with the hint. The text output shows the client name, the channel, and the resolved socket. The `--json` output also has `socketFromEnvironment`. Start with this command when a different app answers a command.

The incident behind these rules: [Dev pane commands answered by release app](../lessons-learned/2026-09-05-dev-pane-commands-answered-by-release-app.md).

## Pane environment

`PaneEnvironment` is the only code that builds the environment of a Pane shell. All surfaces use it, in this order:

1. `PaneEnvironment.processBase` starts from the environment of the app process.
2. It removes `TERM`, `TERMCAP`, `TERMINFO`, `COLORTERM`, `TERM_PROGRAM`, and `TERM_PROGRAM_VERSION`, so that the values that libghostty sets for the PTY apply. An app that starts from `make` or an IDE has `TERM=dumb`.
3. It adds the `envVars` of the Project from Settings (`HierarchyManager.resolvedEnv` supplies them).
4. It writes `CODANS_SOCKET_PATH`, `CODANS_CLI`, `TERM_PROGRAM`, and `TERM_PROGRAM_VERSION`, and puts the `bin/` directory of the bundle first on `PATH`. `PATH` contains that directory only one time.
5. `HierarchyManager.injectingBuiltins` writes `CODANS_WORKTREE_PATH` and `CODANS_ROOT_PATH`. In a Workspace it also writes the Workspace variables, and it removes them in all other Panes.
6. `PaneEnvironment.forSurface` writes `ZMX_DIR` (the runtime root), an empty `ZMX_SESSION`, and `CODANS_PANE_ID`.

Invariants:

- Steps 4 to 6 come after the Project `envVars`. A Project variable with the same name, also a `PATH` that the Project sets, cannot replace a product variable.
- `ZMX_SESSION` is empty in each Pane. An app that starts in a zmx Pane inherits the session name of its parent, and `zmx attach` then tries to switch to a session in a different `ZMX_DIR` and fails.
- The app writes only `CODANS_PANE_ID` as a hierarchy id. The id of a Pane does not change. The Tab, Worktree, and Project of a Pane change when the Pane moves, so the server finds them from the calling Pane. The CLI also reads `CODANS_PROJECT_ID`, `CODANS_WORKTREE_ID`, `CODANS_TAB_ID`, and `CODANS_TAG_ID` for `current`, but only a caller that exports them sets them. See [CLI](cli.md).
- Register each new variable in `CodansEnvironment.Key` first. Typed holders (`BuiltinEnvVar`, `TermProgramEnv`, `CLIBundleLocator.EnvKey`) take their names from it.

The incident that made all spawn paths use one builder: [CLI panes lacked project env and current context](../lessons-learned/2026-09-10-cli-panes-lacked-project-env-and-current-context.md).

### The CLI in a Pane

A command in a Pane must reach the CLI of the app that started the Pane.

- The channel name makes this possible. `PATH` order cannot: the Pane shell is a login shell, and `path_helper` in `/etc/zprofile` moves the system directories, `/usr/local/bin` included, in front of the directory that the app adds. A name that only one build has is found at any position. If it is not found, the result is `command not found`, not a command to the other app.
- `CODANS_CLI` is the absolute path of the bundled CLI. A script that must be sure of the binary uses `"$CODANS_CLI"`.
- `CLIInvocation.command` spells the CLI in commands that the app writes (the handoff kickoff line). It writes the short name when `/usr/local/bin` has no entry of that name, or when the entry resolves to the bundled binary. It writes the quoted absolute path of the bundled binary when the entry points to a different file or is a dangling link.
- `CLIInvocation.command` examines only `/usr/local/bin`. It does not find a binary of the same name in a different `PATH` directory.
- The installer (`CLIInstallerClient`) replaces a link that points into the `Resources/bin/` of a different app bundle, or to a bundled binary that does not exist.

## Background command launch

Feature modules start subprocesses through the shared `CommandRunner`. Each call selects a `CommandLaunch`:

| Mode | Behavior |
|---|---|
| `.direct` | Starts the executable with the environment that the caller gives. This is the default of `run`. |
| `.loginShell` | Starts the executable through the login shell of the user (`LoginShellLaunch`). |
| `.directThenLoginShell` | Starts the executable directly. If the run reports a missing command, the runner runs it one more time through the login shell. |

An app that the Dock or Finder starts has the launchd `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`). A program that git starts, for example a credential helper from Homebrew, is not on that `PATH`. The login shell supplies the `PATH` that a command in a Pane has. Each login-shell launch pays for one shell start and one run of the rc of the user. The cost depends on that rc. Thus only commands that need the user `PATH` use `.loginShell`, and frequent local commands use `.directThenLoginShell`.

| Command | Mode | Reason |
|---|---|---|
| git that contacts a remote (`GitLaunch.mode`): `clone`, `fetch`, `push`, `pull`, `ls-remote`, and `remote show` without `-n`, `remote update`, `remote prune` | `.loginShell` | git starts credential, LFS, and ssh helpers from the user `PATH` |
| `gh`, `glab` (`GitHubGitPlatform`, `GitLabGitPlatform`) | `.loginShell` | Same. `CLIExecutableResolver` resolves the executable to an absolute path first |
| All other local git, also `git --version` in `GitEnvironmentProbe` | `.directThenLoginShell` | Status and diff refreshes run often |
| The bundled `wt` (`GitWorktreeShell.launch`) | `.directThenLoginShell` | Same |
| Lookup of `gh` and `glab` (`/usr/bin/which`), lookup of agent CLIs (`<login shell> -i -c 'command -v …'` in `AgentInstallationStore`) | `.loginShell` | The lookup uses the same shell and `PATH` as the later command |
| Worktree setup script (`/bin/bash -lc`) | `.direct` | The script starts its own login shell and gets the environment of the app |
| Workflow command step (`/bin/sh -c`) | `.direct` | The caller selects the shell |
| `ssh`, also remote git | `.direct` | The remote login shell sets the remote environment. The local `ssh` needs the environment of the app (`SSH_AUTH_SOCK`) |

Terminals are not in this table. libghostty starts the shell of a Pane as a login shell.

### Login-shell launch

One launch is:

```
/bin/sh -c 'exec 3>&1 4>&2 >/dev/null 2>&1; exec "$0" "$@"' \
  <shell> -l -c '<script>' -- <cwd> KEY=VALUE… <executable> <arguments…>
```

The script saves and clears the positional parameters, sources the rc, enters `<cwd>`, and then runs `exec /usr/bin/env -i "PATH=$PATH" KEY=VALUE… <executable> <arguments…>` with fds 3 and 4 moved back to 1 and 2.

Contract:

- **Shell.** `LoginShell.current()` reads the login shell from the user database on each launch, not `$SHELL`. zsh, bash, and fish are supported. Each other shell becomes `/bin/zsh`. A change of the shell or of its configuration applies to the next command.
- **rc.** `-l` reads the profile files. The script sources `${ZDOTDIR:-$HOME}/.zshrc` for zsh and `$HOME/.bashrc` for bash. For fish the script sources nothing, because fish loads `config.fish` and `conf.d` before each `-c` script.
- **Output.** The outer `/bin/sh` moves the captured stdout and stderr to fds 3 and 4 before the login shell starts. Output from the profile, the rc, or the fish configuration does not reach the caller. The rc does not get fds 3 and 4, so a daemon that the rc starts cannot hold the pipes open.
- **Environment.** The command gets exactly the environment of the caller, with only `PATH` from the login shell. A variable that the rc exports does not reach the command. Thus the environment rules of each caller stay true: the keys that `GitProcessEnv` removes, `LC_ALL`, `GIT_TERMINAL_PROMPT=0`, and the token variables that `gh` and `glab` do not get.
- **Arguments.** The rc cannot see or change the command, because the positional parameters are empty while the rc runs. The script is one line, so an alias from the rc cannot change it.
- **Working directory.** The process starts in `/`. The script enters the directory after the rc. If the script cannot enter the directory, the exit status is 125 (`LoginShellLaunch.directoryFailureStatus`): the command did not start.
- **Process.** `/bin/sh` execs the login shell, and the login shell execs the command, so the pid stays the same.
- **Precheck.** If the executable does not exist, the result is `binary not found` and no shell starts. A path that contains `=` is an error, because `env` reads it as an assignment.

### Runner rules

- **Missing command.** A run reports a missing command when the exit code is 127, or when the exit code is not zero and stderr contains `command not found` (`LoginShellLaunch.reportsMissingCommand`). git gives this text for a helper that it starts through a shell. git does not give it for a helper that it executes directly (`cannot run …: No such file or directory`), and such a run does not get the second attempt.
- **Retry.** `.directThenLoginShell` makes at most two attempts. Each attempt has the full timeout. A cancelled caller gets no second attempt. A streamed command passes the output of both attempts to the caller.
- **Stop.** On timeout or cancel, the runner sends SIGTERM to the process group, and SIGKILL one second later. The group includes the commands of the rc and the helpers that git started.
- **Concurrency.** `FoundationCommandRunner` runs at most six one-shot commands at the same time. Streamed commands (`runStream`) are not in this limit.
- **Working directory of the caller.** A `cwd` that is not a file URL gives `spawnFailed`. The runner does not start a process for it.
- **Timeouts.** `GitWorktreeCLI`: 30 minutes for `clone`, 60 seconds for other commands. `GitWorktreeClient.StreamTimeouts`: 30 minutes for a clone, 20 minutes for `wt sw`, 60 minutes for a setup script.

### git environment

Each git caller supplies the environment of git, because the login-shell launch adds only `PATH`:

- `GitProcessEnv.build` (`LiveGitService`, `GitEnvironmentProbe`): only `PATH` and `HOME` from the app, and `LC_ALL=C.UTF-8`.
- `GitProcessEnv.inheriting` (`GitWorktreeShell`, `GitWorktreeCLI`, the bundled `wt`): the environment of the app without any `GIT_*` variable, and `LC_ALL=C.UTF-8` and `GIT_TERMINAL_PROMPT=0`. `ssh` keeps `SSH_AUTH_SOCK`, and a proxy keeps its variables. A missing credential makes the command fail, not wait for a prompt.

## Overrides

`CodansEnvironment.Key` is the full list, with the writer and the reader of each variable. These variables change where an instance keeps its data:

| Variable | Effect |
|---|---|
| `CODANS_CONFIG_DIR` | Moves the config root. If `CODANS_STATE_DIR` is not set, the state root is the same directory. |
| `CODANS_STATE_DIR` | Moves the state root. It has priority over `CODANS_CONFIG_DIR`. |
| `CODANS_RUNTIME_DIR` | Moves the runtime root. |
| `CODANS_CACHE_DIR` | Moves the cache root. If `CODANS_RUNTIME_DIR` is not set, the runtime root is `<cache>/run`. |
| `CODANS_WORKFLOWS_DIR` | Moves the user workflow directory (`~/.codans/workflows`). |
| `CODANS_SOCKET_PATH` | Sets the IPC socket. The app sets it in each Pane. |
| `CODANS_CLI_BINARY` | Gives `CLIBundleLocator` a CLI binary outside the app bundle. |
| `CODANS_GHOSTTY_RESOURCES` | Gives a different root for the libghostty resources when the bundle has none. |
| `CODANS_DISABLE_ACTION_ROUTING`, `CODANS_DISABLE_THEME_DEV_FALLBACK` | Diagnostic and test switches. The value `1` sets them. |
| `CODANS_SURFACE_RECLAIM_SECONDS` | Sets the time before the app reclaims an idle surface. A value that is not a positive number keeps the default. |

An isolated instance needs a private config root, cache or runtime root, and socket. An instance that has only some of them uses the catalog, the daemons, or the socket of the `codans-dev` instance of the user.

`ZMX_*` and `GHOSTTY_*` names belong to external tools. The catalog records how codans uses them.

## Implementation map

- `apps/mac/CodansCore/Environment/BuildChannel.swift`: `BuildChannel`.
- `apps/mac/CodansCore/Environment/CodansEnvironment.swift`: `CodansEnvironment.Key`, `inheritedTerminalKeysToStrip`.
- `apps/mac/CodansCore/AppDirectories.swift`: `AppDirectories` (all roots and their overrides).
- `apps/mac/CodansCore/CLI/CLIInvocation.swift`, `apps/mac/CodansCore/CLI/CLIBundleLocator.swift`: the CLI name and the bundled binary.
- `apps/mac/CodansKit/Transport/SocketDiscovery.swift`: `SocketDiscovery.resolve`, `ForeignPaneRefusal`.
- `apps/mac/codans-cli/Commands/CommonCommandSupport.swift`: the refusal as exit code 15. `apps/mac/codans-cli/Commands/AppCommands.swift`: `DoctorCommand`.
- `apps/mac/codans/App/Features/Socket/SocketPaths.swift`: `SocketPaths.resolve`.
- `apps/mac/codans/Runtime/PaneEnvironment.swift`: `processBase`, `forSurface`. `apps/mac/codans/Runtime/HierarchyManager.swift`: `resolvedEnv`, `injectingBuiltins`. `apps/mac/codans/Runtime/TerminalEngine.swift`: `ensureSurface` applies `forSurface`.
- `apps/mac/codans/Process/CommandRunner.swift`: `CommandRunner`, `CommandLaunch`, `FoundationCommandRunner`.
- `apps/mac/codans/Process/LoginShellLaunch.swift`: `LoginShell`, `LoginShellLaunch`, `ProcessLaunch`.
- `apps/mac/codans/Git/GitLaunch.swift`: `GitLaunch.mode(for:)`. `apps/mac/codans/Git/GitProcessEnv.swift`: `GitProcessEnv`.
- `apps/mac/codans/App/Clients/UpdatesEnvironment.swift`, `apps/mac/codans/App/Telemetry/CrashReporting.swift`: the Debug gates.
- `apps/mac/codans/App/Clients/CLIInstallerClient.swift`: the installed link.

Tests:

- `apps/mac/CodansCoreTests/Environment/`: `BuildChannelTests`, `CodansEnvironmentTests` (the typed holders must agree with the catalog). `apps/mac/CodansCoreTests/`: `AppDirectoriesConfigOverrideTests`, `AppDirectoriesCacheOverrideTests`, `AppDirectoriesRuntimeDirectoryTests`. `apps/mac/CodansCoreTests/CLI/CLIInvocationTests.swift`.
- `apps/mac/CodansKitTests/SocketDiscoveryTests.swift`.
- `apps/mac/codans/Tests/Socket/SocketPathsTests.swift`, `apps/mac/codans/Tests/PaneEnvironmentTests.swift`, `apps/mac/codans/Tests/HierarchyManagerResolvedEnvTests.swift`.
- `apps/mac/codans/Tests/ProcessTests/`: `LoginShellLaunchTests`, `LoginShellRunnerIntegrationTests` (real zsh and bash in a temporary `HOME`), `LoginShellLookupTests`.
- `apps/mac/codans/Tests/GitTests/`: `GitLaunchTests.swift` (`GitLaunchTests`, `LiveGitServiceLaunchTests`), `GitProcessEnvTests`. `apps/mac/codans/Tests/GitWorktreeCLITests.swift`.
