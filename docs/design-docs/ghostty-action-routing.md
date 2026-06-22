# 设计文档：Ghostty Action Routing

**状态：** 已上线
**作者：** Gump（与 Claude）

## 背景与范围

libghostty 把每一个用户可配置的 keybinding 暴露成一个 **action**：用户按下绑定键时，libghostty 不自己应用该绑定，而是回调 runtime-config 的 `action_cb(app, target, action)`。宿主决定是否消费每个 action（返回 `true`），还是让 Ghostty 回退到它的默认行为（几乎总是 no-op——libghostty 自身没有 UI）。

这套路由替代了早先那个永远返回 `false` 的 `action_cb` 桩：在桩状态下，用户在 Ghostty 里配的**每一个** `keybind` 都静默 no-op，每一个 surface 发出的信息型 action（title / pwd / bell / mouse shape / search 状态）都被丢弃，每一次 app 级配置热重载都被忽略。终端能绘制、能接受输入，是因为*渲染*与*键盘*路径绕过了 `action_cb`——但任何需要宿主*响应* ghostty 事件去**做**的事都不会发生。

本设计路由 codans 有明确映射的**全部** ghostty action，而非增量子集。理由：解码器在各桶之间形状一致，多覆盖一批 action 的边际成本只是一个 `case` + 一个 `SurfaceInfo` 字段；而每一个未路由的 action 对用户都是一次静默失败，"半覆盖的 keybinding 系统"换来的分诊成本远超推迟的收益。

### 我们在其上构建的既有状态

- `GhosttyRuntime` 持有 `[PaneID: PaneSurface]` 注册表，以及一个 `weak shared` 静态量用于 UAF-safe 的回调跳转。
- `PaneSurface` 把 16 字节的 `PaneID.raw.uuid` 作为 surface 的 libghostty userdata 内嵌；`ghostty_surface_userdata()` 取回该指针，使 surface 作用域的回调无需解引用 Swift 对象内存即可解析出 Pane。
- `TerminalEngine` 是多订阅者的事件流扇出；生命周期事件经 `TerminalEvent` 发出。
- 不变量"Runtime is TCA-free"由 `docs/architecture.md` §Architectural Invariants 声明——Runtime 只暴露 `@Observable` + AsyncStream 缝，TCA 活在 `apps/mac/codans/App/*`。

## 目标与非目标

**目标**

路由 codans 有明确映射的每一个 ghostty action，按四个分发语义归桶。每个 case 必须要么成功（返回 `true`）、要么是带日志行的显式有意 no-op（返回 `false`）、要么把一个 intent 提升到 `TerminalEvent` 流上交给 TCA feature 消费。**没有静默 fall-through。**

action 集合按宿主侧分发语义分成四类（外加一个 app 级 config 类）。**权威的是分桶分类与下方不变量，而非某个精确的 case 计数**——libghostty 的 action tag 集合会随版本增删，按桶归类是稳定契约，逐 case 清单不是。

