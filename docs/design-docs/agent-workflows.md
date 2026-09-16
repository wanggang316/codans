# 设计文档：Agent Workflows

**状态：** 历史设计；当前目标由 [Agent Workflows v2](agent-workflows-v2.md) 替代
**评审状态：** Draft
**作者：** Gump / Codex
**日期：** 2026-09-15

本文保留旧版方案与设计依据，不再作为后续实现目标。固定模板、创建运行表单、全局 Workspace 约束和 YAML 非目标已被 v2 修订。当前实现范围仍见 [使用说明](../workflow-usage.md)；v2 的定义、Role、文件管理和运行界面尚未实现。

## 背景与范围

codans 是终端与 Agent 的工作环境。用户在 Project → Worktree → Tab → Pane 中启动 Agent，执行开发、审查、交接和调研。Workflow 增加一个执行与观察层：任务如何被委派、基于什么输入、是否送达、交付了什么、为什么等待、由谁处理异常。

设计采用三个分工：

| 层 | 职责 | 不承担的职责 |
|---|---|---|
| Workflow Skill | 指导协调 Agent 拆分任务、选择角色、解释结果、提交后续计划 | 持有执行真相、保证消息送达、绕过执行约束 |
| Workflow | 承载本次协作的目标快照、已提交计划、角色、依赖、交付契约与运行记录 | 要求用户预先写出全部步骤 |
| Workflow Engine | 执行已提交步骤，维护身份、状态、等待、存储、预算和可观测事件 | 隐藏调用模型、代替 Agent 判断开放问题、证明代码语义正确 |

CLI 与 UI 是同一个应用服务的入口。Skill 是协调 Agent 使用的方法；Engine 不解析 Skill 的自然语言，不因 Skill 声称“完成”而完成运行。

### 当前接入基础

以下是当前 checkout 的源码事实；不是本设计的实现状态或运行测试结论。

| 已有能力 | 接入依据 | 需要补齐 |
|---|---|---|
| Agent Profiles 与统一启动 | [AgentHandlers.swift](../../apps/mac/codans/App/Features/Socket/AgentHandlers.swift)、[HierarchyClient.swift](../../apps/mac/codans/App/Clients/HierarchyClient.swift) | Workflow 必须取得确定的 pane 地址；启动返回不代表接收任务 |
| 完整提示提交 | [TerminalClient.swift](../../apps/mac/codans/App/Clients/TerminalClient.swift) 的 `sendCommand` 使用 paste 后延迟 Enter | 当前返回 Void、可能静默无操作；增加可等待、可取消、有身份检查的投递 adapter |
| Agent 与终端观察 | [AgentBinder.swift](../../apps/mac/codans/Runtime/AgentBinder.swift)、[AgentStateStore.swift](../../apps/mac/codans/App/Features/AgentState/AgentStateStore.swift) | session ID 尚非可靠前提；`finished` 是展示状态，不能作为业务交付 |
| Handoff 领域服务 | [HandoffCoordinator.swift](../../apps/mac/CodansCore/Handoff/HandoffCoordinator.swift)、[HandoffRequestRegistry.swift](../../apps/mac/codans/App/Features/Handoff/HandoffRequestRegistry.swift) | 复用材料保存与一次性 claim 思路；扩展为通用执行身份与不可变 packet |
| 类型化 Unix socket IPC | [Method.swift](../../apps/mac/CodansIPC/Method.swift)、[Framing.swift](../../apps/mac/CodansIPC/Framing.swift) | 新增 Workflow 协议；当前 frame 上限 16 MiB，业务正文预算必须更小 |
| 版本化 JSON 原子存储 | [AtomicFileStore.swift](../../apps/mac/CodansCore/AtomicFileStore.swift) | 专用单写者 RunStore；不得复用 Catalog 的 debounce 保存关键状态 |
| 共享子进程运行器 | [CommandRunner.swift](../../apps/mac/codans/Process/CommandRunner.swift) | 任意脚本 action 需要额外的 stdin、产物、进程组与取消支持，首版不开放 |

## 目标与非目标

### 目标

1. Skill 可通过 CLI 动态构建执行计划，用户无需先学习 DSL。
2. UI 与 CLI 能一致回答：谁在做什么、等待什么、最后的可靠事实是什么、结果在哪里。
3. 启动、投递、接收、交付、验收分别记录；不能互相冒充。
4. 重试、取消、迟到结果、协调者更换和人工接管不破坏身份与历史。
5. 复用终端/Profile/Handoff/Process 能力，维持 Runtime 的终端所有权。
6. 先支持本地、同一 worktree 的串行协作，再增加受控并行。

### 非目标

- 首版提供 YAML 编程语言、表达式解释器、可视化流程编辑器或模板市场。
- 在应用中隐藏调用模型，或复刻各 Agent 的推理/工具循环。
- 把 WorkItem 发展成 Issue tracker、排期或项目管理系统。
- 首版支持跨主机、跨 worktree 自动集成、多写者或无人值守发布。
- 通过终端文本推断“任务完成”，或声称知道 Agent 没有上报的内部进度。
- 首版保证崩溃后自动续跑、外部操作 exactly-once 或自动回滚。

## 总体设计

### 系统关系

```text
User ------------------------> Work Item / Run UI
                                      |
Coordinator Agent + Skill             |
          |                           |
          +---- codans CLI / IPC -----+
                                      v
                            Workflow Service
                       admission / command validation
                                      |
                                      v
                            Workflow Runtime
                    RunMachine + ordered effect lanes
                         |            |             |
                         v            v             v
                  Agent Adapter  Native Actions  Human Decisions
                         |            |             |
                 Profile / Pane  Handoff / Process  TCA UI
                         |            |             |
                         +---- correlated events ---+
                                      |
                         RunStore + ArtifactStore
                                      |
                          UI / CLI state projection

Terminal observations --> Watchdog --> Runtime events
```

Engine 根据已提交依赖调度，不负责生成计划。Agent 读到结果后，通过一个带版本检查的事务追加下一阶段。Handoff、Advisor 和 Committee 使用内置计划构造器生成相同事务，不另起一套执行路径；首版不开放通用模板语言。

### 与现有层级的关系

