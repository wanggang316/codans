# 设计文档：Pane Layout

**状态：** P1 已上线（可见）：模型与迁移、内容运行时、每 Pane 一条 tab 条、键盘、CLI / IPC / 环境变量；P2 的 chip 拖拽（条内重排、移到另一 Pane 的条、拖到 Pane 四边生成新 Pane）已上线；P2 其余项（布局区边缘 split、zoom 退出控件）与 P3 已规划
**作者：** Gump（与 Claude）
**实现：** 模型与迁移 `apps/mac/CodansCore/`（Pane / Tab / ContentSnapshot / SplitTree / catalog v3 → v4 迁移器）；内容运行时 `apps/mac/codans/Runtime/Content/`；布局与 tab 条 `apps/mac/codans/App/Features/TabBar/` 与 split 视口；CLI `apps/mac/codans-cli/Commands/{TabCommands,PaneCommands,TerminalCommands}.swift`。词汇表见仓库根 [CONTEXT.md](../../CONTEXT.md)；决策记录见 [ADR-0001](../adr/0001-three-ids-pane-tab-content.md)、[ADR-0002](../adr/0002-content-runtime-outside-hierarchy-manager.md)。

## 背景与范围

Worktree 的内容区由一棵 split 树组成，叶子是 **Pane**；每个 Pane 自带一条 tab 条，条上的每个 **Tab** 装一份 **Content**（第一期只有 terminal 一种）。层级为 `Project → Worktree → Pane → Tab`，Content 是 Tab 的载荷，不算一级。

本文定义：数据模型与不变量、焦点与选中、键盘与 CLI 的作用对象、tab 条与拖拽、内容运行时、catalog v4 与 v3 → v4 迁移、公共面（环境变量 / CLI / IPC）的映射表。主窗口其余子系统（Sidebar、Header）见 [main-window.md](main-window.md)。

## 目标与非目标

### 目标

- 一个 Worktree 内可以并排、嵌套排列多个 Pane，每个 Pane 内可以堆叠多个 Tab，一次只显示其选中 Tab。
- 会话身份跨迁移、重启、布局变动稳定：zmx 会话、agent 状态、通知、command queue 以 ContentID 记账。
- 内容运行时与层级管理分离，内容种类可增而不改共享层。
- 规则明确：每个 id、每个 CLI 动词、每个环境变量只有一个含义。

### 非目标

- 自由浮动（canvas）布局；Pane 只能在 split 树里平铺。
- 跨 Worktree、跨窗口拖拽 Tab。
- 对旧 CLI 二进制、旧 IPC 形状、旧环境变量语义的在线兼容。CLI 与 app 同包同版本。
- 内容的 hibernate / wake 动作；surface 回收沿用 [surface-reclaim.md](surface-reclaim.md)。

## 设计

### 概览

```
Worktree
└── splitTree: SplitTree<PaneID>          focusedPaneID
    ├── Pane A ── tabs [Tab a1*, Tab a2]   selectedTabID = a1
    │              └── Content (terminal) ── Surface
    └── Pane B ── tabs [Tab b1*]
```

三个 id 各司其职（ADR-0001）：

| id | 指向 | 用途 |
|---|---|---|
| `PaneID` | split 树叶子 | 布局、焦点、容器级 CLI 动词 |
| `TabID` | 条上的位置 | chip 属性（标题、颜色、图标）、tab 级 CLI 动词、键盘选中 |
| `ContentID` | 会话身份 | zmx 会话名、agent 状态、通知来源、command queue、run-script 绑定、`CODANS_CONTENT_ID` |

### 数据模型（CodansCore）

```swift
struct Worktree { …; var splitTree: SplitTree<PaneID>; var panes: [Pane]; var focusedPaneID: PaneID? }

struct Pane: Identifiable { let id: PaneID; var tabs: [Tab]; var selectedTabID: TabID? }

struct Tab: Identifiable {
  let id: TabID
  var name: String?                 // user-set title; nil follows the live title
  var cachedDisplayTitle: String?
  var color: TabColor?
  var icon: String?
  var iconLock: TabIconLock
  var content: ContentSnapshot
}

struct ContentSnapshot { let id: ContentID; var state: ContentState }

enum ContentState { case terminal(TerminalContentState) }   // kind-keyed; additive

struct TerminalContentState {
  var workingDirectory: String
  var labels: Set<String>
  var agentKind: AgentKind?
  var agentSessionID: String?
  var runScriptID: UUID?
  var commandQueue: [QueuedCommand]
  var initialCommand: String?       // live-only, never encoded
}
```

