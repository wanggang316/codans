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

<!-- One entry per doc, alphabetical: [Title](file) — one-line summary. Feature availability belongs in each doc; see ../README.md for metadata conventions. -->

- [Agent Profiles 与 Handoff](agent-handoff.md) — 命名 agent 启动预设（Settings → Agents / toolbar / palette / `codans agent`）+ agent 到 agent 的任务交接：worktree 内 `.codans/handoff/` 工件、archive-first 迁移、源 agent 自写 briefing 的 `codans handoff`、应用内 Hand Off 面板
- [AgentState View](active-agents-view.md) — 侧栏底部 AgentState 面板：按前台进程组识别每个 Pane 的 agent（11 种 kind）+ 派生运行态（idle/working/blocked/finished），独立于通知系统
- [App Appearance & Terminal Theme](app-appearance.md) — Light/Dark/System 外观（单写者 `NSApp.appearance`）+ Ghostty 配置 managed-keys（theme/font/cursor）写入
- [CLI (`codans`)](cli.md) — `codans` 动词集与 system/hierarchy/pane/terminal/editor RPC 契约；stateless RPC client、alias→UUID、`/usr/local/bin` 管理员授权安装；`open` / `help-json` / `workspace` 可用，`skill` 本地管理安装，hook 未实现
- [Command Palette](command-palette.md) — ⌘P 模糊搜索面板：分层评分 + recency 衰减 + 稳定 ID，按需从实时 Catalog 生成项
- [Editor Integration](editor-integration.md) — 在外部工具打开 Worktree：本地应用经 Launch Services，SSH 编辑器经内置 CLI，`$EDITOR` 经 Pane；默认解析、错误边界与外部 Git 客户端委托
- [Environment](environment.md) — 构建通道（Debug/Release）、路径与环境变量的单一来源：`BuildChannel` 一处 `#if DEBUG`、`CodansEnvironment.Key` 变量名目录、`HandoffLayout`、`PaneEnvironment` 两阶段 pane 环境；写明通道隔离了什么与没隔离什么、两个 socket resolver 的故意不对称
- [Ghostty Action Routing](ghostty-action-routing.md) — libghostty `action_cb` 两遍解码 + Info/Effect/Intent/Config 四桶路由，保持 Runtime TCA-free
- [Git Diff Viewer](git-diff-viewer.md) — 独立只读 Uncommitted / Outgoing 窗口、DiffViewKit 渲染与当前文件编辑器跳转
- [GitHub Integration](github-integration.md) — repository-batched `gh api graphql` PR 取数（成本 O(Repositories)）、事件驱动失效、fork-PR 过滤；零应用内 HTTP / 零 Keychain
- [Keyboard Shortcuts](keyboard-shortcuts.md) — 统一快捷键注册表：物理键持久化、三态模型、三级冲突 + 级联重置、独立 `shortcuts.json`
- [Lifecycle Hooks](lifecycle-hooks.md) — **已设计未实现**：Pane/Tab/Worktree 生命周期 hook 的 out-of-process 执行模型 + 事件 wire schema + stdout DSL
- [Main Window](main-window.md) — 主窗口三子系统（Sidebar / Header / Tab 条）的不变量与边界：env 直读 catalog、intent 侧选择编排、单一来源默认编辑器解析、runtime-only dirty 态
- [Master Terminal](master-terminal.md) — 系统级热键唤起的 slide-in NSPanel，承载跑 `claude remote-control` 的 Ghostty surface，app 级、在 Catalog/RPC 之外
- [Notifications](notifications.md) — 运行时事件 → 持久 inbox + 四级上卷徽标 + 状态栏铃铛；策略闸 `NotificationCoordinator` 统一门控设置与授权
- [Project Tags + Single-Window](project-tags.md) — 单窗口强制（已上线）+ Project `Tag` 分类模型与持久化（过滤与分配 UI 隐藏，Tag CLI 未提供）
- [Remote SSH Projects](remote-ssh-projects.md) — `.server` 项目：`Project.remoteHost` 叠加、SSH 上发现远程 worktree + 运行持久化终端（本地 zmx 包裹 ssh 重连循环、共享 ControlMaster）；auth 委托给 ssh config/agent；已接线远程 worktree 创建/删除与连接编辑
- [Settings](settings.md) — 独立 Settings 窗口 + `settings.json` v3 单写者模型（`projects[ProjectID]` + 嵌套 `git`、版本读取与恢复、四正交通知开关）
- [Update Channel & Release Pipeline](updates-channel-pipeline.md) — Sparkle 更新通道：单一 feed + 客户端 channel 过滤；含 Developer-ID 签名/公证/CI 发布管线不变量
- [Workspace](workspace.md) — 跨多仓库的 Project：根目录即侧栏上的 workspace 行、子仓库 checkout 为真正的 Worktree 行；`.codans/workspace.json` 定成员、git 定活体事实；reconcile 在 git 探测前短路；创建 / 添加 / 移除经 `WorkspaceClient`（GUI 与 `codans workspace` 共用，记账回滚）；PR 按成员仓库取数、workspace 行聚合
- [Worktree](worktree.md) — Worktree 全生命周期（`git-wt` 创建/发现/archive/remove/prune）+ 四段侧边栏排序 + titlebar 状态栏 + header 分支切换器
- [Worktree Processes](worktree-processes.md) — 当前 Worktree 的实时前台任务、启动名称归属、采样失效规则与 Pane 跳转