```text
Project
  +-- Worktrees --> Tabs --> Panes
  +-- WorkItems
        +-- WorkflowRuns
              +-- PlanRevisions
              +-- RoleBindings --> Panes
              +-- StepInvocations --> Attempts --> Deliveries
              +-- Decisions / Artifacts / Events
```

WorkItem 不成为终端层级中的第五层。Pane 是可替换的执行资源；关闭或移动视图不删除工作项与运行历史。首版创建 Run 时可顺带创建轻量 WorkItem，用户只需填写或确认目标，无需维护额外任务表单。

## 领域模型与所有权

| 实体 | 核心字段 | 所有权与不变量 |
|---|---|---|
| WorkItem | ID、projectID、目标、验收条件、约束、goalRevision、成果引用 | WorkItemService 单写；表达可独立验收的用户任务 |
| WorkflowRun | ID、workItemID、目标快照、worktree 地址、activePlanRevision、controlEpoch、状态、预算 | Runtime 单写；一次协作不等于整个工作项 |
| PlanRevision | revision、baseRevision、节点快照、提交者、变更理由、sealed | 提交后不可变；未提交草稿无执行效力 |
| Step | ID、类型、指令/操作、输入引用、依赖、输出契约、验收方式 | 一旦产生 invocation，执行相关字段不可原地修改 |
| StepInvocation | ID、stepID、introducedRevision、角色、输入快照摘要 | 代表一个逻辑步骤的执行；新的审查轮次使用新 step 与 invocation |
| Attempt | ID、invocationID、attemptNumber、generation、投递状态、deadline | 重试产生新 attempt，旧凭证失效；执行身份不依赖当前 plan revision |
| RoleBinding | roleID、profile 快照、pane 地址、bindingGeneration、可选 sessionID | 在发令前重新核对；sessionID 缺失不伪造 |
| Delivery | ID、attemptID、内容摘要、artifactRefs、验证/接受记录 | 幂等提交；接受的正文不可覆盖 |
| Decision | ID、关联 attempt/成果摘要、允许选项、决策者、结果 | 旧决策不适用于新版本；只能消费一次 |
| Event | runID、sequence、时间、来源、对象身份、类型、紧凑 payload | 是产品历史；不把完整提示、环境变量、token 写入工程日志 |

### WorkItem 完成与 Run 结束

WorkItem 状态为 `open / active / blocked / completed / cancelled`。业务状态由 WorkItemService 更新，UI 可附加从 Run 派生的执行摘要，但不能让 Run 状态与 WorkItem 状态互相覆盖。

Run 的 `succeeded` 表示本次计划按契约结束，不自动完成 WorkItem。例如 Handoff 成功后，工作项仍 active。WorkItem 的 `completed` 必须有独立验收记录，关联 `goalRevision` 和具体成果。改变目标或成果版本后，旧验收只作历史证据。

首版工作项验收采用用户显式操作。协调 Agent 可提交验收建议，不能自行写 `completed`。Run 内 Human 节点确认的是该节点的请求；WorkItem 验收是独立命令，不能假装两份文件同时事务提交。

### 三类执行节点与控制关系

| 类型 | 行为 | 完成依据 |
|---|---|---|
| `agent` | 分配给当前、已选或新启动的 Agent；复用角色 pane | 与有效 attempt 对应的显式 Delivery 被接受 |
| `action` | 执行注册的原生操作或后续受控进程操作 | 类型化结果及产物通过契约验证 |
| `human` | 创建持久待决策请求，等待 UI 操作 | 对本次请求与成果摘要作出的有效决定 |

顺序与 Join 由 `after` 依赖表达，不启动一个 Agent 来判断结果是否都到了。首版仅支持 `after: all accepted`；条件分支与循环由协调 Skill 根据输出追加步骤，不引入条件表达式。

节点接受仅表示交付符合该节点的契约。例如 review 的 `issues` 是合法结果，不能等同于代码通过审查。若下一步依赖 `clean`，首版由协调者读取 verdict 后提交下一阶段，不预先用普通 `after` 冒充 verdict 条件。

输入引用只有两种：已存在的 artifactID，或 `fromStep + outputName` 指向声明的生产者。后者必须由 after 依赖保证先接受，绑定在 invocation 创建时解析为不可变 artifact ID 与摘要；不接受任意模板求值、路径插值或“最新结果”隐式引用。

## 动态计划协议

### 草稿与提交

草稿可存在于 Agent 上下文、CLI 输入文件或 UI 编辑态。只有 `plan.apply` 成功提交的完整事务才产生调度效力，不需要单独的服务器草稿存储。

每次提交携带 `commandID / baseRevision / controlEpoch`。Engine 在同一个串行命令通道中校验控制权、版本、结构与资源规则，持久化新 revision 后再检查调度资格。created Run 只保存计划，必须 start 后才可派发；paused Run 不因提交计划恢复。版本冲突返回当前 revision 与差异摘要，不自动覆盖或合并。

事务支持 `addSteps / updateUnstartedSteps / removeUnstartedSteps / seal`；阶段 2 增加显式 `authorizeRepair`。不支持任意状态写入、历史删除或隐式取消运行中的节点。

规则：

- Step ID 在一个 Run 内不复用；已执行历史只能追加说明或关联后续处理。
- 未创建 invocation 的步骤才可更改；变更后必须重新验证整个依赖图。
- 不能给已经开始的步骤补一个后来才发生的依赖，也不能更换它的输入、执行者或契约。
- 运行中的任务要变更，先显式撤销旧 attempt，再新增步骤；改变计划本身不终止外部工作。
- 图必须无环；引用必须有明确生产者，引用的输出符合声明的契约。
- 新 revision 可以保留旧 revision 已开始的任务。交付按 attempt/generation 校验，不能因全局 revision 增加而拒收有效 worker。
- sealed 禁止拓扑与契约修改，允许既定节点的交付、决策和受控重试。

### 开放计划与结束

开放计划只有在没有活动 attempt、没有未决决定或失败阻塞、没有剩余待执行节点时，才进入 `waiting_for_plan`，保留等待原因和协调者身份。等待 worker 的 Run 保持 running，等待人工决定或失败处理则使用对应状态与原因。不能因任务列表暂时清空自动成功。

协调者通过 `seal` 声明不再扩展本次计划，再调用 `finish`：

