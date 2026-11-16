# 0012. The build channel separates Debug and Release, and the CLI name is the channel

Status: Accepted

## Context

A developer runs a Debug build next to the installed Release build, often from
a Pane of the Release app. The two builds must not share a catalog, session
daemons, or an IPC socket.

A command typed in a development Pane reached the Release app. Both CLIs had
the name `codans`, and the app put its own `bin/` directory first on `PATH`.
The Pane shell is a login shell, and `path_helper` moves `/usr/local/bin` in
front of that directory, so the installed Release CLI was found first. See
[Dev pane commands answered by release app](../lessons-learned/2026-09-05-dev-pane-commands-answered-by-release-app.md).

## Decision

1. **One bundle id.** Both builds keep the bundle id `com.gumpw.codans`.
   Separate bundle ids split the notification identity and the update state,
   and a Debug build then does not behave as the shipped app does.
2. **A compile-time channel.** `BuildChannel` in `CodansCore` is `development`
   or `release`. Its slug (`codans-dev` or `codans`) names each resource that
   the builds must not share: the config, state, runtime, and cache roots, the
   IPC socket, and the CLI. The channel is a constant of the build, not a
   property of the bundle, so the CLI and the app of one build compute the
   same names.
3. **The CLI name is the channel.** The Debug CLI is `codans-dev` and the
   Release CLI is `codans`. A name that only one build has is found at any
   `PATH` position. If it is missing, the result is `command not found`, not a
   command to the other app.
4. **Socket resolution is not symmetric.** `CODANS_SOCKET_PATH` is an override
   and also a value that each Pane inherits. The app ignores the default
   socket of the other channel. `codans` in a development Pane refuses and
   exits with code 15. `codans-dev` in a release Pane uses the development
   socket. `--socket` always wins.

## Consequences

- `UserDefaults` and system notifications are common to the two builds. A
  Debug build must not write state that the installed app reads: it does not
  start the updater or crash reporting.
- All Debug builds share the `codans-dev` resources, also builds from
  different branches. An isolated instance needs a private config root, a
  private cache or runtime root, and a private socket.
- The `CODANS_CLI_NAME` build setting must be equal to the channel slug. No
  check enforces this.
- The two socket resolvers have different rules on purpose. Do not merge them.

Current behavior: [Environment](../domains/environment.md).
