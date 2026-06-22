# 产品规格：AgentState View

**状态：** 已上线
**作者：** Gump（与 Claude）
**Related:** [docs/design-docs/active-agents-view.md](../design-docs/active-agents-view.md)

## 摘要

codans 用户通常同时驱动多个 CLI 编程 Agent，每个 Agent 占用一个 Pane，散布在不同 Worktree 和 Tab 下。用户随时关心的一句话其实只有一个：「**哪个 Agent 现在在干什么？**」——可在 AgentState 之前这个问题在 UI 上无解，用户必须在 Tab 之间扫一圈，或在通知收件箱里翻历史。

AgentState 是侧栏底部的一处常驻面板（`AgentStateSidebarPanel`，标题 "Agents View"），列出当前被识别为运行已知 Agent 的每个 Pane，含品牌 logo、所属 Project / Worktree 路径、四态运行态（`working` / `blocked` / `finished` / `idle`），点击行即把所在 Project → Worktree → Tab 级联激活并把 Pane 拉到 first responder。它不是通知系统——通知讲的是「刚刚发生了什么」，AgentState 讲的是「现在正在发生什么」。

识别覆盖 `AgentKind` 注册表中的**全部 Agent**：v1 shipped 11 类——Claude Code、Codex、pi、opencode、Gemini、Cursor Agent、Cline、GitHub Copilot、Kimi、Droid、Amp。新增一类是一次代码改动（扩 `AgentKind` + `AgentKindPatterns`），不是配置改动。

## Context

三类信号迫使 AgentState 立项：

1. **通知收件箱不解决「现在」问题。** 现有 Notifications 系统记录的是 transition（`taskFinished`、`waitingForInput`），收件箱里成堆的历史事件回答不了「我此刻该去看哪个 pane」。
2. **侧边栏 busy glyph 只覆盖部分情况。** OSC 9;4 busy 指示器只在显式发 progress report 的 Agent 上亮起；且就算亮了，用户也得自己关联到具体哪个 Agent 在跑什么。
3. **跨 Worktree 切换成本高。** 用户开 3–8 个 Worktree 是常态；当前要确认某个 Agent 在 worktree A 上的状态，需要先切到 worktree A 才能看到那个 Pane 的内部。AgentState 把跨 Worktree 的 Agent 状态合并到侧栏一处。

设计与实现细节已在 design doc 中固化；本 spec 仅负责「产品意图 + AC」两件事，作为下游 user-tests 与 PR 描述的引用源。

## User Stories

- 作为一名同时开着多个 Agent 的开发者（persona: `dev_running_long_task`），我希望侧栏底部面板一句话告诉我「**现在最该关注哪一个 Agent**」，这样我不用 Tab 之间扫一圈。
- 作为一名 Agent 用户，当任意一个 Agent 在执行 tool call 时，我希望对应行的状态图标可视化地动一下（细微 breathing），表示「有东西在跑」——这样我能从余光里捕获活动信号。
- 作为一名 Agent 用户，打开面板时我希望看到一个列表，按重要性排序（被阻塞/等输入 > 刚完成 > 在跑 > 闲置）展示所有 Agent，每条带 logo、`<Project> / <Worktree>` 路径和状态图标。
- 作为一名 Agent 用户，点击列表中的一行，应该一步跳到那个 Pane——切换 Project、切换 Worktree、切 Tab、focus pane 全部一次完成。
- 作为一名 Agent 用户，当某个 Agent 弹出 permission prompt 停下等我同意，我希望 AgentState 立刻把那一行标成 `blocked`（琥珀），即使同一时刻另一 Agent 处于 `working`，它仍排在列表更前。
- 作为一名重启了 codans 的用户，我希望已识别过的 Agent Pane 依然显示对应 logo，不用每次重启都重新识别一遍——也就是说「这个 Pane 是 Claude Code」这件事是持久的，「它现在在等输入」这件事是新派生的。
- 作为一名 Agent 用户，我希望关掉某个 Agent Pane 后，对应那一行立刻从面板消失。
- 作为一名对**通知**做了 mute 的 Pane 的用户，我仍然希望该 Pane 在 AgentState 视图里显示——mute 是「别打扰我」，AgentState 是「我主动来看」，两件事是独立的。
- 作为一名启用了 macOS "Reduce Motion" 的用户，我希望 `working` / `blocked` 图标的 breathing 动效自动停掉。

