# Product Spec: ActiveAgents View

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-05-22
**Related:** [docs/design-docs/active-agents-view.md](../design-docs/active-agents-view.md), [docs/exec-plans/active-agents-view.md](../exec-plans/active-agents-view.md)

## Summary

touch-code 用户通常同时驱动多个 CLI 编程 Agent（Claude Code、Codex CLI、pi），每个 Agent 占用一个 Pane，散布在不同 Worktree 和 Tab 下。用户随时关心的一句话其实只有一个：「**哪个 Agent 现在在干什么？**」——可今天这个问题在 UI 上无解，用户必须 Tab 之间扫一圈，或在通知收件箱里翻历史。

ActiveAgents 是 `WorktreeHeader` 上的一处常驻状态条徽章 + 悬停浮窗。徽章用一句话概括所有 Agent 的当前总览（"Claude Code is waiting for input" / "3 agents working"）；hover 出 popover 列出每条 Agent，含品牌 logo、所属 Project / Worktree 路径、四态运行态（`waitingForInput` / `loading` / `finished` / `idle`），点击行即把所在 Project → Worktree → Tab 级联激活并把 Pane 拉到 first responder。它不是通知系统——通知讲的是"刚刚发生了什么"，ActiveAgents 讲的是"现在正在发生什么"。

## Context

三类信号迫使 ActiveAgents 立项：

1. **通知收件箱不解决"现在"问题。** 现有 Notifications 系统记录的是 transition（`taskFinished`、`waitingForInput`），收件箱里 17 条历史事件回答不了"我此刻该去看哪个 pane"。
2. **侧边栏 busy glyph 只覆盖部分情况。** OSC 9;4 busy 指示器只在 Claude Code 这类显式发 progress report 的 Agent 上亮起；且就算亮了，用户也得自己关联到具体哪个 Agent 在跑什么。
3. **跨 Worktree 切换成本高。** 用户开 3–8 个 Worktree 是常态；当前要确认 Codex 在 worktree A 上的状态，需要先切到 worktree A 才能看到那个 Pane 的内部。ActiveAgents 把跨 Worktree 的 Agent 状态合并到顶部一处。

设计与实施细节已在 design doc 和 exec plan 中固化；本 spec 仅负责"产品意图 + AC"两件事，作为下游 user-tests 与 PR 描述的引用源。

## User Stories

- 作为一名同时开着多个 Agent 的开发者（persona: `dev_running_long_task`），我希望主窗口顶部状态条一句话告诉我「**现在最该关注哪一个 Agent**」，这样我不用 Tab 之间扫一圈。
- 作为一名 Agent 用户，当任意一个 Agent 在执行 tool call 时，我希望状态栏徽章可视化地动一下（细微 pulse），表示"有东西在跑"——这样我能从余光里捕获活动信号。
- 作为一名 Agent 用户，hover 状态栏徽章时我希望弹出一个列表，按重要性排序（等输入 > 在跑 > 刚完成 > 闲置）展示所有 Agent，每条带 logo、`<Project> / <Worktree>` 路径、状态图标和相对时间。
- 作为一名 Agent 用户，点击列表中的一行，应该一步跳到那个 Pane——切换 Project、切换 Worktree、切 Tab、focus pane 全部一次完成。
- 作为一名 Agent 用户，当 Claude 弹出 permission prompt 等待我同意，我希望 ActiveAgents 立刻标红/标黄那一行（`waitingForInput` 态），状态栏的 headline 也优先反映这条等待，而不是被"在跑"的同类淹没。
- 作为一名重启了 touch-code 的用户，我希望已识别过的 Agent Pane 依然显示对应 logo，不用每次重启都重新识别一遍——也就是说"这个 Pane 是 Claude Code"这件事是持久的，"它现在在等输入"这件事是新派生的。
- 作为一名 Agent 用户，我希望关掉某个 Agent Pane 后，对应那一行立刻从 popover 消失；如果全部关掉，徽章自身也隐藏。
- 作为一名对**通知**做了 mute 的 Pane 的用户，我仍然希望该 Pane 在 ActiveAgents 视图里显示——mute 是「别打扰我」，ActiveAgents 是「我主动来看」，两件事是独立的。
- 作为一名启用了 macOS "Reduce Motion" 的用户，我希望徽章的 pulse 动效自动停掉，不再忽明忽暗。