`catalog.json` 的 Tab 条目形如：

```json
{ "id": "…", "name": "dev server", "color": "blue",
  "content": { "id": "…", "state": { "kind": "terminal", "terminal": { "workingDirectory": "/…" } } } }
```

### 不变量

- split 树的叶子集合与 `panes` 的 id 集合一一对应，无重复。
- Pane 永不为空：关闭最后一个 Tab 即关闭 Pane；Worktree 可以零 Pane。
- 每个 Pane 的 `selectedTabID` 指向自己的一个 Tab。
- `focusedPaneID` 当且仅当 `panes` 非空时存在，且指向一个存在的 Pane。
- 全 Worktree 内 TabID、ContentID 各自唯一。
- 解码只修复悬空引用（选中、焦点），不调和树与 panes；加载器与迁移器以 `isConsistent` 守门，不一致则整份拒绝。

### 焦点与选中

- `focusedPaneID` 与各 Pane 的 `selectedTabID` 持久化；切回 Worktree 时恢复到焦点 Pane 的选中 Tab。
- 键盘和 Tab 级快捷键作用于焦点 Pane：⌘T 新 Tab、⌘W 关 Tab、⌘1–9 按位置选 Tab、⌘⇧[ / ⌘⇧] 相邻 Tab。
- Pane 级：splitRight / splitDown 在焦点 Pane 旁新建 Pane 并放一个新 Tab；四向 focusSplit 移动焦点；toggle zoom 作用于焦点 Pane。不新增和弦。
- Zoom 按 Pane：被 zoom 的 Pane 填满布局区，其 tab 条照常显示并在条尾提供退出控件。

### Tab 条

- 每个 Pane 一条，复用现有胶囊 tab 条实现（`TabBarView` 系列，含溢出堆叠与新建 / 关闭动画）。
- 焦点 Pane 的条用活动样式；非焦点 Pane 的条用非活动窗口样式（按 Finder 非活动窗口实测补齐）。
- 条尾控件：“+”（含 agent 菜单）与 agent 历史。Pane 宽度不足时只保留 “+”，历史收进 “+” 的菜单。split 经键盘、命令面板与 chip 的动作菜单。
- 每个 chip 悬停时两端各出一个同尺寸按钮：左端关闭 Tab，右端 “…” 弹出该 Tab 的动作菜单（`TabActionsMenu`）：交接、命令队列，再按终端右键菜单的分组列出 `PaneSurfaceAction`（复制、粘贴、四向 split、重置、复制 ID、关闭 Tab）。没有选区时复制项禁用而不隐藏。
- 条与上方边缘、条与下方内容的间距相同（`trackTopInset` = `trackBottomInset`）。贴着布局区顶边的条不留上间距：工具栏自身已在按钮下方留出间距，track 与工具栏按钮的距离因此与 Safari 的 tab 栏相同。
- track 高 32，取自 Safari（macOS 26）的 tab 栏；标题字号、颜色与曲线取自系统窗口 tab 栏（`NSTabBar`）。
- 条左端没有关闭 Pane 的按钮；关闭 Pane 经 `pane close`、右键菜单或关掉最后一个 Tab。

### 分隔线

- Pane 之间是平铺的，参照 Xcode 编辑器分栏：无圆角、无间隙，相邻两个 Pane 之间画一条 1pt 的浅分隔线（`separatorColor` 的 60%）。
- 分隔线是调整比例的拖动区，双击均分。

### 拖拽（P2）