- `succeeded`：已 sealed，无活动 attempt，所有必需节点 accepted 或其失败已被有效替代步骤解决，无未决人工决定。
- `incomplete`：已 sealed，无活动 attempt，明确列出未完成项、被放弃节点和结束理由。
- 有活动任务时 `finish` 拒绝，不隐式取消。
- `cancel` 是独立操作，允许在任意非终态撤销后续调度。

### 失败的后续处理

执行失败不会擦除已完成结果。Engine 暂停新的自动派发并通知协调者；协调者可选择重试、追加修复阶段或请求用户决定。

`retry` 只针对未 accepted 的 invocation，保持指令、输入 artifact 与执行契约不变，产生新 attempt。对声明了受检版本的任务，实时工作区版本也是输入：派发前重验，不匹配返回 INPUT_CHANGED，不能只检查 artifact ID。代码或任务输入变化时必须新增步骤。存在外部副作用且结果未知时，首版禁止 Agent 自动重试，由用户检查并明确处理。

动态修复使用显式关系：新步骤可声明 `replacesFailedStep`。旧失败保持可见，只有替代步骤被接受且符合原声明的输出契约后，失败 disposition 才成为 resolved。旧下游依赖不自动重写；尚未开始的下游必须在同一次计划事务中显式重连。被替代步骤与替代链必须无环。

Agent 不能通过删除失败节点或写 `resolved=true` 把一次失败变成成功。放弃必需工作只能结束为 incomplete，或由用户显式调整目标与验收范围。

失败暂停只阻止普通调度。有效 retry 命令可授权该 invocation 的新 attempt；阶段 2 的 authorizeRepair 在计划事务中明确失败步骤、允许执行的修复子图和最终替代步骤。Engine 校验后只派发这些修复节点，不要求旧失败先 resolved 才启动修复。修复成功且没有其他 blocker 后恢复普通调度；修复再次失败回到 needs_attention。显式 paused 状态优先，修复授权不能覆盖用户暂停。

## 执行状态与时序

### Run 状态

| 状态 | 精确定义 |
|---|---|
| `created` | 已保存初始运行信息，尚未启动 |
| `running` | 在预算和资源范围内执行已提交工作 |
| `waiting_for_plan` | 开放计划没有活动、待执行或被阻塞工作及未决决定，等待协调者提交或结束 |
| `needs_attention` | 未决失败、协议问题、人工阻塞或执行状态不确定 |
| `paused` | 用户或协调者明确暂停新派发；在途结果仍可保存 |
| `cancelling` | 已撤销调度授权，正在处理各 executor 的停止状态 |
| `succeeded / incomplete / cancelled` | 本次执行终态 |
| `interrupted` | 应用重启发现的未结束 Run；首版不在原 Run 自动续跑 |

状态与等待原因分开建模。UI 应显示 `waiting_for_delivery`、`waiting_for_role`、`waiting_for_user`、`coordinator_unavailable` 等具体原因，不只显示“运行中”。

### Attempt 状态

```text
queued -> preparing -> dispatching -> awaiting_delivery
                                      |
                                      v
                                  persisting
                                      |
                       +--------------+---------------+
                       v                              v
               awaiting_acceptance                 accepted

Nonterminal -> failed / revoked / execution_unknown
```

`submittedToTerminal`、`claimedByAgent` 是独立 receipt 事实。没有 Agent claim 时，UI 只能显示“已提交，等待接收/交付”，不能凭 terminal working 显示“任务已被接收”。有效 deliver 可同时证明 claimant 身份，无须强迫所有 Agent 先额外 claim。

### 标准执行序列

1. 选择可运行步骤，解析角色及输入引用。
2. 持久化 invocation、attempt、输入快照和 execution intent。
3. 注册观察，再经有序 effect lane 请求 adapter 执行。
4. adapter 在真正启动、paste、Enter 的边界检查 attempt 与绑定 generation。
5. 收到投递 receipt 后保存事实；Agent 节点继续等待 deliver。
6. 校验交付身份、长度、结构、artifact 引用及声明的输入版本。
7. 先保存不可变产物，再原子提交接受/待验收记录、attempt 状态及后续 eligible 状态。
8. 持久化成功才向 CLI ACK；随后调度依赖或通知协调者。

任何存储失败都不能返回成功 ACK 或启动依赖它的操作。Runtime actor 在 await 时可重入，因此仅有 actor 不够：命令处理和提交使用串行通道，副作用有队列，最终 adapter 边界仍检查 fence。

### Agent 交付与验收

输出契约首版支持有界文本、限定字段的 JSON 对象、枚举 verdict、必需 artifact 引用。采用共享 validator，不建立通用 JSON Schema 解释器作为首版前提。

受检摘要采用显式字段映射，例如输出 reviewedDigest 必须等于输入 change artifact 的 digest；这由契约检查器比较，不让 Agent 自报的任意版本通过。它只能证明报告关联了指定输入，不能证明 Agent 实际充分审查了该版本。

身份错误、过期凭证、超限正文始终拒绝。内容格式不满足契约时，保存可检查的 rejected submission，返回具体错误；首版不提供“强行当作合格”的普通 worker 命令。

`acceptance: contract` 在结构验证通过后自动接受；`acceptance: human` 则先保存 delivery，再创建人工决定。用户如需接受偏离契约的材料，必须用明确的 override 决策并留下偏离项，不能将其记录为自动验证通过。依赖仍必须满足实际可消费的输入类型。

同一 delivery ID、同一内容摘要重复提交，返回同一 receipt；相同 ID 不同内容返回冲突。ACK 丢失后重试不能产生第二份接受记录或重复派发。

## 协调权、资源与人工接管

### 协调者

一个 Run 同时只有一个有效 ControllerBinding，记录 coordinator pane/identity、`controlEpoch` 和作用域凭证。协调者能改计划、读取全部 Run 结果、在权限内重试和结束；worker 只能读取分配给自己的输入、上报进度并交付自己的 attempt。

首版以 epoch fencing 和明确的断开/接管事件管理控制权，不要求 Agent 每隔固定秒数执行 heartbeat。长模型调用、阻塞式 CLI 等待不能因为没有 heartbeat 被误判失去协调权。

