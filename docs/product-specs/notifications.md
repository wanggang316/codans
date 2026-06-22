# 产品规格：Notifications

**状态：** 已上线（可见）
**作者：** Gump（与 Claude）

## 摘要

codans 让用户在许多 Worktree 间并行运行编码 agent 和长任务。用户经常在某个 Pane 后台跑着 build、测试或 agent 时离开它。通知的职责是**把用户的注意力拉回到那个确切需要他的 Pane**——且只拉回那一个。

本规格定义：哪些事件构成通知、如何提醒用户、未读状态在 UI 何处呈现，以及用户可控的策略（设置、静音、阈值、worktree 提升）。它刻意保持精简：无 stdout 扫描器、无规则编辑器、无 hook（理由见「技术决策」）。

## 背景

- 层级：`Catalog → Project → Worktree → Tab → Pane`。一个 Pane 是一个 Ghostty surface，多个 Pane 在一个 Tab 内分屏。
- 检测建立在运行时已发出的结构化事件之上（OSC 9、bell、OSC 133、子进程退出、idle、crash）；codans 在其上提供持久化、按层级上卷、策略闸与设置。

## 技术决策

**为何无 stdout 扫描器 / 规则编辑器 / hook 检测。** 这三类能力刻意排除在范围外：

- **stdout 正则扫描**会漂移并误命中（如 `"(y/n)"` 命中聊天记录），且发布一套正则会顺势招来规则编辑器；记录「请发 OSC 9」比永久维护正则更便宜。两者都不发的工具不被覆盖，这是记录在案的限制而非缺陷。
- **规则编辑器 / 模板 DSL**是上述正则路线的连带产物，一并排除。
- **基于 hook 的检测**待 c3-hooks 证明需求后再说；当前运行时的结构化事件已覆盖任何遵守 OSC 9/133 的工具，严格更广。

完整的设计层根因（检测/策略三层拆分）见 [设计文档](../design-docs/notifications.md) 的「技术决策」。

## 目标与非目标

**目标**

- 呈现两类事件：某 Pane 正**等待输入**，或某 Pane **完成长任务 / 意外退出**。
- 经四条通道提醒：应用内未读指示、应用内 inbox popover、macOS 横幅、Dock 徽标——每条都可独立控制。
- 把未读计数沿层级上卷到用户看不到的最高祖先。
- 跨重启存活。让用户调节噪音（命令完成阈值、逐 pane 静音）并更快分诊（提升被通知的 worktree）。

**非目标**

- stdout 正则扫描 / 用户可编辑的检测规则 / 模板 DSL。
- 基于 hook 的检测（待 c3-hooks 证明需求后再说）。
- 应用内 toast/内联横幅；hover-popover 入口。
- snooze / 重新标为未读；超出「需响应」vs「信息性」的严重级别。
- 跨窗口聚合；inbox 的 CLI 访问。
- 逐事件自定义音效；可配置的击键抑制窗口；自动降回。

## 用户故事

- 跑着 agent 时，它停下来问权限，我被提醒。
- 在另一个 Worktree 跑长 build，它结束时我被提醒。
- 应用在后台 → macOS 横幅；应用在前台但在别的 Pane → 安静的计数而非横幅（我已经在键盘前）。
- 应用关了一整夜 → 昨天的未读还在。
- 折叠的 Project 显示「里面有东西需要注意」，我钻进去。
- 点击通知精确聚焦到来源 Pane，跨 Worktree 也行。
- 嘈杂的 Pane → 它的右键菜单上一键「Mute notifications」。
- 快命令（< 10 秒）和我 Ctrl-C 取消的命令不产生横幅。
- 长列表底部的嘈杂 worktree 在首次未读时跳到顶部。

## 需求

### 检测

- **N1 — 等待输入。** 从运行时发出的结构化事件检测——OSC 9 桌面通知、终端 bell——**不**靠扫描 stdout。两者都不发的工具不被覆盖（记录在案的限制）。
- **N2 — 长任务结束。** 前台进程退出、pane 进入 idle（`≥ 30 秒`、近期有输出、未检测到提示符），或 shell-integration 的 `commandFinished`（OSC 133，受下方阈值约束）。
- **N3 — 非零退出并入 N2**；body/标题反映状态。
- **N4 — 逐 Pane 静音。** 默认监控所有 Pane；逐 Pane 静音（`notifications:muted` 标签）只抑制该 Pane 的 N1/N2。
- **N5 — 去重窗口。** 30 秒内同 `(Pane, kind)` 更新既有条目而非新增；未读计数不变。

### 通道（每条由 Settings 独立把关）

- **C1 — 未读指示。** 每个层级一个布尔 + 状态栏铃铛上的数值计数（见 Display）。
- **C2 — inbox popover。** 状态栏铃铛打开最新在前的 popover，含读/未读与来源 `(project, worktree, tab, pane)`。无侧栏路由。
- **C3 — macOS 横幅。** 仅当应用非最前 **或** 来源 Pane 非聚焦 Pane 时投递。受 `systemEnabled` + 授权把关。
- **C5 — Dock 徽标。** 镜像全局未读计数，0 时清除。受 `dockBadgeEnabled` 把关。

### Display — 按层级上卷

- **L1–L4。** 未读沿 `Pane → Tab → Worktree → Project` 上卷，**只在最深的仍隐藏的祖先处显示**：L1 Pane = 2–4 px 顶线（绿 = 完成，琥珀 = 等待；二者皆有则琥珀胜）；L2 Tab = 标题前的点；L3 Worktree = 铃铛字形替换行图标；L4 Project = 名字后的点。L2–L4 是 kind 无关的布尔。
- **L5 — 状态栏铃铛。** 唯一的 popover 入口；数值计数（过 100 显示 `99+`）；为 0 时隐藏。

