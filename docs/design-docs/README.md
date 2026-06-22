# Design Docs

Design docs capture the **why** and **how** behind features and systems.

## When to Write a Design Doc

- New feature or system that touches multiple domains
- Significant architectural change
- Technical decision with long-term implications
- Any work where multiple approaches exist and the choice matters

## Template

Use [_template.md](_template.md) as a starting point.

## Index

<!-- Format: [Title](filename.md) — one-line summary. Numbered docs first, then alphabetical. -->

- [Terminal Engine and Five-Level Hierarchy (C1 + C2)](0001-terminal-and-hierarchy.md) — Domain model, libghostty surface ownership, `SplitTree<PaneID>` layouts, and `catalog.json` persistence for the Space→Project→Worktree→Tab→Pane hierarchy
- [0007 — TCA Shell](0007-tca-shell.md) — `RootFeature` composing sidebar/tab-bar/split-view sub-features with `HierarchyClient`/`TerminalClient` dependency keys and `NavigationSplitView` topology
- [Ghostty Action Routing](0008-ghostty-action-routing.md) — Replaces the stub `action_cb` with full-surface dispatch routing every libghostty keybind, surface action, and config hot-reload to host handlers
- [AgentState View](active-agents-view.md) — Status-bar entry plus hover popover listing every Pane running a known agent with its derived runtime state, independent of NotificationStore
- [App Appearance & Terminal Theme](app-appearance.md) — Wires the Light/Dark/System picker into SwiftUI + AppKit chrome and adds a Terminal pane writing Ghostty light/dark palette themes into the user's config
- [C3 — Lifecycle Hooks](c3-lifecycle-hooks.md) — Translates `TerminalEvent`s into typed `HookEvent`s matched against user subscriptions and dispatched to out-of-process shell handlers via a JSON envelope with stdout feedback DSL
- [C4 — CLI (`codans`)](c4-cli.md) — Defines the `codans` CLI verb set and `hierarchy.*`/`terminal.*`/`git.*`/`skill.*`/`hook.*` RPC method contracts over the Unix socket, machine- and human-friendly output
- [Published Agent Skill (C5)](c5-agent-skill.md) — Repo layout, package shape, and install CLI for the agent skill teaching agents to drive codans (superseded: skill is now pure text, no engineering coupling)
- [Agent Notifications v2 — Hardening & Cross-Source Robustness (C6.2)](c6-agent-notifications-v2.md) — Deprecated deltas hardening C6 v1: status-bar bell, cross-source dedup window, user-typing suppression, auth refresh, tracker invalidation
- [Agent Notification Aggregation (C6)](c6-agent-notifications.md) — Deprecated FSM-tracker design classifying agent Pane state via C3 hooks and surfacing transitions on OS notification, Dock badge, and in-app inbox
- [C6 M5 — InboxSidebar UI](c6-m5-inbox-sidebar.md) — Deprecated sketch for the slide-in sidebar listing AgentNotifications with filter chips, swipe-dismiss, deeplink, and mute toggles wired into the TCA tree
- [External Editor Integration (C8)](c8-editor-integration.md) — Superseded Worktree-level "open in editor" via a `$PATH`-probed allowlist of CLI wrappers (`code`/`cursor`/`subl`) plus user-defined command templates
- [Editor Integration — NSWorkspace Rewrite (C8a)](c8a-editor-integration-nsworkspace.md) — Replaces `$PATH` probing with NSWorkspace/Launch-Services bundle-ID detection over a 28-entry registry, decoupling the path-open action from Worktree
- [CLI install — `/usr/local/bin` with bundled binary](cli-install-system-bin.md) — Migrates CLI install to `/usr/local/bin` via an admin-auth dialog symlinking the bundle-embedded signed binary, removing the misleading PATH advisory
- [Command Palette (Quick Action)](command-palette.md) — Keyboard-first fuzzy-search surface enumerating every actionable command across menus/sidebar/ghostty bindings as a discoverability multiplier, not a new capability
- [Diff Inspector](git-changes-inspector.md) — Replaces GitViewer overlay with a 280pt right-edge changed-files inspector plus a full-region diff drawer, rendering diffs via the vendored WKWebView bundle
- [GitHub Integration v2 — Repository-batched PR fetch](github-integration-batched.md) — Replaces per-Worktree `gh` subprocess fetches with one reducer-owned `gh api graphql` call per repository, cutting subprocess cost from O(W) to O(R)
- [GitHub Integration (PR-centric, gh-delegated) — v1, SUPERSEDED](github-integration.md) — Superseded per-Worktree PR surface delegating to `gh` for a glanceable badge, focused popover, and command-palette merge actions on the Worktree model
- [Keyboard Shortcuts (Unified Management)](keyboard-shortcuts.md) — Consolidates the three disjoint hardcoded shortcut locations into one unified, user-overridable keyboard-shortcut management surface
- [Master Terminal](master-terminal.md) — System-wide summon-by-hotkey slide-in NSPanel hosting one Ghostty surface running `claude remote-control`, app-level and outside the Catalog/RPC surface
- [Main-Window Redesign — T0 Foundation & Contracts](mw-t0-foundation.md) — Adds `Space.lastActiveWorktreeID` and `Worktree.gitViewerVisible` catalog fields plus an inbox unread-aggregation API for the T1/T2 redesign tasks to consume
- [Main-Window Redesign — T1 Sidebar & Space Switcher](mw-t1-sidebar.md) — Redesigns the sidebar visual tree, hover chrome, Worktree context menu, Space switcher, and per-level unread-dot aggregation on the T0 contracts
- [Main-Window Redesign — T2 Header Row](mw-t2-header.md) — Header row above the Tab bar carrying a branch label, unread-badge notification bell + popover, "Open in…" split button, and Git Viewer toggle
- [Notifications v1.1 — Policy Chokepoint, Settings Wiring, Command-Finished Suppression](notifications-v1-1.md) — Inserts a `NotificationCoordinator` policy chokepoint between detector and side effects, wires five Settings toggles, per-pane mute, worktree-promote, and a versioned inbox envelope
- [Notifications](notifications.md) — Approved replacement for the C6 line: translates waiting-for-input/task-finished Pane events into a persisted inbox with hierarchical roll-up badges, a bell popover, and focus-aware banners in ≤7 files
- [Pane Resume](pane-resume.md) — Integrates zmx as a per-Pane sidecar daemon owning the PTY so panes (live tier) or VT snapshots (snapshot tier) survive `cmd-Q`, restoring shell + scrollback on relaunch
- [Project Management (P1 child branch)](pm-project-management.md) — User-facing Project lifecycle flows (add local folder, health reconciliation, rename, per-Project options, reorder, remove) over the existing HierarchyManager data layer
- [Project Settings — Sub-Pane Implementation (Phase 2)](project-settings-phase2.md) — Makes every per-Project preference editable, adds worktree setup/archive/delete hooks, user scripts, env-var propagation, and inline hook editing; collapses sidebar to General/Scripts/Hooks
- [Project Settings — Unified Per-Project Preferences](project-settings.md) — Renames `Repository*`→`Project`, consolidates all per-Project preferences into `settings.json` v3, and redefines hook scoping, superseding the T4 repositories design
- [Project Tags + Single-Window — Removing Space and Multi-Window](project-tags.md) — Replaces the `Space` container with per-Project `Tag` labels and collapses multi-window to single-window, sharing one catalog migration
- [Settings Window — Shell & Persistence Base (T1)](settings-base.md) — Independent Settings window (NavigationSplitView, six sections + Repositories tree) and a unified `Settings` schema fixing the two-store last-writer-wins file clobber
- [Settings Window — Developer Pane (T3)](settings-developer.md) — Developer pane: CLI install status with Install/Uninstall/Retry, read-only user-hooks list, and diagnostics; ships the reusable `HookMergeView` component
- [Settings Window — Notifications Pane (T2)](settings-notifications.md) — Fills the Notifications pane with five toggle controls and completes `NotificationCoordinator` wiring so `systemEnabled`/`soundEnabled`/`inAppEnabled` and the Dock badge source take effect
- [Settings Window — Repositories Subtree (T4)](settings-repositories.md) — Deprecated: per-Project General pane (default-editor + worktree-dir overrides) and read-only merged Repository Hooks pane with a Reveal-in-Finder escape hatch
- [Wire up "Snapshot and exit" quit action end-to-end](snapshot-and-exit-wireup.md) — Reconnects the no-op snapshot tier to the `zmx attach` runtime: quit sends `.snapshot` (tag 14), launch consumes `reaper.sweep()` states, and `zmx attach` parses `--restore-from`
- [Tab Bar Uplift](tab-bar.md) — Production-quality Tab bar: active underline, three-state chips, full tab operation set (rename/reorder/context menu), macOS shortcuts, overflow scrolling, per-tab focus memory, and a busy read-path
- [Update channel — release pipeline](updates-channel-pipeline.md) — Release pipeline producing stable + tip appcast items behind a single SUFeedURL, with client-side channel filtering via `allowedChannels(for:)` so tip users auto-follow stable
- [Worktree Branch Switcher & Diff History](worktree-branch-switcher-and-history.md) — header 分支区升级为可点击 popover（列分支 + 最近 commits + 应用内 `git switch`），并在 Diff Viewer 增加 History tab 渲染整 commit diff
- [Worktree Management (T-WORKTREE)](worktree-management-design.md) — Full Worktree lifecycle (create with base-ref + streaming file-copy, discovery, archive/unarchive, safe/force remove, prune, terminal-safety) via the bundled `git-wt` submodule
- [Worktree 侧边栏排序规则](worktree-sidebar-ordering.md) — 把侧边栏 worktree 排序正式定义为四段（main / creating / pinned / rest），并明确创建中、pin/unpin、归档等操作在各维度上的位置行为
- [Worktree Status Bar](worktree-status-bar.md) — 把主窗口 titlebar 中段空白改造成按优先级切换形态的状态栏：motivational 默认态 → PR 徽章 + checks 色环 → inProgress/success/warning toast