协调 pane 退出、被替换或身份不再可确认时，暂停新派发并显示 `coordinator_unavailable`；已有 worker 可继续交付。用户选择接管或更换协调者时增加 controlEpoch，旧协调者的写命令随即失效。

这些能力凭证用于同机协作隔离和防串单，不构成抵御同一 OS 用户恶意访问的安全边界。Token 不写入一般日志或产物；持久记录仅保存 verifier，明文只在当次授权响应中返回。重启统一作废旧授权。

Run 启动同时冻结 allowedActionIDs 和执行范围。首版只注册 save-packet 等已有领域操作；阶段 2 的测试 action 执行用户选择的项目测试配置，以固定 executable/argv 调用共享运行器。协调者不能把任意字符串升级成 shell action，也不能通过修改计划增加发布权限。Agent 自身工具的权限仍由所选 Profile 和运行时管理，Engine 的限制只约束它发起的操作。

### 身份观察边界

Agent adapter 维护 surface 生命周期 generation，并在可用时记录前台进程实例身份（PID 与启动标识）；pane 地址、surface 重建、前台进程更换或身份不再可确认时使旧绑定失效。不能只依赖 AgentKind 的 bind/unbind 事件，因为同种 Agent 替换可能不触发 kind 变化。

发令前和 paste/Enter 间重新检查这些值。身份无法确认时不继续发送 Enter，显示 submission unknown。该保证覆盖可观测到的生命周期变化，不声称消除最后检查与 OS 实际键入之间的所有进程竞态；Agent 的 assignment claim/delivery 提供下一层显式确认。

### 同 pane 自发起

协调 Agent 可能也是 author。它执行 `workflow start` 时，不能再等待该 pane idle 后向它注入任务，否则 CLI 与 Agent 会互等。

`start --claim-current` 在调用者身份匹配时，原子领取一个已就绪、分配给自己的任务，并在响应中返回输入引用、指令和 attempt 凭证，不再次注入该 pane。调用立即结束，Agent 根据返回内容继续工作。

协调者自己的角色绑定固定为 pull/claim 路由：后续 plan.apply 即使发现该角色的就绪节点，也只登记可领取状态，不向其 pane 自动注入。普通 worker 使用 push 路由。claim 与 push 由同一派发登记互斥，一个 attempt 不能两条路径都执行。普通 GUI 启动的非协调角色才走 idle 检查与终端注入。

后续 claim 采用相同路径。协调者不能阻塞等待一个只能由自己领取完成的任务；wait 应返回 SELF_WAIT_CONFLICT 与领取指引。

### 占用与预算

- 首版一个 worktree 只允许一个 active Run，一个 pane 只绑定该 Run 的一个交互角色。
- 同一 pane 同时最多一个未完成委派；author/reviewer 可跨轮复用 pane。
- 首版新增步骤串行派发，后续阶段才允许不同 pane 的受控并行。
- 同 worktree 最多一个受 Engine 调度的 writer。写者限制不拦截用户或外部进程修改，需使用版本检查使证据失效。
- writer reservation 跨 attempt、step 和 Run 保留；撤销、取消或 interrupted 不自动释放。只有 adapter 确认停止，或用户检查后记录明确处置，才允许新 writer。任何新增步骤、重试和新 Run admission 都执行这个检查，不能通过更换 step ID 绕过。启动先从持久记录重建未决占用。
- 预算在启动时冻结：总执行时长、最大节点数、最大 attempt 数、最大并发数及产物额度。协调者不能通过新增 revision 或 retry 重置预算。
- Skill 的 review round 上限是协作策略；Engine 另有总节点/attempt/时间硬上限。将轮数变成强制策略时必须使用受校验的专用策略字段，不能信任 Agent 自报计数。
- 首版建议默认总时长 2 小时、100 个步骤、每步骤最多 3 次尝试、并发数 1；启动时可由用户调整。预算触顶暂停新派发并请求处理，不隐式丢弃现有结果。

总时长从 start 起计算，包含暂停、人工等待与系统睡眠；运行中用户可显式延长并记录事件，协调者无权重置。Watchdog 使用注入时钟与最新观察快照，working 不触发自动催促；idle 只可生成提醒建议。首版不自动向终端注入 nudge，用户确认后才走同一受身份约束的投递路径。

### 暂停、接管和取消

Pause 停止新的外部派发，允许在途工作交付。人工接管在 Pause 的基础上撤销协调者写权限；恢复时新授权不得复用旧 epoch。

Cancel 先在内存立即停止新派发并提高 attempt fence，再尝试持久化撤销意图，随后尽力取消 Engine 所拥有的进程操作。保存失败返回 STORAGE_UNAVAILABLE，保持本进程停止派发，UI 显示“已停止派发，取消记录未保存”，不能 ACK 持久 cancelled。默认不关闭 pane，不对用户控制的 Agent 自动发送 Ctrl-C，也不声称已撤销文件或 Git 改动。

Run 可以在调度已停止后成为 cancelled，但每个外部执行者必须单独显示 `stopped / may_still_be_running / unknown`。用户可另行选择中断 Agent。未确认旧 writer 停止前，不允许自动启动替代 writer。

普通 deliver 对 revoked attempt 一律返回 STALE_ATTEMPT，不保存其正文。用户可通过明确的“导入历史材料”操作归档迟到结果，记录人工来源；导入不能接受为新任务结果、解锁依赖或改变终态。

## CLI 与 IPC 契约

以下为拟议接口。GUI 通过同一 WorkflowService 调用，无独立推进逻辑。CLI 不直接读写 App 的 RunStore；显式输入文件作为上传数据通过 IPC 传送，不能被 watcher 当成完成信号。