## Requirements

### Must Have

#### 状态栏徽章

- [ ] **AA-B1.** 主窗口 `WorktreeHeader` 显示一处 ActiveAgents 徽章；当没有任何被识别的 Agent Pane 存活时徽章完全隐藏（不占位）。
- [ ] **AA-B2.** 当**仅一个** Agent Pane 存在时，徽章 headline 为 `<DisplayName> is <verb>`，其中 verb ∈ {`waiting for input`, `working`, `finished`, `idle`}。
- [ ] **AA-B3.** 当存在**多个 Agent 且全为同一状态**时，headline 为 `<count> agents <verb>`。
- [ ] **AA-B4.** 当存在**多个 Agent 且状态混合**时，headline 形如 `<n1> <verb1> · <n2> <verb2>`，按优先级 `waitingForInput > loading > finished > idle` 截取前两组。
- [ ] **AA-B5.** 任意 Agent 处于 `loading` 或 `waitingForInput` 时，徽章图标做轻微透明度 pulse 动效；其他状态徽章静止。
- [ ] **AA-B6.** 系统启用 "Reduce Motion" 时，pulse 必须完全停止。

#### Popover 列表

- [ ] **AA-P1.** 鼠标在徽章上**持续悬停 250 ms** 后弹出 popover；提前移走不弹。
- [ ] **AA-P2.** popover 弹出后，鼠标可以平滑移入 popover 区域而不让它关闭（hover bridge）；离开 popover 与徽章共同区域后 150 ms 内淡出关闭。
- [ ] **AA-P3.** popover 表头展示 `Active Agents (<count>)`，列表展示**所有**被识别为 Agent 的 Pane（包括状态为 `idle` 的），不因数量 0 隐藏（只有徽章本身隐藏时 popover 不会有触发器）。
- [ ] **AA-P4.** popover 行排序按状态优先级桶分组：先 `waitingForInput`，再 `finished`，再 `loading`，最后 `idle`；同桶内按"最近一次状态变化时间"降序。
- [ ] **AA-P5.** 每一行展示：左侧 Agent logo（16pt，找不到资源时回落到通用 SF Symbol 机器人图标），中部 `<ProjectName> / <WorktreeName>`（中段截断），右侧状态图标 + 状态文案 + 相对时间（"working · 12s"、"idle · 1h" 等）。
- [ ] **AA-P6.** 四种状态各有可视化区分的图标 + 颜色（waitingForInput=琥珀、loading=accent 旋转、finished=绿勾、idle=次级灰圈），并通过 a11y label 朗读为文字。

#### 点击聚焦

- [ ] **AA-C1.** 点击 popover 中任意一行，该 Pane 所属的 Project / Worktree / Tab 依次被激活，Pane 取得 first responder，popover 关闭。
- [ ] **AA-C2.** 若被点击的 Pane 在该 Tab 内并非"最后聚焦的 Pane"，依然需要把它切为 first responder（与现有 `HierarchyClient.focusPane` 语义一致）。
- [ ] **AA-C3.** 点击行不应误关键盘焦点或干扰 Pane 内已有输入；popover 关闭后焦点落在 Pane 而不是顶部徽章。

#### Agent 识别与持久化

- [ ] **AA-I1.** v1 识别 **Claude Code**、**OpenAI Codex CLI**、**Inflection pi** 三类 Agent；其他 Pane 不进入 ActiveAgents。
- [ ] **AA-I2.** 识别成功后，Pane 的 Agent 类型在 catalog 中持久化；touch-code 重启后无需重新识别即可立即在 popover 中显示对应 logo。
- [ ] **AA-I3.** Pane 关闭（用户主动 close、子进程退出、崩溃）后，该 Pane 的 Agent 绑定自动清除，对应行从 popover 消失。
- [ ] **AA-I4.** 同一 Pane 内用户从 Claude 退到 shell 顶层 prompt 后再启动 Codex，应当能被重新识别为 Codex（受 shell-integration 可用性约束——若 shell 不发 OSC 133 prompt-end，识别保持原始 sticky 值，不视作 bug）。
- [ ] **AA-I5.** 未被识别为已知 Agent 的 Pane 不进入 ActiveAgents 视图——徽章/popover 不展示任何 generic / fallback 行。

