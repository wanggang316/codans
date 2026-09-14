# Lessons Learned: CLI-spawned panes lacked the project environment, and `current` never worked for containers

**Status:** Resolved
**Date:** 2026-09-10
**Area:** CLI / IPC (`HierarchyHandlers`, `AliasResolver`, `PaneEnvironment`, the published `codans` skill)
**Fix:** branch `feat/cli-all` — see CHANGELOG `[Unreleased]` (CLI section)

## Summary

The first black-box regression of every `codans` verb against a Debug build
(`docs/user-tests/cli-regression/harness.sh`) surfaced two defects that unit
tests had never seen, plus a set of skill / CLI drifts:

1. A pane opened with `codans pane new` started with the **bare app
   environment**: no `CODANS_CLI`, no `CODANS_SOCKET_PATH`, none of the
   project's `envVars`, and `TERM_PROGRAM=ghostty`. In a development build the
   pane could not even find `codans-dev`.
2. `--project current`, `--worktree current`, `--tab current` failed inside
   every pane with "no current project context", although nearly every
   command defaults to them and the skill promised they work.

## Root cause

1. `HierarchyHandlers.openPane` called `manager.openPane(...)` without the
   `env:` argument; the manager's default is `[:]`. The sidebar's paths go
   through `HierarchyClient`, which resolves `HierarchyManager.resolvedEnv`
   first. The handler already owned an `envProvider` closure for
   `focusPane` and simply did not use it here. libghostty then filled the
   gap with its own `TERM_PROGRAM=ghostty` and shell integration appended
   `Contents/MacOS` to PATH, which made the pane look almost right.
2. A pane exports only `CODANS_PANE_ID`. `AliasResolver` resolved `current`
   for the other kinds from `CODANS_{PROJECT,WORKTREE,TAB}_ID`, which nothing
   sets, and threw `noContext` before dialling. The server's
   `resolveCurrent` refused non-pane kinds too.

Both survived because the handler tests exercised each RPC in isolation and
the CLI was only ever tried by hand from a pane the GUI had created.

## Fix

- `openPane` passes `envProvider(projectID)`; a handler test asserts the
  surface receives it.
- `current` for any kind falls through to the server, which attributes the
  caller to its pane (peer PID ancestry, else `contextPaneID`) and reads the
  pane's tab / worktree / project off the catalog. Outside a pane the error
  says so and suggests an id. Verbs whose target already fixes its containers
  (`tab close t3`, `pane new --tab t3`, `worktree rm <id>`) resolve them from
  the tree (`ScopeResolver`).
- Along the way: `list` verbs, `open`, `help-json` wired; `worktree new`
  runs the sheet's `wt sw` pipeline instead of writing a catalog row only;
  `project add` validates, refuses duplicates, and discovers the git root;
  names accepted as targets; `--timeout` honoured everywhere; `--raw` hex
  tokens; `launch` forwards its socket / config env to the app.

## Recurrence checks

- Run `docs/user-tests/cli-regression/harness.sh <Debug Codans.app> all`
  after any change under `apps/mac/codans-cli`, `CodansKit`, or
  `Features/Socket`. It drives an isolated instance (private socket, scratch
  config, fixture repo, fake agents) and asserts exit codes for every verb,
  including the in-pane `current` cases.
- Any new pane-spawning RPC must resolve env through `envProvider` /
  `HierarchyManager.resolvedEnv`; the `HierarchyHandlersOpenPaneEnvTests`
  pattern is the template.
- Keep `skills/codans-cli/SKILL.md` in step with `codans --help`; the harness
  exercises the exact flags the skill documents (`-p` only on `send`, no
  `--screen` on `read`, list verbs present).

## Follow-up (2026-09-14): the two hand-off cases that "never came up"

The harness's `handoff to … --split` cases (H11/H12) failed on every run
while the same steps passed by hand. Two separate causes:

- **Harness:** `codans handoff to --json` printed `launchedPane` ids as
  `{"raw": "…"}` objects (the wire shape), so `jq -r .launchedPane.paneID`
  yielded a JSON blob and every readback targeted a pane that did not
  exist. Fixed by re-shaping the CLI output to plain strings like every
  other verb; the harness now asserts the type. When a readback fails,
  print the extracted id before suspecting the product.
- **Product:** the kickoff typer looked for the *start* of the prompt in the
  pane's active rows. The harness's receiver pane was a few rows tall
  (sixth split in the tab), so the 380-character prompt's head had scrolled
  into history by the time its echo finished; Enter was never sent. It now
  matches the *end* of the prompt, which sits at the cursor whatever the
  pane size. Manual tests used a tall pane and never hit it — size the
  receiver pane down when testing typed kickoffs.