| CLI 概念命令 | RPC | 主要参数与返回 |
|---|---|---|
| `workflow create` | `workflow.create` | 目标、workItem 引用/新建内容、worktree、控制者、预算；返回 runID |
| `workflow plan apply` | `workflow.plan.apply` | commandID、baseRevision、controlEpoch、计划事务；返回新 revision |
| `workflow start` | `workflow.start` | runID、可选 claim-current；立即返回接纳与 assignment，不等待全流程 |
| `workflow claim` | `workflow.claim` | runID、调用者；返回自己的可领取 assignment |
| `workflow status` | `workflow.status` | runID；结构化状态、原因、允许操作、最后事件序号 |
| `workflow events` | `workflow.events` | runID、afterSequence、limit；有界分页事件 |
| `workflow wait` | `workflow.wait` | runID、afterSequence、timeout；有界长轮询，无变化返回原 cursor |
| `workflow read` | `workflow.read` | assignment/artifact ID、UTF-8 安全分页；返回授权内容 |
| `workflow report` | `workflow.report` | attempt、进度/阻塞说明；记录 agent-reported 事实，不更改执行结果 |
| `workflow deliver` | `workflow.deliver` | attempt、deliveryID、凭证、正文/产物；返回持久 receipt 与 acceptance 状态 |
| `workflow retry` | `workflow.retry` | invocation、预期 attempt；创建新 attempt，不改写旧输入 |
| `workflow decide` | `workflow.decide` | decisionID、被审阅摘要、选择；首版权威人工决定只由 App UI 签发 |
| `workflow pause / resume` | `workflow.pause / resume` | 同 Run 权限、原因；resume 仅限当前进程内 paused Run |
| `workflow takeover` | `workflow.takeover` | 首版由 UI 授予新控制者并提高 epoch，普通 worker 无权限 |
| `workflow seal / finish` | `workflow.seal / finish` | 当前 revision；finish 带 outcome 和总结产物 |
| `workflow cancel` | `workflow.cancel` | runID、原因；返回调度状态及外部执行剩余状态 |
| UI 中断收尾 | `workflow.resolveInterrupted` | 确认外部执行处置与结束原因；只关闭旧记录，不恢复调度 |

首版人工决定入口只实现 UI；CLI 命令目录为完整目标接口，不要求每个子命令首阶段同时暴露。App 未运行时明确返回连接错误，不私自离线读 engine 文件；对用户显式提供计划文件的纯 validate 可以离线实现。

### 计划提交示例

协调者先登记一个 review，读到结果后再追加 fix 和下一次 review。示例中的 `reviewer` 在 create 时已绑定；凭证由 envelope 携带，不出现在计划内容中。

```json
{
  "commandID": "cmd-17",
  "baseRevision": 0,
  "controlEpoch": 1,
  "addSteps": [
    {
      "id": "review-1",
      "kind": "agent",
      "role": "reviewer",
      "instruction": "Review the assigned revision against the acceptance criteria.",
      "inputs": {
        "change": {"artifactID": "change-A"}
      },
      "after": [],
      "output": {
        "format": "object",
        "required": ["verdict", "reviewedDigest", "summary"],
        "verdicts": ["clean", "issues"]
      },
      "acceptance": "contract"
    }
  ]
}
```

CLI 可从 stdin 读取该 JSON。计划输入不插入 shell 命令片段。完整 wire schema、命令分组与 flags 在实现阶段通过共享契约文件生成并测试，本文不复制全部 Swift 声明。

### 幂等、取消等待与错误

- 变更命令带稳定 commandID，先按调用者作用域和 payload digest 查询 receipt，再检查预期 revision，避免已成功命令因重试被误判冲突。同 ID 不同 payload 返回冲突。
- token 等敏感响应字段只在当前进程内重试缓存；重启后返回 interrupted/重新授权提示，不从磁盘重建旧授权。
- 断开 `wait` 只释放 waiter，不取消 Run；先登记 waiter 再检查 cursor，防丢失事件。
- 典型错误码：`PLAN_CONFLICT`、`CONTROL_REVOKED`、`INVALID_DEPENDENCY`、`STEP_ALREADY_STARTED`、`ROLE_BUSY`、`INPUT_CHANGED`、`STALE_ATTEMPT`、`DELIVERY_CONFLICT`、`DELIVERY_INVALID`、`SELF_WAIT_CONFLICT`、`BUDGET_EXCEEDED`、`STORAGE_UNAVAILABLE`、`RUN_INTERRUPTED`。
- stdout 只输出结果；诊断去 stderr。非成功结果包含可操作原因，不要求 Agent从错误文本猜状态。
- 请求正文默认最多 1 MiB UTF-8 bytes，内容 read page 最多 256 KiB；最终编码 envelope 仍检查低于现有 16 MiB framing 上限。超限返回明确错误，首版不做隐式路径绕行或静默截断交付。

## 存储、恢复与产物

### 单写者存储

沿用版本化 JSON 和 AtomicFileStore，不新增数据库作为首版前提。根目录由 CodansEnvironment/BuildChannel 派生，Debug 与 Release 分开，不在 Feature 中硬编码路径。

```text
<channel-data-root>/workflows/
  items/<work-item-id>.json
  runs/<run-id>/
    run.json
    artifacts/<artifact-id>/content
    artifacts/<artifact-id>/metadata.json
  index.json
```

`run.json` 是单个 Run 的权威 snapshot，包含当前状态、plan revisions、attempts、决策、命令 receipts、待执行 intents 和紧凑控制事件。一次接受交付相关的元数据在同一 snapshot 中原子替换，不声称多个 JSON 事务提交。原始正文和日志是不可变 artifacts；先写完整 artifacts，再提交引用它们的 snapshot。

Index、列表统计和 WorkItem 上的 Run 摘要是可重建投影，写失败不改变已经提交的 Run 事实。WorkItem 的目标和业务验收由独立 service 管理；run finish 与 item accept 是两个明确操作。

控制事件首版存于 snapshot，保持单文件提交边界。高频 terminal output 不进入 snapshot，重复进度进行合并/限流。建议单 Run 上限 4096 条控制事件、8 MiB metadata、256 MiB artifacts；接近上限提前进入 attention，预留用于取消与结束的记录空间。不丢弃既有事件来假装继续正常执行。后续若实测写放大明显，再设计分段事务日志或数据库迁移。

Artifact ID 是 Engine 分配的逻辑身份，CLI 通过 read/export 获取内容。运行材料不写入项目目录；Handoff 的显式导出 packet 可以复用既有工作区材料语义，但接受记录引用本次不可变副本，而非 shared current 文件。

### 持久化保证与限制

