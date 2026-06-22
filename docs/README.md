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

### Write the present, not the path to it

Describe the system **as it is now**, in the present tense. Do **not** narrate
how it got here — no "从前 / 曾经 / 取代了 / 降到 N 级 / v1→v2 / superseded /
used to". A reader wants today's truth, not the changelog. If a transition's
*rationale* is load-bearing (a constraint a future maintainer must not undo),
record it in a dedicated `## 技术决策 / Decisions` section as a decision entry —
never woven into the descriptive prose.

### Every doc declares a liveness status

A symbol existing in code does **not** mean the feature is live — it may be
hidden, unwired, or only a stub. Before describing a feature, verify it is
reachable in the current build, then put a status field at the top:

| `**状态：**` value | Meaning |
|---|---|
| `已上线（可见）` | Shipped and reachable by the user today |
| `已实现但隐藏` | Code exists but the UI/entry point is intentionally hidden/dormant |
| `已设计未实现` | Design only; no working implementation (a command-id or stub ≠ a feature) |

A **removed** feature gets **no doc** — delete it (git keeps the history). Never
describe a removed feature as current. When a doc is `已实现但隐藏` or
`已设计未实现`, say so in the prose too, so no reader mistakes intent for reality.