- **Bucket 1 — Tab / Split intent**（→ `PaneActionRouterFeature` → `HierarchyClient`）：`NEW_TAB` / `CLOSE_TAB` / `MOVE_TAB` / `GOTO_TAB` / `NEW_SPLIT` / `GOTO_SPLIT` / `RESIZE_SPLIT` / `EQUALIZE_SPLITS` / `TOGGLE_SPLIT_ZOOM` / `PRESENT_TERMINAL` / `TOGGLE_COMMAND_PALETTE` 一类。
- **Bucket 2 — Window / App intent**（→ `WindowActionRouterFeature` → `NSWindow` + app 服务）：`NEW_WINDOW` / `CLOSE_WINDOW` / `CLOSE_ALL_WINDOWS` / `GOTO_WINDOW` / `TOGGLE_FULLSCREEN` / `TOGGLE_MAXIMIZE` / `TOGGLE_TAB_OVERVIEW` / `TOGGLE_VISIBILITY` / `TOGGLE_BACKGROUND_OPACITY` / `QUIT` / `CHECK_FOR_UPDATES` / `OPEN_CONFIG` 一类。其中 `TOGGLE_WINDOW_DECORATIONS`（macOS 无逐窗装饰开关）与 `TOGGLE_QUICK_TERMINAL`（codans UX 当前不提供 quick-terminal HUD）是**显式有意 no-op**。
- **Bucket 3 — Surface info**（→ `PaneSurface.SurfaceInfo` + `panelInfoChanged` 事件）：title 族（`SET_TITLE` / `SET_TAB_TITLE` / `PROMPT_TITLE` / `PWD`）、mouse 族（`MOUSE_SHAPE` / `MOUSE_VISIBILITY` / `MOUSE_OVER_LINK`）、geometry 族（`CELL_SIZE` / `SIZE_LIMIT` / `INITIAL_SIZE` / `RESET_WINDOW_SIZE`）、`COLOR_CHANGE` / `RENDERER_HEALTH` / `SCROLLBAR`、secure-input / key 族（`SECURE_INPUT` / `KEY_SEQUENCE` / `KEY_TABLE`）、`READONLY` / `QUIT_TIMER` / `FLOAT_WINDOW`、search 族（`START_SEARCH` / `END_SEARCH` / `SEARCH_TOTAL` / `SEARCH_SELECTED`）、`PROGRESS_REPORT`。
- **Bucket 4 — Effectful**（→ Runtime 内直接副作用 + 一个可观测事件）：`OPEN_URL`（`NSWorkspace.open`）、`DESKTOP_NOTIFICATION`（扇出到 `NotificationCoordinator`）、`RING_BELL`（计数 + 事件 → Notifications / Dock）、`COMMAND_FINISHED`、`SHOW_CHILD_EXITED`、`UNDO` / `REDO`（`NSApp.sendAction`）、`COPY_TITLE_TO_CLIPBOARD`（直接走 `NSPasteboard`）。
- **App 级 config**（→ `GhosttyRuntime` 本地 + 事件）：`CONFIG_CHANGE` / `RELOAD_CONFIG`，以及 target 为 `GHOSTTY_TARGET_APP` 时的 `QUIT`。这些在 `GHOSTTY_TARGET_APP` 而非 `GHOSTTY_TARGET_SURFACE` 上触发，直接碰 runtime 的 config 对象，故在解码器里单独成路。

少数 libghostty 内部 / 非 macOS 的 action（`RENDER`、`INSPECTOR`、`SHOW_GTK_INSPECTOR`、`RENDER_INSPECTOR`、`SHOW_ON_SCREEN_KEYBOARD`）是显式不支持：`.debug` 日志 + 返回 `false`。

**非目标**

- **用户可配置的 codans action 绑定表。** 首版硬编码 1:1 的 ghostty-action → codans-operation 映射；可编辑的绑定表是另一份设计。
- **Clipboard 读 / 写 / 确认回调**（`read_clipboard_cb` 等）。另文处理。本文的 `COPY_TITLE_TO_CLIPBOARD` 直接用 `NSPasteboard`，不走这些回调。
- **Search overlay UI、secure-input 视觉指示、scroll bar 渲染、progress bar overlay。** 这些归后续 UI feature。本设计只把状态*存*在 `SurfaceInfo` 上并发 `panelInfoChanged`，供未来 overlay 消费。
- **多窗口模型重设计。** window intent 桶映射到*当前* NSWindow（按架构计划 1:1 对应一个 Space）；本文只交付 intent，接收方决定策略。

## 设计

### 总览

在 `GhosttyRuntime` 解码，把每个 action 归入四桶之一（外加 config），按桶分发。**桶之间的不对称是刻意的**：

- **Info** action 完全留在 Runtime 内——写一个 `SurfaceInfo` 字段，发一个 delta 事件，**无 reducer 介入**。（理由：它们是逐帧噪声；把每个都过一遍 TCA 会浪费 Effect 分配与 Equatable 检查。）
- **Effectful** action 在 Runtime 内立即执行副作用（`NSWorkspace` / `NSPasteboard` / `NSApp.sendAction`）并发一个可观测事件。（理由：没有什么需要 reducer 去*决策*——"打开这个 URL"只有一种正确动作。）
- **Intent** action（tab / split / window）发一个 typed `PaneActionRequest` 或 `WindowActionRequest` 交给 feature 服务。（理由：reducer 拥有策略——worktree 是否已归档？是否有 modal 弹着？关闭一个有进程在跑的 tab 是否需要确认？）
- **Config** action 碰 Runtime 已经拥有的 `ghostty_config_t` 句柄——留在本地。

这套分层在覆盖用户能绑定的每一个 action 的同时，保住了 **"Runtime is TCA-free"** 不变量。

### 系统上下文