- 执行 intent 持久化在外部动作之前；交付接受记录持久化在 ACK 和下游派发之前。
- Artifact 写入成功但 snapshot 未提交时可能遗留孤立文件，允许后续清理；不能存在已接受却引用半写文件的结果。
- 外部动作已发生而 receipt 尚未保存时，状态是 unknown；存储不能消除这个窗口。
- AtomicFileStore 的现有保证面向单文件原子替换。本文不承诺跨文件事务、断电持久性或外部效果 exactly-once；若需要断电保证，先扩展共享文件/目录同步 primitive。
- Engine Store 写入失败触发暂停和错误 UI，不仅写 warning。不得使用 Catalog 的 debounce 保存此类状态。
- 未知 schema version、损坏 snapshot 或不安全路径保留原文件并显示 unavailable，不以默认空 Run 继续执行。

### 重启

启动读取 snapshot 后，所有非终态 Run 标为 interrupted，撤销旧控制/worker 凭证，不重新执行 pending intents。活动外部任务显示 unknown 或仍被观察到的状态；终端/zmx 存活不等于流程恢复。

首版提供“查看记录、定位原 pane、导出材料、从材料创建新 Run”。没有原 Run 自动 resume。必须先处理旧 writer，再授权替代任务。新 Run 复制所需材料到自身 ArtifactStore，校验摘要并保留 provenance，不复制旧执行成功状态；跨 Run 共享 artifact 引用留到阶段 3。

用户可通过“结束中断记录”逐项记录外部执行处置，然后将旧 Run 转为 cancelled 或 incomplete。已确认停止的 writer 或用户明确确认释放的 reservation 才可释放；后者保留 human_decision 来源，不伪装成程序已验证停止。处置不完整则旧 reservation 继续存在。此操作不重放 intent，不发 terminal input；成功后旧 Run 才解除未处理 interrupted 的清理保护。

### 保留与隐私

首版不自动删除历史。提供磁盘用量、手工导出和清理；清理前显示影响，拒绝删除 active/interrupted 未处理运行及被 WorkItem 验收记录引用的产物。阶段 1 的新 Run 持有复制材料，不依赖旧 Run 存活；阶段 3 增加跨 Run 共享引用后，清理还必须检查引用关系。终态 Run 删除需显式确认，删除失败不影响其他 Run。

Metadata 与 artifacts 为用户私有数据；目录权限、路径 containment、符号链接处理必须在 ArtifactStore 边界验证。输出可能含敏感内容，完整产物不自动发送遥测。工程日志继续使用项目既有 os.Logger；运行历史是产品数据，不另建调度依赖的日志通道。

## 可观测性与交互

### 事实来源

| provenance | 可表达的事实 | 不能推出的结论 |
|---|---|---|
| `engine` | 已接纳计划、已尝试投递、已收交付、已保存、已撤销 | Agent 理解了提示或代码正确 |
| `agent_report` | Agent 自述进度、阻塞、结论 | 程序验证已执行 |
| `program_check` | 命令退出状态、测试报告、版本检查、结构校验 | 超出实际检查范围的语义正确性 |
| `human_decision` | 用户对特定成果作出的选择 | 对后来修改版本仍然有效 |
| `terminal_observation` | 活动、idle、进程消失、最后采样时间 | 本次委派已经完成 |

UI 不把这些来源合成未经证实的绿色成功。例如“Agent 报告测试通过；尚无程序验证记录”是合法展示。

### 三层界面

1. **状态条**：当前 Worktree 的 Run 名称、实际阶段、等待原因、最后可靠活动、attention 数量。没有步骤总数时不显示伪造的完成百分比。
2. **Run 总览**：默认时间线；显示 committed future steps 与 actual execution 的区别。每行包含角色、状态、尝试数、耗时和结果；并行阶段以后用分支分组，而非默认全屏 DAG。
3. **委派详情**：指令、输入版本、事件、进度报告、交付、程序证据、人工决定、完整输出入口和允许的处理动作。

点击角色定位现有 pane；不存在时保留历史身份并显示不可定位。选中的 Run 完成后仍保持详情与滚动位置，不自动跳到另一个 Run。

未来步骤来自 committed plan，Skill 未提交的意图不被 UI 猜测。Agent 可上报 `nextIntent` 文本作为“拟议下一步”，但它不成为 queued 节点。

人工操作从 Runtime 提供的 allowedActions 渲染，点击时再次校验 revision/decision/attempt。UI 不能绕过 Engine 写状态，也不能用旧按钮接受新材料。

### 事件与指标

控制事件包括 plan committed、attempt created、submit attempted/confirmed/unknown、claimed、delivery received/accepted/rejected、decision requested/resolved、role lost、control transferred、paused、budget reached、finished。

每个事件带 run sequence、关联身份、来源、发生时间、记录时间及原因。UI 断连后从 cursor 补取；过旧 cursor 返回完整 snapshot 与新 cursor，不静默遗漏。

默认计算排队时长、投递到接收/交付时长、人工等待时间、尝试数和被拒绝的重复/过期提交。只有 adapter 提供可靠数据时才显示 token/cost；缺失显示 unavailable，不按终端文字估算。

通知只针对需要用户行动、明确完成、控制者失联等有意义变化。工作中的每个进度事件不发铃铛；用户正在查看相关 Run 时沿用现有通知抑制策略。

## Workflow Skill 契约

Skill 内容包含触发条件、目标澄清方式、角色建议、计划片段、结果解释规则、异常策略和结束条件。Skill 可以附脚本，但脚本也通过同一 CLI 协议操作，不直接修改 RunStore。

标准流程：

1. 读取目标、约束及当前工作区事实。
2. 创建或关联 WorkItem/Run，申请协调权，冻结预算。
3. 提交足够执行的第一阶段，start 或 claim-current。
4. 使用 wait/read 读取结构化事件与成果，不用无限轮询终端文本。
5. 根据结果提交下一 revision；上下文压缩或更换协调 Agent 后先读 status、plan 和 artifacts。
6. 无法判断或达到预算时创建人工决定；不以重命名步骤绕过限制。
7. seal、finish，返回成果与未解决项；WorkItem 验收由用户处理。

Skill 来源可记录名称、版本或内容摘要作为 provenance。Engine 不需要读懂 Skill，也不能因为名称匹配而自动授予额外权限。

## 端到端示例

产品构建以 [Workflow 用例与构建顺序](workflow-use-cases.md) 的 Handoff、Advisor、Committee 为主验收集。下列实现/测试闭环、开放调研及协调者恢复保留为扩展场景，不优先于三个主用例。基础能力参考 Skill 不作为独立 Workflow。

