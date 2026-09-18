# 设计文档：Agent Workflow

**状态：** 草案（待评审）
**作者：** Gump（与 Claude）
**日期：** 2026-09-18

## 背景与范围

codans 已经具备"一个 agent 编排其它 agent"所需的全部**原语**：Agent Profiles 与统一的启动管线（`HierarchyClient.launchAgent`）、`AgentStateStore` 的逐 pane 运行态（`idle` / `working` / `blocked` / `finished`）、`codans agent wait --until`、`codans pane send --wait --capture`、`codans handoff` 与 worktree 内的 `.codans/handoff/` 工件、以及 `{schemaVersion, data | error}` 的 JSON 信封（见 [cli.md](cli.md)、[agent-handoff.md](agent-handoff.md)、[active-agents-view.md](active-agents-view.md)、[lessons-learned 2026-09-14](../lessons-learned/2026-09-14-cli-agent-orchestration-gaps.md)）。

但用户每天真正在跑的编排——"在旁边分屏起一个 reviewer，把 diff 交给它审，读它的结论，修，再让它复审，直到 clean"——今天只存在于手敲的 CLI 序列或 agent 自己临场拼出的 bash 循环里。它不可复现、不可分享、没有可观测的进度，出了问题（agent 卡在权限提示、忘了汇报、回答得不合格式）也没有一个地方能停下来问用户。Handoff 是这类编排里唯一被固化的一条，而它是写死的状态机：目标列表、briefing 章节、kickoff 文案都是字面量，第二条编排就得再写一遍。

本设计引入 **Workflow**：用 YAML 声明的、由 codans 执行的多 agent 编排。参考对象是 Prowl 的 `prowl.workflow/v1`（`~/dev/opensource/Prowl/docs-ai/063-agent-workflows/`），本设计沿用其中已被实战验证的骨架——角色抽象 + 本机绑定、显式交付（`deliver`）+ activation token、attention 而非失败、纯状态机 + effect 解释——同时按 codans 已有的边界与"Slow is Fast"的取向裁剪掉脚本 action 包、JSON Schema 校验、全局历史库等重型部件，把这些空间留给后续里程碑。

