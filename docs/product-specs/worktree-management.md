# Product Spec: Worktree Management

**Status:** Shipped（生命周期 / 侧边栏排序 / 状态栏 / 分支切换器均已上线）；Diff Viewer History tab 为 Future（见 §History tab）。
**Author:** Gump (with Claude)

## Summary

A **Worktree** is a `git worktree` of a Project — a concrete branch checkout on disk with its own directory and its own Tab/Pane layout. codans is built around running multiple features in parallel, one Worktree per feature, each with its own terminal and agent.

本规格覆盖面向用户的 Worktree 全生命周期及其相邻能力：

- **生命周期**——创建（分支名 + base ref + 可选 fetch / copy-ignored / copy-untracked，带流式进度）、发现 CLI 创建的、切换、archive（软隐藏，可逆）、remove（物理删除 + 安全检查）、prune。
- **侧边栏排序**——每个 Project 下 worktree 行的四段排序模型（main / pinned / pending / unpinned）与段内可拖拽重排。
- **状态栏**——titlebar 中段按优先级切换形态的状态槽（motivational / PR / inProgress / success / warning）。
- **分支切换器**——header 分支区可点击 popover：列本地/远程分支、应用内 `git switch`、列最近提交。

Worktree 操作通过打包的 [`git-wt`](https://github.com/khoi/git-wt) helper（与 supacode 同款，submodule）驱动，它包裹 `git worktree` 并给出更好的默认值、JSON listing 与流式输出。技术形状见 [worktree 设计文档](../design-docs/worktree.md)。

## Goals

1. 让"创建/切换/归档/删除 worktree"无须用户敲完整 `git worktree add` 咒语，且 CLI 外部创建的也自动出现。
2. 让"切换分支"和"查看 PR/CI 状态"成为 worktree detail 内一等公民，省去切到终端/浏览器的来回。
3. 侧边栏 worktree 排序有正式定义、用户可控（pin/unpin/拖拽），且创建流式过程可见、不阻塞。
4. titlebar 中段承载"当前 Worktree 现在怎么样"的单行叙事——环境信息 → 实时状态 → 成败反馈。
5. 离线可用：未登录 `gh` / 无网络时仍稳定回退到 motivational 默认态，不闪空白或错误。

## User Stories

- 作为开新 feature 的开发者，我想用分支名 + base ref 创建 Worktree，得到一个隔离 checkout。
- 作为有未提交工具（`.env` / `node_modules`）的用户，我想可选把 ignored/untracked 文件拷进新 Worktree，使它立即可跑。
- 作为回到 Project 的用户，我想 CLI 外部创建的 worktree 自动出现在侧边栏。
- 作为切 feature 的用户，我想点侧边栏 worktree 行即恢复其 tabs/panes/终端态。
- 作为完成 feature 的用户，我想 **archive** 一个 Worktree 把它从主列表隐藏而不删文件，日后可回。
- 作为清理的用户，我想 **remove** 一个 Worktree（物理删目录 + 从 git 注销分支），带未提交检查与确认。
- 作为在多分支并行的工程师，我想在 header 一键切到另一分支，不必切终端跑 `git switch`；切换失败（脏树）时看到清楚的 git 报错，不无声丢工作。
- 作为多 Worktree 用户，我想切 Worktree 时 titlebar 立即展示其 PR 的 checks 状态、跑长任务时显示进度、操作成功/告警以瞬态 toast 反馈。
- 作为嘈杂 worktree 的用户，我想新建的 worktree 出现在显眼位置、并能把常用的 pin 住、拖拽排序。

## Requirements

### Must Have — 创建

- [ ] **Create Worktree sheet** 从侧边栏 Project 行的 `[+]` 触发，提示：
  - **Branch name**（必填）：实时过 `git check-ref-format --branch`；不得与本 Project 已有本地分支重名（重名是阻塞错误）。
  - **Base ref**（必填，预填 Project 默认远程分支如 `origin/main`）：下拉列本地与远程 ref。
  - **Fetch origin before creating**（可选，默认关）。
  - **Copy ignored files** / **Copy untracked files**（可选，默认关；传 `--copy-ignored` / `--copy-untracked`）。
- [ ] **流式进度**：启用 copy 标志时，创建过程在侧边栏 **pending 行**显示实时输出，sheet 立即关闭、不阻塞用户切换 project/worktree（见 §侧边栏排序）。
- [ ] **路径派生**：on-disk 路径 = `<Project.worktreesDirectory>/<sanitized-branch-name>`（`worktreesDirectory` 默认 `~/.codans/repos/<project-name>/`，见 [project-management](project-management.md)）；分支名净化：`/`→`-`、剥除 macOS 非法字符；净化后碰撞则报点名错误，不自动加后缀。
- [ ] **创建后选中**：成功后新 Worktree 加入侧边栏 unpinned 段**顶部**、被选中，开一个含单 Pane 的 Tab。
- [ ] **创建失败**：pending 行进入失败态，提供 Retry / Discard；错误人类可读（分支已存在 / ref 未找到 / 文件系统 / fetch 失败）；`catalog.json` 无残留。

### Must Have — 列表 / 发现

- [ ] **发现既有 worktree**：Project 添加时 + reconcile（启动 + 窗口聚焦）查 `git-wt ls --json` 并入侧边栏；CLI 外部创建的无须操作即出现。
- [ ] **main checkout 常驻**：Project 根 checkout 永远是第一行（main 段），是唯一不可从 app 删除或归档的 Worktree。
- [ ] **每行元数据**：分支名（或 detached HEAD 标记）、相对 git root 的路径（同分支多 worktree 时消歧）、未读通知点（消费既有 inbox 数据）、活跃标记（本 Project 当前选中）。
- [ ] **排序（分段，非按时间）**：worktree 按四段渲染——main → pinned → pending → unpinned；段内顺序 = `Project.worktrees` 数组下标（用户拖拽即改此顺序）。**不存在"按创建时间排序"**——见 §侧边栏排序。

### Must Have — 切换 Worktree

- [ ] **一键激活**：点 Worktree 行即选中、恢复其 Tabs/Panes、更新 header 分支标签与 git-viewer 态。
- [ ] **切换即时**：无进度 UI（目标 Worktree 状态已在内存）。

### Must Have — Archive（软隐藏，可逆）

- [ ] **Archive Worktree**（行右键菜单）：从主列表隐藏、关闭其 Tabs/Panes、**不动**磁盘文件、**不**从 git 注销分支、可经 Unarchive 复原。
- [ ] **归档面**：二级面（sheet 或 Project 底部分段）列本 Project 的归档 worktree，每行 Unarchive / Remove。
- [ ] **Unarchive** 把 Worktree 还回主列表原相对顺序；不自动重开 tabs/panes（用户自行选中激活）。
- [ ] **归档确认**：session 内首次归档弹确认解释软隐藏语义（"Files and branch are kept. Find it later under 'Archived Worktrees'."），后续归档本 session 跳过。
- [ ] **生命周期脚本**：若 Project 配了 archive-script，则归档前内联运行（见设计文档 §生命周期脚本）。

### Must Have — Remove（硬删除）

- [ ] **Remove Worktree**（行右键菜单 + 归档面每行），两种模式：
  - **Safe remove**——先查未提交改动，无改动才删；有改动则失败并点名文件，弹一键"Force Remove"跟进。
  - **Force remove**——独立确认对话框，显式声明"uncommitted changes will be discarded"与"this cannot be undone"。
- [ ] **删除效果**：成功后目录从磁盘删除、worktree 从 git 注销、行从侧边栏与归档列表消失、其 Tabs/Panes 关闭。
- [ ] **删除前终端安全**：删除目录前先终止该 Worktree 挂着的运行进程；确认文案点名进程数（"This will terminate N running processes…"）。
- [ ] **删除失败**：保留 Worktree 原位、git 报错进 banner；绝不让 catalog 与磁盘脱节。
- [ ] **main checkout 不可删**：该行右键菜单无 Remove/Archive。

### Must Have — Prune

- [ ] **Prune stale**（Project `⋯` 菜单）：跑 `git worktree prune` + 重查 `git-wt ls --json`；目录已不存在的行从侧边栏移除；摘要 toast（"Pruned 2 stale worktrees"）。
- [ ] **外部删除韧性**：Worktree 目录被外部删除时，窗口聚焦 reconcile 把该行标 stale 并提供一键 Prune——绝不崩溃、绝不静默状态错配。

### Must Have — 侧边栏排序

- [ ] **四段模型**：main（rootPath）/ pinned（`isPinned` 且非 main）/ pending（创建中占位）/ unpinned（其余）；固定渲染顺序 main → pinned → pending → unpinned。
- [ ] **Pin** → 移到 pinned 段末尾；**Unpin** → 移到 unpinned 段顶部。
- [ ] **段内拖拽**：pinned 段、unpinned 段段内可拖（main 无重排，pending 无拖拽）；重排持久化（写 catalog 数组顺序）。跨段拖拽不支持，用 Pin/Unpin 菜单替代。
- [ ] **pending 行操作**：Cancel（仅 running）/ Retry（仅 failed）/ Discard（仅 failed）；pending 不可选中、不可 Pin/Reveal/Open-in/Archive/Remove、⌃⌘N 跳过。
- [ ] **新建落位**：默认进 unpinned 段顶部。

### Must Have — 状态栏

- [ ] 中段五形态按优先级切换：P0 inProgress（spinner）> P1 success(✓)/warning(▲) > P2 PR（`#编号` 徽章 + checks 色环 + 简述）> P3 motivational（时段图标 + `HH:mm – Open Command Palette ⌘P`）。
- [ ] **toast 自动清除**：`success` 3s、`warning` 8s、`inProgress` 不自动清（由发射方结束）。inProgress 展示时收到 success/warning 则被覆盖（inProgress 结束本身即 success 的发生）。
- [ ] **PR 态**：点击复用既有 `PullRequestPopover`；按住 ⌘ 简述临时换成 `Open on GitHub`，`⌘+click` 在浏览器开 PR；徽章色按 PR 状态（open 绿/draft 灰/merged 紫）；checks 色环按 statusCheckRollup 汇总（`total==0` 不渲染）；简述优先级：merge-ready 阻塞 > checks 汇总 > `(Drafted)` > 标题。"活跃 PR"= snapshot 存在、`state != CLOSED`、`number` 非空。
- [ ] **motivational 态**：按本地 hour 切四种时段图标，每分钟刷新时间。
- [ ] **数据复用**：PR 数据读 `GitHubFeature.snapshots[worktreeID]`（与 sidebar 同源），不新增 `gh` 调用面。
- [ ] **不动两侧**：左侧分支标题、右侧 🔔/⇪/📖/⚙︎ 位置与行为完全不变；macOS 26+ 中段无多余背景胶囊；所有切换 `easeInOut(0.2)`；未登录 `gh`/无 PR 时稳定回退 motivational。

### Must Have — 分支切换器

- [ ] Header 两行：行 1 分支名 + chevron / spinner，行 2 `folder · project`（caption）。
- [ ] 点击行 1 弹 popover，含 Branches + Recent Commits 两组。
- [ ] Branches 组列本地 + 远程分支，current 行带 checkmark 且置顶；本地分支 `git switch <name>`；远程分支首切 `git switch --track <origin/x>`；同名本地存在时走本地 fast-path（不重建 tracking）。
- [ ] 切换发起 header 立即 spinner；HEAD 变化或 git 报错时收回。脏树切换失败时**原始 git 报错以可见 inline 错误展示，不静默吞掉**（可关闭、不阻塞）。
- [ ] Recent Commits 组列最多 10 条 commit。
- [ ] 切换后 header / sidebar 分支显示由 `WorktreeHeadWatcher` 既有回路驱动刷新，无手工 reload。
- [ ] `GitService.currentBranch / listAllBranches / switchBranch` 走 `CommandRunner`，并有 unit test 覆盖输出解析与命令拼装。

### Should Have

- [ ] **Reveal in Finder** / **Copy path**（Worktree 行）。
- [ ] **Git fetch** per Worktree（行右键 "Fetch origin"，不走 Create 流程）。
- [ ] Popover 顶部分支搜索框（实时 filter）；⌘B 打开/关闭 popover；Popover 全键盘可访问（上下箭头 + 回车 + esc）。
- [ ] Detached HEAD 时 header 行 1 显示 `(detached @ <short-sha>)`。
- [ ] 窄窗口阈值下中段状态槽整体隐藏（不塌缩成溢出菜单）；VoiceOver 在切换时朗读一次当前状态（不重复朗读过渡态）；暗色模式颜色满足 AA 对比度。

### Nice to Have / Future

- [ ] **Diff Viewer History tab**（见 §History tab，未上线）。
- [ ] **Rename branch** in-place（`git branch -m` 包装，实时校验）。
- [ ] **Line-change badge**——每行 `+123 -45` 指示。
- [ ] **Branch-name autocomplete**（Create sheet）。
- [ ] inProgress 多任务并发聚合态（`N tasks running`，点击弹列表）；success toast 的 undo；motivational 自定义右半句。
- [ ] PR merge 时自动提示归档（依赖 GitHub 集成）。

## History tab（Future — 未上线）

产品愿景里 Git Diff Viewer 右侧拆 Changes / History 双 tab：History 列当前分支 commit 历史（分页），点 commit 在左侧渲染整 commit unified diff，左侧标题显示 `<short-sha> · <subject>`；branch popover 底部"View all"跳到 History tab。

**当前状态：未实现。** 代码里没有 `DiffFeature` / Changes-History tab 结构；Diff 能力仅在 service 层（`commitDiff` 等）。落地前置依赖是先有 `DiffFeature`。在它存在前，popover 不提供"View all"入口或将其降级。本能力的设计意图见 [worktree 设计文档 §Diff Viewer History tab](../design-docs/worktree.md)。

## Acceptance Criteria

### 创建 / 列表 / 切换

- Given Project `worktreesDirectory` 在默认 `~/.codans/repos/<project-name>/`, when 用户创建名为 `feature/login`（base `origin/main`）的 Worktree, then `~/.codans/repos/<project-name>/feature-login/` 出现、侧边栏 unpinned 段顶部加一行、终端在该目录打开。
- Given 用户输入已存在的本地分支名, when 尝试创建, then Create 禁用且 inline 错误 "Branch 'x' already exists"。
- Given 用户输入非法分支名（含空格）, then "Branch name is invalid" 且 Create 禁用。
- Given 用户在 500 MB `node_modules` 仓启用 "Copy ignored", when 创建运行, then 侧边栏 pending 行流式进度、完成后该 Worktree 含 `node_modules/`。
- Given 用户启用 "Fetch origin" 而网络断, then fetch 错误清晰呈现、不创建 Worktree。
- Given 用户在 codans 外手动 `git worktree add`, when 聚焦 codans 窗口, then 新 Worktree 在 reconcile 周期内出现。
- Given 同分支两 Worktree 不同路径, then 各行显示相对路径消歧。
- Given 用户点非活跃 Worktree 行, then header 分支标签更新、其 Tabs/Panes 恢复。

### Archive / Remove / Prune

- Given Worktree 被归档, then 主列表不可见、"Archived Worktrees"里可见；Unarchive 还回原相对顺序；从归档列表 Remove 走同一删除流程。
- Given 有 3 个修改文件的 Worktree, when Safe Remove, then 失败、错误点名未提交文件、错误对话框出现 "Force Remove" 按钮。
- Given 用户确认 Force Remove, then 目录消失、行消失、其终端 tab 关闭、`git worktree list` 不再引用。
- Given main checkout 行, when 打开右键菜单, then 无 Remove/Archive。
- Given Worktree 目录被外部删除, when 在 Project 上 Prune, then stale 行消失、toast "Pruned 1 stale worktree"。

### 侧边栏排序

- Given 1 main + 2 pinned + 1 pending + 3 unpinned, when 渲染, then 7 行按 main → pinned → pending → unpinned 顺序。
- Given 新建一个 worktree（不 pin）, then 它出现在 unpinned 段顶部。
- Given 在 unpinned 行 Pin, then 它落 pinned 段末尾；Given 在 pinned 行 Unpin, then 它落 unpinned 段顶部。
- Given 段内拖拽 pinned/unpinned, then catalog 数组顺序改变并持久化。
- Given pending 行 running, then 仅 Cancel 可用；failed 时仅 Retry/Discard 可用。

### 状态栏

- Given 新建空 Project（无 PR）, when 选中一个 Worktree, then 中段 300ms 内渲染 motivational，文本形如 `14:02 – Open Command Palette ⌘P`。
- Given 我点 `Open in Xcode`, when Editor 返回 success, then 中段 200ms 内显示绿 ✓ + `Opened in Xcode`，3s 后回落。
- Given inProgress `Running tests` 展示, when 发出 success `Tests passed`, then 切换为 success 且 spinner 消失。
- Given warning 展示, when 不操作, then 8s 后回落。
- Given 当前 Worktree 分支有活跃 PR（open、checks 全绿）, when 无 toast, then 显示 `#123` 绿徽章 + 绿 ring + `4/4 checks`。
- Given PR 态展示, when 按住 ⌘, then 简述 100ms 内换成 `Open on GitHub`；点击徽章弹 `PullRequestPopover`（与 sidebar 同源）。
- Given PR 被 merged, then 0.2s 内过渡为紫色徽章且不再显示 checks ring；Given PR 已 closed, then 回落 motivational。
- Given 窗口宽度低于阈值, then 中段整体不渲染、两侧按钮位置稳定、不溢出菜单。

### 分支切换器

- Given git Worktree 在 `main`, when 打开 worktree detail, then header 行 1 显示 `main`、行 2 显示 `<folder> · <project>`。
- Given Worktree detached HEAD, then header 行 1 显示 `(detached @ <short-sha>)`。
- Given header 行 1, when 点击, then 300ms 内弹 popover，含 Branches 与 Recent Commits。
- Given popover 打开且当前分支 `main`, then `main` 行带 checkmark 且置顶。
- Given 远程分支 `origin/feat/x`（本地无同名）, when 点击, then popover 关闭、spinner 出现、新本地分支被创建并切换。
- Given 远程分支 `origin/main`（本地有同名）, when 点击, then 走本地 fast-path、不创建新分支。
- Given 在 `bugfix/foo` 有未提交改动, when 点 `main`, then popover 关闭、spinner 出现、随后 inline git 原始报错且分支仍 `bugfix/foo`。
- Given 无远程, then 不渲染 Remote 子分隔与对应行。
- Given 切换成功且 HEAD 变化被 `WorktreeHeadWatcher` 捕获, then spinner 收回、分支名变新值，全程无须用户刷新。

### 视觉 / 系统

- Given macOS 26+, then header popover 与中段状态槽无多余 toolbar 背景胶囊。
- Given VoiceOver, when 导航到 header 行 1, then 朗读 "Branch <name>, button"。
- Given 任何中段形态切换, then 左右两侧 ⎇/🔔/⇪/📖/⚙︎ 位置与大小无可感知变化。

## Scope

### In Scope

- 创建（branch + base ref + 可选 fetch + copy-ignored/untracked，流式）、自动发现外部创建、切换（全状态恢复）、archive/unarchive、safe/force remove、prune。
- 四段侧边栏排序 + pin/unpin + 段内拖拽 + pending 段。
- 五形态状态栏（含 PR 态复用既有 popover、motivational、瞬态 toast）。
- 应用内分支切换（local/remote/fast-path）+ header 两行布局 + 最近提交 popover。
- 每行元数据：分支、相对路径、未读点、活跃标记。

### Out of Scope（承重边界）

- **无分支的 detached-commit worktree**——v1 总是创建命名分支。
- **应用内 commit / rebase / merge / pull / push / cherry-pick / revert / stash / discard UI**——terminal-first，用 `git`/`lazygit`。脏树切换失败时原样冒泡 git stderr，不裁剪、不翻译、不自动 stash。
- **创建/删除/重命名分支**（仅 switch）；popover 内的 PR / 远程比较视图。
- **多 worktree 批量操作**（如"归档所有已合并 worktree"）；冲突解决 UI。
- **跨 Project 移动 worktree**；创建后改 worktree on-disk 路径（force-remove 重建）。
- **改 `worktreesDirectory`**——只在 Project options，不在 Create sheet（per-create override 会让 worktree 散落、破坏可预测默认）。
- **`Worktree.sortIndex` 字段**——段内顺序由 catalog 数组下标承担，无独立排序字段。
- **toast / motivational / pending 持久化**——纯内存，重启丢弃。
- **命令面板 keybinding 配置系统**——快捷键硬编码 ⌘P（经共享常量消除漂移）。
- **非 git Plain Project 的分支 popover / PR 槽**——它们无分支/PR，affordance 隐藏而非禁用；motivational 仍适用。
- **菜单栏 / Dock 徽章 / 通知中心推送**（属 notifications 范畴）；多窗口 broadcast（单 `WindowGroup`）。

### Future Consideration

- Diff Viewer History tab（依赖先有 `DiffFeature`）；inline rebase/merge helpers；branch rename in-place。
- Archive hook / script 经 C3（v1 的生命周期脚本是内联同步执行，与异步 C3 hook 不同）。
- PR merge 时自动提示归档（依赖 GitHub 集成）。

## References

- 设计：[worktree.md](../design-docs/worktree.md)
- 模型：`apps/mac/CodansCore/{Worktree,Project}.swift`、`CodansCore/Git/GitModels.swift`（`BranchRef.shortName`）
- 关系数据：`apps/mac/codans/Runtime/HierarchyManager.swift`（`WorktreeSegment`）、`WorktreeHeadWatcher.swift`
- `git-wt`：<https://github.com/khoi/git-wt>，submodule 于 `apps/mac/ThirdParty/git-wt/`
