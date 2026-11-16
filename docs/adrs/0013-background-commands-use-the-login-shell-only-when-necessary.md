# 0013. Background commands use the login shell only when they need the user PATH

Status: Accepted

## Context

An app that the Dock or Finder starts has the launchd `PATH`
(`/usr/bin:/bin:/usr/sbin:/sbin`). Tools that the user installed are not on
it. git starts credential, LFS, and ssh helpers from `PATH`, so a remote git
command failed for a user with a Homebrew helper, and `gh` and `glab` were not
found.

The login shell of the user supplies the `PATH` that a Pane has. A launch
through it costs one shell start and one run of the user's rc. That cost
depends on the rc. Status and diff refreshes run often.

## Decision

1. Each `CommandRunner` call selects a launch mode: `.direct`, `.loginShell`,
   or `.directThenLoginShell`.
2. Commands that start user tools use `.loginShell`: git that contacts a
   remote, `gh`, `glab`, and the lookups that find those tools.
3. Frequent local commands use `.directThenLoginShell`: they start directly,
   and run one more time through the login shell only when the run reports a
   missing command.
4. The login shell runs for each command. The app does not read `PATH` one
   time at launch, so a change to the shell configuration applies to the next
   command without an app restart.
5. The command gets exactly the environment of the caller, with only `PATH`
   from the login shell. A variable that the rc exports does not reach the
   command, and output from the rc does not reach the caller.

## Consequences

- The environment rules of each caller stay true through the login shell, for
  example the removed git and token variables. Each git caller must set the
  git environment itself.
- A slow rc slows remote commands. It does not slow local status and diff.
- The retry recognizes only exit code 127 and the text `command not found`. A
  helper that git executes directly, without a shell, fails with a different
  message and gets no second attempt.

Current behavior: [Environment](../domains/environment.md#background-command-launch).