不在范围：可视化编辑器；Server（SSH）项目（工件目录在远端，与 handoff 同一理由）；跨 worktree 的角色；应用重启后恢复运行中的 run；codans 替 agent 发起隐藏的模型调用；并行分支与 join-any（V2 预留，见 [里程碑](#里程碑)）。

## 目标与非目标

**目标**

- 一份 `*.workflow.yaml` 文件就能表达"起 reviewer → 审 → 修 → 复审直到 clean"这类循环，可放进仓库分享，可在 Settings 里看到、启用、校验。
- 工作流声明的是**抽象角色**（"一个能审代码的 agent"），角色 → Profile / pane 的绑定在本机解析、记忆、可覆盖；文件不绑定任何机器。
- agent 之间**只通过 `codans` CLI 参与**（`codans workflow deliver`），因此任何已识别的 agent 都能扮演任何交互式角色；用 CLI 手工编排的路径依然一等（工作流是原语之上的一层，不是替代）。
- 每一步"等 agent"都是可观测、可介入的：卡住时进入 `needs_attention`，用户在 app 里或通过 CLI 选 Accept / Ask again / Skip / Cancel，而不是 run 悄悄失败。
- 领域逻辑是纯值：定义解析、校验、状态机、表达式求值全部在 `CodansCore`，可在临时目录里单测；I/O 只在 app 层的 effect 解释器里。
- 两个内建工作流：`codans.review-loop`（author/reviewer 循环）与 `codans.handoff`（现有 handoff 的工作流表达，现有 `codans handoff` 保持不动）。

**非目标**

- 不做通用脚本 action 包（`action.yaml` + 解释器 + JSON Schema 输入输出 + 内容指纹审批）。V1 用 `run:` 步骤跑一条 shell 命令并捕获退出码与输出，覆盖 80% 的确定性工作；action 包若有需要在 V2 引入。
- 不做完整表达式语言。V1 的表达式只够写条件与计数（比较、逻辑、`??`、整数加减、`exists` / `length`），不做数组操作、浮点、函数定义。
- 不做全局历史库、配额与导出。run 目录随 worktree 走，只保留最近 N 次。
- 不给 `expect` 之外的步骤提供"等 agent 干完活"的保证：`message` / `launch` 不带 `expect` 即 fire-and-forget（与 Prowl 一致），需要同步就用 `expect` 或 `wait`。
- 不替 agent 回答权限提示、不发送 Ctrl-C。`blocked` 只会升级为 attention。

## 设计

### 总览

```
~/.config/codans/workflows/*.workflow.yaml      <repo>/.codans/workflows/*.workflow.yaml      app bundle: codans.*
                 │                                          │                                        │
                 └──────────────── WorkflowDiscovery (scope 优先级 repo > user > bundle) ────────────┘
                                                            │  WorkflowDefinition + diagnostics
                                                            ▼
   codans workflow run ──► WorkflowHandlers ──► WorkflowAdmission ──► WorkflowEngine (@MainActor @Observable)
   Command Palette ────► WorkflowStartFeature ─┘   (绑定角色、冻结 profile、分配 run 目录)   │
                                                                                            │ WorkflowMachine (纯 reducer, CodansCore)
                                                                                            │   event ──► [WorkflowEffect]
                                                                                            ▼
        ┌──────────────┬────────────────┬──────────────────┬──────────────┬─────────────────┬──────────────┐
   awaitRoleIdle     inject          launch            runCommand      notify / close    persist / log
   AgentStateStore   TerminalEngine  HierarchyClient   CommandRunner   NotificationStore  WorkflowRunStore
                                     .launchAgent                                        <worktree>/.codans/workflow-runs/<run>/
                                                            ▲
   codans workflow deliver - ──► WorkflowHandlers ──► WorkflowActivationRegistry (token ↔ activation) ──► machine.deliver
```

三层与 handoff 完全同构：`CodansCore/Workflow/` 持有定义、解析、校验、表达式、状态机、run 记录布局（纯值 + 纯文件系统，无子进程、无 pane）；`CodansIPC` 定义 `workflow.*` wire 契约；app 内 `WorkflowEngine` 拥有所有活动 run，把机器吐出的 effect 翻译成对 `AgentStateStore` / `HierarchyClient` / `CommandRunner` / `NotificationStore` 的调用，`WorkflowHandlers` 把 IPC 接到 engine，`WorkflowStartFeature`（TCA）只持有启动草稿——运行态从 `@Observable` 的 engine 直读，与 `CommandQueueFeature` 的做法一致。

### 定义文件

一个工作流是一个 YAML 文件（`schema: codans.workflow/v1`），不是目录包——V1 没有脚本 action，因此没有"需要一起打包的辅助文件"。

```yaml
schema: codans.workflow/v1
id: review-loop                 # [a-z0-9][a-z0-9_.-]{0,63}；codans.* 保留给内建
name: Review Loop
description: Launch a reviewer beside the author and iterate until the review is clean.

inputs:
  max_rounds: {type: integer, default: 3, min: 1, max: 10}
  focus:      {type: string, default: "", prompt: "Anything the reviewer should focus on?"}

roles:
  author:   {source: current}                       # 发起 run 的 pane
  reviewer:
    source: launch                                  # codans 按 profile 起一个新 agent
    agents: [claude-code, codex]                    # 可选：AgentKind 白名单；省略 = 任何可启动 profile
    profile: Reviewer                               # 可选：优先匹配的 profile 名（本机记忆优先于它）
    placement: split                                # split | tab
    direction: right
    background: true

state:
  round:   {type: integer, initial: 0}
  verdict: {type: string,  initial: "issues"}

steps:
  - id: kickoff
    launch: reviewer
    prompt: |
      Review the uncommitted changes in this worktree. {{ inputs.focus }}
      Report findings under "## Findings" and finish with a verdict.
    expect: {delivery: review, sections: ["## Findings"], verdicts: [clean, issues]}

  - id: loop
    while: state.verdict == 'issues' && state.round < inputs.max_rounds
    steps:
      - id: bump
        set: {round: state.round + 1}
      - id: fix
        message: author
        instruction: |
          Address the review at {{ deliveries.review.path }}. Deliver a short summary when done.
        expect: {delivery: fixes}
      - id: recheck
        message: reviewer
        text: "Re-review after the fixes described in {{ deliveries.fixes.path }}."
        expect: {delivery: review, sections: ["## Findings"], verdicts: [clean, issues]}
      - id: record
        set: {verdict: deliveries.review.verdict}

  - id: done
    if: state.verdict == 'clean'
    then:
      - {id: ok,   notify: "Review clean after {{ state.round }} round(s)"}
    else:
      - {id: stop, notify: "Still has issues after {{ state.round }} round(s); see {{ deliveries.review.path }}"}
```

**发现与作用域**（按 id 后者遮蔽前者）：app bundle（`Resources/workflows/`，只有它能用 `codans.*` id）→ 用户 `~/.config/codans/workflows/`（Debug 通道为 `codans-dev`，走 `AppDirectories.configDirectory`）→ 仓库 `<repo root>/.codans/workflows/`。仓库作用域是"随分支走"的：每个 worktree 看到自己分支上的文件。这要求 `.codans/.gitignore` 从整目录 `*` 改为放行 `workflows/`（见 D9）。

**校验**分两段：`WorkflowDocumentParser`（YAML → 结构诊断：未知键、类型错误、缺必填）与 `WorkflowValidator`（交叉引用：未定义角色、重复 step id、同一 `launch` 角色启动两次、循环体内 `launch`、表达式引用了不存在的命名空间或没有生产者的 delivery、`verdicts` 数量 2–4、`on_timeout` 无 `timeout`、`text` 里手写 `codans workflow deliver`）。诊断是 `{severity, code, message, location}`；有 error 的文件在 Settings 里可见但不可启动，`codans workflow validate <file>` 不需要 app 在线。

### 角色与绑定

| `source` | 含义 | 规则 |
|---|---|---|
| `current` | 发起 run 的 pane | 每个工作流至多一个；只有当有未被跳过的 `message` 指向它时才要求 pane 里有已识别的 agent，否则裸 shell 也可以（context-only handoff 就是这样启动的）；没有 `current` 角色的工作流从 worktree 启动 |
| `launch` | codans 起一个新 agent | 走 `HierarchyClient.launchAgent(AgentLaunchSpec)`；profile 在启动时解析并**冻结进 run**，之后改 profile 不影响 |
| `pick` | source worktree 内一个已识别的 agent pane | 启动时必须显式给出（GUI 选择器 / CLI `--role r=p12`）；已在其它 run 里的 pane 不可选 |

`launch` 角色的绑定解析（逐级回退，每级候选都要重新验证"存在、启用、满足 `agents`、该 agent 有 `promptStyle`"）：

```
--role 覆盖 → 本机记忆 → 定义里的 profile: 名 → 满足 agents 的唯一启用 profile → GUI 询问 / CLI PROFILE_REQUIRED
```

记忆键是 `(scope, workflow id, role, 角色需求摘要)`，摘要是 `{source, agents, profile}` 规范 JSON 的 SHA-256——改了角色需求就作废记忆，只改 prompt 不作废。记忆存在 `settings.json` 的 `workflows.bindings`，是本机偏好，不进文件。

**一个 pane 同时至多属于一个 run**。admission 时 `current` / `pick` 的 pane 若已被别的 run 占用即 `PANE_BUSY`；`launch` 出来的 pane 在 engine 绑定之前被预留，不会被并发的第二个 run 抢走。

### 步骤动词

每个 step 有 `id`（全局唯一）、可选模板化的 `title`、恰好一个动词：

| 动词 | 载荷与行为 |
|---|---|
| `message: <role>` | `text`（单行）或 `instruction`（多行，落到 run 目录的文件，pane 里只键入一行指针）；**先等角色 idle 再注入**；可选 `expect` |
| `launch: <role>` | `prompt`（进 profile 的 `promptStyle`）；每个 `launch` 角色至多一次，且不能在循环体内；可选 `expect` |
| `run: <command>` | 经 `CommandRunner` 在 worktree 根目录执行（默认 headless；`in: <role>` 则以 `pane send --wait --capture` 的方式键入该角色 pane，可见但 best-effort）；`timeout`（默认 60s）、`allow_failure`；结果进 `runs.<step>.{exit_code, output_path}` |
| `wait: <role>` | `until: idle \| blocked \| exit`（默认 `idle`），可选 `timeout`；填补 Prowl 观察到的"没有 delivery 就无法等待"的空档（F5），代价是 turn-idle ≠ task-idle（F4），文档明说 |
| `notify: <text>` | 进通知 inbox（`NotificationStore`），标题 `Workflow · <name>` |
| `close: <role>` | 关闭 `launch` 角色的 pane；只有当该 run 仍是这个 pane 的最近绑定者时才执行 |
| `set: {k: expr}` | 原子赋值，全部表达式对同一份旧 state 求值 |
| `if` / `then` / `else`、`while` + `max_iterations`、`break: true` / `continue: true` | 控制流，在进程内执行，一次最多推进 64 步后让出 |

`launch` / `message` 不带 `expect` 时注入 / 启动成功即完成该步（fire-and-forget）；工作流的确定性到 prompt 边界为止，这一点与 Prowl 一致并在授权指南里写明。

### `expect`：显式交付

```yaml
expect:
  delivery: review            # 名字；默认 = step id；多个 step 可交付同名（后者覆盖，latest wins）
  format: markdown            # markdown（默认）| text | json
  sections: ["## Findings"]   # 必需标题；大小写与层级宽容；fence 内不算（复用 MarkdownDocumentNormalizer）
  verdicts: [clean, issues]   # 2–4 个 slug；声明后 --verdict 成为必填
  timeout: 30m                # 可选硬上限；无默认——不写就等 agent 干完
  on_timeout: attention       # attention（默认）| skip | cancel
  strict: false               # false：缺章节 / 缺 verdict 记为 provisional 交给用户裁决；true：直接拒收
```

带 `expect` 的 step 进入时铸造一次 **activation**：`(run id, step id, 全局单调的 invocation ordinal, 角色)` + 一枚随机 token。token 随注入的那一行走（`CODANS_WORKFLOW_TOKEN=<t> codans workflow deliver [--verdict v] -` 由 renderer 追加在指令末尾，作者永远不手写它），`launch` 角色则由 profile 的 `env` 前缀带进 agent 进程（与 profile 自己的 `envVars` 同一条路，launch-scoped，agent 退出后 pane 回到用户环境）。

`codans workflow deliver`：

1. 由 socket 对端 PID → 进程祖先链 → pane（`CLICommandContext`，与 handoff 相同）定位调用方 pane，查 `WorkflowActivationRegistry` 找到该 pane 当前等待中的 activation；
2. 要求 token 匹配——**token 是关联而不是认证**（同一 pane 的旧 activation 已被 Skip / Ask again / Relaunch 吊销，迟到的 `deliver` 得到 `TOKEN_INVALID` 而不是被误记到新 step 上）；
3. 校验正文：空正文 / 超 16 MiB 一律拒收；`sections` / `format` / `verdicts` 不合按 `strict` 决定拒收还是 provisional；
4. 先落盘 `deliveries/<name>.<ordinal>.md`，原子替换 `deliveries/<name>.md`，再完成 activation。CLI 收到 `delivered` 或 `provisional` 的回执，后者附 `issues`。

Provisional 使 run 进入 `needs_attention`，动作表：**Accept** / **Accept with verdict …**（缺 verdict 时用户挑一个）/ **Ask again**（把缺什么 + 完成命令再键入角色 pane，token 不变）/ **Skip** / **Cancel**。Skip 的后果立即算出：若后续任何表达式、条件、`run` 输入引用了这份 delivery 且没有 `exists()` / `??` 兜底，run 以 `skipped(step, dependent)` 结束——UI 与 CLI 在确认前展示这个后果。

`deliveries.<name>.path` 是 worktree 内的绝对路径；agent 之间传的是路径而不是内文（Prowl F1：agent 读文件零成本，真正缺的只是 `notify` 里不能内联——V1 允许 `notify` 内联 `deliveries.<name>.verdict`，正文仍只传路径）。

### 表达式与状态

`{{ expression }}` 用于 `text` / `instruction` / `prompt` / `notify` / `run` 命令 / `set` 值 / `if` / `while`。只读命名空间：

| 命名空间 | 内容 |
|---|---|
| `context.workflow` | `id`、`name` |
| `context.run` | `id`、`path` |
| `context.worktree` | `id`、`path`、`name`、`branch`（每步前刷新） |
| `context.roles.<role>` | `pane_id`、`agent`、`display_name`、`observed.state`（该步的快照） |
| `context.step` | `id`、`iteration`（循环外为 null） |
| `inputs.<name>` | 启动时的类型化输入 |
| `deliveries.<name>` | `path`、`verdict`（可为 null） |
| `runs.<step>` | `exit_code`、`output_path` |
| `state.<name>` | 声明过的可变类型化状态 |

文法（强到弱）：字面量（null / 布尔 / 整数 / 单双引号字符串）、字段与下标访问、括号、一元 `!` / `-`、`+ -`（仅整数）、`< <= > >=`、`== !=`、`&&`、`||`、`??`；函数 `exists(ref)`、`length(str)`。`&&` / `||` / `??` 短路。缺失引用是错误，`exists()` 与 `??` 是唯一的显式兜底；不做任何隐式类型转换；条件必须求值为布尔。`state` 类型：`integer` / `boolean` / `string`；`inputs` 类型：`integer`（`min` / `max`）/ `string`（单行）/ `enum`（`values`）。求值器暴露 `requiredReferences(expr)`（排除 `exists()` 与 `??` 右侧），同时供校验器报"引用了无生产者的 delivery"与运行时算 Skip 后果。

### 运行状态机

`WorkflowMachine`（`CodansCore/Workflow/WorkflowMachine.swift`）是纯值 reducer：`start(definition, bindings, inputs, now, makeToken) -> (WorkflowRun, [WorkflowEffect])`、`apply(event) -> [WorkflowEffect]`、`deliver(ordinal, body, verdict) -> DeliveryOutcome`。没有 I/O、没有时钟、没有随机数——全部注入，所以整个执行语义可以用"给事件、断言 effect 序列"的方式在 `CodansCoreTests` 里当可执行规范来写。

```
status:  running ─┬─► needs_attention ─┬─► running
                  │                    └─► (terminal)
                  └─► completed | cancelled | skipped(step, dependent) | iteration_limit_reached | interrupted

phase:   idle | waiting_for_role(role, ordinal) | injecting(ordinal) | launching(ordinal)
       | waiting_for_delivery(ordinal) | waiting_for_state(role) | running_command(step)

activation: waiting → persisting → delivered
                    ↘ provisional → delivered (Accept) | waiting (Ask again)
                    ↘ skipped | revoked
```

事件：`roleIdle` / `roleBlocked` / `roleGone`、`injected` / `injectionFailed`、`launched` / `launchFailed`、`commandFinished(step, outcome)`、`deliveryPersisted` / `deliveryPersistFailed`、`watchdog(ordinal, verdict)`、`user(action)`、`tick`。

effect（engine 解释）：`awaitRole(role, until)`、`openActivation(ordinal, token)`、`revokeActivation(ordinal)`、`materialize(instruction)`、`inject(pane, line)`、`launch(spec)`、`runCommand(step, command, cwd, timeout)`、`armWatchdog(ordinal, deadline)` / `disarmWatchdog`、`notify`、`close(pane)`、`persistDelivery`、`persistRecord`、`log(line)`、`finished`。

**Idle 门控。** `message` 只在角色 idle 时注入。idle 的判定来自 `AgentStateStore`：`.idle` 需持续 2 s（分类器有 1.2 s 的 working→idle 迟滞，再叠一层稳定期避免在两个 tool call 之间注入）；`.blocked` 持续超过 30 s 升级为 attention（动作：Focus pane / Keep waiting / Skip / Cancel）；pane 消失是 `roleGone` → attention（Relaunch 仅对 `launch` 角色可用）。永远不往 `working` 的 pane 键入任何东西。

**Watchdog。** 等待交付时不用墙钟而用角色状态：注入后角色曾 `working` 又回到 `idle` 且 `idle_grace`（默认 180 s）内没有交付 → 自动 nudge 一次（重键入完成命令，token 不变）→ 再等一个 `idle_grace` → attention。角色一直 `working` 就一直等——`expect.timeout` 是唯一会打断工作中 agent 的东西，而它没有默认值。

**取消 / 中断。** Cancel 吊销当前 activation、把活动步记 `failed`、结束 run；不关闭任何 pane、不终止 agent 的工作、不撤销副作用；正在跑的 `run:` 命令走 `CommandRunner` 的 SIGTERM→SIGKILL 阶梯。app 启动时把记录里仍是 `running` / `needs_attention` 的 run 标为 `interrupted`——只供查看，不恢复。

### 启动与 admission

无论从 CLI 还是 Command Palette / 启动面板发起，最终都是同一个 `WorkflowAdmission.admit(request)`，它不碰任何 pane：

1. 按 id（再按唯一 name）解析定义；有 error 诊断 → `WORKFLOW_INVALID`（带诊断）；Settings 里被禁用 → `WORKFLOW_DISABLED`；
2. 确定 source：调用方 pane（`CODANS_PANE_ID` / 进程祖先链）或显式的 pane / worktree 引用；有 `current` 角色却没有 pane → `SOURCE_REQUIRED`；
3. 仓库作用域且含 `run:` 步骤的文件需要已被信任（D8）→ 否则 `WORKFLOW_TRUST_REQUIRED`；
4. `--input` 类型化并检查范围；无默认值的输入缺失 → GUI 询问 / CLI `INPUT_REQUIRED`；
5. `--skip` 只接受"其 delivery 没有非可选消费者"的 step，否则 `INVALID_ARGUMENT` 指出依赖它的 step；
6. 角色绑定（上节）；`current` / `pick` pane 被占用 → `PANE_BUSY`；
7. 冻结 profile + 渲染好的 `AgentLaunchSpec`，分配 run 目录，写初始 `run.json`，**然后**才回复 CLI。

GUI 启动面板（`WorkflowStartFeature`，与 Handoff 面板同宿主同外观）只做三件事：角色选择器（launch 角色预填解析结果，pick 角色列出 worktree 内的 agent pane）、输入表单、可跳过 step 的勾选（旁边即时显示 Skip 后果）。确认即调用与 CLI 相同的 admission；面板不持有任何运行态。

**自发起。** 当 `run` 从将成为 `current` 角色的 pane 里调用、且第一步就是给该角色的 `message`，响应里直接带上渲染好的指令与完成命令（`self_initiated`），engine **不**再往调用方 pane 键入——调用它的 agent 手里已经有任务了。这让 agent 的自我交接变成两条命令：`codans workflow run codans.handoff`，然后照返回的命令 `deliver`。

### CLI 与 IPC

`codans workflow` 动词（全部支持 `--json`，信封与错误码遵循 [cli.md](cli.md) 的约定）：

| 动词 | 作用 |
|---|---|
| `list [--json]` | 三个作用域可见的定义、启用状态、校验状态 |
| `validate <file>` | 离线校验（不需要 app） |
| `run <id\|name> [source] [--role r=<profile\|auto\|pN>]… [--input k=v]… [--skip <step>]…` | admission + 启动；返回 run id、冻结的绑定、可能的 `self_initiated` |
| `status [run-id]` | 无参数时回答"我是谁"：调用方 pane 所属 run、角色、等待中的 step 及其完成命令；有 run-id 时返回 `status` / `step` / `activation` / `deliveries` / `attention` |
| `deliver [-\|--file <p>] [--verdict v] [--token t] [--run <id> --step <id>] [--force]` | 交付；无调用方 pane 时需显式 `--run --step`（记为 `source=manual`） |
| `resolve <run-id> <accept\|accept-with-verdict <v>\|ask-again\|keep-waiting\|skip\|cancel\|relaunch>` | 对 `needs_attention` 做出与 GUI 相同的动作 |
| `cancel <run-id>` | 吊销所有 token、结束 run |
| `runs [--worktree w] [--json]` | 列出该 worktree 的历史 run（读 `runs/index.json`） |

IPC 方法：`workflow.list` / `workflow.run` / `workflow.status` / `workflow.deliver` / `workflow.resolve` / `workflow.cancel` / `workflow.listRuns`。`validate` 不经 IPC（CLI 直接用 `CodansCore` 的解析器与校验器，这是把它们放进 leaf 包的另一个理由）。

错误码新增到 `CLIErrorCode`：`WORKFLOW_NOT_FOUND`、`WORKFLOW_INVALID`、`WORKFLOW_DISABLED`、`WORKFLOW_TRUST_REQUIRED`、`RUN_NOT_FOUND`、`SOURCE_REQUIRED`、`INPUT_REQUIRED`、`PROFILE_REQUIRED`、`PANE_BUSY`、`ROLE_MISMATCH`、`STEP_NOT_EXPECTING`、`TOKEN_REQUIRED`、`TOKEN_INVALID`、`OUTPUT_INVALID`、`OUTPUT_TOO_LARGE`、`VERDICT_REQUIRED`、`RENDERED_TEXT_INVALID`。每个都对应脚本可以分支的一种失败，不只是消息文本（lessons-learned 的复发检查）。

环境变量登记到 `CodansEnvironment.Key`：`CODANS_WORKFLOW_TOKEN`（activation 关联）、`CODANS_WORKFLOW_RUN`、`CODANS_WORKFLOW_ROLE`（后两个只是交叉检查提示，registry 才是权威）。

### 运行目录与记录

```
<worktree>/.codans/workflow-runs/
  index.json                         该 worktree 的 run 索引（id、workflow、状态、起止时间）
  <run-id>/
    run.json                         状态、绑定（profile id/name/agent、pane id）、输入名、state、
                                     invocation → step/iteration/activation/文件 的映射、steps、deliveries、runs
    log.md                           append-only 时间线（步进、注入、交付、attention、用户动作）
    definition.workflow.yaml         启动时的定义副本（run 只认它，源文件之后怎么改都不影响）
    instructions/<step>.<ordinal>.md 物化的多行指令
    deliveries/<name>.<ordinal>.md   每次交付（含 provisional）
    deliveries/<name>.md             最新视图，临时文件 + rename 原子替换
    runs/<step>.<ordinal>.{stdout,stderr}.log   `run:` 步骤输出（上限 16 MiB / 4 MiB）
```

放在 worktree 内而不是 `~/.config/codans/`，与 handoff 同一理由：参与的 agent 在自己的 cwd 下直接读 `deliveries.<name>.path`，不需要一条带作用域校验的 `workflow read` 命令；`.codans/.gitignore` 已自我忽略；工件与 worktree 生命周期一致。代价是删除 worktree 即删除历史——接受。

`run.json` 遵循 [architecture.md](../architecture.md) 的持久化不变量（顶层 `version`、原子 rename、snake_case、ISO-8601）。**token、环境变量值、渲染后的启动命令、凭据永不落盘**。所有写入先做包含性检查（无 `..`、在 base 内、不跟符号链接）。

保留：每个 worktree 只留最近 20 个终态 run，run 结束时修剪；`index.json` 里 `keep: true` 的不修剪。没有全局配额、没有导出。

### 可观测性与 UI

- **AgentState 面板**新增一组 "Workflows" 行：`<name> · <step title> · running/needs attention · 已用时间`，点击弹出 popover：步骤列表、角色 pane（可跳转）、attention 动作按钮（**按 `attention.actions` 原样渲染，UI 不重新推导策略**）、log 与 run 目录链接。选择这里而不是 toolbar 中央状态槽：该槽已被 worktree 进程徽标与状态项占用，而 AgentState 本来就是用户分诊 agent 的唯一去处，run 就是 agent 的上下文。
- **通知**：run 进入 `needs_attention` / 终态时进 inbox（`NotificationCoordinator` 门控），`notify:` 步骤同路。
- **Command Palette**：`Run Workflow: <name>`（对当前 worktree 可见的定义）、`Cancel Workflow: <name>`（活动 run）。
- **Settings → Agents → Workflows**：三个作用域的列表、启用开关、校验诊断、每个 launch 角色的记忆绑定（可清除）、仓库作用域文件的信任状态（D8）。

### 组件边界

| 组件 | 职责 | 不负责 |
|---|---|---|
| `CodansCore/Workflow/Definition` | `WorkflowDefinition` 及子类型、YAML 解析（Yams）、校验、诊断 | 发现、文件 I/O |
| `CodansCore/Workflow/Expression` | 词法 / 语法 / 求值、`requiredReferences`、模板渲染 | 任何命名空间的**来源** |
| `CodansCore/Workflow/Machine` | `WorkflowRun` 值、`WorkflowMachine`、控制流游标、Skip 后果、watchdog 策略、attention 动作表 | I/O、时钟、随机数 |
| `CodansCore/Workflow/Store` | run 目录布局、`run.json` / `log.md` / deliveries 读写、包含性检查、修剪 | 子进程、pane |
| `CodansIPC` `workflow.*` | wire 契约、错误码 | 语义 |
| `App/Features/Workflow/WorkflowEngine` | 拥有活动 run；每 run 一条 FIFO effect 队列；解释 effect；订阅 `AgentStateStore` / `TerminalEvent`；watchdog 计时 | 定义解析、UI |
| `App/Features/Workflow/WorkflowActivationRegistry` | token ↔ activation、按 pane 查等待中的 activation、吊销 | 交付校验 |
| `App/Features/Workflow/WorkflowDiscovery` | 三作用域扫描、文件监视、遮蔽、缓存诊断 | 校验逻辑（调 Core） |
| `Socket/WorkflowHandlers` | IPC → admission / engine / registry；调用方 pane 归属 | 运行态 |
| `WorkflowStartFeature` / `WorkflowStartOverlayView` | 启动草稿（角色 / 输入 / skip） | 运行态（直读 engine） |
| `AgentState` 面板 Workflows 组 / Settings pane | 呈现 + 转发用户动作 | 策略 |

依赖方向不变：`codans-cli` → `CodansKit` → `CodansIPC` → `CodansCore`；app → 全部；`Runtime/` 不 import 任何 Workflow 类型（engine 在 `App/` 层，通过既有 client 调 Runtime）。子进程只经 `CommandRunner`。

## 技术决策

- **D1 — 纯状态机 + effect 解释器（Prowl H2 原样借鉴）。** 执行语义能在无 pane、无 app 的 `CodansCoreTests` 里当规范测；engine 只是 effect 的翻译。这是整份设计里最值钱的一条。
- **D2 — 等待的正解是显式交付，不是猜屏幕。** `expect` + `deliver` + token 让"agent 干完了"成为一个有正文、有校验、可关联的事件；`wait: until idle` 只是廉价补充，文档明说它测的是 turn 不是 task（Prowl F4/F5）。
- **D3 — 校验是审查闸而不是墙（Prowl H14）。** 缺章节 / 缺 verdict 默认 provisional 交给用户，`strict: true` 才拒收。agent 的一次不合格式回答不应让一轮 20 分钟的 review 作废。
- **D4 — token 关联不认证。** 真正的地址是调用方 pane 的等待中 activation；token 只用来拒绝迟到 / 重复 / 错 step 的交付。这与 `CODANS_HANDOFF_REQUEST_ID` + `HandoffRequestRegistry` 是同一个模式的推广。
- **D5 — 单文件 YAML，不做目录包。** 没有脚本 action 就没有需要打包的东西；文件更容易 diff、review、复制。V2 若引入 action 包，`*.workflow.yaml` 与 `*.codansworkflow/` 可以并存于发现层。
- **D6 — `run:` 步骤代替 action 包。** codans 是终端编排器，"跑一条命令拿退出码与输出"已经是 `pane send --wait --capture` 与 `CommandRunner` 的日常；JSON Schema 化的输入输出契约留到有真实需求时再加。默认 headless（确定的退出码 + 完整 stdout）而不是键入 pane（best-effort），`in: <role>` 是给"让用户看见"的可选项。
- **D7 — 引擎是 `@Observable` 运行态对象而不是 TCA reducer。** 与 `HierarchyManager` / `AgentStateStore` / `CommandQueueRunner` 同一模式：TCA 只持草稿与呈现，避免把长生命周期的 effect 队列塞进 reducer 的 `Effect` 生命周期里（Prowl 把 runner 放在 reducer 里，为此额外造了 effect 队列的 fence 机制）。
- **D8 — 仓库作用域的 `run:` 需要一次性信任。** clone 一个仓库不应等于同意跑它 `.codans/workflows/` 里的 shell 命令。信任绑定 `(路径, 文件 SHA-256)`，存 `settings.json` `workflows.trusted`，只能在 app 里授予（Settings 或首次启动时的确认），CLI 不能；文件一改就要重新信任；只含 `message` / `launch` / `notify` 等步骤的文件不需要信任。用户作用域与内建隐式信任。
- **D9 — `.codans/.gitignore` 从 `*` 改为放行 `workflows/`。** 仓库作用域必须能提交；`HandoffLayout` 写 gitignore 的地方改成写 `*` + `!.gitignore` + `!workflows/`，创建 `workflows/` 时幂等重写。已有仓库在首次发现到 `.codans/workflows/` 时也重写一次。
- **D10 — run 目录在 worktree 内，无全局历史。** 见"运行目录"一节；避免 `workflow read` 这一整套带作用域的读取命令与 30 天 / 5 GiB 的保留策略。
- **D11 — 现有 `codans handoff` 不动。** `codans.handoff` 是它的工作流表达（author 写 briefing → `run:` 走 `HandoffCoordinator` 保存 → 可选 launch receiver），两者并存到工作流稳定为止（Prowl 020 的同一决定）。
- **D12 — 表达式语言故意小。** 循环计数与 verdict 分支需要的只有比较、逻辑、整数加减与 `exists` / `??`；每多一个运算符都是校验器、求值器、文档三处的长期负担。

## 备选方案

- **继续用 CLI 手工编排（bash 循环 + `agent wait` + `pane send`）。** 这条路保留且一等，但它不是机制：不可分享、无 attention、无 token 关联（迟到的输出会串到下一步）、无进度可见。工作流是在这些原语之上加上"可声明、可观测、可介入"三件事。
- **让一个 master agent 当编排器（用户 `multi-agent-dev` skill 里的 MSGID / ACK 协议）。** 否决作为*机制*：编排本身消耗 master 的 token 与注意力，每一步的确定性都靠 prompt；ACK 循环是在没有交付通道时的补偿。工作流可以把 master 声明为 `current` 角色来兼容这种用法。
- **原样移植 Prowl v1（目录包 + 脚本 action + JSON Schema + 内容指纹审批 + 全局历史 + 状态中心）。** 否决：Prowl 的 workflow 相关 Swift 上万行、20 余份设计文档，而它的作者也把脚本 action 与手 handoff 迁移拖到了 release 之后。codans 的 `run:` 与 `CommandRunner` 已覆盖确定性工作的主要场景；分阶段引入比一次性背上全部复杂度更符合"Slow is Fast"。
- **JSON 定义（免去 Yams 依赖）。** 否决：多行 prompt / instruction 在 JSON 里不可读，而工作流的主要内容就是 prompt。Yams 是纯 Swift、无传递依赖，`Package.resolved` 已受控（锁定精确版本）。
- **代码式 DSL（Swift / JS 脚本）。** 否决：需要内嵌解释器或编译，失去静态校验、GUI 启动面板与 Skip 后果分析；而 YAML 数据可以被校验器、Settings 与 agent 的 authoring skill 三方共同消费。
- **run 目录放在 `~/.config/codans/workflow-runs/`。** 否决：agent 读不到 cwd 之外的路径而不带作用域校验的读取命令；见 D10。
- **`expect` 用 idle 检测代替显式交付。** 否决：Prowl F4 的实证——后台跑任务的 agent 看起来 idle，会被要求"现在交付"；显式交付把"干完了"的判断权交回 agent 自己。
- **把 run 状态放进 TCA `RootFeature`。** 否决：见 D7；`RootFeature` 已近 3000 行，且 >7 个顶层 Scope 会拖垮类型检查。

## Cross-Cutting

- **安全**：`run:` 以用户 OS 权限执行、无沙箱——因此有 D8 的仓库信任；`run` 命令与 `--input` 值经模板渲染后不再二次 shell 解析（命令作为整体交给 `/bin/sh -c`，`inputs` 只允许单行无控制字符）。token 与 env 值不落盘；`deliver` 正文上限 16 MiB；写入 run 目录做包含性与符号链接检查。Codex 默认沙箱禁 Unix socket 的问题与 handoff 相同，错误提示复用。
- **可观测性**：`log.md` 每个状态跃迁一行（含 `source=cli|gui|watchdog`）；`codans workflow status` 是脚本的轮询点；AgentState 面板行 + inbox 通知是人的入口；`os_log` 子系统 `workflow`。
- **测试**：`CodansCoreTests/Workflow/*`——解析 / 校验诊断快照、表达式求值与 `requiredReferences`、状态机"事件 → effect 序列"规范（review-loop 的完整走通、Skip 后果、watchdog 升级、迟到交付被拒）、store 布局与包含性；`CodansTests/Socket/WorkflowHandlersTests`——闭包桩验证 admission 错误码与零副作用；`WorkflowStartFeatureTests`（`TestStore`）；`EndToEndRPCIntegrationTests` 加一条 run → deliver → status；`docs/user-tests/cli-regression/harness.sh` 加 `workflow` 用例并把新 schema 登记进 `cli-output.schema.json`。
- **迁移**：无既有格式；`settings.json` 新增 `workflows` 子树（`disabled`、`bindings`、`trusted`）走 `decodeIfPresent` + 缺省，v3 版本号不变。
- **回滚**：功能可整体关闭（Settings → Workflows 总开关），关闭时 `workflow.*` 方法返回 `unsupported`，不影响任何既有动词。

## 里程碑

1. **M1 — 核心（无 GUI）**：`CodansCore/Workflow/*`（定义、解析、校验、表达式、机器、store）+ Yams；`workflow.*` IPC；`WorkflowEngine` / registry / discovery / handlers；CLI `list / validate / run / status / deliver / resolve / cancel / runs`；inbox 通知；AgentState 面板一行只读状态。验收：`review-loop` 用两个真实 agent 从 CLI 跑通一轮循环，attention 通过 `resolve` 处理。
2. **M2 — GUI**：启动面板、面板 popover 与 attention 按钮、Settings → Workflows（列表 / 启用 / 诊断 / 绑定 / 信任）、Command Palette 项。
3. **M3 — 内建与 skill**：`codans.review-loop`、`codans.handoff`；`skills/codans-workflow`（authoring / running / participating 三段，随 app 嵌入并由 `codans skill install` 链接）；`.codans/.gitignore` 放行（D9）。
4. **V2 预留**（各自另写设计）：`wait: {all|any: [...]}` 并行分支与败者取消；脚本 action 包（`*.codansworkflow/` 目录 + JSON Schema）；`expect.status: idle` + `capture` 的观察模式；Server 项目。

## 风险

- **turn-idle ≠ task-idle**：后台跑任务的 agent 会被过早 nudge。缓解：nudge 文案永远是"完成后交付"而不是"现在交付"；`idle_grace` 默认 180 s；authoring skill 写明。
- **屏幕分类器的误判**（`AgentStateStore` 靠渲染文本识别 working/idle）：某个 agent 版本改了 UI 会让 idle 门控卡住或误注入。缓解：注入前的 2 s 稳定期；`blocked` / 长时间 `waiting_for_role` 都会升级 attention 而不是无限等；分类器本身已有逐 agent 的检测器与测试。
- **agent 不遵守交付协议**（忘了、写错命令、用了 `pane send` 汇报）：watchdog 的一次 nudge + attention 的 Ask again；`status`（无参数）随时回答"我是谁、该做什么"；skill 与 kickoff 里都给出精确命令。
- **仓库作用域文件是供应链入口**：D8 的信任闸；无 `run:` 的文件不需要信任但仍需用户从 Settings / Palette 主动启动，工作流从不自动运行。
- **Yams 新依赖**：锁定精确版本进 `Package.resolved`（CI 曾因 float 的传递依赖断过，见 memory / lessons-learned）；解析器只用在定义读取这一处，替换成本低。
- **`RootFeature` 继续膨胀**：Workflow 的 TCA 面只有启动面板一个 `@Presents`，放进现有的 `routerScopes` 组；运行态与设置面板不进 TCA。

## 参考

- Prowl `docs-ai/063-agent-workflows/`：`dsl-spec.md`（V1 规范）、`007-b2-runner-core.md`（纯机器 + effect 的决策 H2 / H4 / H14）、`012-v1-boundary-observations.md`（F1–F7 实证）、`015-action-bundles-and-control-flow.md`、`020-handoff-workflow.md`；`skills/prowl-workflow/`
- [agent-handoff.md](agent-handoff.md) —— profile 启动管线、`.codans/handoff/` 工件、`HandoffRequestRegistry`
- [active-agents-view.md](active-agents-view.md) —— `AgentStateStore` 与运行态分类
- [cli.md](cli.md) —— 动词、信封、错误码、调用方 pane 归属
- [notifications.md](notifications.md) —— inbox 与 `NotificationCoordinator`
- [environment.md](environment.md) —— `CodansEnvironment.Key` 与通道隔离
- [lessons-learned 2026-09-14](../lessons-learned/2026-09-14-cli-agent-orchestration-gaps.md) —— 编排缺口的前置经验与复发检查
