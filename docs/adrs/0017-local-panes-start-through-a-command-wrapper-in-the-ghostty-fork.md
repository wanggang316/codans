# 0017. Local Panes start through a command wrapper in the Ghostty fork

Status: Accepted

## Context

A local Pane needs two things. libghostty must see the shell of the user, so
that it can detect the shell and load its integration (the working directory
and command marks, the `ssh` and `sudo` wrappers). The zmx daemon must be the
outer process, so that the session survives an app quit.

With `zmx attach` as the `command` of the surface, libghostty saw zmx as the
program. No integration was loaded, and `ssh` from a Pane sent
`TERM=xterm-ghostty` to hosts that do not know it. A set of startup shims for
each shell in codans duplicated the upstream scripts and broke user
configuration: a shim that pointed `ZDOTDIR` at a missing directory made zsh
skip `.zshrc`.

`shell-integration-features` is parsed so that each assignment starts from the
struct defaults. A default configuration layered under the user's file cannot
work: one user line resets every other item.

## Decision

1. The codans fork of Ghostty adds `command_wrapper` to the surface
   configuration. libghostty resolves the shell, loads the integration, and
   wraps it in `login(1)` as upstream does. Only then does it put the wrapper
   argv in front. codans passes `zmx attach <pane UUID>` as the wrapper.
2. codans keeps no startup shims of its own. The integration logic exists in
   one place, upstream libghostty and its scripts.
3. The codans defaults of `shell-integration-features` are struct defaults in
   the fork: `sudo` and `ssh-env` on, `title` and `path` off.
4. A remote Pane sets a `command` (the SSH loop) and turns the integration off
   for that surface.

## Consequences

- Each rebase of the fork must apply the wrapper patch and the defaults patch
  again. `README.tc.md` in the fork lists them.
- The direct child of the daemon is `login(1)`, which is setuid root. The
  foreground process group must be read with `sysctl`, not `proc_pidinfo`.
- A change to the launch chain or the defaults reaches a Pane only when a new
  session starts.

Current behavior: [Pane shell integration](../domains/pane-shell-integration.md).
