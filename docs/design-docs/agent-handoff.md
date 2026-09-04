# 设计文档：Agent Profiles 与 Handoff

**状态：** 已上线（可见）
**作者：** Gump（与 Claude）

## 背景与范围

codans 的用户同时驱动多个编码 agent（Claude Code、Codex、Gemini CLI、…）。在本设计之前，"在这个 worktree 里起一个 agent"只能靠手敲命令，而"把手头任务从 A agent 交给 B agent"根本没有通道——两个 agent 是独立进程，各自的会话上下文互不可见，用户只能自己复述。

本设计交付两件事：

1. **Agent Profiles**——命名的启动预设（agent、模型、推理强度、执行模式、放置位置、额外参数、launch-scoped 环境变量、独立 HOME），从 Settings → Agents 编辑，从 worktree toolbar 的 Agents 菜单、Command Palette、`codans agent launch` 一键启动。
2. **Handoff**——agent 到 agent 的任务交接：以 worktree 下的 `.codans/handoff/` 为唯一持久通道，由**在线的源 agent 自己**写 briefing 并通过 `codans handoff` 完成迁移，接收方在同一 worktree 的后台 tab 里带着 kickoff prompt 启动。应用内的 Hand Off 面板只是这条 CLI 迁移的触发器与观察者。

不在范围：agent 内部会话的 fork / 续写（codans 永远不替 agent 起隐藏的模型调用）；Server（SSH）项目的 handoff（工件目录在远端）；跨 worktree 的交接。

## 目标与非目标

**目标**

- 一个 profile 是可预览、可复制的**确定性命令行**：Settings 里的 Launch Preview 与真正键入 pane 的字符串出自同一个渲染器（`AgentLaunchCommand`）。
- 只列出能正确拼写的选项：某 CLI 没有的旋钮在编辑器里不出现，其余留给 Extra Arguments。
- Handoff 的迁移序列在所有入口上**完全相同**且 archive-first：先归档上一轮，再安装/移除 briefing，再重生成 context，最后启动接收方并记日志。
- briefing **必须**由源 agent 显式提供（`--brief -`）或显式放弃（`--no-brief`）；缺失或不合格的 briefing 报错且**零副作用**。
- 接收方启动走与 toolbar 相同的 profile 管线，因此模型 / 执行模式 / 环境变量等预设自然生效。

**非目标**

- 不为 profile 做"推荐"记忆（按仓库最近启动的 profile）。菜单顺序即 Settings 顺序。
- 不解析 Extra Arguments 的语义（例如识别 bypass flag 给出警告）。
- 不在 handoff 中携带源会话的原始 transcript，只记录 session id、可复原的 resume 命令与当前屏幕文本摘录。

## 设计

### 总览

```
Settings.agents (settings.json)          .codans/handoff/ (per worktree)
   │ AgentProfile[]                          current.md / context.md / log.md
   ▼                                          archive/ / sessions/ / .gitignore
AgentCatalog.descriptor(kind)                 ▲
   │  models / efforts / modes / promptStyle  │ HandoffStore (pure FS)
   ▼                                          │ HandoffCoordinator (sequence)
AgentLaunchCommand.render(profile, prompt) ───┤
   │                                          │
   ▼                                          │
HierarchyClient.launchAgent(spec) ◄── HandoffHandlers (handoff.* IPC)
   ▲                 ▲                        ▲            ▲
   │                 │                        │            │
toolbar / palette   agent.launch (CLI)   codans handoff   HandoffFeature (面板 fallback)
```

三层：`CodansCore` 持有 profile / descriptor / 命令渲染 / handoff 工件与迁移序列（纯值 + 纯文件系统，无子进程）；`CodansIPC` 定义 `agent.*` 与 `handoff.*` 的 wire 契约；app 内 `AgentHandlers` / `HandoffHandlers` 把 IPC 接到运行时（catalog、`AgentStateStore`、终端 surface、git、启动管线），`HandoffFeature` 复用同一个 `HandoffHandlers` 实例做面板的回退路径。

### Agent Profile 数据模型