- 只拖 Tab chip。条内拖动重排；拖到同 Worktree 另一个 Pane 的条上移动过去，插入点按光标与各 chip 中线比较，目标条在插入点让出空位；拖到 Pane 内容区，按最近的一边在该 Pane 旁生成新 Pane（`PaneDropZone`），落点以半 Pane 高亮预览；拖到布局区边缘生成跨越根的 split。
- Tab 移动不重建内容：`HierarchyManager.moveTab(_:toPane:at:)` 与 `splitTab(_:beside:direction:)` 只改 catalog，移入的 Tab 在目标 Pane 选中并获得焦点。移走最后一个 Tab 的 Pane 随之关闭；Pane 唯一的 Tab 拖到别的 Pane 边上等于移动整个 Pane，拖到自己 Pane 上不是落点。
- 拖拽状态由每个视口一个的 `TabDragSession` 持有：chip 自己的 `DragGesture` 驱动它，各条与内容区按窗口坐标登记 frame，由它判定落点。光标在源条内时由源条就地重排；离开源条后浮起的 chip 画在视口层。
- 跨两个 Pane 的落点预览画在父 split 上。无有效落点时松手无操作。
- 不提供整 Pane 拖动，内容区上方没有拖动把手。

### 关闭确认

设置项 `closeTabConfirmation: busy | always | never`，默认 `busy`。关 Tab 与关 Pane 共用：`busy` 在目标 Tab 内有未结束的前台命令、agent 处于 working、或 command queue 非空时确认；`always` 总是确认；`never` 直接关。

### 内容运行时（ADR-0002）

放在 `apps/mac/codans/Runtime/Content/`：

| 类型 | 职责 |
|---|---|
| `TabContent`（协议） | 一种内容的实现：创建、挂载、卸载、关闭、接受焦点。`TerminalContent` 是第一个实现，持有 surface 生命周期。 |
| `ContentRuntime` | 按 `ContentID` 的活体注册表；创建与销毁内容实例，供视图按 id 取 renderer。 |
| `TabChrome` | 每个内容一个 observable，向 tab 条暴露忙碌、进度、徽标、只读、实时标题。 |
| `ContentGeometry` | 挂载时的像素尺寸与缩放，用于按槽位大小创建 surface。 |

`HierarchyManager` 只持有 catalog 变更与结构性运行态（焦点流、选择）。`AgentStateStore`、`SurfaceReclaimPolicy`、通知 inbox 以 `ContentID` 为键。

### 公共面

#### 环境变量

| 变量 | 值 |
|---|---|
| `CODANS_PANE_ID` | 所在 Pane 的 id |
| `CODANS_TAB_ID` | 所在 Tab 的 id |
| `CODANS_CONTENT_ID` | 会话身份；agent 与脚本定位"自己"用它 |

#### CLI

| 命名空间 | 动词 | 对象 |
|---|---|---|
| `codans tab` | list / show / new / focus / rename / close / send / send-key / capture / read / info / label / reset | Tab 及其 Content |
| `codans pane` | list / focus / split / close / resize / equalize / zoom | Pane |
| 顶层 | `send` / `send-key` / `capture` / `broadcast` | 目标经 `--tab` 或 `--pane`，`--pane` 解析为该 Pane 的选中 Tab |

- 任何接受 id 的位置，Pane id、Tab id、Content id 都认，解析到所属层级；短句柄只有 `p<n>` / `t<n>`。
- `pane close` 收到 Tab id 时报错并提示 `tab close`。`pane split` 新建 Pane 与首个 Tab，打印新 Tab id。
- `broadcast` 作用域：`pane`（Pane 内全部 Tab）、`worktree`、`label`。
- 旧位置的动词（如 `pane send`）报错并指向新位置，退出非零。

#### IPC

`hierarchy.describe` 输出 `WorktreeDescription { focusedPaneID, paneCount }`、`PaneDescription { id, handle, worktreeID, selectedTabID, tabIDs, isFocused }`、`TabDescription { id, handle, paneID, contentID, title, name, icon, color, isSelected, workingDirectory, labels, agent, agentSessionID, isLive }`。`TargetHandles` 含 `panes` 与 `tabs`。IPC 握手版本号随之提升。

### 持久化与迁移

- `Catalog.currentVersion = 4`。
- **v3 → v4**：加载时在内存迁移，先经 `StoreBackup` 留一份 v3 副本，再立即写出 v4。规则：
  1. Worktree 当前选中的旧 tab 的 split 树决定 Pane 布局，每个叶子会话成为一个单 Tab 的 Pane。
  2. 其余旧 tab 按顺序，把各自的会话堆进焦点 Pane 的条里；多叶子的旧 tab 按叶序摊成相邻 Tab。
  3. 每个旧会话的 UUID 原样成为 ContentID；TabID、PaneID 新生成。
  4. 旧 tab 的 name / cachedDisplayTitle / color / icon / iconLock 写到它第一个会话的 Tab 上。
  5. 旧 zoom 状态与零会话的旧 tab 丢弃；旧 `selectedTabID` 为空时以第一个 tab 为焦点来源。
  6. 任一记录不可读则整个迁移不执行、不写文件，进入只读界面。
