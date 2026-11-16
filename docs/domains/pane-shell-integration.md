# Pane Shell Integration

Each local Pane runs the user's own login shell, with Ghostty shell integration loaded, inside a zmx session daemon that survives an app quit. Two parties must agree for this to work: libghostty must see the user's shell (not zmx) to integrate it, and zmx must be the outer process to keep the session. This page explains the launch chain that satisfies both, the shell-integration defaults, what a remote Pane does instead, and how a Pane reports that its shell exited.

## Scope and ownership

This page owns the launch shape of a Pane surface, the shell-integration defaults, and the TERM fallback of a remote Pane.

Neighbor topics:

- The variables of a Pane and the order in which they are layered: [Environment](environment.md).
- zmx daemons, surfaces, reclaim, and the session lifecycle: [Terminal runtime](terminal-runtime.md).
- The SSH transport and reconnect loop of a remote Pane: [Remote projects](remote-projects.md).
- The Ghostty config file that codans shares with Ghostty.app: [Appearance](appearance.md).

## The Ghostty fork

codans embeds libghostty from its own fork (submodule `apps/mac/ThirdParty/ghostty`, branch `v1.3.1-tc`, based on upstream `v1.3.1`). The fork lists its carried patches in `README.tc.md`. Two of them belong to this domain:

- **Command wrapper and integration opt-out.** `ghostty_surface_config_s` gets `command_wrapper` / `command_wrapper_count` (an argv) and `disable_shell_integration` (one surface only). Config files cannot set them.
- **Feature defaults.** The struct defaults of `shell-integration-features` change (see below).

Everything else on this page that libghostty does (shell detection, injection of the integration scripts, the macOS `login(1)` wrapping, the `/bin/sh -c` wrapping of a `command`, `wait-after-command`) is upstream behavior.

When the fork changes a C struct, the header in the xcframework and the Zig side must come from the same fork commit. The C compiler does not detect a mismatch: add fields only at the end of the struct.

## Launch chain of a local Pane

A local Pane sets no `command`. libghostty resolves the shell exactly as Ghostty.app does: it honors the user's Ghostty `command` and `shell-integration` settings, detects the shell, injects its integration, and wraps it in `login(1)`. Only then does the fork prepend the wrapper argv. The whole resolved command line becomes the arguments of `zmx attach`, and zmx runs it as the program of a new session:

```
 codans app
   └─ libghostty  (resolve shell → inject integration → login(1) wrap → prepend wrapper)
        └─ zmx attach <pane UUID> [--restore-from <snapshot>] <resolved command>   (client, owns PTY)
             ══ unix socket ══ zmx daemon (per Pane, survives app quit)
                                 └─ login(1) ─ user shell (integration loaded)
                                                 │ OSC 7, OSC 133, ssh(), sudo()
   bytes flow back through zmx to libghostty → actions → codans (pwd, commandFinished, …)
```

Why this order:

- The wrapper must go **after** the login wrapping and the integration rewrite. If codans passed `zmx attach` as the `command`, libghostty would see zmx as the program and skip integration. Bash integration also rewrites the command line, which is not possible when the command is zmx.
- The integration logic exists in one place, upstream libghostty and its bundled scripts. codans does not keep per-shell startup shims. A shim that points `ZDOTDIR` at a missing directory makes zsh skip the user's `.zshrc`.
- The integration variables (`ZDOTDIR`, `GHOSTTY_SHELL_FEATURES`, `GHOSTTY_RESOURCES_DIR`, and related) are written by libghostty into the child environment, pass through the zmx client and daemon, and survive `login -p`. `PaneEnvironment` does not touch them.

A live session keeps the process chain and environment it was created with. A change to the launch chain or the defaults reaches a Pane only when a new session is created.

### Consequences of `login(1)` in the daemon

The daemon's direct child is `login(1)`, not the shell:

- `login(1)` stays setuid root. `proc_pidinfo` returns EPERM for it, so the foreground process group must be read with `sysctl(KERN_PROC_PID)` (`ForegroundJobReader`). With `proc_pidinfo`, busy detection and agent detection always see an idle Pane.
- `login(1)` and the shell are in different process groups. At the prompt, the foreground group holds only the shell.
- `login(1)` is on the ancestor chain of every process in the Pane, so the CLI caller-Pane resolution through ancestors still finds the Pane.

## The two launch shapes

`SurfaceLaunch` is the launch description; `PaneSurface` is the only place that turns it into a `ghostty_surface_config_s`. `TerminalEngine` picks the shape per Pane.

| Shape | Used by | `command` | `command_wrapper` | Shell integration |
|---|---|---|---|---|
| `interactive(wrapper:)` | local Pane | none | `[zmx, attach, <pane UUID>, (--restore-from <path>)]` | per user config |
| `command(_:)` | remote Pane | `zmx attach <pane UUID> /bin/sh -c '<SSH loop>'` | none | off for this surface |

Rules:

- The wrapper argv is already split. It is executed directly, so a path with spaces needs no quoting. The string form is quoted for `/bin/sh -c` and is only for the remote shape.
- zmx consumes `--restore-from` wherever it appears, so it never reaches the shell command.
- The zmx session name is the bare Pane UUID. It does not change, which is what makes re-attach after a relaunch work.
- The remote shape turns shell integration off because its command is a local SSH loop, not a user shell.

