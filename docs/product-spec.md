# Product Spec: codans

**Last Updated:** 2026-04-19

## Product Overview

### Problem

Developers who already live inside CLI coding agents (Claude Code, Codex CLI, aider, etc.) are forced to work in environments that treat the agent as a second-class citizen. They juggle multiple projects across tiled OS windows, run parallel features through git worktrees that each need their own terminal setup, and receive agent output scattered across disconnected terminal sessions with no unified orchestration. Today they cope with tmux scripts, window managers, and shell aliases — none of which understand projects, worktrees, or agent lifecycles as first-class concepts.

### Solution

A native macOS application, built on libghostty, that treats **terminals as the primary surface** and orchestrates them into a four-level hierarchy: Project → Worktree → Tab → Pane (with cross-cutting Tag classification on Projects). It exposes terminal lifecycle hooks and a CLI so coding agents become first-class citizens — their output can be aggregated, their completion can trigger cross-pane actions, and their worktree-per-feature workflow takes zero ceremony. A lightweight read-only diff/history viewer handles quick git inspection in-app. **codans is deliberately not an IDE** — for reading or editing code, it opens the user's preferred external editor (VSCode, Cursor, Zed, Xcode, Sublime Text, Finder, etc.) with one command or click.

## Target Users

| Role | Scenario | Core Need |
|---|---|---|
| CLI-agent power user (solo dev / senior engineer) | Actively works on 3+ projects per day; uses git worktrees to run multiple features in parallel within a single project; drives most coding through a CLI agent | Unified orchestration of projects and worktrees; frictionless worktree creation; aggregated agent notifications; scriptable CLI control over every Pane |

**Explicitly not targeted (v1):**
- Developers who prefer GUI-first IDE workflows (VSCode / JetBrains users without CLI agent adoption)
- Teams needing collaborative / shared sessions
- Windows-native users (covered in Future Consideration)

## Core Capabilities

| # | Capability | Description | Status | Maturity |
|---|---|---|---|---|
| C1 | Terminal engine | libghostty-based multi-pane terminal rendering and lifecycle management | Planned | Alpha |
| C2 | Project / Worktree / Tab / Pane hierarchy with Tag classification | Four-level organization: Project maps to a git repo; Worktree maps to a `git worktree`; a Worktree holds one or more Tabs; a Tab holds one or more Panes (split layouts); a Pane is a single libghostty-rendered terminal session. Projects carry zero or more **Tags** (name + Finder-style color) for cross-cutting classification; the sidebar can be filtered by an active Tag set. Switching at any level is instant and stateful | Planned | Alpha |
| C3 | Lifecycle hooks | Programmable hooks at Pane create / ready / output / idle / exit, plus Tab and Worktree activation events; enables agent notifications, command injection, custom automation | Planned | Alpha |
| C4 | CLI (`codans`) | A command-line interface for controlling Projects, Worktrees, Tabs, Panes, and Tags from inside any Pane — including cross-pane messaging | Planned | Alpha |
| C5 | Published Agent Skill | A standard-format Agent Skill (Claude Code / Codex / pi compatible — `SKILL.md` + `references/` + optional `agents/`) that teaches coding agents how to drive codans via its CLI and concepts. Distributed as an independent package; consumed by the coding agent, not by the app. Zero runtime coupling with the app. The app ships installation helpers (e.g. `codans skill install --claude-code`) that copy or symlink the bundled skill into the agent's skill directory | Planned | Alpha |
| C6 | Agent notification aggregation | Detect agent completion / blocking-on-input states via hooks; surface as OS notifications, badge counts, and in-app inbox | Planned | Alpha |
| C7 | Git diff / history viewer | Read-only viewer for diffs and commit history of the current Worktree — a quick inspection surface, not a code-review or editing tool; no write operations | Shipped | Beta |
| C8 | External editor integration | Open the current Worktree directory in an external editor or file manager (VSCode / Cursor / Zed / Xcode / Sublime Text / Finder, etc.) via CLI (`codans open`) or a button on the Worktree header; default editor configurable globally and per-Project. Worktree-level only — no file-level or diff-level open in v1 | Shipped | Beta |