```
                libghostty (Zig / C)
                      │  action_cb(app, target, action)
                      ▼
┌────────────────────────────────────────────────────────────┐
│ GhosttyRuntime.actionCallback (static, @convention(c))       │
│   两遍解码（见下）→ hop to MainActor → handleAction           │
│                                                              │
│   target == APP     → handleAppAction                        │
│   target == SURFACE → ghostty_surface_userdata → 16 bytes    │
│                       → PaneID → handleSurfaceAction         │
│                                                              │
│   GhosttyActionDecoder（唯一碰 ghostty_action_tag 的模块）    │
│     ├─ INFO     → pane.apply(delta); emit panelInfoChanged   │
│     ├─ EFFECT   → NSWorkspace/NSPasteboard/NSApp; emit event │
│     ├─ INTENT   → emit panelActionRequested /                │
│     │            windowActionRequested                       │
│     ├─ CONFIG   → runtime.applyClonedConfig(...)             │
│     └─ IGNORED  → log .debug; return false                   │
└────────────────────────────┬─────────────────────────────────┘
                             │ TerminalEvent 流
                             ▼
            PaneActionRouterFeature   WindowActionRouterFeature
              （唯一订阅者）              （唯一订阅者）
                 │                            │
                 ├─ HierarchyClient           ├─ WindowService (NSWindow)
                 │  (createTab/splitPanel/     ├─ UpdatesClient
                 │   closeTab/focus/zoom/      ├─ EditorClient (OPEN_CONFIG)
                 │   resize/equalize/move)     ├─ AppLifecycleClient (QUIT)
                 └─ UIClient                   └─ GhosttyRuntime (bg opacity)
```

### `GhosttyActionDecoder` 是唯一碰 C union 的模块

`GhosttyActionDecoder`（`apps/mac/codans/Runtime/Ghostty/`）是**唯一**知道 `ghostty_action_tag` 与 action union 形状的模块；其余所有人只消费 typed Swift 枚举。它把 C enum 解码到 Core 的 `PaneInfoDelta` / `PaneActionRequest` / `WindowActionRequest`，**不让 ghostty 的 C enum 类型泄漏进 `CodansCore`**——解码器就是这道翻译边界。

不变量（编码进代码的契约，而非任何精确清单）：

- 一个 action 对应一个 case；
- intent case 发 `emit(.panelActionRequested(…))` 或 `emit(.windowActionRequested(…))`；
- info case 写 `pane.apply(delta)` + `emitPanelInfoChanged`；
- effect case 跑副作用 + 发可观测事件；
- 不支持的 case 记日志并返回 `false`；
- `panelActionRequested` / `windowActionRequested` 各自的 router 是这些事件的**唯一订阅者**（架构不变量，code review 把关，防双重消费）。

### 解码器必须两遍（关键 C-互操作约束）

`action_cb` 可能在非主线程被调用，且 **action union 里的 C 指针在 `action_cb` 返回时即被释放**。因此解码**必须分两遍**：

1. 一个 `nonisolated` 的同步 decode，在**任何主线程跳转之前**，把 union 里每一个指针型字段——`title` / `pwd` / `needle` / `url` / `body` / key-table 名等 → Swift `String`；`CONFIG_CHANGE` 用 `ghostty_config_clone` 克隆 config——复制成一个 `Sendable` 值。
2. 拿着这个 `Sendable` 值跳到主线程，再做分桶分发。

C thunk 同步上报 `consumed`（`if Thread.isMainThread` 走快路径同步执行；否则 `DispatchQueue.main.async` 跳转后返回 `false`，因 Ghostty app 级默认是 no-op，异步落地是良性的）。**异步路径返回 `true` 是 bug**——consumed 语义必须同步给出。

`PaneID` 从 surface 的 16 字节 userdata 恢复（`ghostty_surface_userdata` 指向一块由 `PaneSurface` 拥有、与 `ghostty_surface_t` 同生命周期的专用分配，故 UAF-safe）；bytes 在任何主线程跳转之前就已复制出来。

### C-enum → Swift 映射规则（读者无法从代码自行推断）

- `GOTO_TAB`：`goto_tab:n` 是 **1-based**；越上界 **clamp 到末 tab**。
- `MOVE_TAB`：两端**环绕**（cyclically wrap）。
- `NEW_SPLIT`：**1:1 镜像** libghostty 的 4-way（right / left / up / down）。
- `RESIZE_SPLIT`：pixels → `SplitTree` ratio，钳到 `[0.1, 0.9]`，按经验常数 `pixelsPerRatioStep = 400` 缩放。

