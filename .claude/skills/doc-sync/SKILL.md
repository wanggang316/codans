---
name: doc-sync
description: 每晚审阅当天提交的代码 diff，检测 docs/ 知识库的漂移（liveness 漂移、过程词、与代码矛盾），低风险事实更新直接落盘到分支、其余实质漂移产出报告并开 PR 交人审。仅当用户要求运行 doc-sync 或配置每日文档同步时触发，不要在常规对话中自动调用。
---

# doc-sync

夜间文档同步引擎：把 `docs/README.md` 的两条约定（**现状优先** + **liveness 状态字段**）机械化为可执行的每日检测，杜绝知识库随代码漂移。

## 1. 目的与边界

- `docs/` 是**精选的 Library，不是 logbook**——只承载持久的 invariants、边界、以及代码无法表达的*为什么*。实现进度与「我们建了什么」属于代码、git history 与 CHANGELOG。
- 本 skill 是「杜绝文档漂移」的**执行引擎**：当代码改动让某篇 Library 文档失真时，把它纠正回今日真相。
- **只看当天的 commit/diff**——用 `git log --since=...` 取出当日提交、用 `git diff` 取出改动内容。**不做全仓扫描**，不审阅未被当天改动触及的文档。
- 范围只限 `docs/` 知识库；不碰 `docs/generated/`（自动产物）与任何运行时状态。

## 2. 检测三类漂移

对每一篇被当天 diff 波及的文档，逐条跑以下三类检测。

### a. Liveness 漂移（核心）

对文档里引用的**每一个 feature / 符号 / 文件路径**，核验它是否仍**存在**且**可达**——不是被隐藏、未接线、或仅是 stub。判据：「**符号在 ≠ 功能活**」。一个 command-id 或空壳 stub 不构成 feature。

| 当天 diff 的事实 | 文档现状 | 建议动作 |
|---|---|---|
| feature/符号被移除 | 文档仍把它当现状描述 | **建议删档**（git history 保留；已移除的 feature 不该有文档） |
| feature 仍存在但被刻意隐藏/未接线 | 文档标为 `已上线（可见）` | 建议改标 **`已实现但隐藏`**，并在正文点明 |
| 仅有设计/command-id/stub，无可用实现 | 文档当作已上线 | 建议改标 **`已设计未实现`**，并在正文点明 |

状态字段取值（与 `docs/README.md` 一致）：`已上线（可见）` / `已实现但隐藏` / `已设计未实现`。

### b. 过程词

扫描描述性正文里的过程叙事词：`从前` / `曾经` / `取代了` / `降到 N 级` / `v1→v2` / `superseded` / `used to`。文档要写**现状**而非到达现状的路径。

- 若该转变的*理由*是 load-bearing（一条未来维护者不得撤销的约束）→ 建议把理由**下沉到 `## 技术决策 / Decisions`** 段落作为一条决策记录。
- 否则 → 建议**改写为现状陈述**，删去叙事。

### c. 与代码矛盾

当天 diff 修改了文档所述的**行为 / 契约 / 默认值 / 接口形状**——文档与代码直接矛盾。逐处定位文档中的失真句，给出代码侧的今日真相。

## 3. 自治度（apply-safe vs propose）

- **低风险的事实性更新**——重命名的符号、改了的默认值、删掉的字段、明显的死链——**直接在分支上落盘**。
- **其余一切实质改动**（删整篇文档、改 liveness 状态、重写行为描述、下沉过程词到技术决策）→ 产出 **drift 报告**并**开 PR** 交人审，不自行落盘。
- **绝不静默重写知识库**：每一处自动落盘都必须落在分支/PR 的可见 diff 里。
- **无 drift 当天零提交**——不为了「跑过了」而制造空提交。

## 4. 护栏

- 只在**分支 / PR** 上动手，**绝不推 main**，绝不直接改已发布的主分支内容。
- 绝不**重建过程文档**（exec-plans 之类）或写入**运行时状态**（`.harness-runtime/`、`docs/generated/`）。
- 严格尊重 `docs/README.md` 的两条约定：**现状优先**（present-tense、无叙事）+ **每篇文档声明 liveness 状态字段**。
- 不扩大范围：只处理当天 diff 波及的文档，不顺手重构无关文档。

## 5. 触发 / 调度

本地 **nightly cron / launchd → headless `claude -p`**（能完整访问本地代码与本地 MCP），**优先于云端 routine**——漂移检测需要读真实工作区与本地工具。

以下为**用户需手动安装的一次性配置**（skill 自身不安装调度器）。

crontab（每晚 02:30 跑一次本 skill）：

```cron
30 2 * * * cd /Users/wanggang/.codans/repos/codans && /usr/bin/env claude -p "Run the doc-sync skill: review today's commits, detect docs drift, apply safe facts on a branch and PR the rest." >> ~/.codans/logs/doc-sync.log 2>&1
```

launchd（`~/Library/LaunchAgents/dev.codans.doc-sync.plist`，加载后每晚 02:30 触发）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.codans.doc-sync</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>cd /Users/wanggang/.codans/repos/codans && claude -p "Run the doc-sync skill: review today's commits, detect docs drift, apply safe facts on a branch and PR the rest."</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>2</integer>
    <key>Minute</key><integer>30</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>/Users/wanggang/.codans/logs/doc-sync.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/wanggang/.codans/logs/doc-sync.err.log</string>
</dict>
</plist>
```

安装：`launchctl load ~/Library/LaunchAgents/dev.codans.doc-sync.plist`（卸载用 `launchctl unload`）。

## 6. 流程步骤

执行时严格按序：

1. **取当天 diff**：`git log --since=midnight --oneline` 列出当日提交；`git diff --stat <first-commit>^..HEAD` 取文件清单与摘要，必要时 `git diff <first-commit>^..HEAD -- <path>` 看具体改动。无当日提交则直接跳到第 6 步。
2. **映射受影响的 docs**：按改动的子系统 / 路径，找出 `docs/` 下对应被描述的文档（一个改动的 feature 对应它的 design-doc / product-spec）。只纳入被波及的文档。
3. **逐 doc 跑三类检测**：对每篇映射到的文档跑 §2 的 a/b/c；对每条引用核 liveness（必要时用 Grep/Read 回查代码确认符号是否可达）。
4. **分类**：把每条发现归入 **apply-safe**（§3 低风险事实性）或 **propose**（实质改动）。
5. **落盘 + 开 PR**：
   - 创建工作分支（如 `docs/doc-sync-<date>`）。
   - 把 apply-safe 项直接落盘。
   - 把 propose 项写成 drift 报告（每条：文档路径 + 行号、漂移类型、当前文档原文、今日真相 / 建议动作），随分支提交，并用 `gh pr create` 开 PR 交人审。
6. **无 drift**：不创建分支、不提交，仅向日志追加一行（日期 + no drift），退出。

## 7. 可选补充

PR / commit 时的 drift hint（在 authoring 时就提示漂移），作为夜间批处理的前置补漏——非本 skill 必需，可单独以 git hook 实现。
