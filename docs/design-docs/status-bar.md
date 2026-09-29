# 设计文档：状态栏

**状态：** 可用
**作者：** Gump（与 Claude）
**实现：** [StatusBar/](../../apps/mac/codans/App/Features/StatusBar/)、[CodansCore/StatusBar/](../../apps/mac/CodansCore/StatusBar/)、[WorktreeDetailView.swift](../../apps/mac/codans/App/Features/WorktreeDetail/WorktreeDetailView.swift)（`statusSlot`）

## 背景与范围

状态栏是主窗口 toolbar 的中段，不是窗口底部的栏。它回答"刚才发生了什么、现在在忙什么、这个 worktree 的 PR 怎么样"，给各模块一个统一、轻量的反馈出口，替代零散的底部 pill 和 OK 弹窗。

toolbar 中段从左到右：

```
[分支身份] ── flexible ── [ 状态槽 │ 进程徽章 ]  [🔔] ── flexible ── [Agents] [Run] [Open] [⚙]
```

| 部件 | 内容 | 设计文档 |
|---|---|---|
| 状态槽 `StatusBarView` | Toast / Activity / PR / motivational 四选一 | 本文 |
| 进程徽章 `WorktreeProcessesView` | 当前 worktree 的前台任务数 + 列表 popover | [worktree-processes.md](worktree-processes.md) |
| 铃铛 `InboxBellView` | 全局未读，窗口级 chrome；`statusBarBellEnabled` 控制显示 | [notifications.md](notifications.md) |

macOS 26 用两个 `ToolbarSpacer(.flexible)` 把状态胶囊放在视觉中点，保留系统 glass 胶囊；更早版本放 `.principal`。创建 worktree 期间状态槽换成同尺寸的 `SkeletonStatusPillView`，toolbar item 结构不变，只替换内容（结构一变 NSToolbar 会重建所有 item 并从左侧滑入）。

## 目标与非目标

目标：

- 任何模块都能用同一套词汇报告"开始了 / 进行中 / 成功了 / 失败了"，不需要自建 UI。
- 进行中的工作可并发、可见、可列出；需要时可停止。
- 状态最少：只把必须由 reducer 管理的东西放进 state，其余从已有数据派生。

非目标：

- 不承载致命错误。阻断性错误走 sheet / 内联 banner（创建、clone、连接服务器、Settings 写入等保持原样）。
- 不做历史记录。toast 被下一条覆盖即消失，需要留存的事件走 [通知 inbox](notifications.md)。
- 不替代就地进度。sidebar 的 pending / archive / delete 行、分支切换 spinner、sheet 内进度仍是主进度，状态栏不重复它们。

## 设计

### 形态与优先级

`StatusBarView` 每次渲染按优先级选一种形态：

```
toast != nil                     → Toast        （结果，3 s / 8 s 后自动清除）
activities 非空                  → Activity     （最近开始的一项 + 计数环）
snapshots[wt] 存在且非 closed    → PR
否则                             → Motivational （时段图标 + 时间 + ⌘P 提示）
```

toast 压过 activity：一项工作结束时它的结果先显示几秒，然后槽位回到仍在运行的其他 activity。

只有 toast 与 activities 是 `StatusBarFeature` 的 state。PR 与 motivational 是视图层派生（`gitHub.snapshots` + `TimelineView`），不进 reducer——它们是已有数据的纯函数，进 state 只会多一条手动同步的冗余轴。PR 数据与 sidebar 徽章读同一个 `GitHubFeature.snapshots` 字段，两处永不分叉。

### 两个值类型（`CodansCore/StatusBar/`）

**`StatusToast`**——刚落地的结果：

| case | 图标 | 自动清除 |
|---|---|---|
| `.success(String)` | 绿色 ✓ | 3 s |
| `.warning(String)` | 橙色 ▲ | 8 s |

没有 `error`：致命错误不进一行宽、会被下一条覆盖的槽位。也没有 `inProgress`：进行中的工作没有"结束者"就会永远挂着，这由 `StatusActivity` 负责。

- `StatusToast.failure(action, reason:)` / `failure(action, error:)` 生成 `"<action> failed: <reason>"`，`reason` 只取第一行。
- `StatusToast.oneLine(_:)` 取第一个非空行。
- 视图显示 `displayMessage`（截断到 80 字符），完整文本在 tooltip 与 AX value 里。截断在显示端做，是因为 `ViewThatFits` 按理想宽度选形态，过长的文本会直接退化成只剩图标。

**`StatusActivity`**——仍在运行的工作：

| 字段 | 含义 |
|---|---|
| `id: StatusActivityID` | `domain` + `key`，唯一标识一项工作；同 id 再次 begin 会替换并移到最前 |
| `title` | 现在分词短语："Merging PR #12" |
| `detail` | 次要状态："Waiting for Claude"；确定进度且 `detail == nil` 时显示 `completed/total` |
| `progress` | `.indeterminate` / `.determinate(completed:total:)` |
| `isCancellable` | popover 行是否显示 Stop |

槽位显示 `summary`（`"Title | detail"`）和进度环；多于一项时环中显示数量。点击打开列表 popover，最近开始的在上，可取消项带 Stop 按钮。

