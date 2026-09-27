# Product Spec: codans


## Product Overview

### Problem

Developers who already live inside CLI coding agents (Claude Code, Codex CLI, aider, etc.) are forced to work in environments that treat the agent as a second-class citizen. They juggle multiple projects across tiled OS windows, run parallel features through git worktrees that each need their own terminal setup, and receive agent output scattered across disconnected terminal sessions with no unified orchestration. Today they cope with tmux scripts, window managers, and shell aliases — none of which understand projects, worktrees, or agent lifecycles as first-class concepts.

### Solution

A native macOS application, built on libghostty, that treats **terminals as the primary surface** and orchestrates them into a four-level hierarchy: Project → Worktree → Tab → Pane (with cross-cutting Tag classification on Projects). It provides CLI control, agent profiles and handoff, live agent state, and notification aggregation. Programmable lifecycle hooks are designed but not implemented. **codans is deliberately not an IDE** — an independent read-only window reviews current and outgoing code changes without resizing the terminal. Editing opens the user's preferred external editor; broader Git and history workflows remain available through the external Git Viewer command.

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
| C1 | Terminal engine | libghostty-based multi-pane terminal rendering and lifecycle management | Shipped | Stable |
| C2 | Project / Worktree / Tab / Pane hierarchy with Tag classification | Four-level organization: Project maps to a local or SSH-hosted directory; git-backed Projects expose git worktrees, plain folders have one synthetic Worktree, and Workspaces group checkouts from multiple repositories; a Worktree holds one or more Tabs; a Tab holds one or more Panes (split layouts); a Pane is a single libghostty-rendered terminal session. Projects carry zero or more **Tags** (name + Finder-style color) for cross-cutting classification. Switching at any level is instant and stateful. *(The Tag data model and persistence ship; the sidebar Tag-filter entry point is implemented but currently hidden — see Key Concepts.)* | Shipped | Stable |
| C3 | Lifecycle hooks | Programmable hooks at Pane create / ready / output / idle / exit, plus Tab and Worktree activation events; enables agent notifications, command injection, custom automation | Designed, not yet implemented | — |
| C4 | CLI (`codans`) | A command-line interface for controlling Projects, Worktrees, Tabs, and Panes from inside any Pane — including cross-pane messaging. Hierarchy, Workspace, terminal automation, editor, and introspection commands are callable. Skill management is local filesystem work; programmable lifecycle hooks are not implemented | Shipped (core verbs) | Beta |
| C5 | Agent Skill | Repository-maintained instructions at `skills/codans-cli/SKILL.md`, consumed by coding agents independently of the app runtime. `codans skill list/install/uninstall/path` manages bundled skill links for user or project scope without a running app | Available | — |
| C6 | Agent state and notifications | Live Agents View identifies known agents and derives their state. Separately, runtime notifications feed the inbox, badges, and OS notifications; these do not require the planned lifecycle hook runtime | Shipped | Beta |
| C7 | Git viewer selection | Open the built-in viewer or the current Worktree in the user's external git client (Fork / Sourcetree / GitHub Desktop / GitKraken / Sublime Merge, etc.) via the "Toggle Git Viewer" command (⌘G chord / menu / command palette); default git client configurable globally (`general.defaultGitViewerID`). Shares the same registry, launcher, and open path as C8 — a separate global default pointed at the registry's git-client category. Built-in is the first and default Git Viewer option; selecting it opens the read-only diff window, while external choices use the shared launcher | Shipped | Beta |
| C9 | Agent profiles & handoff | Named launch presets per coding agent (Settings → Agents; toolbar Agents button, Command Palette, `codans agent launch`) and agent-to-agent task handoff over a worktree-local `.codans/handoff/` artifact: the live source agent writes its own briefing via `codans handoff`, the receiver starts in a background tab with a kickoff prompt; an in-app Hand Off panel triggers and observes that same transition | Shipped | Beta |
| C8 | External editor integration | Open the current Worktree directory in an external editor or file manager (VSCode / Cursor / Zed / Xcode / Sublime Text / Finder, etc.) via CLI (`codans open`) or a button on the Worktree header; default editor configurable globally and per-Project. The read-only diff window also opens current files, with line navigation where supported | Shipped (directory); implemented (diff file navigation) | Beta |
| C10 | Read-only diff viewer | Uncommitted shows aggregate current changes, including untracked files; Outgoing compares the merge base of the remote default branch (or an explicit base) to HEAD. Includes unified / split rendering, syntax highlighting, a native tree/list file sidebar, file filtering, and current-file editor handoff. See [Git diff viewer](design-docs/git-diff-viewer.md) | Implemented | Experimental |

### Capability Relationships

The terminal runtime and hierarchy underpin CLI control, agent launch/handoff,
and external-tool delegation. Agents View and notifications consume runtime
signals independently; neither depends on the unimplemented lifecycle hook
runtime. The Agent Skill documents the callable CLI and has no app runtime role.

