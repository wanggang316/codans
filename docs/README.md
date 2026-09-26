# Documentation

This directory is the **system of record** for all project knowledge. If it's not here, it doesn't exist to the agent.

## Structure

| Directory / File | Purpose |
|---|---|
| [architecture.md](architecture.md) | System architecture, domains, layers, invariants |
| [product-spec.md](product-spec.md) | What the product is, for whom, and its boundaries |
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

### Feature availability and implementation references

A symbol existing in code does **not** mean the feature is live: it may be
hidden, unwired, or a stub. Feature documents describe availability by user entry point. Use the document's language:

| Availability / 状态 | Meaning |
|---|---|
| Available / 已上线（可见） | Implemented with a reachable user entry point |
| Hidden / 已实现但隐藏 | Implemented, but its entry point is hidden or unwired |
| Planned / 已设计未实现 | No working implementation |

For a mixed subsystem, state which operations are available, hidden, or planned.
An existing `Status: Implemented` field must describe that scope explicitly.

Link feature contracts to their implementation entry points. Keep index summaries
focused on responsibilities and link to the owning document for capability
limits. Describe implemented behavior in the present tense and separate
unimplemented capabilities explicitly.

Review dates, inspection notes, implementation milestones, and change narratives
belong in review reports or change history, not feature explanations. Runtime
sequences and schema-conversion rules belong in the knowledge base when they
explain actual system behavior.

Removed behavior must not remain in current feature descriptions or acceptance
cases. Git history retains superseded designs. Dated test results and incident
reports describe their recorded run or incident, not current feature availability.