### `StatusBarFeature` 动作

| Action | 语义 |
|---|---|
| `push(StatusToast)` | 显示结果，替换当前 toast，按严重度排自动清除 |
| `begin(StatusActivity)` | 开始或重启一项工作 |
| `update(id:detail:progress:)` | 更新运行中工作的 detail / 进度；已结束则忽略 |
| `end(id:outcome:)` | 结束工作；`outcome` 非 nil 时同时 push。未知 id 也会 push，迟到或重复的 end 无害 |
| `cancelTapped(id)` | popover 的 Stop；仅对 `isCancellable` 生效，移除该项并发 `delegate(.cancelRequested(id))` |

toast 自动清除用 `sequence` 令牌防竞态：每次 push 自增，计时器触发 `.cleared(seq)` 时只有 `seq == state.sequence` 才清。`cancelInFlight` 取消旧计时器，但 `clock.sleep` 已恢复后仍可能发出旧的 `.cleared`，令牌把它丢弃。

### PR 形态

`#N` 徽章（`PullRequestNumberPill`，与 sidebar 徽章同一视图）+ `+N −M`（仅 open PR）+ `ChecksRollupRing`（passing / failing / pending / neutral 四段环，无 check 时不渲染）+ 一句简述。简述优先级：Merged / Closed → Blocked / Merge conflicts / Behind base → N checks failing → N checks pending → All checks passing → (Draft) → PR 标题。

- 单击：在 GitHub 打开 PR。
- 悬停 150 ms：弹出 `WorktreePullRequestPopover`（与 sidebar 徽章同一视图，但各自持有 popover 状态，互不抢锚点）。
- 按住 ⌘（`CommandKeyObserver`，只监听本进程 `flagsChanged`，不需要辅助功能权限）：简述换成 `Open on GitHub <chord>`，chord 读 `.openCurrentPR` 的实际绑定，默认 ⌘⇧G。

### Motivational 形态

时段图标（6–12 日出、12–17 日间、17–21 日落、其余夜间）+ 本地化短时间 + `Open Command Palette <chord>`，`TimelineView(.everyMinute)` 每分钟刷新；chord 读 `.commandPaletteToggle` 的实际绑定，缺失时用 schema 默认值。

### 窄窗口

每种形态提供完整与 compact 两档，`ViewThatFits` 依次尝试完整 → compact → 零尺寸，保证左右 toolbar 组不被挤动。compact 时 toast 只留图标、activity 只留环、PR 去掉简述、motivational 只留时间；文本仍在 tooltip / AX value 中。形态切换用 `easeInOut(0.2)` 淡入淡出；activity 之间互相替换不触发切换动画，只更新文字。

## 使用规则（各模块接入）

### 1. 谁可以发

- **子 feature 从不引用 `StatusBarFeature`。** 它们把结果暴露为自身的普通 action（`...Completed` / `...Failed` / `...Notice`），可以在 payload 里携带 `CodansCore` 的 `StatusToast` 或字符串。
- **子 feature → 状态栏的映射只写在 `StatusBarRootBindings.swift`。** 这个 reducer 挂在 `RootFeature.body` 最前面，读者看这一个文件就知道状态栏会报告什么。
- **`RootFeature` 自己拥有的 effect**（run script / command、agent 启动、hand-off、refresh、复制路径、打开链接……）可以直接 `send(.statusBar(...))`。
- 不走侧信道（全局 bus、NotificationCenter）：出了 reducer 系统，TestStore 就看不见。

### 2. 选 Toast 还是 Activity

| 场景 | 用法 |
|---|---|
| 用户动作可能超过 ~0.5 s，且没有就地进度（或进度在关闭的 popover 里） | `begin` → `end(outcome:)` |
| 动作瞬间完成，但用户看不到任何效果（快捷键复制、面板里的操作） | `push(.success)` |
| 动作失败但不阻断 | `push(.warning)` 或 `end(outcome: .warning)` |
| 已有就地进度（sidebar pending 行、sheet 进度、分支 spinner） | 不 begin；只在失败时 push |
| 效果本身可见（新 pane 打开、行消失、Finder 前置） | 不发成功 toast |
| 致命 / 需要用户决定 | sheet 或内联 banner，不进状态栏 |

### 3. Activity 生命周期

- **每个 begin 都要在所有退出路径上 end**：成功、失败、guard 早退。activity 不会自己过期。
- 子 feature 可能拒绝一个请求（已在运行、没有待确认项）时，`StatusBarRootBindings` 在 child scope **之前**读取请求到达时的 child state，只在请求会被接受时 begin。例：`mergeRequested` 在 `gitHub.mutating` 已含该 worktree 时不 begin。
- **可取消 = 真能停下。** `isCancellable: true` 的发起者必须处理 `.statusBar(.delegate(.cancelRequested(id)))`，停掉 effect 并撤销副作用。Stop 按下时 activity 已被移除，发起者之后发出的 `end` 只贡献结果 toast（通常被取消的 effect 不会再发）。
- **id 统一登记在 `StatusActivityIDs.swift`。** 一个 domain 一个工厂方法，key 取让该工作唯一的标识（worktree id、request id）。同 key 的工作天然串行化：再次 begin 替换旧项。
- 进度更新用 `update(id:detail:progress:)`，不要反复 begin（会把它移到最前）。

