# Product Spec: Worktree Branch Switcher & Diff History

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-05-24

## Summary

把 Worktree detail header 现在那个静态的分支标签升级为一个**可点击的分支切换器**，并在 Git Diff Viewer 右侧新增一个 **History tab**。Header 改为两行布局（第一行分支名，第二行 `folder · project`），点击分支名弹出 popover：第一组列出当前 worktree 的所有本地与远程分支，单击即可切换（带必要安全检查与 loading 指示）；第二组列出当前分支最近 10 次提交，底部 "View all" 跳到 Diff Viewer 的 History tab。Diff Viewer 右侧拆为 Changes / History 两个 tab —— Changes 保持现有未提交改动视图，History 列当前分支的 commit 历史，点击某个 commit 左侧展示该 commit 的整体 diff。

目标：让"切换分支"和"查看历史 diff"成为 worktree detail 内一等公民，省去用户切到终端跑 `git switch` 或 `git log -p` 的来回开销，并把分支身份从只读文本升级为可操作入口。

## Goals

1. Worktree detail header 的分支区域**变成主操作入口**：可点击、可切换、有 loading、有上下文（最近提交）。
2. 分支切换在应用内完成，**安全前置**：脏工作区由 `git switch` 自身的错误冒泡到 UI，不让用户在不知情下丢工作。
3. Diff Viewer 一次性能查"现在改了什么"和"以前改了什么"，**两种视角共用左侧 diff 渲染**。
4. 分支与提交数据**走已有 `GitService` 协议**，新增的能力（list-all-branches / current-branch / switch-branch）以同样的 nonisolated + Sendable 风格扩展，不破坏现有调用方。
5. 切换分支后的 UI 更新**复用已有 HEAD 变化回路**（`WorktreeHeadWatcher`），不引入手工 refresh 链。

## Non-Goals

- 不做"创建新分支"、"删除分支"、"重命名分支"等写操作（仅 switch）。
- 不实现 stash / discard / pop 的 UI 选项；脏工作区直接展示 git 报错。
- 不在 popover 内做 PR / 远程比较视图（只列分支名与最近提交）。
- 不改动现有 Changes tab 的 diff 渲染、文件行交互、refresh 按钮行为。
- 不实现 commit 操作（cherry-pick / revert / checkout file …）；History tab 仅 read-only。
- 不在 spec 内规定 popover 的最终配色 / 阴影 / 圆角（交给 hs-design + SwiftUI 落地）。
- 不为 Plain（非 git）Project 适配 —— 它们没有分支与历史，header 行 2 退化为现有 `folder · project` 但行 1 显示文件夹名（沿用现状）。
- 不实现"跨 worktree 切分支"或"分支搜索全局命令"（命令面板的范畴）。

## Stakeholders & Users

- **Primary**：在多个 feature 分支间来回切换的开发者，习惯 `git switch` + `git log` 的 CLI 节奏，但希望在 GUI 里更快看到"现在在哪、最近做了什么、要切到哪"。
- **Secondary**：刚加入项目、想浏览历史 commit diff 找上下文的协作者；他们不切分支，但常用 History tab。
- **受影响系统**：
  - `WorktreeHeaderFeature` / `WorktreeHeaderInfoLabel`（header 视图）
  - `DiffFeature` / `DiffInspectorView` / `DiffDrawerView`（右侧面板拆 tab + 新 History 子状态）
  - `GitService` / `LiveGitService`（新增 3 个操作）
  - `WorktreeHeadWatcher`（切分支后被动触发 catalog 更新，本 spec 不改其实现，仅依赖它）
  - `HierarchyManager`（提供 `Worktree → Project` 关系，供 header 行 2 显示项目名）

## User Stories

- As a 在多分支并行开发的工程师，I want 在 header 上看到当前分支名并一键切到另一个分支，so that 不必切到终端跑 `git switch`。
- As a 想确认远程协作者新推分支的工程师，I want popover 列出 remote 分支并允许一键 track 到本地，so that 不必先 `git fetch && git switch --track`。
- As a 刚 pull 完想回顾这次进度的工程师，I want popover 直接展示当前分支最近 10 次 commit，so that 一目了然最近做了什么。
- As a 想详细回顾历史改动的工程师，I want Diff Viewer 有一个 History tab，能像浏览 Changes 那样点 commit 看 diff，so that 不必去 GitHub / `git log -p`。
- As a 工作区有未提交改动的工程师，I want 切换分支失败时看到清楚的 git 错误信息，so that 不会无声丢数据。
- As a 正在切换分支的工程师，I want header 上分支名旁出现 loading，so that 我知道切换在进行，不会以为应用卡住。

