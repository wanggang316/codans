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

<!-- Status reflects each plan's own Progress/Outcomes sections. Numbered plans first, then alphabetical. -->

## Active Plans

- [Main-Window T0 — Foundation & Contracts](0008-mw-t0-foundation.md) — Catalog Space/Worktree fields + HierarchyManager setters, pane/worktree resolvers, NotificationInbox aggregation, drop sidebar mode Picker; M7 push/PR pending, Status "Draft"
- [Main-Window T1 — Sidebar & Space Switcher](0009-mw-t1-sidebar.md) — Planned sidebar: Project sections + Worktree active/unread dots, Space-switcher popover with last-active restore, context-menu actions, FinderClient; all 10 milestones unchecked
- [Main-Window T2 — Header Row](0009-mw-t2-header.md) — Planned Worktree Header: branch label, notification bell popover, Open-in split button, Git Viewer toggle; removes legacy dropdown + inspector toggle; all 7 milestones unchecked
- [Crash reporting via Sentry](0017-crash-reporting.md) — Wires sentry-cocoa with opt-out toggle, DSN via gitignored xcconfig, SystemHangFilter, InstallIdentifier, dSYM upload in release pipeline; Status "In Progress", Outcomes unfilled
- [Move pane I/O to the exec backend via `zmx attach`](0019-pane-attach-exec-backend.md) — Replaces external_pty_fd with zmx attach under libghostty exec backend so PTY sizing is correct on first frame; Status "Draft", behavioural verification + QuitAction rename still open
- [AgentState View](active-agents-view.md) — WorktreeHeader badge + hover popover summarizing per-pane agent state via AgentKind/Pane fields, AgentBinder, AgentStateStore; Status "Draft", all tasks T1–T8 not_started
- [App Appearance & Terminal Theme](appearance-terminal-theme.md) — Light/dark/system appearance picker plus Settings→Terminal Ghostty theme pane writing ~/.config/ghostty/config with live surface sync; success criteria unchecked
- [Agent Notifications v2 — Hardening, UX Gaps, New Surfaces (C6.2)](c6-agent-notifications-v2.md) — Stage A/B notification hardening landed (dedup, master toggle, typing suppression, OS-dismiss routing); Stage C + B9 deferred to v2.1
- [Migrate `codans` install to `/usr/local/bin` with admin auth](cli-install-system-bin.md) — PrivilegedShell AppleScript installer to /usr/local/bin, legacy ~/.local/bin cleanup, dropped PATH advisory; M7 manual smoke still pending
- [Notifications v1.1 — Policy Chokepoint, Settings Wiring, and Command-Finished Suppression](notifications-v1-1.md) — Draft, 0/34 cases; planned NotificationCoordinator chokepoint, settings gates, command-finished suppression, worktree promote, inbox envelope
- [Pane Resume](pane-resume.md) — Approved; only M6 hardening tasks (SessionCoordinator, write-through persist, orphan reaper, settings, agent restore) done — core M0–M5 zmx sidecar/daemon work not started
- [Project Management — Add / Health / Options / Reorder](pm-project-management.md) — Draft; all phases P0–P8 unchecked — add-project picker, ProjectReconciler, options sheet, reorder, failed-row UX not started
- [Project Settings Phase 2 — Sub-Pane Implementation](project-settings-phase2.md) — Per-project General/Scripts/Hooks panes, lifecycle scripts, env injection via libghostty per-surface env, Run split-button; M7/M12 unfinished
- [Project Settings — Unified Per-Project Preferences](project-settings.md) — Renames RepositorySettings→ProjectSettings, settings.json v3 / catalog v2 / hooks v2 migrations, kind-aware sidebar; Final push+PR pending
- [Project Tags + Single-Window — Removing Space and Multi-Window](project-tags.md) — Catalog v3 flips Spaces to colored Tags, chip-footer filtering, TagManager, single-window ⌘W/⌘Q gate, codans tag CLI; final review pending
- [Mac app packaging, signing, and release pipeline](release-pipeline.md) — Developer-ID archive/notarize/staple/DMG scripts + version bump + GitHub Actions tag release; M1-M6 done, M7 Sparkle deferred
- [Settings Window — Developer Pane (T3)](settings-developer.md) — Draft for Developer pane: codans CLI installer, read-only Hooks via HookMergeView, Diagnostics; all steps unchecked
- [Settings Window — Notifications Pane (T2)](settings-notifications.md) — Five M5 notification toggles + permission alert wired into NotificationCoordinator (K4/K5); Steps 0-4 done, Final push/PR pending
- [Settings Window — Repositories Subtree (T4)](settings-repositories.md) — Per-project editor/worktree-dir overrides + read-only merged Hooks pane; superseded by project-settings.md before any step ran
- [Sidebar 渲染演化为异构 SidebarRow（task02）](worktree-sidebar-segments.md) — Sidebar 渲染层从 [Worktree] 演化为异构 [SidebarRow]，挂 pinned/unpinned 段内拖拽 forwarder，pending 段占位留给 task03；M7 push+PR 未完成

