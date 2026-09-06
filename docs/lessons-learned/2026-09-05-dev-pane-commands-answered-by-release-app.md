# Lessons Learned: commands typed in a development pane were answered by the release app

**Status:** Resolved
**Date:** 2026-09-05
**Area:** Environment / build-channel isolation (`BuildChannel`, `PaneEnvironment`, `SocketDiscovery`, `CLIInvocation`, `embed-codans.sh`)
**Fix:** branch `feat/quick-agents` — `build(cli): embed the CLI under its build-channel name`, `feat(cli): name the CLI after its build channel`, `feat(cli): keep each CLI inside its own build channel`, `fix(handoff): write the short command name when nothing shadows it`

## Summary

Inside a pane of the Debug (development) app, `codans doctor`, `codans tree`
and a hand-off started from the pane's menu were all served by the *release*
app in `/Applications`: doctor printed the release socket, `tree` reported "no
current project context", and the hand-off once launched a fresh release app.
The development app has its own socket, config root, zmx directory and its own
bundled CLI, so this looked impossible. It took three attempts to fix because
each one patched a symptom instead of the naming gap underneath.

## Root cause

The development build had isolated its **data** and its **process** but not
the **name** `codans`:

1. On the machine, `codans` on PATH resolved to `/usr/local/bin/codans` (and
   `/opt/homebrew/bin/codans`), both symlinks into `/Applications/Codans.app`.
   The development bundle carried its CLI as `Contents/Resources/bin/codans`
   too — the same file name — and was reachable only through an installed
   `codans-dev` symlink, which did not exist. Agents follow the skill, which
   says `codans`, so every command they typed went to the release binary.
2. That installed release CLI (0.5.0) had an older bug: the environment lookup
   for `CODANS_SOCKET_PATH` lived in a Swift default argument, and the caller
   passed an explicit `nil` that replaced it. So even the correct socket the
   development app exported into the pane was never read.
3. The interim fix — prepend the bundle's `bin/` to every pane's PATH — cannot
   work on macOS. Panes run a login shell; `/etc/zprofile` runs `path_helper`,
   which rebuilds PATH with the `/etc/paths` directories first and appends the
   inherited entries after them. `/usr/local/bin` therefore always precedes the
   injected directory:

   ```
   env PATH=/tmp/zzz-first:$PATH /bin/zsh -l -c 'echo $PATH'
   # /usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:...:/tmp/zzz-first
   ```

## Fix

Treat the two builds as two applications and let the *name* carry the channel:

- The Debug bundle embeds its CLI as `bin/codans-dev` (per-configuration
  `CODANS_CLI_NAME` build setting, mirrored by `BuildChannel.slug`); the CLI
  calls itself `codans-dev` in help, hints and the handshake. A unique name
  needs no PATH priority: with no competitor in the system directories it
  resolves wherever `path_helper` puts the entry, and when it is absent the
  failure is "command not found", not a silent hit on another app.
- `SocketDiscovery.resolve` enforces "the name is the channel": the release
  `codans` refuses to act on a pane whose `CODANS_SOCKET_PATH` is the
  development socket (exit 15, `wrong-channel`, hint names `codans-dev`); the
  development `codans-dev` run from a release pane ignores the inherited path
  and dials its own socket. `--socket` still crosses on purpose.
- The hand-off kickoff line writes `codans-dev` when nothing in
  `/usr/local/bin` shadows the name, otherwise the bundled binary's absolute
  path. The installer recognises a symlink into another bundle (or a
  dangling one left by the rename) as stale and replaces it.

## What still cannot be fixed from the development side

The release CLI already installed on a developer's machine predates all of
this. It ignores `CODANS_SOCKET_PATH` and has no channel guard, so an agent
that types a bare `codans` inside a development pane still reaches the
release socket until a release with these changes is installed. Everything
codans itself writes into a development pane now says `codans-dev`.

## Recurrence checks

- `ls -la /usr/local/bin/codans*` — which builds are installed and where they
  point. A Debug bundle must contain `Contents/Resources/bin/codans-dev`.
- In a pane: `basename "$CODANS_CLI"` is the command that belongs to the pane;
  `codans doctor` / `codans-dev doctor` print the client name, channel and the
  socket that would be dialled.
- Any "commands go to the other app" report: first ask which *name* the shell
  resolved (`type codans`), not which socket the app injected.

## Pitfalls to remember

- **PATH order is not a contract in a login shell on macOS.** `path_helper`
  reorders it. Prefer a unique name over a prioritised directory.
- **Do not read environment variables in Swift default arguments.** A caller
  forwarding its own optional replaces the default with `nil` and the lookup
  silently never runs.
- **Isolation has three layers — process, data, name.** Checking the first
  two and declaring the builds isolated is how this hid for so long.
