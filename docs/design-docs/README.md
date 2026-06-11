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

<!-- List design docs here as they are created -->
<!-- Format: [Title](filename.md) — one-line summary -->
- [0001 — Terminal Engine and Five-Level Hierarchy (C1 + C2)](0001-terminal-and-hierarchy.md) — libghostty integration boundary, Space/Project/Worktree/Tab/Pane model, SplitTree, persistence

- [C5 — Published Agent Skill](c5-agent-skill.md) — `codans-skill/` package shape, `codans skill install` UX, versioning, mirror-repo story

- [0007 — TCA Shell](0007-tca-shell.md) — RootFeature + NavigationSplitView + Sidebar/TabBar/SplitView composition, HierarchyClient + TerminalClient DependencyKeys; unblocks C6/C7/C8
- [C7 — Read-Only Git Diff / History Viewer](c7-git-viewer.md) — shell-out-to-`git` data layer, TCA feature, unified-diff parser, keyboard-first rendering
- [C8 — External Editor Integration](c8-editor-integration.md) — built-in allowlist (VSCode/Cursor/Zed/Xcode/Sublime/Finder) via CLI wrappers, `$PATH` discovery, per-Project default, `codans open`
- [Command Palette (Quick Action)](command-palette.md) — `⌘P` fuzzy launcher over Space/Worktree/Pane/Window/Editor commands; procedural item generation + TCA delegate routing; ghostty `toggle_command_palette` hook reused
- [Worktree Status Bar](worktree-status-bar.md) — Titlebar 中段多态状态槽；新 `StatusBarFeature` + RootFeature 路由 `.editor / .gitHub.*Completed` 转 toast；PR / motivational 纯视图派生；`ViewThatFits` 做窄窗口退化
