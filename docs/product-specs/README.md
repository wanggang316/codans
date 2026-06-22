# Product Specs

Product specs define **what** to build and **for whom**.

## Template

Use [_template.md](_template.md) as a starting point.

## Index

<!-- One entry per doc, alphabetical: [Title](file) — one-line summary. Each doc carries a `**状态：**` field. -->

- [AgentState View](active-agents-view.md) — 一句话看清每个 agent 此刻在做什么（11 种 kind、前台进程组识别），区别于通知的「刚发生了什么」
- [Notifications](notifications.md) — 把注意力拉回需要输入/长任务完成的 Pane：四通道（inbox/横幅/Dock/上卷徽标）+ 五项设置 + 命令完成阈值 + worktree 提升
- [Project Management](project-management.md) — Project 全生命周期（add / health / rename / per-project prefs / reorder / remove）：纯数据记账，绝不动磁盘文件
- [Main-Window UI](ui-main-window.md) — 两栏主窗口：Sidebar（扁平 Project/Worktree + 底部排序/刷新 footer）+ Detail（终端之上 branch 标签 + "Open in …" split button）
- [Settings Window](ui-settings-window.md) — 独立 Settings 窗口：全局分段 + 按 Project 覆盖，子行按 ProjectKind 动态裁剪
- [Worktree Management](worktree-management.md) — 面向用户的 Worktree 全生命周期（create/discover/switch/archive/remove/prune via `git-wt`）+ 侧边栏分段排序 + 状态栏 + 分支切换器