### A：交接后继续开发

WorkItem 是“修复登录过期问题”。本次 Run 只负责交接：

```text
author:briefing -> action:save-packet -> receiver:ack
```

author 通过 claim-current 获得整理任务，提交目标、约束、已完成内容、证据和下一步。save-packet 复用 Handoff 保存逻辑，产出本次不可变 packet 与 digest。receiver 在新 pane 启动，读取该 packet，交付相同 digest、建议的 next action 和待澄清问题。

接收确认表示 Agent 对本次 packet 作出回应，不证明全部理解或完成开发。存在关键疑问时协调者请求用户处理；确认接收后 seal/finish succeeded，WorkItem 保持 active，接收者后续工作可以使用新的 Run。

receiver 启动失败只重试接收阶段，材料不重写；共享 current 文件更新不会改变已交付 packet。没有确认时 UI 显示“已启动，等待接收确认”。

### B：实现、测试、审查与修复

WorkItem 是“新增段落收藏”。Skill 首先提交 author 实现步骤。交付后由 action 捕获代码版本，再提交测试阶段；测试通过后提交 review。

```text
implement -> capture-revision -> test -> review-1
                                             |
                              Skill reads verdict
                          clean /                  \ issues
                 human decision              fix-1 -> test-2 -> review-2
```

测试与 review 必须引用同一受检版本。没有 commit 时，版本摘要必须覆盖受检 tracked/untracked 输入，不能只记录 HEAD。验证期间不调度同 worktree writer，验证前后重新检查版本；外部变动使当前证据失效。

review 返回 issues 是 accepted 的审查结果，Skill 决定追加修复。测试断言失败是结构合法的程序结果，可交给 Skill 决定修复；测试进程无法启动、产物缺失、状态未知是执行失败，进入 attention，不能伪装成正常 findings。

Skill 建议最多三轮，Engine 始终执行总时间/节点/attempt 预算。达到策略上限仍有问题时 finish incomplete 并列出未解决项。clean 后可提交 Human 节点检查当前成果；Run 成功后，用户独立接受工作项目标。

### C：并行调研后追加缺口调查

这是后续并行阶段，不属于首个交接闭环。

```text
research-runtime ---+
research-risk ------+--> coordinator reads results
research-product ---+              |
                                   v
                         investigate-gap -> synthesize
```

首个 revision 声明三个无依赖任务，分别绑定 pane，遵守并发槽。Engine 为每个分支维护 attempt/deadline/产物命名空间。协调者读取结果后追加缺口调查与汇总，新阶段引用已接受产物，不回写历史依赖。

首版并行策略为 join-all。一个分支失败时保留其他结果，并暂停新阶段；协调者请求重试或用户允许部分结果结束。选择部分结果必须显式标记缺失维度，不将“没有报告”解释为“没有风险”。只读提示是约定；强制隔离必须由 executor 实现，不能用 Profile 名称代替权限控制。

### D：协调 Agent 消失与用户接管

reviewer 正在工作，协调 Agent 的 pane 退出。Engine 保留 reviewer 的有效 attempt，暂停新的派发，状态条显示“协调者不可用，审查仍在进行”。用户可先等交付，再把协调权交给另一 pane。

新协调者获得新的 controlEpoch，通过 status/read 重建计划与证据。旧协调者即使恢复并发送 plan.apply，也会收到 CONTROL_REVOKED。若应用本身重启，则进入 interrupted，不走上述同进程控制权转移路径。

## 组件边界与实现阶段

| 模块 | 拟议职责 |
|---|---|
| `CodansCore/Workflows` | 纯模型、状态转移、依赖验证、输出契约；无 Runtime/SwiftUI 依赖 |
| `CodansIPC/Workflows` | wire types、错误、权限作用域、分页与 envelope 预算 |
| `codans/Workflows` | Runtime actor、命令通道、admission、Store、队列、watchdog、adapter 编排 |
| `App/Clients/WorkflowClient` | TCA 到应用服务的 Sendable command/query/event 桥 |
| `App/Features/Workflows` | 启动、总览、详情、人工决定；只保存视图状态与运行投影 |
| `App/Features/Socket/WorkflowHandlers` | IPC 边界解析与服务调用，不持有独立 Run 状态 |
| `Runtime` | pane/surface 生命周期及主线程投递；只向 Engine 输出值类型事件 |
| `Process` | 共享有界程序执行能力；Feature 不直接创建 Process |
| `skills/` | Workflow Skill 指引与示例，版本与 CLI 契约一起校验 |

首版这些是文件夹和接口边界，不立即新增多个 Tuist targets。Pure machine 可放 Core，I/O 与 storage ownership 放应用层；不将 PaneSurface、TCA Store 或 AgentStateStore 引用传给非主线程 runner。

### 阶段 1：串行执行、交接与顾问

实现轻量 WorkItem/Run、动态 plan apply、单协调者、agent/human/内置 save-packet 节点、claim-current、显式交付、存储屏障、取消、interrupted 收尾、状态条/时间线/详情及交接 Skill。人工至少能撤销协调权、保存 worker 交付、取消/收尾，不要求把协调权转给新 Agent。总并发 1，不做任意脚本或通用 DAG 并行。

Advisor 在阶段 1 复用交接已提供的委派和交付能力，增加建议报告、协调者处置与有限追问合同，不转移任务责任。详细场景验收见 AC-01 至 AC-04。

### 阶段 2：有界会诊、验证与修复

实现受控测试 action、代码版本 artifact、证据失效规则、失败替代链、有界动态修复示例和人工修订未开始计划。新增 Process 能力必须在共享层落实输出/取消契约。

优先用两成员串行 Committee 验证相同输入、独立分析、一轮互评与保留异议的汇总；总并发仍为 1。场景轮次由内置计划策略与 Engine admission 校验，不能只依赖 Skill 的文字约定。通用实现/测试闭环作为后续扩展，不阻塞三个主用例。

### 阶段 3：结构化并行与复用

实现独立分支状态、join-all、并发槽、只读/单写者调度策略、跨 Run artifact 引用和更换协调者。基于实际重复流程再决定是否提炼模板格式；不因并行示例顺带引入跨 worktree 集成或自动恢复。