`AgentProfile`（`CodansCore/Agents/AgentProfile.swift`）：`id`、`kind`、`name`、`isEnabled`、`systemImage`、`modelID` / `reasoningEffortID` / `executionModeID`、`target` + `direction`（复用 `ScriptTarget` / `ScriptSplitDirection`）、`extraArguments`、`envVars`、`usesDedicatedHome`。覆盖字段为 `nil` 即"Runtime default"——codans 不贡献 flag，由 agent CLI 自己决定。

`AgentDescriptor`（`AgentCatalog`）是每个 agent 的静态事实：可执行名、品牌图标、模型 / 推理强度 / 执行模式目录，以及 **`promptStyle`**——该 CLI 如何在保持交互式的同时接受初始 prompt（Claude Code / Codex 位置参数，Gemini `-i`）。没有 `promptStyle` 的 agent 可以裸启动，但不能作为 handoff 的接收方。

渲染形状：

```
[env KEY='value' … HOME='…'] <executable> [model] [effort] [mode] [extra] [prompt]
```

环境变量走 `env` 前缀而不是 pane 的 spawn 环境：变量只到达 agent 进程，agent 退出后 pane 里的 shell 仍是用户自己的环境。Dedicated HOME 落在 `<config>/agent-homes/<profile id>/`，首次启动即登录时刻，codans 不读不拷任何凭据。

`settings.json` 里 `agents.profiles` 是可加子树：无 `agents` 键 → 播种每个内建 agent 一条 profile（确定性 id，见 `AgentProfile.seedID`）；`profiles: []` 是用户的真实选择，往返保留。

### 启动管线

所有入口最终汇到 `HierarchyClient.launchAgent(AgentLaunchSpec)`：spec 携带**已解析的 `AgentProfile` 值**（而非 id），这样 handoff 可以为没有启用 profile 的 agent 构造一个临时裸预设走同一条管线。launch 把 profile 渲染成合成的 `ScriptDefinition` 交给脚本调度器（新 tab / 分屏 / 当前 pane，tab 图标为 `agent:<kind>` 品牌引用），唯一的行为差异是 `tracksRunPane: false`——agent 是会话不是作业，同一 profile 启动两次开两个会话，绝不往第一个 pane 重复键入。

### Handoff 工件

```
<worktree>/.codans/handoff/
  .gitignore            "*"——整个目录自我忽略
  current.md            源 agent 写的 briefing（无则不存在）
  context.md            codans 生成的仓库 + 会话状态；每次 save 重写
  log.md                append-only 历史
  archive/<ts>-<from>-to-<to>.md      每次迁移前的上一轮快照（briefing + context 合并）
  archive/<ts>-replaced-current.md    被 checkpoint 替换掉的 briefing
  sessions/<ts>-<pane>.md             屏幕摘录 + session id + resume 命令
```

不变量：

- **archive-first**——任何对 `current.md` 的重写之前，旧内容必定已在 `archive/`。
- **`current.md` 存在 ⇔ 一份通过校验的 briefing 产生了它**。没有 briefing 的迁移会删掉过期的 `current.md`，接收方被指向 `context.md` 与 `archive/`——上一轮的 briefing 永远不会冒充本轮契约。
- `checkpoint`（`handoff save`）**从不删除**已有 briefing：没有接收方时，最后一份有效 briefing 继续有效。
- codans 从不撰写语义内容：`MarkdownDocumentNormalizer` 只剥掉聊天包装（fence、前言、结尾闲话），正文逐字节保留；校验只看 `## Objective` / `## Current State` / `## Next Steps` 三个必需章节是否在 fence 之外出现。

git 事实（分支、变更文件、shortstat）由 app 层通过 `GitServiceClient` 采集后以 `HandoffRepoState` 值传入领域层——`HandoffStore` 不 shell out，符合"子进程统一走 `CommandRunner`"的边界。

### 迁移序列

`HandoffCoordinator.transition`：

```
validate briefing → archiveCurrent(from, to) → writeBriefing | removeCurrentBriefing
→ writeSession(screen excerpt) → writeContext → [launch receiver] → appendLog
```