## Completed Plans

- [Bootstrap codans monorepo](0001-bootstrap-monorepo.md) — Tuist monorepo skeleton: mise-pinned toolchain, ghostty submodule + build script, empty mac app + `codans --version` CLI, swift-format/swiftlint + CI (2026-04-19)
- [Terminal Engine and Five-Level Hierarchy (C1 + C2)](0002-terminal-and-hierarchy.md) — CodansCore domain + SplitTree, CatalogStore/HierarchyManager, GhosttyKit bring-up, TerminalEngine event stream + crash isolation, live PaneSurface, GitWorktreeCLI (2026-04-20)
- [Lifecycle Hooks and `codans` CLI (C3 + C4)](0003-hooks-and-cli.md) — Hook taxonomy/dispatcher + ProcessHookExecutor, Unix-socket SocketServer + MethodRouter, CodansKit RPCClient, full `codans` CLI (hook/hierarchy/terminal verbs) (2026-04-20)
- [Published Agent Skill (C5)](0004-agent-skill.md) — Built `codans skill install/status` + SkillInstaller, `.app`-bundled skill, agents.json, Tier-A/B CI + mirror-push; now Superseded by PR #15 (2026-04-20)
- [Read-Only Git Viewer (C7) + External Editor Integration (C8)](0005-git-viewer-and-editor.md) — GitService + DiffParser, GitViewerFeature TCA + SwiftUI viewer, EditorService/registry/prober, Settings + Worktree-header Open-in, `editor.*` IPC handlers (2026-04-20)
- [Agent Notification Aggregation (C6)](0006-agent-notifications.md) — FSM tracker + DetectionRouter + rule DSL, InboxStore, OSNotifier/DockBadger, inbox sidebar UI; Deprecated/reverted, superseded by notifications.md (2026-04-30)
- [TCA Shell (0007)](0007-tca-shell.md) — NavigationSplitView shell: RootFeature + HierarchySidebar/WorktreeDetail/TabBar/SplitViewport features, HierarchyClient/TerminalClient bridges, lazy pane lifecycle, restore-on-launch (2026-04-20)
- [Ghostty Action Routing for All 62 Actions](0008-ghostty-action-routing.md) — Routes all 62 libghostty keybind actions into TCA via GhosttyActionDecoder + Pane/Window ActionRouterFeatures, SurfaceInfo, RootFeature integration + unit tests (2026-04-22)
- [Lift LazyPaneHost side-effects into PaneHostFeature](0009-panel-host-feature.md) — Moves pane surface lifecycle into PaneHostFeature TCA reducer so saved-catalog launch no longer crashes on `TerminalClient.liveValue`; LazyPaneHost becomes pure renderer (2026-04-22)
- [Worktree Management (T-WORKTREE)](0010-worktree-management.md) — Bundled git-wt submodule, GitWorktreeClient streaming create/list/remove, archive flag, reconcile, and Create/Archived sidebar sheets; all 14 milestones, 855 tests green (2026-04-21)
- [Worktree Management follow-ups (Issue #24)](0011-worktree-followups.md) — Five hardening fixes: wt-process termination on cancel, case-insensitive stderr mapping, diff-based worktree path picking, reconcile os_log, .enabled(if:) skip trait (2026-04-21)
- [GitHub Integration v1 (PR-centric, gh-delegated)](0012-github-integration.md) — gh-delegated PR badge + popover + Settings GitHub section over GitHubService/GitHubFeature; M0–M4/M6 landed, M5 command palette and M7 post-merge automation deferred (2026-04-23)
- [GitHub Integration v2 — Repository-batched PR fetch](0013-github-integration-batched.md) — Batched GraphQL PR fetch via gh api graphql (RemoteInfo, batchPullRequests, project-level reducer cutover); M1–M6 shipped, M7 FS-watch deferred (2026-04-23)
- [Worktree Status Bar](0014-worktree-status-bar.md) — Titlebar StatusBarFeature with toast/PR/motivational forms, editor+gh result routing, ChecksRollupRing, ViewThatFits fallback; M1–M7 done, 13 commits (2026-04-24)
- [Worktree pending row — segment data model + lifecycle (task03)](0015-worktree-pending-row.md) — Non-blocking Create flow via PendingWorktree state + cancellable wt stream lifecycle in HierarchySidebarFeature; PR #48 shipped M1–M4+M6, M5 view integration deferred (2026-04-26)
- [Unified Keyboard Shortcut Management](0016-keyboard-shortcuts.md) — CommandID registry + schema/override store + 3-tier conflict detection + UCKeyTranslate display + Settings Shortcuts pane; all 10 milestones, 14 commits, 64 tests (2026-04-28)
- [GitHub PR Status Liveness — focus-gated adaptive refresh](0018-github-pr-status-liveness.md) — App-active-gated adaptive poll (15s/60s) re-issuing projectRefreshRequested; migrated post-mutation/retry to project-level and retired v1 single-branch path; M1–M3+M5 done, M4 deferred (2026-05-30)
- [Editor Integration NSWorkspace Rewrite (C8a)](c8a-implementation.md) — Replaced PATH-spawn editor open with NSWorkspace/Launch-Services 28-entry registry, AppLauncher, resolution cascade, settings + per-project pickers, IPC handlers, migration (2026-04-22)
- [Redesign `codans` CLI Surface](codans-cli-redesign.md) — Rebuilt CLI into resource-oriented clig.dev tree (status/launch/doctor, project/worktree/tab/pane groups, tree, send/broadcast --stdin), regenerated completions (2026-05-09)
- [Command Palette (Quick Action)](command-palette.md) — Shipped ⌘P palette: CommandPaletteItem/Feature/View, DP fuzzy scorer with recency decay, UserDefaults persistence, RootFeature routing, ghostty toggle hook; 33 tests (2026-04-23)
- [Diff Inspector](diff-inspector.md) — Replaced GitViewer with DiffFeature: 280pt inspector + edge-to-edge drawer, vendored YiTong WKWebView bundle, bridge/coordinator, gitViewer→diff rename (2026-04-29)
- [Master Terminal](master-terminal.md) — Shipped a summon-by-hotkey slide-in NSPanel hosting a Ghostty surface running `claude remote-control`, Carbon hotkey, AGENTS.md bootstrap + CLAUDE.md symlink (2026-05-05)
- [Notifications v1](notifications.md) — Shipped runtime-event inbox: detector, OSNotifier banners, dock badge, per-level rollup indicators, status-bar bell popover, click-to-navigate, permission flow; 52 tests (2026-04-30)
- [Rename the "panel" concept to "pane" across the project](panel-to-pane-rename.md) — Renamed Panel→Pane across Swift/IPC/CLI/env/hooks/docs (PaneID, codans pane, CODANS_PANE_ID, pane.* events) in one atomic commit + doc sweeps (2026-04-24)
- [Settings Window — Shell & Persistence Base (T1)](settings-base.md) — Standalone ⌘, Settings window, single SettingsStore writer, settings.json v1→v2 migration, frozen contracts for T2/T3/T4 (2026-04-21)
- [Tab Bar Uplift](tab-bar.md) — Tab chip restyle, right-click menu/rename/drag-reorder/middle-click, overflow scroll, trailing splits, shortcuts, focus memory + dirty path; M1-M3 + post-review fixes shipped (2026-04-25)
- [Worktree Branch Switcher & Diff History](worktree-branch-switcher-and-history.md) — Header branch-switcher popover, GitService branch list/switch, Diff Viewer Changes/History tabs; 16 tasks shipped, runtime user-tests deferred (2026-05-24)
- [Worktree Reorder Primitives in Catalog Layer](worktree-reorder-catalog.md) — Segment-aware reorderWorktrees + unpinned-boundary createWorktree + pin/unpin repositioning on HierarchyManager/HierarchyClient (2026-04-26)