### 4. 文案

- 成功：过去式短句，说结果不说过程——"PR #12 merged"、"Opened in Zed"、"Copied worktree path"。
- 失败：`StatusToast.failure("<动词>", reason:)` → "Merge failed: …"。错误文本本身已是完整句子时（如 `TerminalLinkError` 的 "File not found: …"），直接 `.warning(StatusToast.oneLine(text))`。
- 注意事项（非失败）：`.warning`，先说结果再说原因，如 "Worktree removed. Branch \"x\" was kept because it's checked out elsewhere…"。
- Activity 标题：现在分词 + 对象——"Merging PR #12"、"Removing shop"；`detail` 写等待对象或进度。
- 英文、句首大写、无句号。

### 5. 新增一处接入的步骤

1. 子 feature 已有完成 / 失败 action？没有就加一个（带足够的 id 让 end 精确匹配），reducer 对它 `return .none` 即可。
2. 在 `StatusActivityIDs.swift` 加 id 工厂（只有 activity 需要）。
3. 在 `StatusBarRootBindings` 加映射；Root 自有 effect 则直接在 effect 里 send。
4. 在 `StatusBarRootBindingsTests` 加断言：begin 的 activity、end 的 outcome、被拒请求不 begin。

## 当前接入清单

| 来源 | Activity | 结果 |
|---|---|---|
| PR merge / close / mark ready / rerun failed jobs | ✓（按 worktree） | success / `<Verb> failed: …` |
| 在外部编辑器打开 | ✓（`$EDITOR` 除外，它开 pane） | "Opened in X" / 失败原因 |
| 设置项目默认编辑器失败 | | warning |
| Hand off（briefing 模式，等待源 agent 写 briefing） | ✓ 可取消：Stop = supersede 请求 + 取消等待 | "Handed off to X" / "Progress saved…" / `Hand off failed: …` |
| Hand off（context-only） | | 同上 |
| Hand off 前置条件不满足 | | warning |
| 手动 Refresh（sidebar ↻、palette 刷新当前 worktree） | ✓ | 无（完成即消失） |
| 移除 workspace / workspace 成员 | ✓ | 失败或保留分支说明 → warning |
| archive / delete worktree 失败或保留分支 | 否（行内已有进度） | warning |
| Prune | | "Pruned N stale worktrees" / "No stale worktrees to prune" / 失败 |
| Run script / command / global command、Agent 启动（header、palette、创建后） | | 失败 warning |
| Tab 栏启动 agent / 恢复会话 | | 失败 warning |
| 打开终端里 ⌘-click 的链接 | | 失败 warning |
| 打开当前 PR / 仓库（无 PR / 无 GitHub remote） | | warning |
| 复制当前 worktree 路径（快捷键 / palette） | | success |

未接入，且是有意的：

- 分支切换 / 重命名 / 新建分支：失败保留在 `BranchSwitcherErrorBannerView`，完整 stderr 需要常驻可读；成功时 header 分支名自己会变。
- 后台 PR 轮询失败：与手动刷新走同一个 `projectBatchLoaded(.failure)`，无法区分来源，报出来只会是噪音。
- Clone、创建 workspace、连接服务器、归档 sheet 内移除：各自 sheet 有进度与错误区。

## 测试

- `StatusBarFeatureTests`：toast 计时与令牌竞态、activity begin / update / end / cancel。
- `StatusBarRootBindingsTests`：子 action → 状态栏 action 的映射，含被拒请求不 begin。
- `RootFeatureTests`：hand-off 的 activity 生命周期与 Stop → supersede。
- `CodansCoreTests/StatusBar`：`oneLine` / `failure` / `displayMessage`、`summary` 与进度。

## 备选方案

- **toast 保留 `inProgress`。** 否决：单槽位里一个 inProgress 会被任何后来的 push 覆盖，而它的结束者之后会把别人的结果覆盖掉；并发两项时第一项的进度直接丢失。keyed activity 让每项工作有自己的生命周期。
- **映射留在 `RootFeature` 的 switch 里。** 否决：散落在 3000 行 reducer 的多处，还挤占 Swift 的类型推断预算；独立 reducer 集中且可以单独测试。
- **子 feature 直接发 `.statusBar`。** 否决：违反"delegate up, action down"，子 feature 会依赖兄弟 feature。
- **Root 在 child 之后根据新状态判断是否 begin。** 否决：请求被拒与被接受后 child state 可能相同（都含 `mutating`），只有请求前的状态能区分。

## 参考

- 值类型：`apps/mac/CodansCore/StatusBar/{StatusToast,StatusActivity}.swift`
- feature：`apps/mac/codans/App/Features/StatusBar/{StatusBarFeature,StatusBarRootBindings,StatusActivityIDs,StatusBarView}.swift`
- 视图：`apps/mac/codans/App/Features/StatusBar/Views/`
- 挂载：`WorktreeDetailView.statusSlot`、`RootFeature.body`
