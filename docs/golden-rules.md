# Golden Rules

These rules are non-negotiable. Some are enforced by repository checks and CI, while others remain process rules that should be encoded mechanically over time.

When agents struggle, the fix is almost never "try harder." Ask: "What capability is missing, and how do we make it legible and enforceable?"

---

## 1. AGENTS.md is a map, not a manual

Keep AGENTS.md under 150 lines. It should be a table of contents pointing to deeper docs in `docs/`. Progressive disclosure: agents start with a small, stable entry point and are taught where to look next.

**Enforcement:** Repository review, document structure checks.

## 2. Validate boundaries, never probe data

Parse and validate data at system edges. Never guess at data shapes. Use typed schemas and validation libraries at boundaries between systems.

**Enforcement:** Code review, type checking.

## 3. Prefer shared utilities over hand-rolled helpers

Centralizes invariants. Prevents drift. If three places need the same logic, extract it. Don't let agents replicate patterns — give them a single canonical implementation.

**Enforcement:** Code review, periodic sweep agent.

## 4. Repository knowledge is the system of record

If it's not in the repo, it doesn't exist to the agent. Slack discussions, verbal agreements, and Google Docs are invisible. Every architectural decision, product spec, and convention must be discoverable from the repository.

**Enforcement:** Cross-link review, repository structure checks.

## 5. Plan complex work before building — but a plan is not a Library doc

For non-trivial work, capture a plan before starting (the sequence, the surprises, the decisions). Planning and progress are **working state**: they live in gitignored runtime state (`.harness-runtime/`), never committed under `docs/`. `docs/` is a curated Library of durable knowledge — when a plan settles a durable decision, fold *that decision* into the relevant design-doc or `architecture.md`, not a progress log.

**Enforcement:** Process convention; the `docs/README` current-state + liveness conventions; the `doc-sync` sweep.

## 6. Fix the environment, not the prompt

When an agent fails, treat it as an environment bug. The fix is always one of: missing tool, missing documentation, missing guardrail, or missing feedback loop. Fix it structurally so it never recurs.

**Enforcement:** Culture, retrospectives.

## 7. Enforce architecture mechanically

Documentation rots. Cultural norms don't scale to agents. Encode architectural invariants as linters and structural tests. Lint error messages should tell the agent exactly how to fix the issue.

**Enforcement:** Custom linters, structural tests, CI gates.

## 8. Commit in small, deliberate steps

Agents and humans both reason better over narrow diffs. Break work into paced, reviewable commits that each capture a coherent step. Do not pile many unrelated or weakly related edits into one large commit.

**Enforcement:** Code review, commit history review.

## 9. Corrections are cheap, waiting is expensive

With high agent throughput, fast fix-forward is often cheaper than slow gates. Keep merge gates minimal. Address test flakes with follow-up runs. Don't let process bottleneck throughput.

**Enforcement:** CI configuration, team norms.

## 10. Garbage-collect continuously

Agents replicate existing patterns — including bad ones. Run regular cleanup sweeps. Encode golden principles and scan for deviations on a recurring cadence. Small frequent corrections beat large periodic rewrites.

**Enforcement:** Sweep agent, scheduled CI jobs.

## 11. Agent legibility is the primary design goal

Optimize code and documentation for agent readability first. Anything the agent can't access in-context while running effectively doesn't exist. Favor dependencies that can be fully internalized and reasoned about in-repo.

**Enforcement:** Code review, architecture docs.
