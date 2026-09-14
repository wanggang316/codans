# Lessons Learned: the CLI could not tell what an agent was doing, wait for it, or promise an output shape

**Status:** Resolved
**Date:** 2026-09-14
**Area:** CLI / IPC (`AgentHandlers`, `TerminalHandlers`, `CodansKit/Render`, the published `codans` skill)
**Fix:** branch `feat/cli-all` — see CHANGELOG `[Unreleased]` (CLI section)

## Summary

A review of the CLI against what an agent orchestrating other agents
needs found five gaps that no single bug report had named:

1. The Agents View's per-pane runtime state (`working` / `blocked` / `idle`
   / `finished`) was app-only; the CLI exposed the binding (`agentKind`)
   and nothing else, so "wait until the sibling agent is done" meant a
   hand-written loop over `pane capture` and a guess.
2. `pane send` was fire-and-forget. A script had to sleep, capture, and
   guess whether the command had finished.
3. `--json` printed a bare object per verb with no version and no schema;
   errors went to stderr as text even in JSON mode. The `{"raw": …}`
   id shape that broke the regression harness a few days earlier was a
   symptom: nothing checked output shapes.
4. Positional arguments were inconsistent: `pane split` took the anchor
   *and* a command positionally, `pane send` overloads one vs. two
   arguments, and worktrees could not be addressed by path.
5. The skill lived only in the repository; a user had to copy it by hand
   and nothing kept the copy current after an app update.

## Root cause

The CLI grew verb by verb from the GUI's IPC surface, so it mirrored
what the app could *do* and not what a script needs to *know*: state,
completion, and a contract. The Agents View design explicitly listed an
IPC surface as a non-goal, and the output renderer predates any consumer
that parsed it programmatically.

## Fix

- `agent status` (`agent.listStates`) reads `AgentStateStore.entries`
  through the same handle registry `tree` uses; `agent wait --until`
  (`agent.wait`) polls the store server-side and returns `satisfied` or
  the last state at the deadline. The store stays app-only state; the
  CLI only reads it.
- `pane send --wait / --capture` polls the foreground-job busy bit
  (`HierarchyManager.paneIsBusy`) plus screen stability; a command too
  short for the 500 ms poller completes after a quiet grace. Capture is a
  before/after screen diff — the terminal exposes rendered text, not
  command boundaries, so it is best effort and documented as such.
- Every `--json` is `{schemaVersion, data | error}`; the command path
  reaches the renderer through a task-local set by `CommandRunner`, error
  codes are a `CLIErrorCode` enum with a default per exit code, and a JSON
  Schema in `codans-cli/Resources/schema` is validated over every output
  of a regression run.
- One positional target per verb; `pane split` takes `--command`;
  worktree paths resolve client-side to absolute and match server-side
  against worktree roots.
- The app embeds `skills/` and `codans skill install` links them into
  `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills` (or a
  repository's).

## Recurrence checks

- A new verb's `--json` needs a `$defs` entry and a `schemaVersion`
  binding in `cli-output.schema.json`; the harness's final case fails
  otherwise.
- A new failure path that a script should branch on gets a
  `CLIErrorCode` case, not just a message.
- Anything that writes under the user's home in the harness must go
  through `$HOME`; `homeDirectoryForCurrentUser` ignores the variable,
  and the first `skill` run of the harness linked into the real
  `~/.codex/skills` because of it.
- The "Embed zmx" build phase is dependency-analysed and can be skipped
  after "Embed codans" wipes `Resources/bin`; a Debug bundle without
  `bin/zmx` fails every `pane new` with exit 20. Check the bundle before
  blaming the CLI.