### 读 / 导航 / 持久化

- **R1** 聚焦某 Pane 标记其未读为已读 · **R2** 点击某行标记该行 · **R3**「全部标为已读」· **R4** 无 snooze/重标未读。
- **G1** inbox 行点击精确聚焦来源 · **G2** 横幅点击激活 + 同样聚焦 · **G3** 死目标 → 回退到最深的仍存在祖先；行保留并可见地标记。
- **P1** 跨重启存活 · **P2** 上限 500（逐出最旧已读，再逐出最旧未读）· **P3** 启动时老化 > 7 天 · **P4** 死目标行保留至 P2/P3。

### 授权

- **PM1** 首次横幅时按需弹窗（非启动时）· **PM2** Settings 显示状态 + Request / 打开系统设置 的恢复路径。

### 设置 — 五个控件（v1.1）

- **S1 In-app**、**S2 System**、**S3 Sound**、**S4 Dock badge**——四个正交开关（in-app 与 system 独立，可实现「仅后台」）。System 关时 Sound 被禁用但持久值保留。**S5** 只读的静音摘要 + Reveal-rules.json-in-Finder。
- **P-alert。** 在被拒状态下开启 System 会弹信息性 alert，含「打开系统设置」深链；开关保持开启（捕获意图）。

### 命令完成阈值（v1.1）

- **CF1** `commandFinishedEnabled`（默认开）· **CF2** `commandFinishedThresholdSec`（默认 10，`[1,3600]`）抑制更短的命令 · **CF3** exit 130/143（用户取消）永远抑制 · **CF4** 事件前 1 秒（固定）pane 有击键则抑制 · **CF5** 非零退出给出一眼可辨的标题。

### Worktree 提升（v1.1）

- **WT1** `moveNotifiedWorktreeToTop`（默认开）：首次未读（`0 → N`）把 worktree 移到其 Project **未固定**列表的顶部，并持久化 · **WT2** 仅在 `0 → N` 边沿触发 · **WT3** 限于 Project 内，绝不跨 Project · **WT4** 关 → 不重排 · **WT5** 固定 worktree 永不自动提升；无自动降回。

### Inbox JSON 信封（v1.1）

- **J1** 写入时为 `{ version: 1, entries: [...] }` · **J2** 遗留裸数组透明读取，下次刷盘时改写 · **J3** 更高版本文件加载为空并一次性重命名为 `notifications.json.bak-<ISO>`（降级安全）。

## 验收标准

（行为断言；可运行形式见 `docs/user-tests/notifications-v1-1.md`。）

**检测** — D1 `read -p` 提示符 → 1 秒内 N1 · D2 `make build` 退出 → 带状态的 N2 · D3 输出后 idle 30 秒 → 恰好一条 N2 · D4 已静音 pane → 无 · D5 30 秒内第二次触发 → 不新增。
**通道** — C1 最前+聚焦 → 无横幅，仅指示 · C2 后台 → 横幅 · C3 最前但在别的 Pane → 横幅 · C4 Dock 徽标跟随计数，0 时清除。
**上卷** — L1 折叠 Project 显示点、无后代指示 · L2 Project 展开、worktree 持有 → 铃铛字形 · L3 活跃 worktree、非活跃 tab → tab 点 · L4 活跃 tab、未聚焦 pane → 彩色线 · L5 聚焦即清 · L6 `99+` 上限、各级无数字 · L7 一个 pane 上 N1+N2 → 琥珀。
**导航** — G1 全路径聚焦 · G2 横幅同样 · G3 已删 pane → 落到 worktree，行保留并标记。
**持久化** — P1 5 条未读跨重启存活 · P2 容量逐出最旧已读再未读、保持 500 · P3 8 天前条目在渲染前消失。
**授权** — PM1 首条横幅弹窗、应用内照常更新 · PM2 被拒显示「打开系统设置」· PM3 已忽略 → Request 再次弹窗。

**v1.1（`AC-V11-*`）** — **CP1–CP3** 每条通知流经单一闸读取实时设置；丢弃的不会在之后开启时重现。**S1–S8** 四开关生效（in-app 关 → 仍发横幅、无 inbox/Dock；system 关 → inbox/Dock 更新、无横幅；sound 关 → `content.sound == nil`；system 关时 Sound 行禁用；dock-badge 关保持清除；mute 摘要文案；Reveal 在文件不存在时创建）。**P1–P2** 被拒 + 开 system → alert + 深链。**M1–M4** 上下文菜单静音切换标签/勾选；被静音 pane 在闸前丢弃；既有行保留。**CF1–CF7** 开关/阈值/取消/击键/非零标题/UI 校验。**WT1–WT5** 在 0→N 边沿提升并持久化；不重触发；不降回；固定豁免；关 → 不重排。**J1–J3** 信封写入 / 遗留读取 / 前向版本隔离。

## 遗留问题（Open Questions）

设计期间已解决（留作记录）：提示符模式集 → 已无意义（无扫描器，只用结构化事件）；inbox 位置 → 状态栏铃铛，无侧栏路由；分屏可见时的聚焦 → 仅聚焦的 Pane 清未读；idle timer → 依赖运行时输入感知的 `paneIdle`；非零标题 → body 含数字退出码、标题保持紧凑；击键窗口 →「任何进入 pane 的键」；toggle 关时是否回滚提升 → 否（彼时的手动顺序即权威）。

## 参考

- 设计：[notifications.md](../design-docs/notifications.md)
- 层级模型：`apps/mac/CodansCore/{Catalog,Project,Worktree,Tab,Pane}.swift`
- inbox 存储原语：`apps/mac/CodansCore/Notifications/InboxStorage.swift`