### Capability Dependencies

```
C1 Terminal engine (libghostty)
 ├── C2 Project / Worktree / Tab / Pane hierarchy with Tag classification
 │    ├── C7 Git diff / history viewer    (reads the Worktree C2 selects)
 │    └── C8 External editor integration  (opens the current Worktree directory)
 └── C3 Lifecycle hooks
      ├── C4 CLI (`codans`)                   (invokes hooks, dispatches across Panes; also exposes `codans open`)
      └── C6 Agent notification aggregation   (consumer of hooks)

C5 Published Agent Skill   (standalone package; consumed by coding agents, not by the app;
                            documents C4's CLI + C2's concepts; depends on the app only for
                            CLI / concept stability, not for runtime loading)
```

**Reading the graph:** C1 is the foundation. C2 and C3 sit directly on it and are independent of each other — the hierarchy model doesn't need hooks, and hooks don't need the hierarchy. C4 is the programmable surface layer on top of C3. C6 is the first built-in consumer of C3 (and validates the hook design). C7 and C8 are independent specialized consumers of C2's Worktree context: C7 handles diff/history inspection, C8 is a simple Worktree-level handoff to an external editor or file manager. The two do not interact in v1. **C5 is deliberately orthogonal to the app runtime** — it is a documentation/skill package that lives outside the app's process boundary, versioned against C4's CLI surface; the app can ship a helper command to install it into an agent's skill directory but does not load or invoke it.

## Product Boundaries

### In Scope

