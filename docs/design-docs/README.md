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
- [Ghostty Action Routing](ghostty-action-routing.md) — Replaces the stub `action_cb` with full-surface dispatch routing every libghostty keybind, surface action, and config hot-reload to host handlers
- [AgentState View](active-agents-view.md) — Status-bar entry plus hover popover listing every Pane running a known agent with its derived runtime state, independent of NotificationStore
- [App Appearance & Terminal Theme](app-appearance.md) — Wires the Light/Dark/System picker into SwiftUI + AppKit chrome and adds a Terminal pane writing Ghostty light/dark palette themes into the user's config
- [CLI (`codans`)](cli.md) — The `codans` CLI verb set (project / worktree / tab / pane / send / broadcast) and `system.*`/`hierarchy.*`/`pane.*`/`terminal.*`/`editor.*` RPC method contracts over the Unix socket, plus the `/usr/local/bin` admin-auth install path; shipped core, with `list`/`open`/`help-json` defined-but-not-wired
- [Lifecycle Hooks](lifecycle-hooks.md) — **Designed, not yet implemented.** Translates `TerminalEvent`s into typed `HookEvent`s matched against user subscriptions and dispatched to out-of-process shell handlers via a JSON envelope with a stdout feedback DSL
- [Published Agent Skill (C5)](c5-agent-skill.md) — Repo layout, package shape, and install CLI for the agent skill teaching agents to drive codans (superseded: skill is now pure text, no engineering coupling)
- [Agent Notifications v2 — Hardening & Cross-Source Robustness (C6.2)](c6-agent-notifications-v2.md) — Deprecated deltas hardening C6 v1: status-bar bell, cross-source dedup window, user-typing suppression, auth refresh, tracker invalidation
- [Agent Notification Aggregation (C6)](c6-agent-notifications.md) — Deprecated FSM-tracker design classifying agent Pane state via C3 hooks and surfacing transitions on OS notification, Dock badge, and in-app inbox
- [C6 M5 — InboxSidebar UI](c6-m5-inbox-sidebar.md) — Deprecated sketch for the slide-in sidebar listing AgentNotifications with filter chips, swipe-dismiss, deeplink, and mute toggles wired into the TCA tree
- [Editor Integration](editor-integration.md) — NSWorkspace/Launch-Services bundle-ID detection and launch over a 34-entry registry, strictly path-oriented (no `$PATH`, no `Process`), with the path-open action decoupled from Worktree
- [Command Palette (Quick Action)](command-palette.md) — Keyboard-first fuzzy-search surface enumerating every actionable command across menus/sidebar/ghostty bindings as a discoverability multiplier, not a new capability
- [Diff Inspector](diff-inspector.md) — Replaces GitViewer overlay with a 280pt right-edge changed-files inspector plus a full-region diff drawer, rendering diffs via the vendored WKWebView bundle (forward-looking — only the `toggleDiffInspector` command-id has landed)
- [GitHub Integration](github-integration.md) — Repository-batched `gh api graphql` PR fetch (one reducer-owned call per repository, O(Repositories) not O(Worktrees)), event-driven cache invalidation, fork-PR filtering, and check rollup carried on the snapshot; zero in-app HTTP, zero Keychain
- [Keyboard Shortcuts (Unified Management)](keyboard-shortcuts.md) — Consolidates the three disjoint hardcoded shortcut locations into one unified, user-overridable keyboard-shortcut management surface
- [Main Window](main-window.md) — Durable invariants and boundaries for the three main-window subsystems (Sidebar / Header / Tab bar): env-direct catalog reads, intent-side selection orchestration, single-source default-editor resolution, runtime-only per-pane dirty state, and tab-bar UX rules
- [Master Terminal](master-terminal.md) — System-wide summon-by-hotkey slide-in NSPanel hosting one Ghostty surface running `claude remote-control`, app-level and outside the Catalog/RPC surface
- [Notifications v1.1 — Policy Chokepoint, Settings Wiring, Command-Finished Suppression](notifications-v1-1.md) — Inserts a `NotificationCoordinator` policy chokepoint between detector and side effects, wires five Settings toggles, per-pane mute, worktree-promote, and a versioned inbox envelope
- [Notifications](notifications.md) — Approved replacement for the C6 line: translates waiting-for-input/task-finished Pane events into a persisted inbox with hierarchical roll-up badges, a bell popover, and focus-aware banners in ≤7 files
- [Pane Resume](pane-resume.md) — Integrates zmx as a per-Pane sidecar daemon owning the PTY so panes (live tier) or VT snapshots (snapshot tier) survive `cmd-Q`, restoring shell + scrollback on relaunch
- [Project Management (P1 child branch)](pm-project-management.md) — User-facing Project lifecycle flows (add local folder, health reconciliation, rename, per-Project options, reorder, remove) over the existing HierarchyManager data layer
- [Project Tags + Single-Window — Removing Space and Multi-Window](project-tags.md) — Replaces the `Space` container with per-Project `Tag` labels and collapses multi-window to single-window, sharing one catalog migration
- [Settings — Window, Persistence, and Per-Project Preferences](settings.md) — Standalone Settings window plus the single-writer `settings.json` v3 model: `projects[ProjectID]: ProjectSettings` with a nested `git:` subtree, lenient ProjectID-key decode, v1/v2→v3 migration, and the four orthogonal notification gating toggles
- [Wire up "Snapshot and exit" quit action end-to-end](snapshot-and-exit-wireup.md) — Reconnects the no-op snapshot tier to the `zmx attach` runtime: quit sends `.snapshot` (tag 14), launch consumes `reaper.sweep()` states, and `zmx attach` parses `--restore-from`
- [Update channel — release pipeline](updates-channel-pipeline.md) — Release pipeline producing stable + tip appcast items behind a single SUFeedURL, with client-side channel filtering via `allowedChannels(for:)` so tip users auto-follow stable
- [Worktree](worktree.md) — Worktree 全生命周期（创建/发现/archive/safe-force remove/prune via `git-wt`）、侧边栏四段排序（main/pinned/pending/unpinned）、titlebar 状态栏（PR/toast/motivational），以及 header 分支切换器（应用内 `git switch`，由 `WorktreeHeadWatcher` 驱动刷新）