## Requirements

### Must Have

#### 侧栏面板

- [ ] **AA-B1.** 主窗口侧栏底部挂一处 AgentState 面板；面板可由用户折叠/展开，由 footer toggle 控制，展开状态与高度持久化（`@AppStorage`）。
- [ ] **AA-B2.** 面板顶部标题为 "Agents View"；当列表多于 4 条时附带 `(N)` 计数 chip。
- [ ] **AA-B3.** 面板列出**所有**被识别为 Agent 的 Pane（包括状态为 `idle` 的）；没有任何被识别 Agent 时显示空态占位（"Run an agent and it'll show up here."）。
- [ ] **AA-B4.** 列表行排序：先按状态优先级桶分组，桶序为 `blocked > finished > working > idle`（把需要分诊的「刚停下等你」和「刚完成」顶到最上）；同桶内按「最近一次状态变化时间」降序。
- [ ] **AA-B5.** 任意行处于 `working` 或 `blocked` 时，其状态图标做轻微 breathing 动效；`finished` / `idle` 图标静止。
- [ ] **AA-B6.** 系统启用 "Reduce Motion" 时，breathing 必须完全停止（图标静态满不透明渲染）。
- [ ] **AA-B7.** 面板提供 `normal`（两行身份列）/ `compact`（单行）两种行密度，以及 auto-sort 开关，均由 `Settings → General → Agents View` 控制。

#### 行内容

- [ ] **AA-P1.** 每一行展示：左侧 Agent logo（20pt，找不到资源时回落到通用 SF Symbol），中部 `<WorktreeName>`（主）/ `<ProjectName>`（次，按 project 配色着色），右侧状态图标 + 短状态文案（`working` / `blocked` / `finished` / `idle`）。
- [ ] **AA-P2.** 四种状态各有可视化区分的图标 + 颜色（`blocked`=琥珀 pause、`working`=九宫格活动动效、`finished`=绿勾、`idle`=灰色虚线圈），并通过 a11y label 朗读为对应文字。
- [ ] **AA-P3.** 当前主窗口聚焦的 Pane 对应的行有选中态高亮（中性灰 + logo 加深），使用户能把「正在看的 pane」和列表行对上。
- [ ] **AA-P4.** 面板在点击某行后**保持打开**，便于用户在 Agent 间连续 fan-jump。
- [ ] **AA-P5.** 解析不到来源（Pane 已离开 catalog）的「ghost」行以 em-dash `—` 占位，并由 catalog-membership 兜底在下一次结构性变更时移除。

#### 点击聚焦

- [ ] **AA-C1.** 点击面板中任意一行，该 Pane 所属的 Project / Worktree / Tab 依次被激活，Pane 取得 first responder。
- [ ] **AA-C2.** 若被点击的 Pane 在该 Tab 内并非「最后聚焦的 Pane」，依然需要把它切为 first responder（与现有 `HierarchyClient.focusPane` 语义一致）。
- [ ] **AA-C3.** 点击行不应误关键盘焦点或干扰 Pane 内已有输入；聚焦后焦点落在 Pane 而不是面板。

#### Agent 识别与持久化

- [ ] **AA-I1.** v1 识别 `AgentKind` 注册表中的 11 类 Agent（Claude Code、Codex、pi、opencode、Gemini、Cursor Agent、Cline、GitHub Copilot、Kimi、Droid、Amp）；其他 Pane 不进入 AgentState。
- [ ] **AA-I2.** 识别成功后，Pane 的 Agent 类型在 catalog 中持久化（`Pane.agentKind`）；codans 重启后无需重新识别即可立即在面板中显示对应 logo。
- [ ] **AA-I3.** Pane 关闭（用户主动 close、子进程退出、崩溃）后，该 Pane 的 Agent 绑定自动清除，对应行从面板消失。
- [ ] **AA-I4.** 同一 Pane 内用户从一个 Agent 退到 shell 顶层 prompt 后再启动另一个 Agent，应当能被重新识别——重绑由前台进程组变化驱动，不依赖 OSC 133；一个仍在跑的 Agent 始终是其 Pane 的前台进程，故退出与重启会被自然观察到。
- [ ] **AA-I5.** 未被识别为已知 Agent 的 Pane 不进入 AgentState 视图——面板不展示任何 generic / fallback 行。
- [ ] **AA-I6.** 识别只看 Pane 的**前台进程组**（真实 `argv0` / 进程名 / 命令行 token），刻意忽略 terminal title、initial command 与 desktop-notification 文本。