- Native macOS application; universal binary (Apple Silicon + Intel)
- libghostty-backed terminal rendering with full escape sequence support (inherits ghostty's capability)
- Within a Worktree: multiple Tabs; within a Tab: multiple Panes via split layouts (tiling and stacking)
- Persistent Project / Worktree / Tab / Pane state and Tag assignments across restarts (including split geometry)
- Git worktree creation, listing, switching, and removal from within the app
- Lifecycle hooks (Pane created / ready / output match / idle / exit; Tab activated; Worktree activated)
- `codans` CLI auto-injected into every Pane's PATH
- Cross-pane messaging via CLI (e.g. `codans send <pane-id> <cmd>`, `codans broadcast --tab <tab-id> ...`)
- Published Agent Skill package (`SKILL.md` + `references/` + optional `agents/`) maintained alongside the app — kept in sync with the `codans` CLI surface of each release
- Skill installation helpers: `codans skill install --claude-code | --codex | --pi` copies or symlinks the bundled skill into the corresponding agent's skill directory (e.g. `~/.claude/skills/codans/`)
- OS notifications for agent completion / attention-required
- In-app notification inbox with per-Pane provenance
- Read-only git diff viewer (working tree, staged, per-commit)
- Read-only git history viewer (log, commit details, file-level changes)
- External editor / file manager integration at the Worktree level: open the current Worktree directory in VSCode / Cursor / Zed / Xcode / Sublime Text / Finder and similar; configurable default editor (global and per-Project); CLI entry point (`codans open [--in <editor>]`); UI button on the Worktree header. File-level and diff-level open are explicitly out of scope for v1

### Out of Scope

**codans is deliberately not an IDE.** It does not read or edit source code as an IDE does. Every code-reading or code-editing need is handled by delegating to an external tool via C8, not by growing an editor surface inside codans. The exclusions below reinforce this boundary.

| Exclusion | Reason |
|---|---|
| Text editor / LSP / syntax-aware editing / in-app code reading | Vim, Neovim, Helix, VSCode, Cursor, Zed, Xcode, Sublime Text already solve this. C8 integrates with them; we do not reimplement them. The in-app git viewer (C7) is deliberately limited to diff/history inspection, not full-file reading |
| Self-built coding agent | Users already have Claude Code / Codex CLI / aider; we build the **environment** they run in, not another agent |
| Git write operations (commit, merge, rebase, stash UI) | Terminal-first product; `git` CLI and `lazygit` already cover this; adding write UI dilutes focus |
| Team collaboration / shared sessions / co-editing | Individual power-user tool; collaboration is a different product with different architectural constraints |
| Windows-native support (v1) | Author and primary target are macOS users; covering Windows natively before validating the concept is premature |
| Web / remote / SSH / dev-container first-class support (v1) | Local-first product; remote workflows add IPC, auth, and latency concerns that would distort the v1 design |
| Building our own terminal emulator | libghostty exists and is excellent; reinventing tty/GPU rendering is a multi-year distraction |
| Package manager / dependency management | Out of scope — users invoke `npm`, `cargo`, `uv`, etc. inside Panes like they always have |

### Future Consideration

- **Git write operations** — after the read-only viewer proves useful, evaluate selective write UI (stage/unstage, quick commit from diff)
- **Linux support** — after macOS version validates the product; libghostty is cross-platform so porting cost is moderate
- **Remote / SSH / dev-container workflows** — Projects whose Worktrees live on remote hosts, with local Panes that attach transparently
- **Windows support** — evaluate after macOS + Linux; depends on libghostty Windows maturity
- **Team / shared sessions** — only if demand emerges from solo usage; would be a major architecture shift

## Key Concepts

| Term | Definition | Not to Be Confused With |
|---|---|---|
| Project | A single git repository tracked by codans; the top-level row in the sidebar | A VSCode "workspace" — codans Projects are always git-backed and scoped to one repo |
| Tag | A user-assigned label (name + Finder-style color) attached to zero or more Projects. Used for cross-cutting classification (e.g. "client-acme", "urgent"); the sidebar can be filtered by an active Tag set with OR semantics | A folder — Projects are not nested into Tags; a Project can carry multiple Tags simultaneously |
| Worktree | A `git worktree` of a Project; each Worktree has its own directory, branch checkout, and Tab/Pane layout | A "branch" — a Worktree is a concrete checkout on disk; switching Worktrees switches directories, not just HEAD |
| Tab | A named grouping of Panes inside a Worktree; one Tab is visible at a time per Worktree. Roughly "one Tab per concurrent task" (e.g. "dev server", "agent", "test watcher") | A browser tab — codans Tabs are scoped to a Worktree, not to the whole app |
| Pane | A single terminal session rendered by libghostty; lives inside a Tab. Multiple Panes per Tab form split layouts | A tmux/iTerm "pane" — same idea, but codans uses the term "Pane" consistently; also not an OS window |
| Hook | A programmable callback fired at defined Pane / Tab / Worktree lifecycle events | A shell hook (e.g. zsh `preexec`) — codans hooks are app-level and cross-Pane-aware |
| Skill | A Claude Code / Codex / pi Agent Skill: a directory with `SKILL.md` + optional `references/` and `agents/` that teaches a coding agent how to drive codans. Consumed by the agent, independent of the app runtime | A plugin or app extension — codans does not load or execute skills; skills live entirely on the agent's side |
| CLI (`codans`) | The command-line interface injected into every Pane; controls the app from inside a shell | A system command like `tmux` — `codans` talks to the running codans app, not to a separate server |

## Non-Functional Requirements

| Category | Requirement | Target |
|---|---|---|
| Performance | Cold start time | < 1.0s to first interactive Pane on M1+ |
| Performance | Pane / Tab switch latency | < 16ms (single frame at 60Hz) |
| Performance | Terminal rendering | Full libghostty throughput; no regression vs. standalone Ghostty |
| Resource | Idle CPU usage | ~0% with 8 idle Panes |
| Resource | Memory per idle Pane | < 50MB |
| Reliability | Pane crash isolation | A single Pane crash must not bring down other Panes, its Tab, or the app |
| Reliability | State durability | App-level crash must not lose Project / Worktree / Tab / Pane configuration or Tag assignments |
| Compatibility | macOS version floor | macOS 13 (Ventura) or higher, aligned with libghostty minimum |
| Compatibility | Architecture | Universal binary (arm64 + x86_64) |
| Security | Hook handler sandboxing | Hook handlers execute as user-privileged shell commands defined in user config; no elevated sandbox in v1. The published Agent Skill has no runtime side and therefore no sandboxing concern on the app side |

## Success Metrics

| Metric | Target | Current | Measurement |
|---|---|---|---|
| Personal daily driver | Author (Gump) uses codans as primary terminal for ≥ 5 days/week, fully replacing prior terminal + IDE terminal usage | N/A (pre-build) | Self-report, weekly check-in during dogfooding phase |
| Worktree workflow adoption | Avg. active Worktrees per Project ≥ 2 across the user's projects | N/A | App telemetry (local only, opt-in) |
| Agent notification effectiveness | ≥ 80% of agent-completion notifications lead to the user returning to the correct Pane within 30s | N/A | Local telemetry correlating notification delivery with Pane focus events |
| Agent integration coverage | Shipped Agent Skill supports Claude Code, Codex CLI, and pi with tested examples for each within 3 months of public release | N/A | Presence of `agents/<agent>/` subdirectories in the skill package and end-to-end smoke tests |
| Retention (long-term) | DAU / MAU ≥ 0.7 among installed users | N/A | Opt-in anonymous telemetry |

## Open Questions

1. **CLI binary name** — *Resolved by exec-plan 0003 (C4 D1, D2):* `codans` with install-time collision check (per architecture §Open-Q #3 — manual `codans install-cli`). See [C4 design doc §D1](design-docs/c4-cli.md).
2. **Agent Skill repo location** — Keep the skill in a `codans-skill/` subdirectory of this repo (co-versioned with the CLI) vs. a separate companion repo (`codans-skills`, publishable independently). **Blocks:** release process and skill installation UX. *Leaning: subdirectory of this repo in v1 to guarantee version alignment with `codans`; optionally publish a mirror repo later for people who want `npx skills add` without the app.*
3. **Non-git Projects** — Do we allow a "Project" that isn't a git repo (e.g. a scratch folder)? If yes, what happens to Worktree-related UI? **Blocks:** Project model definition. *Leaning: allow, but Worktree features become inert.*
4. **Hook execution model** — *Resolved by exec-plan 0003 (C3 D1):* out-of-process only in v1. Each hook subscription runs a `/bin/sh -c <command>` with `CODANS_HOOK_ENVELOPE` holding the JSON envelope. In-process JS scripting deferred indefinitely (not compatible with the language-agnostic contract we want for `codans`-shell composition). See [C3 design doc §D1](design-docs/c3-lifecycle-hooks.md).
5. **Agent detection heuristic** — *Resolved by exec-plan 0003 (C3 D10 + C4 Pane labels):* no heuristic detection. C6 relies on (a) user-configured hook rules + (b) Pane labels applied at spawn time via `codans pane label @pane <label>`. Known-binary allowlists are out of scope — they collide with user-renamed binaries and shell aliases, and the wrapper-composition story is stronger without "magic." See [C3 design doc §D10](design-docs/c3-lifecycle-hooks.md).
6. **Worktree storage layout** — Where do new worktrees live on disk? Under the main repo's `.git/worktrees`? A sibling directory? User-configurable? **Blocks:** C2 implementation and user file-system expectations. *Leaning: sibling `<repo>-worktrees/<branch>` by default, configurable per Project.*
7. **External editor discovery & invocation (C8)** — *Resolved by docs/design-docs/c8-editor-integration.md, exec-plan 0003 (C4 D14), and exec-plan 0005 M5–M7.* Built-in allowlist of six editors (`vscode`, `cursor`, `zed`, `xcode`, `sublime`, `finder`) with documented CLI wrappers; installation status resolved via `$PATH` probe on `describe`; arbitrary user-defined templates via `Settings.customEditors` / `settings.json.externalEditors[NAME]`; 4-tier precedence (explicit `--in` → per-Project override → global default → Finder fallback). The `codans open [--in EDITOR] [<worktree>]` CLI wrapper landed in 0003 M7; the `editor.*` IPC surface (`.describe` / `.open` / `.setDefault`) and app-tier `EditorService` land in 0005 M5–M7. See [C4 design doc §D14](design-docs/c4-cli.md) and [exec-plan 0005](exec-plans/).
