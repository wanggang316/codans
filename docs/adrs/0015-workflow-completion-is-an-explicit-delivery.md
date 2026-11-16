# 0015. A workflow step completes by an explicit delivery

Status: Accepted

## Context

A workflow must know when a participant finished its part and what the result
is. The agent runtime state is not sufficient: an agent that moved work to the
background, or that waits between two tool calls, shows `idle` before the work
is complete. A result read from the screen has no boundaries and cannot be
validated.

## Decision

1. A step that needs a result declares `expect`. The participant hands the
   result back with `codans workflow deliver`, with a body and an optional
   verdict.
2. Each wait for a delivery is an activation with a random token. The token
   ties a delivery to its step. It correlates; it does not authenticate.
3. `wait: idle` exists only as a low-cost step for cases that need no result.
   It is not the completion signal of a step with `expect`.
4. A delivery that misses a required section or verdict is provisional by
   default. The run goes to `needs_attention` and the user decides.
   `strict: true` rejects it.

## Consequences

- An agent must follow a protocol. The workflow tells it the exact completion
  command, sends that command one more time when the agent goes idle without a
  delivery, and then asks the user.
- A workflow is deterministic up to the prompt and no further.
- A late delivery for a closed activation is refused.

Current behavior: [Workflow](../domains/workflow.md).
