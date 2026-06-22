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
- [Main-Window UI Redesign](ui-main-window-redesign.md) — Redesigns the main window into a two-column layout: a Sidebar listing Projects/Worktrees with a Space switcher, and a Detail header above the terminal with branch, bell, open-in, and git-viewer
- [Settings Window](ui-settings-window.md) — 独立的设置窗口（全局分段 + 按 Project 覆盖，子行按 ProjectKind 动态裁剪），基础版承载已落地能力的可用 UI 并为未落地能力预留占位分段
- [Worktree Branch Switcher & Diff History](worktree-branch-switcher-and-history.md) — 把 worktree header 静态分支标签升级为可点击分支切换器（列本地/远程分支 + 最近提交），并在 Git Diff Viewer 新增只读 History tab 浏览历史 commit diff
- [Worktree Management](worktree-management.md) — Full user-facing Worktree lifecycle (create with base ref/copy flags, discover, switch, archive, remove, prune) driven through the bundled git-wt helper
- [Worktree Status Bar](worktree-status-bar.md) — 把主窗口 titlebar 中段升级为按优先级切换的多态 Worktree 状态槽：默认时间+命令面板提示，活跃 PR 显示 checks 状态，长任务显示进度，成败以瞬态 toast 反馈
