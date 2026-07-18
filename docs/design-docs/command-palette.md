# 设计文档：Command Palette（Quick Action）

**状态：** 已上线（可见）
**作者：** Gump（与 Claude）

## 背景与范围

Command Palette 是一个键盘优先的浮层：以 `⌘P` 从主窗口任意位置唤起一个搜索框，枚举每一个可执行命令，让用户按名称模糊搜索并执行。它是**可发现性与速度的乘数，而非新能力层**——面板暴露的每条命令在别处都已有专属入口（菜单栏绑定、侧栏/头部按钮、Ghostty 键绑定）。随着动作面增长（Worktree、Pane、Editor、Git viewer、脚本），"用户得知道某动作住在哪个菜单/右键/popover"的成本呈二次增长；面板把这条成本压平。

> liveness（2026-06）：内建的 Git/diff viewer overlay **已移除**——应用内不再有可用的 diff 查看器。"Toggle Git Viewer"（`toggleDiffInspector`）命令本身仍在线，但语义已改为**在用户于 Settings → General → Default Git Viewer 配置的外部 git 客户端里打开当前 Worktree**；当该项为 None 或所选客户端未安装时为 no-op（见 [组件边界](#组件边界) 与 [keyboard-shortcuts.md](keyboard-shortcuts.md)）。Tag 过滤相关命令当前无对应——侧栏 Tag 过滤 UI 处于隐藏状态。

唤起有两条对等入口：window-scope 的 `⌘P` 和 Ghostty 的 `toggle_command_palette` 动作（经 `PaneActionRequest.toggleCommandPalette` → `PaneActionRouterFeature` 抵达 `RootFeature`）。二者落到同一开关。

## 目标与非目标

**目标**

- 单一和弦从主窗口任意位置唤起浮动搜索框。
- 现有三个动作面（菜单栏、侧栏/头部、Ghostty 键绑定）可达的每一条用户可见命令，都能从面板到达。
- 模糊匹配 + 合理排序：prefix/contiguous > subsequence > subtitle-fallback；近期运行过的命令上浮；语境无效的命令不出现。
- 激活命令即关闭面板，并经该 feature **既有的** action 执行——不复制任何代码路径。
- Recency 跨重启存活。

**非目标**

- 不发明一等公民动作。面板只暴露既有能力。
- 无 VS Code 式模式前缀（`>` 命令、`@` 符号、`:` 行号）。面板是扁平模糊列表，无模式切换；本应用没有 symbol / 行号概念，前缀模式不增信息。
- UI 无分组标题 / 分类分节。排序纯由分数与 recency 决定。
- 无用户自定义命令 / 脚本宿主（用户脚本是经 `ProjectSettings.scripts` / `GeneralSettings.globalScripts` 暴露的既有命令，不是面板自定义机制）。
- 无多窗口感知。应用为单窗口，面板挂在唯一的 `WindowGroup` 上。

## 设计总览

一个 TCA feature——`CommandPaletteFeature`——拥有面板的 query、selection、呈现状态，作为 `RootFeature` 的子节点，以全表面 ZStack overlay（**非 `.sheet`**）呈现为距窗口顶部约 15% 的浮动卡片。

**核心设计规则——按需从实时状态重新生成项，无注册协议。** feature **不持有自己的命令目录**。每次打开 / 搜索态变化时，由纯函数 `CommandPaletteItems.build(...)` 读取实时 `Catalog`、当前 `HierarchySelection`、已装 editor descriptors 与 `settings.json` 快照，重新生成可见列表。这条"按需重建"选择让语境敏感变得平凡——未选中 Worktree ⇒ Worktree 域命令自然缺席列表，无需任何额外过滤逻辑——并免去了一套注册协议。

**核心权衡：** 选*过程式生成* + *TCA delegate 路由*，而非*provider 注册表* + *携闭包的命令*。过程式生成是几十行直线 Swift；加一条命令 = 加一个 `Kind` case + 一个 `RootFeature` 分支。注册表模式要在前期付出真实复杂度成本，去省每条新命令的边际成本——在首版约 25 条命令的规模下属过度设计。注册表还会把排序与去重逻辑拽进表内（过程式代码里这些是免费的），并在 `CodansCore` 引入跨 target 的 public 协议面。若日后真出现第三方扩展面（plugin 式，或由 `.claude/skills` 驱动），从过程式重构到注册表是机械的、可以等。

```
       ⌘P menu command ┐
                        ├──► RootFeature.Action.commandPalette(.togglePresented)
 ghostty keybind ───────┤
 (PaneActionRouter)     │
                        ▼
┌──────────────────────────────────────────────┐
│         CommandPaletteFeature                 │
│  State: isPresented, query, selectionID,      │
│         items [rebuilt on open + recompute]   │
│         @Shared recency: [ID: Timestamp]      │
│  ────────────────────────────────────────     │
│  Reducer filters items via FuzzyScorer,       │
│  emits .delegate(.activate(Kind))             │
└──────────────────────┬───────────────────────┘
                        │  RootFeature pattern-matches Kind and forwards
                        ▼
   existing features execute the work (no new business logic added)
```

面板视图挂在 `ContentView` 里，作为主 `NavigationSplitView` 之上的条件 overlay。（原与 Git Viewer overlay 共用同一 `ZStack`；内建 Git Viewer overlay 移除后，面板是该 `ZStack` 里的主 overlay。）

## 数据模型

### `CommandPaletteItem` 与 `Kind`

`CommandPaletteItem` 携带 `id`（跨重启稳定，recency 键）、`title`、可选 `subtitle`、可选 `searchText`（被模糊评分以 title 级优先级匹配但**不在行内显示**——让一项能凭可见标题里没有的词上浮，例如 "Switch to Worktree: <name>" 把 Project 名放进 `searchText`，使 Project 名查询命中它而非沉到 subtitle 带）、`icon`、可选 `shortcut`（展示用提示）、可选 `commandID`（接入快捷键 registry，使行内和弦显示随用户改键流动）、`priorityTier`，以及 `hiddenWhenQueryEmpty`。

`Kind` 枚举覆盖各域命令：App（`openSettings` / `checkForUpdates` / `quit`）、Worktree（`selectWorktree(ProjectID, WorktreeID)` / `closeCurrentWorktree` / `refreshCurrentWorktree` / `toggleDiffInspector`）、Editor（`openCurrentWorktreeInDefaultEditor` / `openCurrentWorktreeIn(EditorID)` / `revealCurrentWorktreeInFinder`）、Project / Global 脚本（`runProjectScript` / `runGlobalScript`，各携 `(ProjectID, WorktreeID, ScriptDefinition.ID)`），以及 Pane / Window 的薄包装 `paneAction(PaneActionRequest)` / `windowAction(WindowActionRequest)`。

> `toggleDiffInspector`（面板项 "Toggle Git Viewer"）当前路由到 `RootFeature.diffInspectorToggledForCurrentWorktree`，把当前 Worktree 在 `Settings → General → Default Git Viewer` 配置的**外部 git 客户端**里打开——内建 diff overlay 已移除（`RootFeature.swift:1454`）。命令名沿用历史的 "diff inspector / Git viewer" 字样，但应用内**无任何内建 diff 查看器**；Default Git Viewer = None 或客户端缺失时该项为 no-op。

**`runProjectScript` / `runGlobalScript` 携 `(projectID, worktreeID)` 是设计决定，不是冗余。** 命令在构建项时捕获当时的选择，使路由跑在*构建该项时的那个确切选择*上，即便用户在打开与激活之间切换了选择。

**稳定 ID 命名约定**（跨重启稳定）：

- 静态命令：`"app.open-settings"`、`"git.toggle-viewer"`。
- 带持久实体的参数化命令：`"worktree.select.<WorktreeID>"`、`"editor.open.<EditorID>"`、`"project.script.<ProjectID>.<scriptID>"`。
- 带瞬态目标的参数化命令：`"pane.split.right"`、`"window.toggle-fullscreen"`——参数是 ID 的一部分，而非当前 pane 身份。

这让"切换到 Worktree X"的 recency 在 X 在 Project 间移动时仍存活——ID 钉在实体身份而非位置上。Global 脚本 ID 只用脚本自身 UUID（无 project 前缀），因为无论选中哪个 Worktree，它都是同一条目。

### Recency（`@Shared`，不在 feature state 上）

Recency 写重（每次激活写）、过滤时只读。提升到 `@Shared(.appStorage("commandPaletteRecency"))`（`[String: TimeInterval]`），避免把它穿过每个 action payload；与应用其他展示偏好同构。**不**经 `SettingsStore`。

`items` / `filtered` 留在 feature state 上（而非计算属性），使测试能确定性地断言过滤输出。每次打开从空 query 起步、首位项预选中；query 文本 / selection / 呈现态都不持久化——一个会记住上次 query 的面板带来的困惑多于帮助。

### 模糊评分（`CommandPaletteFuzzyScorer`，纯函数）

单一入口 `score(item:query:recency:now:) -> Int?`（更高者胜；`nil` = 不匹配，丢弃）。**分层评分策略**，这是面板手感的核心耐久不变量：

1. **空 query：** `hiddenWhenQueryEmpty == true` 的项返回 `nil`（保留给"Delete Worktree""Quit"等破坏性 / 锐利命令，使它们不在静息列表里露面）；其余项返回 `recencyScore + priorityBoost`。
2. **非空 query：**
   - 先尝试把 query 作为 `title` 的**连续（contiguous）子串**（折叠大小写）拟合。命中 → 基底 `0x2_0000` + 长度比加成（标题相对 query 越短越胜）。
   - 否则尝试**子序列（subsequence）匹配**（字符按序、允许间隔）：title → 基底 `0x1_0000`；subtitle 兜底 → `0x0_8000`。分数对每个紧跟**分隔符**（`/`、`-`、`_`、`.`、空格）或**词首大写**的字符加成；并惩罚总匹配跨度（跨度越短越好）。
   - `"..."` 内多字符强制连续模式。
3. **Recency 项：** `recencyScore = K · 0.5^(ageDays / 7)`，**限 30 天**封顶；K 选得使 recency 能在**同一分数桶内重排、但不能把一个 contiguous 命中翻到 subsequence 命中之下**——即只在桶内、不跨层。
4. **优先级层：** 项可设 `priorityTier < 100` 上浮（默认 100）；该层加一个常量增量，同样停留在桶内。

Tiebreak 按序：更高分 → 更短标题 → 更早匹配位置 → 字母序。相同输入下确定性。

分层 + 桶内 recency 的设计要点：**层级边界由分数基底（`0x2_0000` / `0x1_0000` / `0x0_8000`）硬隔开**，recency 与 priority 的增量都被 K 钳在远小于一个基底差的范围，故"最近用过"与"优先上浮"只重排同质命中，绝不让一个弱匹配越过一个强匹配。这是排序可预测的根因，不可"简化"成单一加权和。

不引入第三方模糊匹配库：手写评分把排序策略保持在单文件内可审、可用确定性纯函数测试，省去为约 120 行评分代码引一个 SwiftPM 依赖。

## 组件边界

```
apps/mac/codans/App/Features/CommandPalette/
  CommandPaletteFeature.swift             // reducer / state / actions / delegate
  CommandPaletteItem.swift                // Item struct + Kind enum，无行为
  CommandPaletteItems.swift               // build(...) 纯函数：(Catalog, selection, editors, settings) → [Item]
  CommandPaletteFuzzyScorer.swift         // 纯评分，无 TCA import
  CommandPalettePruner.swift              // recency prune-on-open + 容量上限
  CommandPaletteRecencyPersistence.swift  // @Shared appStorage 桥
  CommandPaletteView.swift                // overlay 卡片 / 文本框 / 列表 / 行
  KeyEquivalentDescriptor.swift           // 行内 shortcut 提示渲染（展示用，非真实绑定）
```

`RootFeature` 拥有激活开关：pattern-match `Delegate.activate(Kind)` 并转发到既有 feature action（`.toggleDiffInspector`、`.panelActionRouter(.requested(paneID, req))`、`.windowActionRouter(...)`、脚本运行等）。**这是面板与应用其余部分的全部集成面——无新 dispatch 路径，无新 client。** 每个 case 复用一个既有 action。

依赖方向：`CommandPaletteItems` / `CommandPaletteFuzzyScorer` 是无 TCA 依赖的纯函数，可独立单测；feature 编排它们；`RootFeature` 路由。

## 项构建的语境带

`CommandPaletteItems.build(...)` 每次打开调用一次（非每次击键），在三个语境带内产出项：

1. **始终：** app 级命令。
2. **选中 Worktree 时：** Git viewer toggle（"Toggle Git Viewer"——现打开外部客户端，见上文 `Kind` 段标注）、editor-open（每个已装 `EditorDescriptor` 一条）、refresh、delete、reveal in Finder，以及该 Project 的 `ProjectSettings.scripts` 与 `GeneralSettings.globalScripts`（脚本经 `SettingsWriter` 读实时快照，切到别的 Project 即重建并暴露那个 Project 的脚本）。Tag 过滤命令未进面板——侧栏 Tag 过滤 UI 当前隐藏。
3. **聚焦 Pane 时：** 需要源 pane 的 `PaneActionRequest` / `WindowActionRequest`。若无聚焦 pane，这些项被略去而非以合成 paneID 发出。

**精确聚焦的区分是耐久不变量。** 依赖"哪个 split 聚焦"的 pane 动作（split / focus 导航 / zoom）**仅当 pane 经 Ghostty 键绑定管线带入（精确聚焦）时才发出**；菜单触发的打开会略去它们，使用户绝不会看到一个"Focus Pane Left"从错误的 pane 静默导航。Tab 域动作（New Tab / Close Tab / Equalize）与 Window 域动作只需当前 tab 里任一 leaf 即可解析（同 tab 每个 leaf 映射到同一 NSWindow），故 fallback 解析的 paneID 足矣，无论聚焦是否精确都安全。

`hiddenWhenQueryEmpty` 把破坏性命令（Delete Worktree / Close Tab / Close Window / Quit）挡在静息列表外——只有当用户键入命中它们的非空 query 时才出现，绝不在"刚打开面板"的默认列表里露面。

## 持久化与 prune-on-open

只有 recency 字典持久化（UserDefaults 键 `commandPaletteRecency`，`@Shared(.appStorage)`）。

每次 `.togglePresented`：

1. 从当前 catalog / selection / editor / settings 重建 `items`。
2. **Prune recency**（`CommandPalettePruner`）：丢弃 ID 命中**动态前缀**（`worktree.select.` / `editor.open.` 等——指向可能已删实体的 ID）且不再出现在当前 items 集合里的条目；静态命令 ID 永不按此规则 prune（它们总能解析）。再以时间戳 LRU 把字典封顶在 200 条，作为对病态 prune 漏网的双保险。
3. 从 `items ∩ query` 重算 `filtered`。

> Pruner 的 `dynamicPrefixes` 出于历史兼容仍列着已废弃的 `space.select.` 前缀（Space 模型移除后已无项再生成它）——保留它纯粹是为了清掉老安装里残留的 `space.select.*` recency 条目；不要把它当作仍存在的命令域。

prune 是 O(n) 且只在打开时跑，成本被框在 `⌘` 按下到首帧之间的一次击键间隙内（约 16 ms 预算）。**稳定 ID + prune-on-open 是 recency 不随实体删除而无界增长、又能跨实体移动存活的根因**：ID 钉在实体身份让"切换到 Worktree X"的偏好在 X 移动 Project 后仍有效，prune-on-open 则在 X 被删后回收它。

## 呈现与交互

- 全表面 ZStack overlay（非 `.sheet`），560pt 宽上限、列表 360pt 高上限（约 8 行），距顶 15%——为 13"–16" 屏调校，无布局条件分支。
- `FocusState` 在出现时强制文本框聚焦，键入即刻开始。
- `.onKeyPress` 在 overlay 作用域处理 Esc（关闭）/ 上下方向键（选择移动，带 wrap）/ Return（提交）；scrim 点击或选中项亦关闭。
- 空列表上 Enter 为 no-op（reducer 在 `filtered.isEmpty` 时短路 `.selectionCommitted`）——静默胜过闪烁。

面板是 fire-and-forget：失败命令（如关闭已空 Worktree 的最后一个 pane）经其所属 feature 既有错误路径报告；面板自身无错误态，激活后无论下游结果如何都关闭，与菜单栏行为一致。

## 为何选 ZStack overlay 而非 `.sheet`

否决 `.sheet`，三条具体理由：macOS 14+ 上 sheet 动画更慢（约 250 ms）且以灰 scrim 压暗窗口 chrome，比面板该有的分量重；sheet 在 reducer 看到之前就完全接管键盘焦点并抢走 `Esc` 语义，复杂化"选中即执行后由 reducer 关闭"的流程；sheet 按窗口而非内容区定位，侧栏折叠时有效中心偏移。ZStack overlay 给出像素精确定位、原生 `.onKeyPress`、以及廉价的 `.scale + .opacity` 出现动画。

亦否决独立浮动 `NSPanel`（Spotlight 式常驻置顶窗口）：本应用单窗口，从别的 app 打开面板非目标，额外的 AppKit 桥接 / NSWindow 生命周期 / key-window 管理不值当；多窗口若日后落地再议。

## 风险

| 风险 | 缓解 |
|---|---|
| `⌘P` 与用户为 print-to-PDF 等配置的 Ghostty 键绑定相撞 | window-scope 的菜单绑定对 SwiftUI 胜出；冒泡经 `performKeyEquivalent` 的 in-ghostty 快捷键在手测中确认不双触发；若现冲突，使 `⌘P` 在 Settings → Shortcuts 可改键。 |
| 评分排序在真实目录上手感不对 | 评分是单文件、无依赖者，重调常量可平凡回退。 |
| 动态实体命令 ID 在实体删除后于 recency 累积 | prune-on-open（见上）+ 字典封顶 200，LRU 逐出。 |
| 全表面 overlay 在打开时挡住 Ghostty 键事件处理 | 这是 Esc / 方向键 / Enter / 键入的**预期**行为；关闭时 overlay 不在视图树，Ghostty 正常收键。 |
| 日后新增 feature action 时忘了加进面板 | 低度税，仅靠约定（无强制契约）；可经日志分析侦测漂移：连续数周零面板激活的 feature 是缺项候选。 |

## 参考

- 层级 / 选择：`apps/mac/CodansCore/{Catalog,Project,Worktree,Tab,Pane}.swift`、`HierarchySelection`
- 动作请求枚举：`apps/mac/CodansCore/{PaneActionRequest,WindowActionRequest}.swift`
- 快捷键 registry（行内和弦显示来源）：`apps/mac/CodansCore/Shortcuts/`，见 [keyboard-shortcuts.md](keyboard-shortcuts.md)
- Ghostty 键绑定路由：`apps/mac/codans/App/Features/PaneActionRouter/`
