# Execution Plans

Execution plans (ExecPlans) are **living documents** for complex work items. They track progress, record decisions, and capture surprises discovered during implementation.

## When to Create an Exec Plan

- Any task requiring more than a few hours of work
- Multi-step changes spanning multiple files or domains
- Work where the approach may need to evolve based on discoveries
- Tasks that benefit from checkpointed progress

## Creating a Plan

Create a new markdown file in this directory from [_template.md](_template.md), then fill it in before implementation starts.

## Required Sections

Every exec plan MUST contain:
1. **Purpose / Big Picture** — what someone gains after this change
2. **Context and Orientation** — current state, key files, definitions
3. **Plan of Work** — sequence of edits and additions
4. **Progress** — checkboxes with timestamps
5. **Surprises & Discoveries** — unexpected findings
6. **Decision Log** — every decision with rationale
7. **Outcomes & Retrospective** — results vs. original purpose

## Active Plans

<!-- List active plans here -->
- [0018 — GitHub PR Status Liveness](0018-github-pr-status-liveness.md) — focus-gated adaptive poll of the active Project so remote PR changes (CI, review, merge/close, new PR) surface without manual refresh; reuses `projectRefreshRequested` + in-flight/queued model; pauses when the app is not active; also migrates post-mutation/manual refresh to project-level (closes 0013 DEC-6)
- [Command Palette (Quick Action)](command-palette.md) — ⌘P fuzzy launcher over Space/Worktree/Pane/Window/Editor commands; procedural item generation, custom fuzzy scorer, TCA delegate routing; reuses existing ghostty `toggle_command_palette` intent

## Completed Plans

- [0005 — Read-Only Git Viewer (C7) + External Editor Integration (C8)](0005-git-viewer-and-editor.md) — Git/editor value types, `GitService` + `DiffParser`, `GitViewerFeature` + SwiftUI viewer, `EditorService` + `ProcessSpawner`, Worktree-header dropdown + Settings section, `editor.*` IPC handlers (`tc open` CLI wrapper + router wiring deferred to 0003 merge per DEC-21) (2026-04-20)
- [0007 — TCA Shell](0007-tca-shell.md) — RootFeature + NavigationSplitView + Sidebar/TabBar/SplitView composition + LazyPaneHost lazy-surface lifecycle + creation modals + C6/C7/C8 slots reserved (2026-04-20)
- [0006 — Agent Notification Aggregation (C6)](0006-agent-notifications.md) — FSM tracker, detection-rule DSL, OS banner + Dock badge + inbox surfaces, TCA InboxSidebar, full C3-dispatcher integration (2026-04-20)
- [0002 — Terminal Engine and Five-Level Hierarchy (C1 + C2)](0002-terminal-and-hierarchy.md) — domain model, CatalogStore, TerminalEngine, HierarchyManager, GhosttyRuntime + PaneSurface, GitWorktreeCLI; live shell end-to-end (2026-04-20)
- [0001 — Bootstrap touch-code monorepo](0001-bootstrap-monorepo.md) — Tuist + mise + ghostty submodule + empty mac app + `tc --version` CLI + CI (2026-04-19; GhosttyKit foreignBuild deferred per DEC-8)

- [0004 — Published Agent Skill (C5)](0004-agent-skill.md) — `touch-code-skill/` package + `tc skill` CLI + `SkillVersionBanner` + Tier-A/B CI + mirror-push workflow (2026-04-20; owner setup pending for mirror push deploy key)

- [0003 — Lifecycle Hooks and `tc` CLI (C3 + C4)](0003-hooks-and-cli.md) — TouchCodeCore hook types, HookDispatcher + HookEventMulticaster + ProcessHookExecutor surface, SocketServer + MethodRouter + in-app handlers (hook/hierarchy/terminal/system), `tc` CLI over tcKit static framework with pipelined handshake + AliasResolver + streaming `hook.events`, router-backed end-to-end integration tests (2026-04-20; M2.1 hot-path internals, M3.1 per-connection backpressure queue + SocketPeerAuth, M8.1 completion scripts + man page deferred; `editor.*` handler + EditorService owned by exec-plan 0005 per DEC-15)

- [0014 — Worktree Status Bar](0014-worktree-status-bar.md) — Titlebar 中段多态状态槽（inProgress / success / warning / PR / motivational）；新 `StatusBarFeature` + RootFeature 路由 `.editor/.gitHub.*Completed` 转 toast；PR / motivational 视图派生；`ViewThatFits` 做窄窗口退化；M1-M7 七个独立 merge 的 milestone