## Shell-integration defaults

`shell-integration-features` is parsed so that **each assignment starts from the struct defaults** and then applies the listed items. A layered default config under the user's config therefore cannot work: one user line such as `no-cursor` resets every other item to the built-in default. For this reason the codans defaults are struct defaults in the fork:

| Feature | Upstream | Fork | Reason |
|---|---|---|---|
| `cursor` | on | on | Same as Ghostty. |
| `sudo` | off | **on** | `sudo` clears `TERMINFO`, and `xterm-ghostty` is found only through the app bundle. The wrapper passes `TERMINFO` on, so `sudo vim` works. |
| `title` | on | **off** | The integration sends OSC 2 continuously and replaces the compact directory name of a tab with a long path or command line. OSC 7 gives the directory. See [ADR 0009](../adrs/0009-agent-title-and-pane-title-follow-separate-standards.md). |
| `ssh-env` | off | **on** | `ssh` from a Pane connects with `TERM=xterm-256color` when the Pane has `xterm-ghostty`, which most hosts do not know. |
| `ssh-terminfo` | off | off | It writes to the remote `~/.terminfo` and opens an extra multiplexed connection that can conflict with the user's ssh config. Its cache needs the `ghostty` CLI, which codans does not ship. |
| `path` | on | **off** | It adds `Codans.app/Contents/MacOS` to `PATH`, which holds no `ghostty` CLI. The codans CLI is on `PATH` through the Pane environment. |

`shell-integration` and `command` keep the upstream defaults. A user value applies as written, also in codans, because codans loads the user's Ghostty config. A user `command = tmux` therefore runs tmux inside every new local Pane.

codans depends on two integration sequences: OSC 7 (the working directory of a Pane, used to reopen it in the same directory and as a tab title fallback) and OSC 133 (command start and end, used for the `commandFinished` notification).

## Remote Pane

A remote Pane does not run a local shell, so the local integration and `ssh-env` do not apply. No integration scripts are deployed to the host; OSC 7 and OSC 133 on the host depend on the host's rc files. Instead, every remote script starts with `RemoteSurfaceCommand.terminfoFallback`:

- It acts only when `TERM` is exactly `xterm-ghostty`. Any other value, also an empty one, passes through.
- It sets `TERM=xterm-256color` when `infocmp` cannot find the entry. A missing `infocmp` counts as a missing entry.
- The probe adds common tool directories (Homebrew, MacPorts, Linuxbrew) to `PATH` in a subshell only, so that `PATH` does not leak into the session.
- It runs before anything else on the host, so a host-side zmx session inherits the corrected `TERM`.

Without the fallback, zsh on the host draws line editing wrong (Backspace, arrows) and `tput`, `clear`, and full-screen programs fail.

## Child exit and "script finished"

In embedded mode, upstream libghostty turns `wait-after-command` on only when `command` is set. codans sets `wait_after_command = true` on every surface, so both shapes behave the same: when the child exits, the surface stays open and libghostty sends `show_child_exited`. Without it, a local shell `exit` would close the surface directly and bypass the Pane's exit handling.

Behind `login(1)`, libghostty classifies every child exit as abnormal and would park the surface on "Process exited. Press any key". codans does not wait for a key: on `show_child_exited` it emits `paneInfoChanged(.childExited)` and then requests the surface close itself.

Rule: anything that waits for "the script finished" keys on `paneInfoChanged(.childExited)`, not on `paneExited`. `paneExited` fires on surface close, which comes later and, for a surface that stays parked, may never come. A Run script with a close-on-finish policy is sent as `<command>; exit` so that the shell exits and `childExited` fires.

## Traps

- A fix to the launch chain or the feature defaults does not reach a running session. The user must close the Pane and open a new one.
- `ssh-env` covers only `ssh` typed in an integrated interactive shell. `ssh` from a script, `docker exec -it`, `kubectl exec -it`, and similar tools still forward `xterm-ghostty`. A user who needs that can set `term = xterm-256color` in the Ghostty config, at the cost of true color, styled underlines, and synchronized output.
- If the user's rc sources the Ghostty integration by hand, the integration loads twice.
- `title` is off by default. A user who sets `shell-integration-features = title` gets OSC 2 titles that replace the directory name of the tab.
- A fork rebase must re-apply the wrapper patch and the defaults patch. Check `README.tc.md` first.

## Shape of the implementation

```
 TerminalEngine ── picks shape ──► SurfaceLaunch ──► PaneSurface ──► ghostty_surface_config_s
   │                                 ▲                                   (fork fields)
   ├─ local:  ZmxAttachCommand.wrapperArgv
   └─ remote: RemoteSurfaceCommand.build (SSH loop + terminfoFallback)
 GhosttyActionDecoder ── show_child_exited ──► childExited event + close request
```

`PaneDaemonBringup` locates the bundled zmx binary and the runtime directory. The build scripts in `apps/mac/scripts/` build the fork into `GhosttyKit.xcframework` and copy its integration scripts and terminfo into the app bundle.