### `PaneSurface` 必须保活 `env_vars` 缓冲直到 surface 生命周期结束

libghostty 的 `ghostty_surface_config_s.env_vars` 缓冲**假定不被 `ghostty_surface_new` 拷贝**。因此 `PaneSurface` 必须保留每一个 `strdup` 出来的 key/value，外加背后的 `UnsafeMutableBufferPointer<ghostty_env_var_s>`，直到该 surface 的整个生命周期结束，并在**显式 `deinit`** 中释放（空 env → `nil, 0`）。这是一条与上面解码同源的 libghostty C-互操作约束：C 侧持有我们分配的指针、却不取得所有权，Swift 侧必须替它保活。

### 新增的 `TerminalEvent` case 与 Core 类型

`CodansCore/TerminalEvent.swift` 增加 `.panelInfoChanged(PaneID, PaneInfoDelta)`、`.panelActionRequested(PaneID, PaneActionRequest)`、`.windowActionRequested(WindowActionRequest)`、`.configChanged`。

`CodansCore/Pane/` 增加三个 `Sendable, Equatable` 枚举：`PaneInfoDelta`（title / pwd / mouse / geometry / scrollbar / secureInput / search / progress / bell / commandFinished / childExited 等的逐字段 delta）、`PaneActionRequest`（tab/split intent）、`WindowActionRequest`（window/app intent）。ghostty 的 C enum 类型留在解码器内，不进 Core。

### Surface info 存储

`PaneSurface` 上挂一个 `@MainActor @Observable final class SurfaceInfo`，持有 title / pwd / mouse / geometry / scrollbar / secureInput / keySequence / keyTable / readonly / search / progress / bellCount / lastCommand* 等字段。**不持久化**——逐 session 临时态，relaunch 重置；catalog 持久化只跟踪稳定层级。

### 消费者

两个轻量 TCA feature，各自是对应事件的唯一订阅者：

- **`PaneActionRouterFeature`** 订阅 `panelActionRequested`，把 `PaneID` 解析为 `(SpaceID, ProjectID, WorktreeID, TabID)`（经 `HierarchyClient.addressOf(paneID:)`），再分发到 `HierarchyClient`（createTab / closeTab / moveTab / activateTab / splitPanel / focusPanel / resizePanel / equalizeTabSplits / zoomPanel）与 `UIClient`（presentTerminal / toggleCommandPalette）。
- **`WindowActionRouterFeature`** 订阅 `windowActionRequested`，映射到 `WindowService`（NSWindow façade）/ `UpdatesClient`（Sparkle）/ `AppLifecycleClient`（`requestQuit` 走退出确认流，**禁止裸 `NSApp.terminate`**）/ `EditorClient`（`OPEN_CONFIG` 用用户默认编辑器打开 `~/.config/ghostty/config`）/ `GhosttyRuntime`（背景不透明度切换）。

**依赖方向保持单向。** `GhosttyActionDecoder` import Core + GhosttyKit，绝不 import `HierarchyClient` / features。Router import Core + Clients，绝不 import Runtime 内部。事件单向流动。

## 备选方案（Alternatives）

- **A — 每 surface 一个 fat bridge**（约 15 个 closure 回调 + 30 个状态字段）。否决：约 500 行重复 `SurfaceInfo` 的逐 surface 状态；逼 Runtime 知道每个 action 该做什么（closure 捕获 manager 方法）→ 破坏 "Runtime is TCA-free"；closure 汤比事件流订阅更难测。
- **B — Runtime 直接调 `HierarchyClient`**（零事件跳转）。否决：破坏架构不变量；把 TCA 拉进 Runtime；丢掉 reducer 拥有的策略（modal / 确认 / active-worktree 检查）。
- **C — 用 `NSNotification` 做跨 reducer 信令。** 否决：codans 架构禁止跨 reducer 的 `NSNotification`（无类型 payload、无顺序保证、跨模块无类型安全）；且相对既有生命周期事件无顺序可言，想同时要 "title changed" 与 "pane exited" 的消费者要去对账两条流。
- **D — 只实现高价值子集，其余推迟。** 否决：每个未路由绑定都是一次静默用户失败；同一解码器里每多一个 action 约 5 行，推迟省下的复杂度极少，却留下一大批"不工作且没人知道为什么"的绑定。
- **E — 把 action 解码留在 Features 侧**（Runtime 把裸 `ghostty_action_s` 当 Core 事件发出）。否决：把 C enum 知识散到 Features；`ghostty_action_s` 非 `Sendable`/`Equatable`，union 无法干净跨模块边界；解码重复风险。