#### 状态派生

- [ ] **AA-S1.** Agent Pane 启动后无 OSC 9;4 busy 且无 waitingForInput 事件时，状态为 `idle`。
- [ ] **AA-S2.** 当 Pane 因 OSC 9;4 progress report 被标记为 busy（在 `HierarchyManager.runningPanes` 中），状态为 `loading`。
- [ ] **AA-S3.** 当 Pane 从 `loading` 退出（busy 标记被移除，或收到 paneIdle / paneExited / paneCrashed）时，状态变为 `finished`，直到下列任一发生：用户在该 Pane 内按下任意键、该 Pane 产生新 output、该 Pane 被 focus。
- [ ] **AA-S4.** 当 Pane 上发出被分类为 "等待用户输入" 的事件（OSC 9 desktop notification 或 bell，分类逻辑共享自现有 `DetectionTranslator.classify`），状态变为 `waitingForInput`，直到用户在该 Pane 内按下任意键、或该 Pane 被 focus。
- [ ] **AA-S5.** 当多个条件同时成立时，最终状态遵循优先级 `waitingForInput > loading > finished > idle`。

#### 与通知系统独立

- [ ] **AA-N1.** 用户在 Pane 上启用了"Mute notifications"的，**仍然**出现在 ActiveAgents 视图里——mute 只压制通知 surface，不影响 ActiveAgents 的展示。
- [ ] **AA-N2.** ActiveAgents 的 `finished` 态的清除条件**不**读取 `NotificationStore.readAt`——即使收件箱中对应的 `taskFinished` 通知未读，只要用户 focus 了该 Pane / 按了键 / 新 output 出现，ActiveAgents 即转为 `idle`。
- [ ] **AA-N3.** 关闭通知系统所有 surface（系统通知 + Dock badge + 收件箱）不影响 ActiveAgents 的工作。

### Nice to Have

- [ ] **AA-NH1.** Pane 右键菜单提供 "Reset agent identity"，手动清空已识别值，让下一轮信号重新识别（用于 OSC 133 不可用时的 sticky 解除）。
- [ ] **AA-NH2.** popover 中每条行末尾可选展示 Agent 自报的 session ID（如 Claude Code 启动 banner 中的 UUID），用户复制后可在 Agent 自己的日志中检索。

### Won't Have (v1)

- macOS 菜单栏 (`NSStatusItem`) 形态的常驻入口——v1 仅 in-app 形态。
- 任意 Agent 之外的工具识别（aider、ollama、cursor-cli、本地 REPL 等）。
- popover 内对 Agent 的直接控制（中断、回复、再启动）——只读视图。
- 历史时间线 / 跨 session 统计——这是通知系统的领域。
- 跨多窗口聚合——v1 仅服务主窗口当前的 Catalog。
- 推送到 macOS Live Activities / Dynamic Island。

## Acceptance Criteria

> 以下 AC 仅捕获产品意图，作为下游 `/hs-test-spec` 在 `docs/user-tests/active-agents-view.md` 中编写可执行 case 的引用锚点。不嵌入实现细节。