SSH Server Projects provide remote worktree discovery, creation/removal, and
terminal sessions. Authentication stays with SSH config and the user's agent.
See [Remote SSH Projects](design-docs/remote-ssh-projects.md) for supported
operations and remote editor limitations.

## Product Boundaries

### In Scope

- Native macOS application; release artifacts target Apple Silicon (arm64)
- libghostty-backed terminal rendering with full escape sequence support (inherits ghostty's capability)
- Within a Worktree: multiple Tabs; within a Tab: multiple Panes via split layouts (tiling and stacking)
- Persistent Project / Worktree / Tab / Pane state and Tag assignments across restarts (including split geometry)
- Git worktree creation, listing, switching, and removal from within the app
- Local panes receive the app-channel CLI in PATH (`codans` for Release, `codans-dev` for Debug); SSH shells do not automatically receive a remote CLI installation
- Cross-pane messaging via CLI (e.g. `codans pane send <pane-id> <cmd>`, `codans broadcast --tab <tab-id> ...`)
- Agent Skill source maintained alongside the CLI at `skills/codans-cli/SKILL.md`
- OS notifications for agent completion / attention-required
- In-app notification inbox with per-Pane provenance
- Git viewer delegation at the Worktree level: open the current Worktree in an external git client (Fork / Sourcetree / GitHub Desktop / GitKraken / Sublime Merge and similar) for diff/history inspection; configurable default git client (`general.defaultGitViewerID`); "Toggle Git Viewer" command (⌘G chord / menu / command palette). Shares the editor-integration registry and launcher; the default Built-in option opens the internal diff window, while selecting an external client delegates to that client
- External editor / file manager integration at the Worktree level: open the current Worktree directory in VSCode / Cursor / Zed / Xcode / Sublime Text / Finder and similar; configurable default editor (global and per-Project); CLI entry point (`codans open [--in <editor>]`); UI button on the Worktree header. The diff window can open the current file; supported editors also receive a current-side line number

- Built-in read-only Uncommitted / Outgoing window, opened from Worktree → Show Changes, the command palette, or the Git Viewer shortcut with Built-in selected. It retains per-worktree scope, base, and file selection for the app session and refreshes local Git state every two seconds while visible; it does not fetch remote refs automatically

### Out of Scope

**codans is deliberately not an IDE.** Its embedded code surface is a read-only comparison viewer. Code editing, language-server workflows, and general source browsing belong to external editors; history exploration remains available in external Git clients.

| Exclusion | Reason |
|---|---|
| Text editor / LSP / syntax-aware editing / general source browser | Vim, Neovim, Helix, VSCode, Cursor, Zed, Xcode, Sublime Text already solve this. C8 integrates with them; we do not reimplement them |
| In-app history browser or merge editor | The built-in viewer covers current and outgoing diffs only; C7 delegates broader Git workflows to external clients |
| Self-built coding agent | Users already have Claude Code / Codex CLI / aider; we build the **environment** they run in, not another agent |
| General-purpose Git editing UI (stage, commit, rebase, stash) | Use terminal or external Git clients; worktree operations, branch switching, and GitHub PR actions remain supported orchestration workflows |
| Team collaboration / shared sessions / co-editing | Individual power-user tool; collaboration is a different product with different architectural constraints |
| Windows-native support (v1) | Author and primary target are macOS users; covering Windows natively before validating the concept is premature |
| Browser-hosted workspace / dev-container orchestration | The current app supports local directories and SSH Server Projects; these additional environments have no first-class implementation |
| Building our own terminal emulator | libghostty exists and is excellent; reinventing tty/GPU rendering is a multi-year distraction |
| Package manager / dependency management | Out of scope — users invoke `npm`, `cargo`, `uv`, etc. inside Panes like they always have |

### Future Consideration

- **Git write operations** — evaluate selective in-app write UI (stage/unstage, quick commit) only if the external-git-client delegation (C7) proves insufficient
- **Linux support** — after macOS version validates the product; libghostty is cross-platform so porting cost is moderate
- **Dev-container workflows** — evaluate container-specific project discovery and session lifecycle
- **Windows support** — evaluate after macOS + Linux; depends on libghostty Windows maturity
- **Team / shared sessions** — only if demand emerges from solo usage; would be a major architecture shift

## Key Concepts

| Term | Definition | Not to Be Confused With |
|---|---|---|
| Project | The top-level row in the sidebar. Usually a single git repository; may also be a plain folder, a remote (SSH) root, or a **Workspace** — a folder holding checkouts of several repositories for one task (`.codans/workspace.json` names them). See [Workspace](design-docs/workspace.md) | A VSCode "workspace" — a codans Workspace is a Project whose Worktree rows are checkouts of *other* repositories, not a saved window layout |
| Tag | A user-assigned label (name + Finder-style color) attached to zero or more Projects. Used for cross-cutting classification (e.g. "client-acme", "urgent"). Designed to let the sidebar be filtered by an active Tag set with OR semantics — the data model and persistence ship, but the filter entry point is currently hidden (implemented yet dormant; the sidebar footer surfaces only sort + refresh) | A folder — Projects are not nested into Tags; a Project can carry multiple Tags simultaneously |
| Worktree | A checkout or synthetic directory root with its own Tab/Pane layout. Git-backed rows carry branch or detached-HEAD information. A Workspace has a synthetic root row and member checkouts from other repositories | A "branch" — a Worktree is a concrete checkout on disk; switching Worktrees switches directories, not just HEAD |
| Tab | A named grouping of Panes inside a Worktree; one Tab is visible at a time per Worktree. Roughly "one Tab per concurrent task" (e.g. "dev server", "agent", "test watcher") | A browser tab — codans Tabs are scoped to a Worktree, not to the whole app |
| Pane | A single terminal session rendered by libghostty; lives inside a Tab. Multiple Panes per Tab form split layouts | A tmux/iTerm "pane" — same idea, but codans uses the term "Pane" consistently; also not an OS window |
| Hook | A designed, unimplemented programmable callback at Pane / Tab / Worktree lifecycle events | A shell hook (e.g. zsh `preexec`) — codans hooks are app-level and cross-Pane-aware |
| Skill | A Claude Code / Codex / pi Agent Skill: a directory with `SKILL.md` + optional `references/` and `agents/` that teaches a coding agent how to drive codans. Consumed by the agent, independent of the app runtime | A plugin or app extension — codans does not load or execute skills; skills live entirely on the agent's side |
| CLI (`codans`) | The command-line interface injected into local panes; controls the app from inside a shell | A system command like `tmux` — `codans` talks to the running codans app, not to a separate server |

## Non-Functional Requirements

Performance and reliability entries are targets, not measured guarantees. Benchmark results and crash-isolation evidence require separate validation.

| Category | Requirement | Target |
|---|---|---|
| Performance | Cold start time | < 1.0s to first interactive Pane on M1+ |
| Performance | Pane / Tab switch latency | < 16ms (single frame at 60Hz) |
| Performance | Terminal rendering | Full libghostty throughput; no regression vs. standalone Ghostty |
| Resource | Idle CPU usage | ~0% with 8 idle Panes |
| Resource | Memory per idle Pane | < 50MB |
| Reliability | Pane crash isolation | A single Pane crash must not bring down other Panes, its Tab, or the app |
| Reliability | State durability | App-level crash must not lose Project / Worktree / Tab / Pane configuration or Tag assignments |
| Compatibility | macOS version floor | macOS 14 (Sonoma) or higher, as configured in `apps/mac/Project.swift` |
| Compatibility | Architecture | Apple Silicon (arm64); release archive uses `ARCHS=arm64` |
| Security | Hook handler sandboxing | Planned hook handlers execute as user-privileged shell commands defined in user config; no elevated sandbox in v1. The published Agent Skill has no runtime side and therefore no sandboxing concern on the app side |

## Success Metrics

These are proposed measurements. The table does not establish that telemetry
collection is implemented or that any target has been met.

| Metric | Target | Current | Measurement |
|---|---|---|---|
| Personal daily driver | Author (Gump) uses codans as primary terminal for ≥ 5 days/week, fully replacing prior terminal + IDE terminal usage | Not measured | Self-report, weekly check-in during dogfooding phase |
| Worktree workflow adoption | Avg. active Worktrees per Project ≥ 2 across the user's projects | Not measured | App telemetry (local only, opt-in) |
| Agent notification effectiveness | ≥ 80% of agent-completion notifications lead to the user returning to the correct Pane within 30s | Not measured | Local telemetry correlating notification delivery with Pane focus events |
| Agent integration coverage | Shipped Agent Skill supports Claude Code, Codex CLI, and pi with tested examples for each within 3 months of public release | Not measured | Reviewed skill examples and end-to-end smoke tests for each supported agent |
| Retention (long-term) | DAU / MAU ≥ 0.7 among installed users | Not measured | Opt-in anonymous telemetry |

## Implementation References and Planned Work

- **Projects and worktrees:** `apps/mac/CodansCore/Project.swift` defines git-backed,
  plain-folder, remote, and Workspace Projects. Storage resolution belongs to the worktree
  implementation; see [Worktree](design-docs/worktree.md).
- **Agent identification:** `AgentKind` and `AgentKindPatterns` define known-agent
  recognition. See [Agents View](design-docs/active-agents-view.md) for runtime
  signals and the boundary with notifications.
- **CLI availability:** the registered subcommands in
  `apps/mac/codans-cli/CodansCLI.swift` define the callable surface. A source file
  alone does not establish a working command; see [CLI](design-docs/cli.md).
- **Editor delegation:** [Editor integration](design-docs/editor-integration.md)
  owns discovery and launch behavior, including SSH-specific limitations.
- **Planned lifecycle hooks:** [Lifecycle hooks](design-docs/lifecycle-hooks.md)
  describes an unimplemented subsystem, including the proposed execution policy.
- **Skill installation:** `codans skill install` links bundled skills into detected
  agent directories; `--target`, `--scope`, and `--project-root` select the destination.