## Layout Overview

### Worktree detail header (改动点 1)

```
┌─────────────────────────────────────────────┐
│ {icon}  feat/git-branch-update  ⌄ / ⟳        │   row 1 — branch (hover → underline; click → popover)
│         repos/codans · codans        │   row 2 — folder · project (caption)
└─────────────────────────────────────────────┘
```

- 行 1：分支名 + 末尾控制图标（默认 chevron-down，切换中替换为 spinner）。整行 hover 高亮，整行可点。
- 行 2：现有"按规则展示的文件夹名" + `·` + project name；caption 字号、次级色。

### Branch popover (改动点 2)

```
┌──────────────────────────────────────────┐
│ [Search …]                                │   可选 filter（Should Have）
├──────────────────────────────────────────┤
│ BRANCHES                                  │
│ ✓ feat/git-branch-update          (local) │   current
│   main                            (local) │
│   bugfix/ipc-crash                (local) │
│   ─────────────                           │
│   origin/feat/new-shell        (remote)   │
│   origin/main                  (remote)   │
├──────────────────────────────────────────┤
│ RECENT COMMITS                            │
│ 9243c20  fix(ghostty): drop isolated…  2h │
│ d3d3ed6  chore(release): bump 0.2.5    1d │
│ 66ec930  test: backfill missing…       1d │
│ … (up to 10)                              │
│ ─────────────                             │
│ [ View all in Diff Viewer →            ]  │
└──────────────────────────────────────────┘
```

- 总宽 ≈ 360pt，单列；分支组与提交组之间用分隔线，组内远程分支再用一层分隔线区分。
- "View all" 按钮：关闭 popover → 切到 Diff Viewer → 选中 History tab。

### Git Diff Viewer 右侧面板 (改动点 3)