启动接收方留给调用方（需要 pane 运行时），其余所有持久化与日志格式在协调器里，所以 CLI 与面板不会漂移。接收方的 kickoff prompt（`HandoffKickoff.receiverPrompt(hasBriefing:)`）按是否有新 briefing 二选一：有则从 Next Steps 继续，无则从 `context.md` 与归档定位；两者都要求接收方在 commit / push / 破坏性 git 前先问。

### 谁是源？

- `codans handoff` 默认源是**调用方 pane**：`AliasResolver` 先看 `CODANS_PANE_ID`，缺失则由服务端按进程祖先链归属（见 [cli.md](cli.md#寻址与别名解析)）。因此在自己 pane 里执行 `codans handoff to …` 的 agent 交接的就是它自己，与用户当前聚焦无关。
- `--pane` 显式覆盖。
- 键入源 pane 的那一行命令写的是**调用方自己这套构建的 CLI**：Debug 装的是 `codans-dev`，写裸 `codans` 会解析到已安装的 Release 二进制并拨到 Release socket，交接就被另一个 app 拿去执行了。命令名在 wire-up 时解析一次，未安装时回退到 app 内置二进制的绝对路径。
- 应用内入口：toolbar Agents 菜单 / Command Palette 取选中 worktree 的聚焦 pane；AgentState 行右键与 pane 右上角的信息菜单取该行 / 该 pane 自己的 pane id。pane 菜单是最贴近语义的入口——交接是这个 pane 里那个 agent 的属性——它在展开时顺带展示 pane 所属 worktree 的 path / branch / 未提交行数。

源 agent 身份优先取 `AgentStateStore` 的实时条目（分类器此刻看到的），回退到 pane 持久化绑定（`Pane.agentKind` / `agentSessionID`），因此重启后恢复的 pane 仍能报出 agent。

### 应用内 Hand Off 面板

`HandoffFeature`（TCA，`@Presents` 于 `RootFeature.handoff`，与 Command Palette 同宿主同外观）三阶段：

1. **choosing**——列出可作为接收方的已启用 profile（其 agent 有 `promptStyle`）+ "Only save progress"。
2. **running(requesting)**——生成一次性 `requestID`、在 `HandoffRequestRegistry` 登记，把一行请求键入源 pane：`[codans] Please hand this task off to <Agent>: run \`CODANS_HANDOFF_REQUEST_ID=<id> codans handoff to <agent> --brief -\` with your briefing on stdin as a heredoc …`。面板此时**非模态**：键盘留给终端（请求可能触发需要用户批准的权限提示），点外面即收起，交接仍在后台完成。
3. **finished**——`HandoffHandlers` 完成后经 registry 广播 `HandoffCompletion`，面板按 `requestID` + 源 pane 匹配，跳到接收方 pane。

回退：**Context Only** 把待处理请求标记 superseded，再在进程内经同一个 `HandoffHandlers` 跑 context-only 迁移；pane 无法接收输入时自动走同一路径。registry 的 claim / supersede 在 main actor 上串行，保证 CLI 与面板**不可能各执行一次**迁移。Cancel 只关面板——已键入的请求无法撤回，agent 若仍交接，tab 照常出现。

### 组件边界

| 组件 | 职责 | 不负责 |
|---|---|---|
| `CodansCore/Agents/*` | profile / descriptor / 命令渲染 / token 解析 | 任何 I/O |
| `CodansCore/Handoff/*` | 工件布局、briefing 校验、迁移序列、kickoff 文案 | 子进程、pane、启动 |
| `CodansIPC` `agent.*` / `handoff.*` | wire 契约 | 语义 |
| `AgentHandlers` / `HandoffHandlers` | IPC → 运行时；源解析、屏幕摘录、git 采集、启动 | UI |
| `HandoffRequestRegistry` | 一次性授权 + 完成广播 | 迁移本身 |
| `HandoffFeature` / `HandoffOverlayView` | 面板状态机与呈现 | 直接写工件（走 `HandoffClient.run`） |

## 技术决策

- **D1 — profile 是确定性 argv，不是 shell 片段。** 预览即真相；`extraArguments` 是唯一原样拼接的逃生口。
- **D2 — 环境变量用 `env` 前缀，不进 spawn env。** launch-scoped：agent 退出后 pane 回到用户环境；同一 pane 里手动再起的 agent 不继承 profile 的账号。
- **D3 — 只有带 `promptStyle` 的 agent 可作 handoff 接收方。** 扩大 `AgentKind` 目录不会自动暴露一个未验证 kickoff 语义的接收方；`--no-launch` 仍接受任何 agent token。
- **D4 — briefing 必须显式给出或显式放弃。** codans 不替第三方调用方发起模型调用；`--brief`/`--no-brief` 缺失时返回可直接粘贴的 heredoc 指引。
- **D5 — 领域层不 shell out。** git 事实由 app 层采集为值传入，`HandoffStore` 保持 `nonisolated` + `Sendable`，可在 `Task.detached` 里跑且可用临时目录单测。
- **D6 — 面板与 CLI 共用一个 `HandoffHandlers` 实例。** 回退路径不复制迁移逻辑；registry 的 claim/supersede 使两条路径互斥。
- **D7 — 接收方永远在新 tab、后台启动。** 无论 profile 保存的放置位置是什么，handoff 不能覆盖源 agent 的 pane；是否聚焦由在场的用户（面板）决定，CLI 路径不抢焦点。
- **D8 — `codans handoff to <agent>` 接受 raw value / 可执行名 / 显示名。** 人与 agent 都按自己习惯的拼法叫它（`claude` = `claude-code`）。

## 备选方案（Alternatives）

- **由 codans 读取 agent 的本地会话记录合成 briefing。** 否决：当前各 CLI 的 transcript 把推理保存为空壳，且这需要 codans 发起隐藏模型调用，成本与安全边界都不可接受。
- **profile 存到 `catalog.json`。** 否决：profile 是用户偏好不是层级状态，`settings.json` 已是单写者模型且可手编。
- **面板自己实现迁移。** 否决：两份序列必然漂移；见 D6。
- **handoff 工件放在 `~/.config/codans/` 而非 worktree 内。** 否决：接收方 agent 需要在自己的 cwd 下读到它，且工件与 worktree 生命周期一致。

## Cross-Cutting

- **安全**：handoff 只**读** git（status / branch / shortstat），从不 commit / push；`.codans/handoff/` 自我忽略；屏幕摘录与 session id 属于本地状态。profile 的 `envVars` 明文存于 `settings.json`，Launch Preview 会显示值——用户需自行避免把密钥写进 profile。
- **可观测性**：每次 save / transition 追加一行到 `log.md`（含 `source=cli` / 面板、pane、briefing 来源）；启动失败记 `launch=failed` 并保留归档路径。
- **测试**：`CodansCoreTests/Handoff/*` 用临时目录断言布局与不变量；`CodansTests/Socket/HandoffHandlersTests` 以闭包桩验证零副作用拒绝、迁移、启动、授权；`HandoffFeatureTests` 用 `TestStore` 覆盖面板状态机；`AgentHandlersTests` / `CommandPaletteAgentItemsTests` 覆盖 profile 选择与 palette 项。

## 风险

- 注入源 pane 的一行请求依赖 agent 把它当指令执行；agent 忙时请求排队，用户可用 Context Only 不等。
- `promptStyle` 对应各 CLI 当前版本的拼法，CLI 改 flag 时需要更新 `AgentCatalog`。
- `AgentInstallationStore` 的 PATH 探测可能误报"未安装"，因此只用于置灰，从不阻止启动。

## 参考

- [cli.md](cli.md) —— `codans agent` / `codans handoff` 动词与 IPC 契约
- [settings.md](settings.md) —— `settings.json` 单写者模型（`agents` 子树遵循同样规则）
- [active-agents-view.md](active-agents-view.md) —— `AgentStateStore`：handoff 源 agent 身份的实时来源