## 验收标准

| ID | 阶段 | 场景 | 必须满足的结果 |
|---|---|---|---|
| WF-01 | 1 | 两个入口以相同 commandID 创建 Run | 只有一个 Run；payload 不同则冲突 |
| WF-02 | 1 | 草稿未提交、created 未 start、baseRevision 过期、循环依赖 | 不执行任何新任务，返回明确诊断 |
| WF-03 | 1 | 修改已开始步骤的依赖或输入 | 拒绝；历史因果不变 |
| WF-04 | 1 | 新 plan revision 提交时旧 worker 交付 | 若 attempt 仍有效则正常接受 |
| WF-05 | 1 | 当前 pane 调用 start/claim | 返回 assignment，不重复注入、不等待自己 idle |
| WF-06 | 1 | paste/Enter 间取消、surface 重建、同种 Agent 可观察替换 | 旧 Enter 不进入已知新身份；不确定投递明确标记 |
| WF-07 | 1 | 重试后旧 token、错误 pane、重复 delivery | 旧/错拒绝；同 ID 同内容幂等；不同内容冲突 |
| WF-08 | 1 | Agent idle、退出或声称测试通过 | 不自动接受任务或生成程序验证证据 |
| WF-09 | 1 | ENOSPC 或接受记录保存失败 | 无成功 ACK、无下游派发、UI 显示存储异常 |
| WF-10 | 1 | ACK 后立即终止应用 | 重启可读已提交结果；不自动重放外部动作 |
| WF-11 | 1 | intent 保存后/投递后/产物保存后崩溃 | 保留可判定事实；中断收尾后可关闭旧记录；未知 writer 不被新 Run 绕过 |
| WF-12 | 1 / 3 | 协调者退出、用户接管、旧命令迟到 | 阶段 1 撤销旧 epoch、保留 worker 交付；阶段 3 新协调 Agent 获授权继续 |
| WF-13 | 1 | open plan 暂时无步骤 | waiting_for_plan，不自动 succeeded；在途等待不误归类 |
| WF-14 | 1 / 2 | seal/finish 时存在活动任务或未解决必需失败 | seal 可关闭计划；finish 拒绝成功结束；阶段 2 修复授权可解除对应调度阻塞 |
| WF-15 | 1 | cancel 与交付竞争 | 按串行命令顺序决定接受/拒绝；取消后不解锁下游；存储失败仍停止派发 |
| WF-16 | 2 | review 后代码被修改，或 retry 面对不同输入版本 | 旧证据不用于新版本验收；retry 返回 INPUT_CHANGED |
| WF-17 | 1 | UI 重连、事件 cursor 过旧、产物缺失 | snapshot/cursor 可重建；缺失明确显示，不伪造空结果 |
| WF-18 | 3 | 并行一个分支失败、另一个完成 | 独立保存；join 不提前成功；部分结果需明确处理 |
| WF-19 | 1 | Run succeeded 或 Handoff 接收确认 | 不隐式完成 WorkItem |
| WF-20 | 1 | 重试/追加计划试图绕过预算 | 总预算不重置，触顶停止新派发 |

Pure machine、计划校验和 Store 使用确定性单测；clock 使用注入时钟，测试不靠真实 sleep。Terminal adapter 覆盖真实 paste/Enter、身份变化与失联窗口。CLI 做 framing、幂等、长轮询取消和 App 重启集成测试。真实 Agent 验收至少覆盖一组同 pane claim 与一组双 Agent Handoff；fake adapter 测试不能标记为真实 Agent E2E。

## 备选方案与技术决策

| 方案/决策 | 结论与理由 |
|---|---|
| 仅 Skill + 现有终端 CLI | 能编排动作，但执行身份、交付、等待与历史仍会在各 Skill 重复实现，无法稳定提供统一 UI |
| 外部脚本持有执行状态 | 适合试验；若成为正式产品，需要解决脚本/App 双重状态与取消归属，首版由 App 单写 |
| 静态完整 DSL 引擎 | 维护面偏大；内置场景构造器与动态 plan transactions 共用协议，通用模板语言留待后续 |
| 根据 terminal finished 推进 | 拒绝；展示状态无法证明业务交付，背景工作尤其容易误判 |
| 首版自动恢复 | 拒绝；不能从 JSON 与存活 pane 推断外部副作用是否完成，需要专门的 reconciliation 与幂等协议 |
| SQLite 作为首版存储 | 暂缓；沿用仓库原子 JSON 契约，在有界 Run 内用单 snapshot 提交，实测后再评估写放大与查询需求 |
| 每个角色独立 Workflow 引擎 | 拒绝；角色是 executor，Run 状态必须单一所有者，避免相互推进 |
| 全量采集终端作为历史 | 暂缓；结构化事件和显式产物优先，原始终端作为诊断入口，避免无界数据和隐私成本 |

## 风险与后续设计门槛

- **Skill 遗漏登记**：仅经 Workflow CLI 的协作具有完整追踪；绕过操作显示为手工介入，不能推断全貌。
- **Agent 输入状态不确定**：增加 submission receipt 与 generation fence；unknown 不自动重发。
- **协调 Agent 丢上下文**：状态、计划、输入与交付均可通过 CLI 重读；Engine 不依赖 Agent 记住 ID 以外的隐含真相。
- **人工/外部修改工作区**：Engine 的 writer reservation 只约束自身；依赖代码摘要和版本失效机制。
- **数据增长与写放大**：限制控制事件/产物，合并非关键进度；并行与长期运行前测量，再决定是否迁移存储。
- **能力边界扩张**：任意脚本需要单独设计代码来源审批、固定副本、JSON I/O、资源限额与进程组停止；远程运行需要身份与通道协议；自动恢复需要 effect reconciliation。这些不因已有 Workflow 名称而自动进入范围。

## 参考

- [Architecture](../architecture.md)
- [Agent Profiles 与 Handoff](agent-handoff.md)
- [CLI](cli.md)
- [Environment](environment.md)
- [AgentState View](active-agents-view.md)
- [Notifications](notifications.md)

本设计参考本地 Prowl `74d9e3a` 的角色绑定、显式交付、纯状态机和有序副作用边界；Prowl 的完整 DSL 和产品行为不是本文的兼容目标。