#### 状态派生

- [ ] **AA-S1.** Agent Pane 启动后、渲染区未分类为活动且无阻塞提示时，状态为 `idle`。
- [ ] **AA-S2.** 当 Pane 的渲染区被 agent 专属启发式分类为「在执行」（spinner / "esc to interrupt" / "• Working (" 等，且已观察到用户输入）时，状态为 `working`。
- [ ] **AA-S3.** 当 Pane 从活动态退回 idle、**且用户当时没在看它**（未 focus）时，状态变为 `finished`，直到下列任一发生：用户在该 Pane 内按下任意键、或该 Pane 被 focus。
- [ ] **AA-S4.** 当 Pane 的渲染区被分类为「等待用户输入 / 被批准提示阻塞」时，状态变为 `blocked`，直到用户在该 Pane 内按下任意键、或该 Pane 被 focus（乐观清除）。
- [ ] **AA-S5.** 当多个条件同时成立时，最终（headline / 主导）状态遵循优先级 `blocked > working > finished > idle`。
- [ ] **AA-S6.** 状态派生**只**读渲染区视口文本与 idle / teardown 事件；desktop notification（OSC 9）、bell、`paneOutput` 刻意不参与运行态派生（它们是收件箱值当的事件，由通知检测器独立消费）。

#### 与通知系统独立

- [ ] **AA-N1.** 用户在 Pane 上启用了「Mute notifications」的，**仍然**出现在 AgentState 视图里——mute 只压制通知 surface，不影响 AgentState 的展示。
- [ ] **AA-N2.** AgentState 的 `finished` 态的清除条件**不**读取 `NotificationStore.readAt`——即使收件箱中对应的 `taskFinished` 通知未读，只要用户 focus 了该 Pane / 按了键，AgentState 即转为 `idle`。
- [ ] **AA-N3.** 关闭通知系统所有 surface（系统通知 + Dock badge + 收件箱）不影响 AgentState 的工作。

### Nice to Have

- [ ] **AA-NH1.** Pane 右键菜单提供 "Reset agent identity"，手动清空已识别值，让下一轮信号重新识别。
- [ ] **AA-NH2.** 面板中每条行可选展示 Agent 自报的 session ID（如 Claude Code 启动 banner 中的 UUID）。字段（`Pane.agentSessionID`）已声明并持久化，但当前 binder 恒写 nil——banner 解析留作 follow-up。

### Won't Have (v1)

- macOS 菜单栏 (`NSStatusItem`) 形态的常驻入口——v1 仅 app 内侧栏面板。
- `AgentKind` 注册表之外的工具识别（aider、ollama、本地 REPL 等）。
- 面板内对 Agent 的直接控制（中断、回复、再启动）——只读视图。
- 历史时间线 / 跨 session 统计——这是通知系统的领域。
- 跨多窗口聚合——v1 仅服务主窗口当前的 Catalog。
- 推送到 macOS Live Activities / Dynamic Island。

## Acceptance Criteria

> 以下 AC 仅捕获产品意图，作为下游在 `docs/user-tests/active-agents-view.md` 中编写可执行 case 的引用锚点。不嵌入实现细节。

