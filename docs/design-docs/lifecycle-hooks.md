# 设计文档：Lifecycle Hooks

**状态：已设计，代码尚未实现。** 本文是初始设计；截至目前无 `apps/mac/codans/Hooks/` 目录，`CodansIPC/Method.swift` 无任何 `hook.*` 方法，`CodansCore` 无 `HookEvent` 等类型。读者**不应**认为此能力已上线——下文记录的是已论证的耐久契约，待实现时遵循。

**作者：** Gump（与 Claude）

## 背景与范围

Lifecycle hooks 是 codans 的**可编程事件面**。应用发出一条类型化的生命周期事件流——Pane 被创建、其 surface 就绪、它产出匹配用户模式的输出、空闲 N 秒、退出、其所属 Tab 被激活、其所属 Worktree 被激活——而用户配置的 **hook handler** 接收这些事件并可采取动作。

Hooks 是让后续能力可编程的基底：

- **CLI（`codans`）** 通过调用触发同一批事件的 RPC 方法来分发 hook，并暴露 `codans hook …` 安装 / 列出 / 测试订阅（该 CLI 面随本设计一起 deferred，见下）。
- **Notifications**（应用内通知聚合）可成为 Pane hooks 的纯消费者——但现行 [Notifications 设计](notifications.md) 刻意**不**依赖 hook：它直接消费运行时已发出的结构化事件（OSC 9/133、bell、子进程退出、idle、crash），把基于 hook 的检测预留为未来增量来源（见该文 A3）。
- **已发布 Agent Skill** 记录 hook 词汇，使编码 agent 能发出在 hook 时改变行为的 `codans` 调用。

两个已就位的同级组件，本设计须无环地插入：

- `CodansCore`（领域类型：`Pane`、`Tab`、`Worktree`、各 ID）—— 叶子包，零内部依赖。
- `Runtime`（应用内模块 `apps/mac/codans/Runtime/`）—— 拥有 `GhosttyRuntime`、`PaneSurface`、`TerminalEngine`、`HierarchyManager`、`CatalogStore`，暴露 per-Pane 的 `AsyncStream<TerminalEvent>`。

本文要新增的应用内模块是 `apps/mac/codans/Hooks/`（**尚未创建**）。其唯一职责是把 `TerminalEvent`（加少量层级级信号）翻译成类型化 `HookEvent` 载荷，匹配用户加载的订阅集，并以定义好的 JSON 信封把命中订阅分发给 out-of-process shell handler。

