# 0016. A repository workflow that runs commands needs a trust grant from the app

Status: Accepted

## Context

A workflow definition can contain `run:` steps, which execute shell commands
headless. Definitions in `<worktree>/.codans/workflows/` come with a clone or a
pull. Cloning a repository must not be consent to run its commands.

## Decision

1. A repository-scope definition that contains a `run:` step must be trusted
   before it starts. Without trust, admission fails with
   `WORKFLOW_TRUST_REQUIRED`.
2. A grant binds the file path and the SHA-256 of the file content. Any edit
   to the file voids the grant.
3. Only the app grants trust, in the start panel or in Settings → Workflows.
   The CLI cannot grant it.
4. Built-in and user-scope definitions, and repository definitions without
   `run:`, need no trust.
5. No workflow starts by itself.

## Consequences

- The user confirms one more time after each edit of a trusted file.
- A change that lets the CLI or an IPC method grant trust removes the
  protection. Do not add one.

Current behavior: [Workflow](../domains/workflow.md).
