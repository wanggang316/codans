# Documentation

This directory is the **system of record** for all project knowledge. If it's not here, it doesn't exist to the agent.

## Structure

| Directory / File | Purpose |
|---|---|
| [architecture.md](architecture.md) | System architecture, domains, layers, invariants |
| [product-spec.md](product-spec.md) | What the product is, for whom, and its boundaries |
| [golden-rules.md](golden-rules.md) | Enforced principles and conventions |
| [product-specs/](product-specs/) | Per-feature product specifications and requirements |
| [design-docs/](design-docs/) | Per-subsystem design: invariants and the *why* behind decisions |
| [references/](references/) | External references, API docs, integration notes |
| [generated/](generated/) | Auto-generated artifacts — do not edit manually |

## Conventions

This directory is a curated **Library**, not a logbook: durable invariants,
boundaries, and the *why* behind non-obvious decisions. Implementation progress
and "what we built" belong to the code, git history, and the CHANGELOG.

- Every document should be self-contained enough for an agent to act on it
- Use relative links between documents
- Keep documents focused: one subsystem / concept per file
- Delete superseded or obsolete docs rather than letting them rot — git history
  preserves them. Prefer one accurate doc per subsystem over many stale ones.