- **AC1.** Given 主窗口当前无任何已识别 Agent Pane，when 用户查看 `WorktreeHeader`，then ActiveAgents 徽章不可见。
- **AC2.** Given 一个 Pane 已被识别为 Claude Code 且其前台进程刚开始执行 tool call，when 用户查看徽章，then headline 形如 "Claude Code is working" 且徽章图标在 pulse。
- **AC3.** Given 上述 Pane 的 tool call 结束（busy 解除），when 用户在另一 Pane 中查看徽章，then headline 在合理时间内（受 paneIdle 阈值约束）变为 "Claude Code is finished"。
- **AC4.** Given Pane 处于 `finished` 状态，when 用户聚焦到该 Pane（点击或键盘切到），then 该 Pane 的状态在 ActiveAgents 中立即变为 `idle`，徽章 headline 同步更新。
- **AC5.** Given Claude Code 在 Pane 上弹出 permission prompt，when 用户查看徽章，then headline 形如 "Claude Code is waiting for input"，对应行图标为琥珀色铃铛——即使同一时刻另一 Agent 处于 working，headline 仍以 waiting 优先。
- **AC6.** Given 同时存在多个 Agent Pane（例如 Claude + Codex + pi），when 用户 hover 徽章 ≥ 250 ms，then popover 弹出，列表行按状态优先级排序展示所有三条。
- **AC7.** Given popover 已弹出，when 用户将鼠标从徽章平滑移到 popover 内部，then popover 不关闭；when 用户从 popover 移出 ≥ 150 ms，then popover 淡出。
- **AC8.** Given popover 弹出且光标悬停于一行尚未点击，when 用户点击该行，then 对应 Project / Worktree / Tab 在主窗口中依次激活、Pane 取得 first responder、popover 关闭。
- **AC9.** Given 一个 Pane 启动时执行命令 `claude`，when 该 Pane 被创建并经过一次事件循环，then 它在 catalog 中被持久化为 `agentKind=claude-code`，且在下次 touch-code 启动后仍带此标记。
- **AC10.** Given 该 Pane 关闭（子进程退出），when ActiveAgents 视图刷新，then 对应行从 popover 消失，且 catalog 中的 `agentKind` 被清除。
- **AC11.** Given 一个 Pane 不匹配任何已知 Agent 模式（如普通 shell、`make`、`pytest`），when 用户查看徽章/popover，then 该 Pane 既不出现在 popover 中，也不计入徽章 count。
- **AC12.** Given 一个 Pane 已被通知系统 mute（label 含 `notifications:muted`），when 该 Pane 的 Agent 进入任意非 idle 状态，then 它**仍然**出现在 popover 中并贡献于徽章 count；与通知系统的抑制策略无关。
- **AC13.** Given 系统 "Reduce Motion" 已开启，when 任意 Agent 处于 `loading` 或 `waitingForInput`，then 徽章图标保持静止（无 pulse）。
- **AC14.** Given VoiceOver 已开启，when 焦点落在徽章上，then 朗读完整 headline 句子加一句 hint "Open active agents popover"；when 焦点落在 popover 任一行，then 朗读 `<DisplayName>, <Project> <Worktree>, <state>, <relative time>`。
- **AC15.** Given 用户在同一 Pane 内 `claude` 退出回到 shell 顶层 prompt 后启动 `codex`，**且** shell-integration 正常发出 OSC 133 prompt-end，when ActiveAgents 视图刷新，then 该 Pane 的 `agentKind` 从 `claude-code` 切换为 `codex`，logo 与 displayName 同步更新。

## Design

技术实现已在 [docs/design-docs/active-agents-view.md](../design-docs/active-agents-view.md) 中固化（含三层组件、识别兜底链、状态机派生表、与通知系统的解耦边界、6 个 alternatives 的拒绝理由）。

执行拆分已在 [docs/exec-plans/active-agents-view.md](../exec-plans/active-agents-view.md) 中固化（M1 数据模型与识别 / M2 派生态机 / M3 UI，共 8 个 task）。

## Open Questions

- **OQ-1（design 已记 OQ-1）：** libghostty 当前版本是否实际向 touch-code 暴露 `paneInfoChanged(.promptEnd)`（OSC 133 D）？AC15 的可观察性取决于这一点；若不可用，AC15 在 user-tests 中标为受约束的 case（`pending shell-integration support`），不阻塞 v1 收尾。
- **OQ-2（design 已记 OQ-2）：** Claude / Codex / pi 的官方 brand mark 使用条款；若任何一家 glyph 受限，相应行回落到通用 SF Symbol 机器人图标。AC5/AC6 的 user-test case 文案需在 OQ-2 解决后选定截图基线。