```
┌──── Diff Viewer ─────────────────────────────────────┐
│ ◀ left: diff renderer    │  ┌──────────────────────┐ │
│   (file diff or commit   │  │ [Changes] [History]  │ │  segmented picker
│    diff)                 │  ├──────────────────────┤ │
│                          │  │  …list of files OR   │ │
│                          │  │  …list of commits    │ │
│                          │  └──────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

- 顶部 segmented picker（Changes / History），保留现 Changes 行为不变。
- History tab 内每行：短 SHA + 第一行 message + 相对时间 + 作者头像/首字母（可选）。
- 选中一行 → 左侧 diff 切换为 `git show <sha>` 的 unified diff。
- History 默认加载第一页（50 条），滚动到底触发下一页。

## Functional Spec

### Header 行为

- **点击区域**：行 1 整体可点（除右下 row 2）。Hover 时整行轻微 background + 分支名下划线。
- **键盘**：⌘B 打开 / 关闭 branch popover（Should Have；具体快捷键在 hs-design 阶段定）。
- **loading 表现**：切换发起后，chevron-icon 立刻替换为 spinner，分支名维持旧值；HEAD 变化通过 `WorktreeHeadWatcher` 更新 `Worktree.branch`，UI 自然刷新；spinner 在 catalog 更新或 git 报错时收回。

### Popover 内容与交互

- **分支列表**来源：`GitService.listAllBranches(at:)` 返回 `BranchInventory { current, local, remote }`（详见 Design Considerations 第 1 点）。
- **顺序**：local 在前，按字典序；remote 在后，按字典序；current 永远置顶 + checkmark。
- **去重**：当 `origin/main` 已经对应本地 `main` 时，remote 区块仍显示 `origin/main`，但点击行为走 fast-path（直接 switch 已存在的本地分支，不会 re-track）。
- **切换动作**：
  - 本地分支：`git switch <name>`
  - 远程分支（无同名本地）：`git switch --track <origin/x>`
  - 远程分支（有同名本地）：fast-path 走本地
- **切换错误**：popover 立即关闭、spinner 启动；git 报错以 inline 错误 row 出现在 header 下方（具体位置 hs-design 定），用户点击 dismiss 后消失。**不**自动重试，**不**自动 stash。
- **commit 列表**来源：`GitService.log(at:page:0)` 取前 10 条。每行 hover 不做任何额外动作（首版不让 commit 行点击 → diff，避免和 "View all" 入口竞争；具体可在 Could Have 演进）。
- **"View all" 行为**：关闭 popover → 打开 Diff Viewer（若关闭则打开）→ 把 selected tab 设为 `.history`。

### Diff Viewer Changes / History 切换

- **tab 切换**：segmented control 立刻切，状态保留（History 已加载的 commits 不重置）。
- **History 加载**：进入 tab 时若 `historyState.commits.isEmpty && !loading`，触发首次 `log(page: 0)`。滚动到底（剩 ≤5 行）触发 `log(page: next)`。错误以 inspector 顶部一行红字呈现 + 重试按钮。
- **选中 commit**：左侧 diff 区切换为 `GitService.commitDiff(at:sha:)` 的 `UnifiedDiff`，复用现有 `DiffDrawerView` / `DiffRendererView`。在 History tab 模式下，左侧标题应显示 `<short-sha> · <message first line>`，而不是文件路径。
- **跨 tab 状态**：从 History 切回 Changes，左侧回到原先选中的文件（若有）；从 Changes 切到 History，左侧切到当前选中 commit（若有），否则显示"选择左侧一个 commit"的空态。

### 错误与边界情况

- **detached HEAD**：`currentBranch` 返回 nil；header 行 1 显示 `(detached @ <short-sha>)`，popover 仍可打开切到任意分支。
- **无远程**：remote 组不渲染（不显示空组标题）。
- **无 commit 历史**（全新仓库）：popover commit 组显示"暂无提交"占位行；Diff Viewer History tab 同样显示空态。
- **切换失败 + 工作区脏**：原样冒泡 git stderr 给用户，**不**裁剪、不翻译。

## State / Data

新增 / 修改：

- `CodansCore/Git/GitModels.swift`：
  - `struct BranchRef { let name: String; let isRemote: Bool; let upstream: String? }`
  - `struct BranchInventory { let current: String?; let local: [BranchRef]; let remote: [BranchRef] }`
- `Git/GitService.swift`：
  - `func currentBranch(at:) async throws -> String?`
  - `func listAllBranches(at:) async throws -> BranchInventory`
  - `func switchBranch(to:at:) async throws`
- `WorktreeHeaderFeature`（或新开 `BranchSwitcherFeature`，归属在 hs-design 决定）新增 state：
  - `inventory: BranchInventory?`、`isSwitching: Bool`、`switchError: String?`
  - `recentCommits: [Commit]`（前 10 条，懒加载）
- `DiffFeature.State` 扩展：
  - `enum DiffTab { case changes, history }`
  - `selectedTab: DiffTab = .changes`
  - `historyState: HistoryState`（commits / cursor / loading / error）
  - `presentedCommit: Commit?`（History tab 下左侧渲染目标）

## Requirements

### Must Have

- [ ] Header 改为两行：第 1 行分支名 + chevron / spinner；第 2 行 `folder · project` caption。
- [ ] 点击 header 行 1 弹出 popover，包含 Branches + Recent Commits 两组。
- [ ] Branches 组列出当前 worktree 的本地 + 远程分支，current 行带 checkmark。
- [ ] 本地分支切换通过 `git switch <name>`；远程分支首切通过 `git switch --track <origin/x>`；同名本地存在时走本地 fast-path。
- [ ] 切换发起后 header 立即显示 loading；HEAD 变化或 git 报错时收回 loading。
- [ ] 工作区脏导致 git switch 失败时，原始 git 报错以可见的 inline 错误展示，不静默吞掉。
- [ ] Recent Commits 组列出最多 10 条 commit，底部含 "View all" 按钮。
- [ ] "View all" 关闭 popover 并打开 Diff Viewer，selected tab 置为 History。
- [ ] Diff Viewer 右侧有 Changes / History 两个 tab，默认 Changes，保留现有 Changes 行为。
- [ ] History tab 加载当前分支的 commit 历史（分页），列表每行展示 short-sha + 标题 + 相对时间。
- [ ] History tab 选中 commit 在左侧渲染该 commit 的 unified diff。
- [ ] 新增 `GitService.currentBranch / listAllBranches / switchBranch` 走 `CommandRunner`，并具备相应的 unit test 覆盖输出解析与命令拼装。
- [ ] 切换完成后 header / sidebar 中的分支显示由 `WorktreeHeadWatcher` 已有回路驱动刷新，无需新增手工 reload 链路。

### Should Have

- [ ] Popover 顶部带分支搜索框（实时 filter）。
- [ ] 切换分支支持 ⌘B 快捷键打开 / 关闭 popover。
- [ ] Detached HEAD 时 header 行 1 显示 `(detached @ <short-sha>)`，popover 仍可正常使用。
- [ ] History tab 分页：滚动到底自动加载下一页，错误展示带重试。
- [ ] Popover 全键盘可访问（上下箭头选中，回车确认切换；esc 关闭）。
- [ ] 暗色模式下 popover 配色与现有 `PullRequestPopover` 风格一致。

### Could Have

- [ ] Recent Commits 行点击也能跳到 History tab 并选中对应 commit。
- [ ] History tab 顶部加 commit 搜索框（按 message / author / sha）。
- [ ] Popover 显示每个分支的 upstream ahead/behind 计数。
- [ ] 远程分支首次切换前显示一个轻量 confirm（"将创建本地 tracking 分支 X"）。
- [ ] 切换成功时在 status bar（如已经合入 worktree-status-bar）发一个 success toast。

### Won't Have (This Spec)

- 创建 / 删除 / 重命名分支
- stash / discard / cherry-pick / revert / checkout file 等写操作
- Plain Project 的特殊适配（沿用现状）
- 跨 worktree 的分支搜索 / 切换（命令面板的范畴）
- History tab 内的 diff per-file 选择视图（仅整 commit diff）

## Acceptance Criteria

GWT 格式，每条对应一个可观察行为。运行时断言交给 `/hs-test-spec` 落 `docs/user-tests/worktree-branch-switcher-and-history.md`。

### Header (HD)

- **AC-HD-1** Given 一个 git Worktree 处于 `main` 分支, when 我打开 worktree detail, then header 第 1 行显示 `main`，第 2 行显示 `<folder> · <project name>`。
- **AC-HD-2** Given header 已渲染, when 我将鼠标移到第 1 行, then 该行有可见的 hover 高亮且分支名出现下划线。
- **AC-HD-3** Given Worktree 处于 detached HEAD, when 我打开 worktree detail, then header 第 1 行显示 `(detached @ <short-sha>)`。

### Branch popover (BP)

- **AC-BP-1** Given header 行 1 可见, when 我点击它, then 在 300ms 内弹出 popover，包含 Branches 与 Recent Commits 两个分组。
- **AC-BP-2** Given popover 已打开且当前分支为 `main`, when 我观察 Branches 组, then 当前行 `main` 末尾带 checkmark 且置于第一位。
- **AC-BP-3** Given popover 已打开且存在远程分支 `origin/feat/x`（本地无同名）, when 我点击该行, then popover 关闭、header 行 1 出现 spinner、新本地分支被创建并切换。
- **AC-BP-4** Given popover 已打开且存在远程分支 `origin/main`（本地有同名 `main`）, when 我点击 `origin/main`, then 走本地 fast-path 切到 `main`，不创建新分支。
- **AC-BP-5** Given 我在 `bugfix/foo` 分支上有未提交改动, when 我从 popover 点击 `main`, then popover 关闭、spinner 出现、随后 inline 出现 git 原始报错且分支保持 `bugfix/foo`。
- **AC-BP-6** Given popover 已打开, when 仓库没有任何远程, then 不渲染 Remote 子分隔与对应行。
- **AC-BP-7** Given popover 已打开, when 当前分支有 ≥10 次提交, then Recent Commits 组显示恰好 10 行，按时间倒序。
- **AC-BP-8** Given popover 已打开, when 我点击 "View all", then popover 关闭、Diff Viewer 打开、selected tab 为 History。

### Switching feedback (SW)

- **AC-SW-1** Given 一次切换正在进行, when 我观察 header 行 1, then chevron 被 spinner 替代且分支名仍为旧值。
- **AC-SW-2** Given 切换成功且 HEAD 变化已被 `WorktreeHeadWatcher` 捕获, when catalog 更新到达, then spinner 收回、分支名变为新值，全程无需用户额外刷新。
- **AC-SW-3** Given 切换失败, when 我点击错误条的关闭按钮, then 错误条消失、spinner 已收回、分支名维持原状。

### Diff Viewer tabs (DV)

- **AC-DV-1** Given Diff Viewer 已打开且没有 History 数据, when 我点击 History tab, then 在 500ms 内开始加载并显示 spinner，加载完成后列出当前分支提交。
- **AC-DV-2** Given History tab 已渲染至少一页, when 我点击第三行 commit, then 左侧 diff 区切换为该 commit 的 unified diff，标题为 `<short-sha> · <message first line>`。
- **AC-DV-3** Given History tab 已加载并选中某 commit, when 我切回 Changes tab 再切回 History, then 之前选中的 commit 仍处于选中状态且左侧 diff 不变。
- **AC-DV-4** Given History tab 列表已滚动到底, when 列表剩余 5 行可见, then 自动触发下一页加载，新数据 append 在尾部。
- **AC-DV-5** Given 当前分支无任何提交（全新仓库）, when 我打开 History tab, then 显示空态文本 "No commits on this branch"。

### 系统 / 视觉 (VS)

- **AC-VS-1** Given macOS 26+, when popover 渲染, then 弹层无多余背景胶囊，与现有 toolbar item 风格一致。
- **AC-VS-2** Given VoiceOver 打开, when 我导航到 header 行 1, then VoiceOver 朗读 "Branch <name>, button"。
- **AC-VS-3** Given Diff Viewer 切换 Changes / History tab, when 切换发生, then 左侧 diff 区不闪烁，过渡平滑（与现有 inspector 风格一致）。

## Design Considerations (for hs-design)

以下决策**不在本 spec 内定案**：

1. **`listAllBranches` 实现**：是用单条 `git for-each-ref --format=... refs/heads refs/remotes` 一次拉，还是分两次 `git for-each-ref refs/heads` + `refs/remotes` 后合并？是否在 service 层做 current 标记，还是返回时让 caller 自己 grep `currentBranch`？
2. **`switchBranch` 的安全检查**：是否在 service 层主动 `git status` 检查脏工作区（早失败 + 自定义错误），还是直接调 `git switch` 让其原生报错？两者的 UX 差异。
3. **popover 状态归属**：扩展 `WorktreeHeaderFeature` 还是新开 `BranchSwitcherFeature`？后者好处是 toolbar 多功能膨胀时不卷成一团。
4. **`WorktreeHeadWatcher` 联动**：切换是否要主动 invalidate 一次（缩短反应窗口），还是完全交给 watcher 的下一个 tick？
5. **`DiffFeature` history 子 state**：内嵌还是 child reducer？影响 TestStore 组织与 selected-tab 持久化。
6. **Diff Viewer 左侧标题**：Changes 用文件路径，History 用 `<sha> · <message>`，是抽象成 `DiffSourceHeader` 还是分支 if/else？
7. **Project 名取得路径**：`WorktreeDetailView` 当前直接消费 `Worktree`，要拿 Project 名需要往上追到 `HierarchyManager.catalog` 反查 owner project；这一步是放 view 里还是 reducer 里做。
8. **错误展示位置**：切换失败的 inline 错误条挂在 header 下方，还是借用未来 status bar 槽位（依赖 worktree-status-bar 是否合入）。
9. **commit 数据复用**：popover 的 Recent Commits 与 Diff Viewer 的 History 是同源（共享 `historyState.commits` 的前 10 条）还是分别加载？

## Open Questions

- [ ] **OQ-1**：当 worktree 处于 `git rebase` / `git merge` 中间态时，切换分支必然失败。需要在 popover 层提前禁用切换、给出提示，还是仍让 git 报错冒泡？
- [ ] **OQ-2**：远程分支数量很多（100+）时，Branches 组是否需要默认折叠 remote 部分？或者按 `<remote-name>/` 分子组。
- [ ] **OQ-3**：分支搜索框（Should Have）是否在首版必须有？没有的话 100+ 分支体验会差。
- [ ] **OQ-4**：History tab 的"当前分支"是按打开 Diff Viewer 那一刻定，还是跟随 `Worktree.branch` 动态变化？后者意味着切分支会清空 / 重置 History 选中。
- [ ] **OQ-5**：commit diff 在很大 merge commit 上会非常巨大，是否需要在 History 模式下限制 `--stat` 优先 / 折叠 binary 文件？
- [ ] **OQ-6**：是否需要把 `git fetch` 的入口暴露在 popover 顶部（"Refresh remote branches"），还是完全依赖外部 / 终端 fetch？

## Glossary

- **Branch popover**：点击 header 分支名后弹出的下拉，含 Branches + Recent Commits 两组。
- **Branch inventory**：`{ current, local, remote }` 三件套，描述一个 worktree 当前可见的所有分支。
- **Fast-path switch**：点击 `origin/x` 时若本地已有 `x`，直接 `git switch x` 而非 `--track` 重建。
- **History tab**：Diff Viewer 右侧新 tab，列当前分支的 commit 历史。
- **Changes tab**：现有 Diff Viewer 内容，未提交改动列表。