Open question "in-process 脚本 vs out-of-process spawn，或两者皆要？"由本文解决：**v1 仅 out-of-process**，留一条通往日后 in-process 的窄路。见 [Decisions](#decisions) §D1。

相关但不在本文范围：

- CLI 面（`codans hook install / list / test …`）—— 归 [CLI 设计](cli.md)；本文定义那些命令调用的 RPC 方法。**注意**：该 CLI 面与本能力一并未实现（`codans-cli` 当前无 `hook` 子命令）。
- 通知聚合 —— 是消费者而非生产者；用 hooks 而不改它们。
- Skill 包内容 —— 独立于应用运行时。

## 目标与非目标

### 目标

- **完整事件覆盖。** 每个生命周期（Pane created / ready / output match / idle / exit；Tab activated；Worktree activated）外加应用已发出的子集（`paneCrashed`、`tabAutoClosed`、`paneExited`）都是一等 `HookEvent`，有稳定 wire schema。
- **语言无关的 handler。** 用户用任意语言写 handler（bash/Python/Node/Ruby/Go）。应用只要求一个在 `PATH` 上（或绝对路径）的可执行文件，读 stdin 上的 JSON 并以状态码退出。
- **自闭合反馈环。** handler 可在 stdout 写一小段 JSON DSL 来产出后续应用动作；应用解释它并执行与 `codans` 相同的 RPC 动词。无自定义脚本语言。
- **确定性 schema。** 每个事件 JSON 含 `{version, event, timestamp, pane?, tab?, worktree?, project?, data}`；消费者按 `event` 区分并可依赖跨补丁发布的字段稳定，schema 变更 bump `version`。
- **低成本的 idle 与 output-match 路径。** idle 定时器是 per-Pane 单发任务、I/O 时重置；output-match 对每个 `pane.output` 事件做编译正则批量评估，非逐字节扫描。无 output-match 订阅时 idle 成本近零。
- **Per-Pane 崩溃隔离。** 一个崩溃、挂起或写垃圾的 handler 绝不影响 Pane、其 Tab 或任何其他 handler。超时杀的是 handler 进程，不是应用。
- **可无头测试。** `HookDispatcher` 单测不依赖 GhosttyKit / AppKit / Process——经可插拔的 `HookExecutor` 协议传 JSON 进、断言 JSON 出。
- **配置热重载。** `codans hook reload`（与对 `~/.config/codans/hooks.json` 的文件系统监听）无须重启即拾取编辑；在飞 handler 用旧配置跑完。

### 非目标

- **In-process 脚本引擎。** v1 无内嵌 JavaScript/Lua/WASM/AppleScript。藏在稳定的 stdout JSON-DSL 契约之后，以便日后加 in-process 路径而不改事件 schema。见 [Alternatives](#alternatives) §A1。
- **handler 的沙箱或提权。** handler 以用户自身权限运行（等同在任意 Pane 键入该命令）。
- **任意事件注入。** 只有应用发 `HookEvent`。handler 可在 stdout 请求动作，但不能伪造一个让 dispatcher 据以触发的事件——防无限 hook 环。
- **跨应用重启的持久 hook 状态。** 从应用视角 handler 进程无状态；要状态自己写文件。
- **hook 规则 DSL。** 订阅匹配是简单元组 `(event, output-match 可选正则, pane/tab/worktree 可选作用域)`。无布尔组合子、无 CEL、无 jq。
- **编辑 hook 的应用内 UI。** v1 直接编辑 `hooks.json`（或用 `codans hook install`）。Settings UI 是 post-v1。
- **非 Pane 锚定事件。** v1 hooks 作用域为 Pane / Tab / Worktree；应用级 hook deferred，wire 格式为前向兼容保留更高层字段。

## 设计

### 概览

Hooks 是一个薄的应用内 dispatcher，订阅既有的 `AsyncStream<TerminalEvent>`（加三个额外层级回调），叠入两条合成流（idle 定时器与 output-match 正则），把命中事件扇出到有界的用户 shell 进程池。

每事件的流水线是单一函数：

```
TerminalEvent  ──►  HookEvent  ──►  match subscriptions  ──►  spawn handler
 (Runtime stream)  (typed schema)      (hooks.json)             (Process)
                                                                    │
                                                                    ▼
                                                           optional stdout JSON
                                                            ─► HookActionDispatcher
                                                                    │
                                                                    ▼
                                                           same RPCs `codans` uses
                                                            (IPC.Method enum)
```

**为何这个架构契合目标：**

- **正确性优先。** 类型化 schema + 编译正则匹配把热路径（每字节终端输出）留在 Swift，无子进程、无 JSON 编组、无 IPC。只有*命中*事件才付子进程成本。
- **依赖方向干净。** `Hooks` import `CodansCore`（ID + wire 载荷类型）与 `CodansIPC`（动作 DSL 镜像），**不**直接 import `Runtime`——而是由 `Runtime` 构造并被递交 `AsyncStream<TerminalEvent>`，使 `Runtime` 保持唯一感知 GhosttyKit 的地方。见 [组件边界](#组件边界)。
- **out-of-process handler 是唯一契合"语言无关"的形态。** 每个解过此问题的参考项目（supacode、supaterm、Ghostty 自身配置、Claude Code 设置 hooks）都 shell out。见 §D1。
- **stdout JSON DSL 让 hook *可动作*。** 只记日志的 handler 有用；能开新 Tab 反应的 handler 才是能力的意义所在。DSL 刻意用与 `codans` CLI 相同的动词——一个面，不是两个。
- **idle 与 output-match 作为合成事件。** Runtime 已发 `pane.output` 与 `pane.idle`。Hooks 层在 `pane.output` 上加 per-pane 正则 pass 生成 `pane.outputMatch`，无须上游改动。

### 系统上下文图

```
┌────────────────────────┐  TerminalEvent     ┌─────────────────────────┐
│ Runtime.TerminalEngine │───────────────────►│ Hooks.HookDispatcher    │
│  (owns Ghostty + idle  │  (AsyncStream)     │  1) event → HookEvent   │
│   timers; produces      │                    │  2) regex match output  │
│   pane.*, tab.*,       │                    │  3) subscription lookup │
│   worktree.*)           │                    │  4) spawn handler(s)    │
└────────────────────────┘                    └────────────┬────────────┘
                                                           │ Process
                                                           ▼
                                              ┌─────────────────────────┐
                                              │ user handler            │
                                              │ (bash / python / node)  │
                                              │  stdin  = JSON envelope │
                                              │  stdout = JSON actions  │
                                              │  exit   = 0 or non-zero │
                                              └────────────┬────────────┘
                                                           │ stdout actions
                                                           ▼
                                              ┌─────────────────────────┐
                                              │ HookActionDispatcher    │
                                              │  translates to the same │
                                              │  IPC.Method verbs codans │
                                              │  uses                   │
                                              └────────────┬────────────┘
                                                           ▼
                                              HierarchyManager + TerminalEngine
                                              (existing writers)

     ~/.config/codans/hooks.json   ──► HookConfigStore ──► HookDispatcher
        (atomic-rename; FSEventStream watch)
```

### 事件分类与 Wire Schema

事件名是小写点分串，是 (a) 产品所列事件与 (b) Runtime 的 `TerminalEvent` 已产出事件的并集：

| 事件名 | 触发于 | 作用域锚 |
|---|---|---|
| `pane.created` | 新 Pane 被插入某 Tab 的 split tree | Pane |
| `pane.ready` | `PaneSurface.state` 从 `.initialising → .ready`（shell 在读输入） | Pane |
| `pane.output` | 合并的输出批次发出（≤ 16KB，≤ 60Hz） | Pane |
| `pane.outputMatch` | 合成：订阅里某编译正则命中一个 `pane.output` 批次 | Pane |
| `pane.idle` | Pane ≥ `idleThreshold` 秒无输出无输入 | Pane |
| `pane.exited` | 底层进程干净退出（有退出码） | Pane |
| `pane.crashed` | Ghostty surface 故障（非干净子进程退出） | Pane |
| `tab.activated` | 用户在某 Worktree 内切到此 Tab | Tab |
| `tab.deactivated` | 用户切离此 Tab（仅对前一选中 Tab 触发） | Tab |
| `tab.autoClosed` | 崩溃隔离策略在 30s 内 3 次崩溃后关闭该 Tab | Tab |
| `worktree.activated` | 用户选中此 Worktree（在前一个的 `deactivated` 之后触发） | Worktree |
| `worktree.deactivated` | Worktree 切换离开上下文 | Worktree |
| `worktree.created` | 新 Worktree 行被追加（无论磁盘 `git worktree add` 是否成功） | Worktree |
| `worktree.removed` | Worktree 被移除（应用侧；不蕴含 `git worktree remove`） | Worktree |

handler 收到的规范 stdin 信封：

```jsonc
{
  "version": 1,
  "event": "pane.outputMatch",
  "timestamp": "2026-04-20T12:34:56.789Z",

  // 恰好四者之一是 "anchor"；其余可作为上下文出现。
  "project":  { "id": "uuid", "name": "codans", "rootPath": "/Users/…/codans" },
  "worktree": { "id": "uuid", "name": "exp/plan", "path": "/Users/…/exp-plan", "branch": "exp/plan" },
  "tab":      { "id": "uuid", "name": "agent", "selectedPaneID": "uuid" },
  "pane":     { "id": "uuid", "workingDirectory": "/Users/…", "initialCommand": null },

  // 事件特定载荷，按 `event` 区分。
  "data": {
    "match":        "agent has completed",
    "matchedRange": { "start": 120, "length": 22 },
    "output":       "…last 4KB of matched batch, utf-8 replaced…",
    "outputBytes":  4096
  }
}
```

> 顶层不再有 `space` 锚（Space 容器已被 per-Project `Tag` 取代）；wire 格式为前向兼容保留更高层应用级锚位。

每事件 `data` schema：

| 事件 | `data` 字段 |
|---|---|
| `pane.created` | `{ createdVia: "cli"\|"ui"\|"restore" }` |
| `pane.ready` | `{ pid?: Int, shell: String }` |
| `pane.input` | *默认不投递给用户 handler*；仅 `event: "pane.input"` + 显式 `allowRawInput: true` 可达。`{ text, inputBytes }` |
| `pane.output` | *默认不投递*（太吵）；仅 `allowRawOutput: true` 可达 |
| `pane.outputMatch` | `{ match, matchedRange: HookMatchRange, output, outputBytes }` |
| `pane.idle` | `{ idleSeconds, sinceLastOutput, sinceLastInput }` |
| `pane.exited` | `{ exitCode: Int32 }` |
| `pane.crashed` | `{ reason: String }` |
| `tab.activated` | `{ previousTabID?: "uuid" }` |
| `tab.deactivated` | `{ nextTabID?: "uuid" }` |
| `tab.autoClosed` | `{ reason, crashCount, windowSeconds }` |
| `worktree.activated` | `{ previousWorktreeID?: "uuid" }` |
| `worktree.deactivated` | `{ nextWorktreeID?: "uuid" }` |
| `worktree.created` | `{ branch?: String, gitExit?: Int32 }` |
| `worktree.removed` | `{ keepDirectory: Bool }` |

**Anchor 规则。** wire 上每个 `project/worktree/tab/pane` 字段声明*可选*（`encodeIfPresent`），因为某些事件缺某些字段（如 `worktree.removed` 不带 `pane`）。但下列保证对每个已编码信封成立，由 debug-only `HookEnvelope.validateAnchors()` 在编码路径强制：`pane.*` 保证 `pane/tab/worktree/project` 非空；`tab.*` 保证 `tab/worktree/project`；`worktree.*` 保证 `worktree/project`。handler 可无须 null 检查地依赖这些。

### API 设计

#### `HookEvent`（在 `CodansCore`）

`CodansCore` 增一个 `HookEvent` Codable 枚举，使应用侧与 `codans` CLI 都能谈论事件而不必让 CLI import `Runtime`。

```swift
// apps/mac/CodansCore/Hooks/HookEvent.swift  (待新增)
public nonisolated enum HookEvent: String, Codable, Hashable, Sendable, CaseIterable {
  case paneCreated     = "pane.created"
  case paneReady       = "pane.ready"
  case paneInput       = "pane.input"
  case paneOutput      = "pane.output"
  case paneOutputMatch = "pane.outputMatch"
  case paneIdle        = "pane.idle"
  case paneExited      = "pane.exited"
  case paneCrashed     = "pane.crashed"
  case tabActivated     = "tab.activated"
  case tabDeactivated   = "tab.deactivated"
  case tabAutoClosed    = "tab.autoClosed"
  case worktreeActivated   = "worktree.activated"
  case worktreeDeactivated = "worktree.deactivated"
  case worktreeCreated     = "worktree.created"
  case worktreeRemoved     = "worktree.removed"

  public var scope: HookScope { /* pane / tab / worktree per case */ }
}

public nonisolated enum HookScope: String, Codable, Sendable { case pane, tab, worktree }

/// 进入匹配 pane 输出的字节偏移 + 长度，可移植 Codable
/// （NSRange 跨平台/JSON 不稳定，wire 上避免）。
public nonisolated struct HookMatchRange: Codable, Equatable, Sendable {
  public var start: Int
  public var length: Int
}
```

#### `HookEnvelope` wire 载荷（在 `CodansCore`）

`HookEnvelope` 含 `version` / `event` / `timestamp`（ISO-8601 编码）/ 可选 `ProjectRef`、`WorktreeRef`、`TabRef`、`PaneRef` / `data: HookEventData`。各 Ref 是对既有类型的单向投影（信封绝不回写 Pane）。

`HookEventData` 是 tagged-union Codable 枚举（每个事件一个 case，载荷如上表）。Codable 手写，带一个 `"kind"` 区分符镜像信封上的 `event` 字段——信封级 `event` 与 data 级 `kind` 须同步，否则解码抛错。

#### `HookSubscription`（在 `CodansCore`）

```swift
public nonisolated struct HookSubscription: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var event: HookEvent
  public var command: String                  // shell 命令，按 §执行模型 tokenise
  public var matchPattern: String?            // 正则；仅对 .paneOutputMatch 有意义
  public var matchFlags: RegexFlags           // caseInsensitive / multiline / dotAll
  public var scope: Scope                      // 可选作用域过滤
  public var timeoutSeconds: Double           // 默认 5
  public var mode: Mode                        // .fireAndForget (默认) | .awaitActions
  public var cwd: String?                      // 覆盖 anchor 的 path
  public var env: [String: String]            // 附加 env；保留键 load 时拒绝
  public var allowRawOutput: Bool             // 订阅 .paneOutput 必需 (默认 false)
  public var allowRawInput: Bool              // 订阅 .paneInput 必需 (默认 false)
  public var idleThresholdSeconds: Double?    // .paneIdle 的客户端侧过滤
  public var disabled: Bool

  public enum Scope: Codable, Equatable, Sendable {
    case anyPane
    case paneID(PaneID)
    case paneLabel(String)         // 经 `codans pane label <pane> <tag>` 设置
    case tabID(TabID)
    case tabLabel(String)
    case worktreeID(WorktreeID)
    case worktreePathGlob(String)  // "**/exp/*"
  }
  public enum Mode: String, Codable, Sendable { case fireAndForget, awaitActions }
  public struct RegexFlags: OptionSet, Codable, Sendable { /* caseInsensitive / multiline / dotAll */ }
}
```

#### `HookConfig` 文件 schema（`~/.config/codans/hooks.json`）

`{ version: 1, recursionWindowMs: 250, subscriptions: [HookSubscription…] }`。与 `catalog.json` 同样的 atomic-rename + version-gated 解码器。loader 是 `Hooks.HookConfigStore.load()`，writer 是 `HookConfigStore.save(_:)`。

#### `Hooks` 应用内子文件夹（`apps/mac/codans/Hooks/`）

`Hooks` 是 `codans` 应用 target 的子文件夹，**非**独立 Tuist target；它与 `Runtime`/`Git`/`App` 的边界由文件夹约定 + code review 强制，与其他应用内模块一致。无 `import Hooks` 存在。

```swift
@MainActor
public final class HookDispatcher {
  public init(config: HookConfig, store: HookConfigStore,
              executor: HookExecutor = ProcessHookExecutor(),
              actionDispatcher: HookActionDispatcher, maxConcurrency: Int = 8)

  /// 接到 Runtime 的事件流。app 启动时由 TerminalEngine 调一次。
  public func attach(to events: AsyncStream<TerminalEvent>)
  /// 手动触发一个事件（被 `codans hook test` 用）。
  public func fire(_ envelope: HookEnvelope) async
  /// 从磁盘热重载；在飞 handler 保留其旧订阅记录。
  public func reloadConfig() async throws
}

public protocol HookExecutor: Sendable {
  func run(subscription: HookSubscription, envelope: HookEnvelope) async -> HookExecutionResult
}
public struct HookExecutionResult: Sendable {
  public let exitCode: Int32; public let stdout: Data; public let stderr: Data
  public let duration: TimeInterval; public let timedOut: Bool
  public let actions: [HookAction]            // mode == .awaitActions 时从 stdout 解析
}

// stdout DSL
public enum HookAction: Codable, Equatable, Sendable {
  case paneSend(PaneID, text: String, raw: Bool)
  case paneBroadcast(scope: BroadcastScope, text: String, raw: Bool)
  case paneOpen(in: WorktreeID, tab: TabID?, workingDirectory: String?, initialCommand: String?)
  case paneClose(PaneID)
  case tabActivate(TabID)
  case tabCreate(in: WorktreeID, name: String?)
  case worktreeActivate(WorktreeID)
  case notify(title: String, body: String?, paneID: PaneID?)
  case log(level: String, message: String)
  case setPaneLabels(PaneID, [String])
}
```

`HookActionDispatcher` 是薄 adapter，把每个 `HookAction` 翻译成对 `SocketServer` 为 `codans` 所用相同进程内 handler 的 `IPC.Method` 调用。

### 执行模型

1. **事件抵达。** `HookDispatcher.attach(to:)` 在一个 detached `Task` 里迭代 `events`。每个 `TerminalEvent` 经 `EventMapper` 同步映射为 `HookEnvelope`，读当前 `HierarchyManager.catalog` 充实载荷。输出事件不预先转信封——保持 `(PaneID, Data)` 直到 output-match pass。
2. **Output-match pass。** 对每个 `.paneOutput`，dispatcher 遍历预编译正则表 `[PaneID: [(Subscription, NSRegularExpression)]]`。未作用于此 pane 的订阅在 config-load 时已排除出表，故每批成本为 `O(matching_subscriptions)`。命中则合成 `.paneOutputMatch` 信封继续正常分发。裸 `.paneOutput` 信封只为 `allowRawOutput: true` 的订阅产出。
3. **订阅匹配。** 查 per-event 索引 `[HookEvent: [HookSubscription]]`。对每个候选，`scopeMatches(envelope)` 测 `scope` 过滤（pane id / label / tab id / path glob 等）。幸存者交给 executor。
4. **Executor。** `ProcessHookExecutor` 包 `Foundation.Process`：
   - `launchPath`：`/bin/sh`（见 §D2）；`arguments`：`["-c", subscription.command]`。
   - `environment`：用户 env **加** 保留键 `CODANS_SOCKET_PATH`、`CODANS_EVENT`、`CODANS_VERSION`，以及信封中存在的相应锚的 `CODANS_*_ID`（`CODANS_PANE_ID` 仅当 `envelope.pane != nil` 时置，依此类推）。
   - `currentDirectoryURL`：`subscription.cwd ?? envelope.anchorPath`（Pane 的 `workingDirectory`，或 Worktree 的 `path`，或用户 home）。
   - `standardInput`：pipe；`JSONEncoder` 写完整 `HookEnvelope` 后 EOF。
   - stdout/stderr：pipe，各缓冲至 1MB，超出截断并警告。
   - **超时**：单独 `Task` 跑 `Task.sleep(seconds: timeoutSeconds)`，醒来调 `Process.terminate()`，2s 宽限后 `SIGKILL`。
5. **动作分发。** 若 `mode == .awaitActions`，stdout 解码为 `{"actions": [HookAction]}`。解析失败记警告并当作零动作。各动作路由到 `HookActionDispatcher.execute(_:originatingFrom:)`，调与 `codans` CLI 相同的方法。动作执行在一个 handler 内**串行**，且对直接 mutation **不触发新 hook**——见 §D4。
6. **并发。** 全局 `AsyncSemaphore` 把在外 handler 进程封顶在 `maxConcurrency`（默认 8）。

### 输出合并与 idle 定时器 —— Hooks 是纯消费者

Runtime 已有 16ms 输出合并器与 per-Pane idle 检测路径，无条件发 `.paneIdle(PaneID, duration)`。本设计**不**加第二个合并器，**不**告诉 Runtime 何时武装 idle 定时器：

- Runtime 发 `.paneOutput(PaneID, Data)` 批次，Hooks 原样消费做 match pass。
- Runtime 在 Pane 越过固定默认 idle 阈值（60s，经 `settings.json.runtime.idleThresholdSeconds` 可配）时无条件发 `.paneIdle`。Hooks 订阅它并按各 `HookSubscription.idleThresholdSeconds` 客户端侧过滤（要"≥120s idle"的订阅直接丢 `duration: 60` 的事件，等 `≥120` 的）。
- 无 `HookRuntimeBridge` 协议：Runtime 不读 hook 状态，Hooks 不向 Runtime 推配置。Runtime → Hooks 是 bootstrap 时递进 `HookDispatcher.attach(to:)` 的单向 `AsyncStream`。

无条件武装 idle 定时器很便宜（每 Pane 一个 `Task.sleep`，I/O 时重置）。"Runtime 是纯生产者"的依赖清洁性是主导考量。

### 组件边界

`Hooks` 与 `Runtime` 都是单一 `codans` 应用 target 的子文件夹，非独立 Tuist target，互不 `import` 为模块。边界由文件夹约定 + code review 强制。

```
CodansCore (static framework)        (叶子；HookEvent + 信封类型加于此)
    ▲                                    ─ 真实 framework import 边 ─
    │
    └── codans app target (single binary)
         ├── codans/Runtime/   (拥有 GhosttyKit，发 TerminalEvent)
         └── codans/Hooks/     (订阅 TerminalEvent 流)
             ▲
             │ AsyncStream<TerminalEvent> 在 app bootstrap 递进
             │ (Runtime.TerminalEngine 构造 HookDispatcher 并传流)
```

- **`codans/Hooks/*.swift` 可引用：** `CodansCore`、`CodansIPC`、`Foundation`。
- **必须不引用：** `codans/Runtime|Git|App/` 下任何东西、`GhosttyKit`、`AppKit`、`SwiftUI`、TCA。
- **`codans/Runtime/*.swift` 可引用 `Hooks` 类型** 仅为 `TerminalEngine.init` 的构造接线；Runtime 其余代码不得伸入 hook 状态。
- **TCA 特性** 经 `HookClient` 依赖（与 `TerminalClient`/`HierarchyClient` 同模式）拿到 `HookDispatcher`。

#### In-process 消费缝（`hook.events` RPC 的 peer）

第一方应用内消费者（通知聚合是动机所在；未来的应用内 logs pane、Settings "recent activity" 共享此路）**在进程内**消费 hook 事件，不经 `hook.events` RPC。RPC 留给第三方工具（`codans hook tail` CLI、外部 monitor）；第一方代码免去 IPC 往返与 JSON 编解码成本。

`HookDispatcher` 两处扩展：

```swift
public extension HookDispatcher {
  /// 第一方消费者的 in-process 缝。hook.events RPC 的 peer，非替代。
  /// 每次调用返回新流；缓冲策略 bufferingNewest(64)。
  func internalEventStream() -> AsyncStream<HookEnvelope>

  /// 注册一个 in-process sentinel-route 订阅者。command 以 prefix 开头的订阅
  /// 短路 ProcessHookExecutor 路径，直接投递给订阅者的 handle(envelope:)。
  /// prefix 必须以保留的 `__codans/internal:` 命名空间开头，否则抛错。
  func register(subscriber: InternalHookSubscriber, for prefix: String) throws
  func unregister(prefix: String)
}
public protocol InternalHookSubscriber: AnyObject, Sendable {
  func handle(envelope: HookEnvelope) async
}
```

`HookDispatcher` 内的路由规则：对每个命中事件的候选订阅，看其 `command` 串；若 `command` 有已注册 `InternalHookSubscriber` 的前缀，在 `@MainActor` 上调 `subscriber.handle(envelope:)` 并完全跳过 `ProcessHookExecutor`（递归守卫、限流、`hook.recent` 记账仍适用）；否则落到正常 out-of-process spawn。

sentinel-prefix 路由使 `hooks.json` 保持唯一用户可见注册表：一个第一方应用内消费者就是文件里的另一行，用户可像用户订阅一样 `codans hook list` / 禁用它。命名空间保留——`HookConfigStore.load()` 拒绝 `command` 以 `__codans/internal:` 开头的用户订阅，除非该文件由标记 `authoredBy: "codans"` 的应用侧安装器写入。

> **耐久实现约束（首方内部消费者必读）。** `HookConfigStore.load()` 出于安全**静默剥除**保留前缀（`__codans/internal:`）订阅，因此 `HookDispatcher.fire()` 是 load-过滤的，且一次 load→save 往返会丢弃应用自身的 sentinel 行。首方内部 hook 消费者**不能**依赖把 sentinel 行往返持久化；必须自行在内存配置里播种该订阅，或直接读 `hooks.json` 并经显式的 `router.handle(envelope:ruleID:)` 缝驱动。

`internalEventStream()` 与 sentinel-prefix 路由是**独立**路径。通知聚合两者皆用：事件流喂其全局通知流水线；sentinel-prefix 路由让它装一个 per-Pane "Stop" hook，经同一 dispatcher shell out，而不为一个本就在进程内的通知付 fork/exec 成本。

### IPC Wire 协议新增

`codans hook …` CLI 归 [CLI 设计](cli.md)；它驱动下列加到 `hook.*` 命名空间的新 RPC 方法。**全部待实现**（`CodansIPC/Method.swift` 当前无 `hook.*`）。

| Method | Params | Result |
|---|---|---|
| `hook.list` | `{ eventFilter?, paneID? }` | `{ subscriptions: [HookSubscription] }` |
| `hook.install` | `{ subscription }` | `{ id: UUID }` |
| `hook.remove` | `{ id }` | `{ removed: Bool }` |
| `hook.enable` | `{ id, enabled }` | `{}` |
| `hook.reload` | `{}` | `{ loadedCount, errors }` |
| `hook.test` | `{ id, envelope }` | `{ result: HookExecutionResult }` |
| `hook.fire` | `{ event, paneID?, data }` | `{ handlersRun }` |
| `hook.recent` | `{ limit? }` | `{ fires: [HookFireRecord] }` |
| `hook.events` | *(streaming)* `{}` | *(流 `HookEnvelope`；被通知聚合用)* |

`hook.events` 是 `hook.*` 里唯一的 server-streaming RPC，遵循 [CLI §Wire 协议](cli.md#wire-协议) 定义的统一流终止契约：请求带 `stream: true`，响应是一串 `{id, stream: true, result: <envelope>}` 帧，任一侧关其写半边时流结束。通知聚合订阅 `hook.events` 而非轮询；CLI 的 `codans hook tail` 同样。

### 数据模型变更（`CodansCore`）

- **`CodansCore/Hooks/` 下新文件：** `HookEvent.swift`、`HookEnvelope.swift`、`HookEventData.swift`、`HookSubscription.swift`、`HookConfig.swift`。
- **不改既有 `Pane`/`Tab`/`Worktree`。** 信封的各 Ref 是对既有类型的单向投影。
- **`Pane` 上新增可选 labels**（为 `scope: .paneLabel`）：`var labels: Set<String> = []`。additive struct 字段，version-gated `Catalog` 解码器容忍其在 v1 文件缺失，无须 bump。
- **`Pane.labels` 的单一规范写者：`HierarchyManager.setPaneLabels(_:labels:replace:)`。** 产品中三个面写 labels（CLI 的 `codans pane label`、hook 动作 DSL 的 `HookAction.setPaneLabels`、任何未来 UI）全经此一方法路由，无其他代码路径写 `labels`。这保持写路径可审计、经 `CatalogStore.scheduleSave` 防抖保存、并保证 `.labels` 集与其别名索引一致。`HookAction.setPaneLabels` 是对同一方法的薄进程内调用，非第二个写者。
- **无 schema bump。** `HookConfig.version` 是自己的文件，从 1 起，独立于 `Catalog.version`。

### 错误处理模型

| 失败模式 | 处理 |
|---|---|
| `hooks.json` 解析错 | 备份到 `hooks.json.broken-<ISO>`，记 `.error`，加载零订阅（不崩） |
| 订阅里坏正则 | load 时以 `HookConfigError.invalidRegex` 拒绝该订阅，加载其余 |
| `env` 里保留键冲突 | load 时以 `HookConfigError.reservedEnv` 拒绝该订阅 |
| handler 二进制缺失 | `Process.run()` 抛错；记为 `exitCode = -1`，警告 |
| handler 退出码非零 | 记 `.info`；保留在 `hook.recent` 环；无用户通知 |
| handler 超时 | `timedOut = true`；进程树被杀；警告 |
| handler stdout 非合法 JSON（`awaitActions`） | `actions = []`；警告；退出码仍传播 |
| handler 发未知 `HookAction` 类型 | 解码抛错；整个动作列表被丢；警告；不部分应用 |
| 递归守卫触发 | 动作被丢；警告；见 §D4 |

错误绝不崩应用。`HookDispatcher` 持一个有界 `[HookFireRecord]` 环（默认 256），供 `codans hook recent` 与 Settings 内省。

## Alternatives

- **A1 — In-process 脚本引擎（JS/Lua/WASM）。** 否决（v1）：单语言锁定、进程体积变大、嵌入脚本可调试性差。stdout JSON DSL 留门：日后 in-process handler 只是通往同一动作集的更快路径。
- **A2 — Apple Events / AppleScript。** 否决：AppleScript 文档稀疏、作为用户编程面已死、非跨 OS，且仍不回答"事件如何流向用户代码"（它是请求驱动而非事件驱动）。
- **A3 — handler 作为长驻 side-car 进程。** 否决（v1）：使 handler 长跑（内存、僵尸风险）、无 per-event 作用域、handler 崩溃阻塞所有 hook、不与 shell 一行式组合。
- **A4 — 直接消费 Ghostty 自身事件回调。** 否决：hook 分类需要*层级级*事件（tab/worktree activated、crash-auto-closed），Ghostty 无此概念。统一在 `TerminalEvent` + 小 idle 合成 pass 更好。
- **A5 — `jq` 式规则 DSL。** 否决：引入解析器依赖或每事件 shell out `jq`（正是热路径要避免的）。需要此力的用户可在 handler 顶部自行过滤并早 exit 0。

## Decisions

每个判断附理由。"Supacode-parallel"指与 supacode/supaterm 同选；"divergent"指不同选及原因。

- **D1 — v1 仅 out-of-process 执行。（解决 in-process-vs-out open question。）** *Supacode-parallel.* 语言无关、隔离、匹配每个可比项目、保持应用进程小，把 in-process 留作藏在同一 stdout 动作 DSL 之后的未来优化。
- **D2 — spawn `/bin/sh -c` 而非自行解析命令。** *Supacode-parallel.* 用户期望写 `command: "~/bin/foo | tee ~/.log/foo.log"`。自行解析 argv 意味着重实现 shell 引号、env 展开、tilde 展开、管道组合。`sh -c` 在 macOS 普遍可用，且是 Ghostty 配置 / Claude 设置 / Claude Code hooks 的做法。
- **D3 — `HookEvent` / `HookEnvelope` 住 `CodansCore` 而非 `Hooks`。** `codans` 需谈论词汇（`codans hook test/install`）而不 import `Runtime` 或 `Hooks`。`CodansCore` 是钦定的共享地，与 `Pane`/`Tab`/`Worktree` 同理。
- **D4 — 递归守卫：handler 发出的动作不为该即时 mutation 触发 hook。** *新（supacode 无 stdout 动作）.* 一个对 `pane.output` 反应、向同 pane 发文本的 handler 会无限循环。dispatcher 给动作打 originating-envelope-id 标签；`pane.output`/`pane.input` 的发射器在可配窗口（`recursionWindowMs`，默认 250）内丢弃其即时上游成因带该标签的触发。Tab/Worktree 级事件仍触发（合法的"idle 时开 tab"handler 需要）。记为限制，非通用环破除器。
- **D5 — `HookAction` 动词是 `codans` 能做之事的最小有用子集。** *Supacode-parallel.* 含 `pane.send/broadcast/open/close`、`tab.activate/create`、`worktree.activate`、`notify`、`log`、`setPaneLabels`。排除（暂）：project add/remove、worktree create/remove、settings mutation——这些应经 UI/`codans` 携用户意图，而非 handler 决定。
- **D6 — v1 无编辑订阅的应用内 UI。** *Supacode-parallel.* `hooks.json` + `codans hook install/list/remove/test` 是全部面。
- **D7 — 超时默认 5s。** *Divergent（supacode 10s）.* hook 作用于 Pane 生命周期、人类可感延迟要紧；5s 够一个快速 `osascript` 或 `curl localhost`。
- **D8 — handler 并发封顶全局（8），非 per-subscription。** 防一个"agent-output-match → 跑测试"handler 带 30 秒 `pytest` 并行 spawn 30 份。
- **D9 — `pane.output` 裸订阅须显式 `allowRawOutput: true`。** 订阅每字节输出是上膛的脚枪；显式 opt-in 记录用户接受其体量。
- **D10 — `Pane.labels` 现在就加。** *Supaterm-parallel.* `scope: .paneLabel("agent")` 是无稳定 UUID 时定向 agent-host Pane 最人体工学的方式。Catalog 解码器已前向兼容。*（同一不变量记于 [CLI §数据模型](cli.md)——`Pane.labels` 的单一规范写者是 `HierarchyManager.setPaneLabels`。）*
- **D11 — 配置用 JSON，非 TOML。** *Divergent（supaterm TOML）；supacode-parallel.* 与 `catalog.json`/`settings.json` 对齐，让同一 atomic-rename + version-gated 解码器服务三者。
- **D12 — `hook.events` 是流式 RPC，非轮询。** 通知聚合须实时反应；轮询给每条 OS 通知加 100ms-1s 延迟。
- **D13 — `HookEventData` 用 tagged-union Codable，非异构 `[String: Any]`。** 跨 CLI ↔ App 边界的类型安全在编译期抓 schema 漂移。
- **D14 — Hooks 接到单一 Runtime 事件流，非 Ghostty 回调。** 保持 `Hooks` 依赖清洁（不 import GhosttyKit），且 Tab/Worktree 事件与 Pane 事件同住一个分类。见 A4。
- **D15 — 动作执行路径自身不调 socket server。** *架构驱动.* `HookActionDispatcher` 直接调进程内 Swift handler，等同 `codans` 方法的进程内分发；经 socket 发回给自己会浪费往返加序列化跳。
- **D16 — 第一方消费者（通知聚合及同类）得 `HookDispatcher` 上的 in-process 缝——`internalEventStream()` + sentinel-prefix `InternalHookSubscriber` 路由——作为 `hook.events` RPC 的 *peer* 而非替代。** *新.* 无 IPC 往返地解锁应用内通知聚合，且不重复订阅/配置/递归守卫/限流机制。`__codans/internal:` command 前缀保留，用户订阅不可认领，`hooks.json` 仍是唯一可见注册表。

## Risks

| 风险 | 缓解 |
|---|---|
| 松散正则对话痨 agent → handler 风暴打满并发封顶 | per-subscription token bucket（默认 30 fires/10s）；超速把订阅转 `disabled` 并在 `hook.recent` 记 "rate-limited"，用户 `codans hook enable` 重启 |
| 忽略 SIGTERM 的僵尸 handler 永占槽位 | 超时后 2s SIGKILL 宽限；进程组杀（`killpg`）；记 `killed: true` |
| 配置重载撞在飞 handler | 在飞 handler 保留其 originating 订阅快照；重载只原子换*新*触发的表 |
| CLI `hook install` 与应用内解码器 schema 漂移 | `HookSubscription` Codable 严格拒绝未知字段；`HookEnvelope.version` 受检；版本偏斜时 CLI 警告 |
| 递归守卫基于时间故不完美 | per-envelope-chain 深度计数封顶 4；超出记录并丢后续动作 |
| `pane.idle` 定时器泄漏 | `PaneSurface.close()` 调 `idleTimers.cancel(paneID:)`；单测覆盖快速开关 |
| `pane.output` 订阅 stdin 巨大 | `allowRawOutput: true` 是显式门（D9）；订 `.paneOutputMatch` 的只收命中区域 + 短上下文 |
| `hook.events` 流背压（慢消费者落后对话痨 pane） | per-connection 有界队列（默认 64）；溢出丢最旧并计数；通知聚合在观察到丢弃时降级为"摘要通知" |

## 参考

- 通知聚合（hooks 的纯消费者，但当前不依赖 hook）：[notifications.md](notifications.md)
- CLI 面（`codans hook …`，与本能力一并 deferred）：[cli.md](cli.md)
- 层级 / 事件类型：`apps/mac/CodansCore/{Catalog,Project,Worktree,Tab,Pane,TerminalEvent}.swift`
- wire 协议 / 方法枚举：`apps/mac/CodansIPC/Method.swift`
