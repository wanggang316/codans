# 0014. CLI exit codes classify a failure by the action of the caller

Status: Accepted

## Context

Agents and scripts branch on the exit code of `codans`. With one "cannot
connect" code, a script had to read stderr to know whether to start the app,
to retry, or to stop.

## Decision

1. The exit codes are a fixed table, stable within a major version.
2. A connect failure maps to the action that the caller must take, not to the
   errno: start the app and retry, retry as is, or stop and get a person.
3. An errno without a mapping stays `unknown`. It does not join the nearest
   category, because a wrong category misleads a script more than an honest
   unknown.
4. A failure that one exit code cannot separate has its own `CLIErrorCode` in
   the `--json` envelope.

## Consequences

- A new failure that a script must branch on needs an exit code or a
  `CLIErrorCode`, not only a message.
- A change to the meaning of an existing code is a breaking change of the CLI.

Current table: [CLI](../domains/cli.md#output-and-exit-codes).