- **AC1.** Given 主窗口当前无任何已识别 Agent Pane，when 用户展开 AgentState 面板，then 列表为空态占位（无 generic 行）。
- **AC2.** Given 一个 Pane 已被识别为 Claude Code 且其渲染区分类为执行中，when 用户查看面板，then 该行状态为 `working` 且其状态图标在动。
- **AC3.** Given 上述 Pane 的执行结束（渲染区退回 idle）且用户当时没看它，when 用户查看面板，then 该行在合理时间内（受 paneIdle 阈值约束）变为 `finished`。
- **AC4.** Given Pane 处于 `finished` 状态，when 用户聚焦到该 Pane（点击或键盘切到），then 该 Pane 的状态在 AgentState 中立即变为 `idle`。
- **AC5.** Given 某 Agent 在 Pane 上弹出 permission prompt 被阻塞，when 用户查看面板，then 该行状态为 `blocked`、图标为琥珀色——即使同一时刻另一 Agent 处于 `working`，`blocked` 行仍排在更前（桶序）且在 headline 语义上优先。
- **AC6.** Given 同时存在多个 Agent Pane（例如 Claude + Codex + 另一类），when 用户打开面板，then 列表行按状态优先级桶排序展示所有条目。
- **AC7.** Given 面板已展开，when 用户点击某行聚焦一个 Pane，then 面板保持打开（不折叠），便于继续 fan-jump。
- **AC8.** Given 面板展开且某行可见，when 用户点击该行，then 对应 Project / Worktree / Tab 在主窗口中依次激活、Pane 取得 first responder。
- **AC9.** Given 一个 Pane 的前台进程组解析为 `claude`，when 该 Pane 被识别并经过一次事件循环，then 它在 catalog 中被持久化为 `agentKind=claude-code`，且在下次 codans 启动后仍带此标记。
- **AC10.** Given 该 Pane 关闭（子进程退出），when AgentState 视图刷新，then 对应行从面板消失，且 catalog 中的 `agentKind` 被清除。
- **AC11.** Given 一个 Pane 的前台进程组不匹配任何已知 Agent 模式（如普通 shell、`make`、`pytest`），when 用户查看面板，then 该 Pane 不出现在列表中。
- **AC12.** Given 一个 Pane 已被通知系统 mute（label 含 `notifications:muted`），when 该 Pane 的 Agent 进入任意非 idle 状态，then 它**仍然**出现在面板中；与通知系统的抑制策略无关。
- **AC13.** Given 系统 "Reduce Motion" 已开启，when 任意 Agent 处于 `working` 或 `blocked`，then 其状态图标保持静止（无 breathing）。
- **AC14.** Given VoiceOver 已开启，when 焦点落在某一行，then 朗读 `<DisplayName>, <Worktree>, <Project>, <state>`（其中 state ∈ {`working`, `blocked`, `finished`, `idle`}）。
- **AC15.** Given 用户在同一 Pane 内某 Agent 退出回到 shell 顶层 prompt 后启动另一个 Agent，when 前台进程组变化被观察到，then 该 Pane 的 `agentKind` 切换为新 Agent，logo 与 displayName 同步更新（受 `releaseMissThreshold` 迟滞约束——连续若干次未命中后才释放旧绑定）。

## Design

技术实现已在 [docs/design-docs/active-agents-view.md](../design-docs/active-agents-view.md) 中固化（含三层组件、前台进程组识别、状态机派生表、与通知系统的解耦边界、6 个 alternatives 的拒绝理由）。

## Open Questions

设计与实现期间已解决（留作记录）：

- **识别信号：** 早期设计假定靠 terminal title / initialCommand / OSC 9 banner 等软信号识别；shipped 实现改为**只看前台进程组**（`ForegroundJob` 携带真实 pid / pgid / argv0 / commandLine），title 等一概忽略。AC9 / AC11 / AC15 据此可观察。
- **重绑触发：** 早期假定靠 OSC 133 prompt-return 重评（无 shell-integration 时可能永不触发）；shipped 实现由前台进程组变化驱动 + `releaseMissThreshold` 迟滞，不再依赖 OSC 133。
- **状态动词集：** 统一以代码枚举 `AgentRuntimeState` 为准（`idle` / `working` / `blocked` / `finished`），UI 文案与 VoiceOver 朗读同源；早期产品稿用的 `waitingForInput` / `loading` 已收敛为 `blocked` / `working`。
- **Agent logo 使用条款：** 若某家 brand mark 受限，相应行回落到通用 SF Symbol。