## 横切关注点

**可观测性。** `os.Logger` category `com.gumpw.codans.runtime.action`；每个解码后的 action 以 `.debug` 记 `(paneID, tag)`，未支持分支以 `.info` 记 tag int。`codans system.status` 增 `ghostty.actions` 段：本 session 逐 tag 计数，使"agent 问为什么 keybind 不工作"一条命令可诊断。`GhosttyRuntime` 暴露有界（256 项，LRU 逐出）的 `unhandledActionCounts` 供 status 命令读取。

**Rollout / 逃生舱。** 启动参数 / 环境变量 **`CODANS_DISABLE_ACTION_ROUTING=1`** 在 C 回调里（任何主线程跳转之前）短路全部 keybind 路由，作为已上线的回归逃生舱。分桶落地顺序 Info → Effect → Tab/Split intent → Window intent → Config，每桶一个 commit，使 bisect 能把责任收敛到单桶。

**错误处理。** `ghostty_surface_userdata` 为 nil 或 PaneID 不在注册表 → 返回 `false`、不发事件（拆除竞态期的预期情况）；畸形 payload（如越界 `GOTO_TAB`，见上文 clamp 规则）→ `.info` 日志；router 侧失败（如 worktree 中途归档导致 `splitPanel` 抛错）→ 经既有错误面弹 toast，绝不崩溃、绝不重试；`CONFIG_CHANGE` 克隆失败（`ghostty_config_clone` 返回 nil）→ `.error` 日志 + 返回 `false`，Runtime 保留旧 config。

**安全 / 隐私。** `OPEN_URL` 经 URL scheme 检查 + 文件路径 tilde 展开后走 `NSWorkspace.open`（无裸 shell，受 LaunchServices gatekeeper 约束）；`COPY_TITLE_TO_CLIPBOARD` 只复制已渲染到屏的 title，无信息升级；`DESKTOP_NOTIFICATION` 经 `NotificationCoordinator`，复用其权限与 mute 规则。

## 风险

| 风险 | 缓解 |
|---|---|
| Action 洪流压垮扇出（chatty TUI 每个 prompt 都发 `SET_TITLE`/`PWD`/`PROGRESS_REPORT`）。 | `TerminalEvent` 上 `.bufferingNewest(256)`；仅当字段真变化才发 `panelInfoChanged`（`apply` 做 diff memo）；生命周期事件不缓冲。 |
| 线程安全：回调在非主线程触发，userdata 与 `PaneSurface` deinit 竞态。 | 两遍解码在任何主线程跳转前就把 16 字节 + 指针字段复制为 Sendable 值；注册表访问 `@MainActor`。 |
| 未知 action 洪流（未来 libghostty 版本发我们没见过的 tag）。 | 默认分支 `.info` + 累加有界计数；`codans system.status` 露出 top 未知 tag；排期 agent sweep 补 case。 |
| Router 长成 god-reducer。 | 只有 intent 走 router；info / effect 留 Runtime；单个 intent 服务逻辑超约 20 行就抽成独立 reducer 组合进 router。 |
| 无多窗口模型下的 window intent。 | `WindowService` 是唯一缝；改多窗口只动一个文件，`WindowActionRouterFeature` 刻意做薄。 |
| Config 重载扰动在飞的 session。 | `ghostty_config_clone` + `applyClonedConfig` 原子替换；surface 完成在飞的 config 相关调用后再在主队列丢弃旧 config。 |
| 退出路径竞态（`QUIT` 在另一 modal 弹着时到达）。 | 经 `AppLifecycleClient.requestQuit`（已与退出确认协商），禁止裸 `NSApp.terminate`。 |

## 参考

- 层级 / 事件：`apps/mac/CodansCore/{Catalog,Project,Worktree,Tab,Pane,SplitTree,TerminalEvent,PaneInfoDelta}.swift`
- 唯一翻译边界：`apps/mac/codans/Runtime/Ghostty/GhosttyActionDecoder.swift`
- Runtime 与 surface 保活：`apps/mac/codans/Runtime/Ghostty/{GhosttyRuntime,PaneSurface,SurfaceInfo}.swift`
- 消费者：`apps/mac/codans/App/Features/{PaneActionRouter,WindowActionRouter}/`
- 架构不变量（Runtime is TCA-free、router 唯一订阅）：`docs/architecture.md` §Architectural Invariants