- **版本高于本构建**：只读的“需要升级”界面；不挪文件、不保存、不运行 session reaper 与 unread 清扫。
- **v4 容错解码**：单个 Tab 不可读只丢该 Tab 并计数；丢失数大于零时本次启动关闭 session reaper 与 unread 清扫。
- settings：以会话为对象的键按新词汇命名——`notifications.mute.mutedPaneIDs` → `mutedContentIDs`（静音跟着会话走）、`ScriptOnFinished` 的 `closePane` → `closeTab`——经 `SettingsMigration` 一次性读旧写新。

### 组件边界

| 组件 | 拥有 | 不拥有 |
|---|---|---|
| `CodansCore`（Pane / Tab / ContentSnapshot / SplitTree / 迁移器） | 模型、不变量、v3 → v4 迁移 | AppKit、运行时 |
| `HierarchyManager` | catalog 变更、焦点与选择流 | 内容活体状态、surface |
| `Runtime/Content/` | 内容实例生命周期、TabChrome | catalog 结构变更 |
| `SplitViewport` / `PaneView` / `TabBarView` | split 树渲染、每 Pane 的条、落点 | 内容创建（经 ContentRuntime） |
| `TabBarFeature` / `PaneActionRouter` | 把 UI 意图转发到 `HierarchyClient` | catalog 状态 |
| CLI / IPC handlers | token 解析、描述输出 | 布局规则 |

依赖方向：app → CodansCore，单向；CodansCore 不 import AppKit。

## 备选方案

- **Tab 在外、split 在 Tab 内**（Worktree → Tab → 分屏会话）：一个 Worktree 只能同时看到一个 Tab 的分屏，无法并排堆叠两组会话；分屏几何绑在 Tab 上，会话跨 Tab 移动要拆树。
- **容器取名 Card，会话保留 Pane**：保住 `pane` 动词与 `CODANS_PANE_ID` 的旧义，但与业界（Xcode 编辑器、同类终端产品）的 pane / tab 用法相反，且 UI 文案里的 "tab" 与模型里的 Pane 指同一物。
- **不引入 ContentID，TabID 兼作会话身份**：少一个 id，但内容在 Tab 之间移动、未来 hibernate 或替换内容时身份随 Tab 走，无法独立记账。

## 横切关注

- **测试**：CodansCore 先写模型不变量与迁移测试；`HierarchyManagerTests` 的核心不变量改为 Pane 永不为空 + 焦点一致；CLI 黑盒回归 harness 全动词；隔离实例截图核对条样式。
- **开发隔离**：本分支构建用私有 `CODANS_CONFIG_DIR` / `CODANS_STATE_DIR` 运行，不与其它分支的 dev 构建共用 catalog。
- **文档**：product-spec C2 与术语表、architecture.md、`skills/codans-cli/SKILL.md`、cli.md、main-window.md 的 Tab Bar 节同一 PR 改写；CHANGELOG 设 Breaking 小节。

## 风险

| 风险 | 缓解 |
|---|---|
| `Tab` / `Pane` 两个类型名互换，中间态难读 | 一组原子提交内在 CodansCore 新建新模型并删除旧类型，由编译器驱动改完全部调用点 |
| 迁移丢会话 | ContentID 延续旧 UUID；迁移前留 v3 副本；不一致整份拒绝；丢失计数关闭 reaper |
| 旧构建读到 v4 | 本构建起版本高于自身即只读；不再把文件挪走 |
| 每 Pane 一条 tab 条放大终端挂载停顿 | `TerminalMountDeferral` 按 Pane 生效：关掉当前 Tab 时只让该 Pane 的内容区等条的动画播完，条与其他 Pane 照常显示 |

## 分期

- **P1**：模型 + 迁移 + 内容运行时 + 每 Pane 条 + 键盘 + CLI / IPC / skill / 文档。
- **P2**：chip 拖拽（已上线）、布局区边缘 split、zoom 退出控件。
- **P3**（各自另开设计）：hover-to-focus、未聚焦变暗、窗口模式、内容种类扩展。
