# Product Specs

Product specs define **what** to build and **for whom**.

## Template

Use [_template.md](_template.md) as a starting point.

## Index

<!-- Format: [Title](filename.md) — one-line summary. Alphabetical by filename. -->

- [AgentState View](active-agents-view.md) — WorktreeHeader 常驻状态条徽章 + 悬停浮窗，一句话汇总所有 CLI Agent 当前运行态（等输入/在跑/完成/闲置），点击行级联聚焦对应 Pane
- [Notifications v1.1 — Settings, Coordinator, Command-Finished Threshold](notifications-v1-1.md) — Adds a single policy chokepoint wiring the four notification toggles, per-pane mute, command-finished duration threshold, and auto-promote-noisy-worktree for agent users
- [Notifications](notifications.md) — v1 notification system that pulls attention back to the exact Pane needing input or finishing a long task, via in-app inbox, hierarchical roll-up badges, macOS banner, and Dock badge
- [Pane Resume](pane-resume.md) — Restores each Pane's terminal content (and optionally the live shell) across app restarts via an out-of-process sidecar daemon, with live-tier and snapshot-tier persistence
- [Project Management](project-management.md) — Full Project (git repo / scratch folder) lifecycle in codans — add, health, rename, per-project prefs, reorder, remove — as data-only bookkeeping that never touches files on disk
- [Main-Window UI](ui-main-window.md) — Two-column main window: a Sidebar listing Projects/Worktrees with a bottom Tag filter, and a Detail header above the terminal carrying a read-only branch label and an "Open in…" split button (bell lives in the status bar; Git diff in the Diff inspector)
- [Settings Window](ui-settings-window.md) — 独立的设置窗口（全局分段 + 按 Project 覆盖，子行按 ProjectKind 动态裁剪），基础版承载已落地能力的可用 UI 并为未落地能力预留占位分段
- [Worktree Management](worktree-management.md) — 面向用户的 Worktree 全生命周期（create with base ref/copy flags、discover、switch、archive、remove、prune via git-wt），外加四段侧边栏排序、titlebar 状态栏（PR/toast/motivational）与 header 分支切换器（应用内 `git switch`；Diff Viewer History tab 列为 Future）
