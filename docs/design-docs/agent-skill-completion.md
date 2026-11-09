# 设计文档：Agent Skill Completion（New Agent 对话框的 Skill 补全）

**Availability:** Partly available: New Agent completion of Claude Code user-level skills and the Skills button. Project-level skills, plugin skills, and other agents are planned.
**Author:** Gump（与 Claude）
**Implementation:** [SkillLocation](../../apps/mac/CodansCore/Agents/SkillLocation.swift), [SkillLocationResolver](../../apps/mac/CodansCore/Agents/SkillLocationResolver.swift), [SkillScanner](../../apps/mac/CodansCore/Agents/SkillScanner.swift), [ComposerSkillCompletion](../../apps/mac/codans/App/Features/Composer/ComposerSkillCompletion.swift), [ComposerSkillCompletionList](../../apps/mac/codans/App/Features/Composer/ComposerSkillCompletionList.swift), [NewAgentFeature](../../apps/mac/codans/App/Features/NewAgent/NewAgentFeature.swift)

## 背景与范围

New Agent 对话框（⌘⇧N，`NewAgentFeature` / `NewAgentView`）让用户选项目、选位置、选 agent profile，再写第一条 prompt。prompt 由 `ComposerTextEditor`（普通 `TextEditor`）输入，目前没有任何补全。

用户在本机装了大量 Agent Skill（见 [GLOSSARY](../../GLOSSARY.md#agent-skills)），分散在各 agent 的用户级目录、项目目录和插件缓存里，且每个 agent 读取的目录与调用写法都不同。本设计在 prompt 里按选中 agent 的规则列出它能用的 Skill，并插入该 agent 认得的调用 token。

现有相关代码：

- `CodansKit/Skills/SkillInstaller.Target`：只有 claude / codex / agents 三项，用于把 codans 的 Bundled Skill 链接出去，语义是"装到哪"，与本设计的"agent 从哪读"不同。
- `AgentProfile.usesDedicatedHome` 与 `AgentLaunchCommand.dedicatedHomeURL`：专属 HOME 为 `<state>/agent-homes/<profile id>`。

## 目标与非目标

目标：

- 输入调用前缀时在光标处弹出补全列表；footer 的 Skills 按钮打开同一个列表。
- 列表与启动后的 agent 实际可解析、可调用的 Skill 一致（[ADR 0010](../adr/0010-skill-completion-offers-only-what-the-agent-resolves.md)）。
- `CodansCore` 内维护按 `AgentKind` 的 Skill Location 表，作为单一来源。

非目标（v1）：

- 远程 SSH 项目的 Skill 扫描（后续单独做）。
- Command Queue 输入框等其他 prompt 输入处接入（组件可复用，后续单独做）。
- 文件监听与跨会话缓存。
- 用户自定义 Skill Location。`AgentKind` 是封闭集合。
- 安装、编辑或同步 Skill（那是 YouSkill 的职责）。

## 设计

### 概览

```
AgentProfile + target dir ──► SkillLocationResolver ──► [SkillDirectory]
                                  ▲ AgentSkillLocations (CodansCore, per AgentKind)
[SkillDirectory] ──► SkillScanner (async, off main) ──► [AgentSkillEntry] (deduped)
[AgentSkillEntry] ──► NewAgentFeature.state.skills ──► ComposerSkillCompletion (popup)
                                                         └─ inserts InvocationStyle token
```

### Skill Location 表

`AgentSkillLocations`（`CodansCore/Agents/`）按 `AgentKind` 给出一条 Skill Location，挂在 `AgentDescriptor` 上：

```swift
struct SkillLocation {
  var userDirectories: [String]        // relative to the effective home, e.g. ".claude/skills"
  var projectDirectories: [String]     // relative to a project dir, e.g. ".claude/skills"
  var projectSearch: ProjectSearch     // .walkUpToRepoRoot | .workingDirectoryOnly
  var configRootEnvVar: String?        // e.g. "CLAUDE_CONFIG_DIR" replaces "~/.claude"
  var plugins: PluginSource?           // .claudeCode | .codex
  var invocationStyle: InvocationStyle // .slash | .slashSkill | .dollar | .at | .none
  var invocationPosition: InvocationPosition // .leading | .anywhere
  var precedence: [SkillSource]        // dedupe order for one name
}
```

调研结果（2026-11，来源见各 agent 官方文档与本机安装）。`invocationStyle` 列是候选值；只有探针实测通过的 agent 在 v1 启用，其余为 `none`（见"探针实测"）：

| AgentKind | 用户级目录 | 项目级目录（查找范围） | 候选调用写法 |
|---|---|---|---|
| claude-code | `.claude/skills` | `.claude/skills`（向上到仓库根） | `/name`，插件 `/plugin:skill` |
| codex | `.agents/skills`、`.codex/skills` | `.agents/skills`（向上到仓库根） | `$name`，插件 `$plugin:skill` |
| pi | `.pi/agent/skills`、`.agents/skills` | `.pi/skills`（仅 cwd）、`.agents/skills`（向上到仓库根） | `/skill:name` |
| opencode | `.config/opencode/skills`、`.claude/skills`、`.agents/skills` | `.opencode/skills`、`.claude/skills`、`.agents/skills`（向上） | `@id` |
| gemini | `.gemini/skills`、`.agents/skills` | `.gemini/skills`、`.agents/skills`（仅 cwd） | `/name` |
| cursor-agent | `.agents/skills`、`.cursor/skills`、`.claude/skills`、`.codex/skills` | 同名四处 | `/name` |
| cline | `.cline/skills` | `.cline/skills`、`.clinerules/skills`、`.claude/skills` | `/name` |
| copilot | `.copilot/skills`、`.agents/skills` | `.github/skills`、`.claude/skills`、`.agents/skills` | `/name` |
| kimi | `.kimi/skills`、`.claude/skills`、`.codex/skills`、`.config/agents/skills` 或 `.agents/skills` | `.kimi`、`.claude`、`.codex`、`.agents/skills`（最近的含 `.git` 祖先） | `/skill:name` |
| droid | `.factory/skills`、`.agents/skills` | `.factory/skills`、`.agents/skills`（仓库根） | `/name` |
| amp | `.config/agents/skills`、`.agents/skills`、`.config/amp/skills`、`.claude/skills` | `.agents/skills`、`.claude/skills`（向上） | 无文档 → `none` |
| grok | `.grok/skills`、`.agents/skills`、`.claude/skills`、`.cursor/skills` | 同名四处（cwd 到仓库根） | `/name` |
| omp | `.omp/agent/skills`、`.agents`、`.claude`、`.codex`、`.config/opencode` 下的 skills | `.omp`、`.agents`、`.claude`、`.codex`、`.opencode`、`.github` 下的 skills | `/skill:name` |

### 目录解析

`SkillLocationResolver` 输入 profile 与目标目录，输出要扫描的目录列表：

- **有效 HOME**：`usesDedicatedHome` 时为 `AgentLaunchCommand.dedicatedHomeURL(for:)`，否则为用户 HOME。
- **配置根变量**：profile 的 `envVars` 含该 agent 的 `configRootEnvVar` 时，以其值替换对应的默认配置根（例如 `CLAUDE_CONFIG_DIR` 替换 `~/.claude`）。
- **项目级起点**：选中已有分支或 worktree 时，用 agent 启动所在的 worktree 目录；选 New Worktree 时目录尚不存在，用项目主仓库根；Folder 或 Workspace 项目用其唯一工作目录。查找范围按 `projectSearch`。
- **远程项目**：不解析，补全关闭。

### 插件 Skill

- **Claude Code**：读 `<config root>/plugins/installed_plugins.json` 得到每个插件的 `installPath`，只保留 `<config root>/settings.json` 中 `enabledPlugins` 为 true 的插件。Skill 在 `<installPath>/skills/*/SKILL.md`；个别插件放在 `<installPath>/.claude/skills`，两处都要扫。调用名为 `<plugin>:<skill>`。
- **Codex**：`<config root>/plugins/cache/<marketplace>/<plugin>/<version>/skills/*/SKILL.md`，以 `config.toml` 的 `[plugins."<plugin>@<marketplace>"] enabled = true` 过滤。调用名为 `<plugin>:<skill>`。

### 扫描与条目

`SkillScanner` 在后台读取每个目录下的 `*/SKILL.md`，解析 frontmatter 的 `name` 与 `description`。frontmatter 损坏的 Skill 仍列出，名称取文件夹名，不显示描述。

`AgentSkillEntry`：调用名、描述首行、来源（Project / User / Plugin）、路径。同名条目按该 agent 的 `precedence` 去重。

扫描时机：对话框打开、切换 agent、切换项目、切换目标。结果存在 `NewAgentFeature.State`；不监听文件，不跨会话缓存。

### 交互

- **触发**：在 token 开头（prompt 开头或空白之后）输入当前 agent 的前缀字符（`/`、`$`、`@`）时弹出列表。`invocationPosition == .leading` 的 agent 只在整个 prompt 开头触发。
- **过滤**：对名称与描述做模糊匹配，名称前缀匹配优先。过滤结果为空时自动收起。
- **按键**：弹出时 Return / Tab 插入、↑↓ 移动、Esc 只关弹窗。收起后 Return 发送、Esc 关对话框，与现在一致。
- **插入**：把已输入的前缀和查询替换为 `<调用 token> `（末尾带空格）。
- **Skills 按钮**：在光标处插入前缀（替换选中文本；光标前紧跟非空白字符时先补一个空格，`invocationPosition == .leading` 时插在 prompt 开头），并把光标移到前缀后，于是弹出同一个弹窗。
- **不可用**：agent 的 `invocationStyle == .none` 或项目为远程时，不弹出，Skills 按钮置灰，tooltip 说明原因（`NewAgentFeature.State.skillsUnavailableReason`）：远程项目为 "Skill suggestions are not available for remote projects"，不支持的 agent 为 "Skill suggestions are not available for <agent>"；未选项目或 agent 时提示先选择。

组件 `ComposerSkillCompletion` 与 `ComposerTextEditor` 并列放在 `App/Features/Composer/`，不依赖 New Agent，便于后续接入其他输入处。

`.composerSkillCompletion` 修饰符同时接管输入框的 Return 和 Esc（`onSubmit` / `onCancel`）：SwiftUI 先把按键交给最外层的 `onKeyPress`，宿主另写的处理器会在弹窗之前拿走 Return。弹窗跟随文本与光标一起更新，光标移出调用 token（点击、方向键）即收起；扫描未完成时已输入的前缀保留，结果到达后弹出。切换 profile 时先清空旧结果，只接受属于当前 profile 的扫描结果。

### 探针实测

对本机已装的 Claude Code、Codex、Pi、Gemini、OpenCode：在隔离实例的临时项目里放一个探针 Skill（执行时输出固定标记），用 New Agent 的实际启动路径带调用 token 作为首条 prompt 启动，检查标记是否出现，分别测 prompt 开头和中间两种位置。结果写入 Skill Location 表的 `invocationStyle` / `invocationPosition` 及本节。未通过或未安装的 agent 保持 `none`。

结果（2026-11-09，Claude Code 2.1.319）：

| Agent | 写法 | prompt 开头 | prompt 中间 | 结论 |
|---|---|---|---|---|
| Claude Code | `/name` | 通过：CLI 直接展开 Skill，输出标记 | 通过：模型调用 `Skill(name)` 加载后输出标记 | `.slash`，`.anywhere` |
| 其余 agent | — | 未测 | 未测 | `none` |

- 探针：`~/.claude/skills/codans-probe-455/SKILL.md`，正文要求只回复 `PROBE-MARKER-7F3A`（标记只在正文，描述里没有）。
- 实测两次：直接运行 `claude '/codans-probe-455'` 与 `claude 'Run this for me: /codans-probe-455 and nothing more'`；再在隔离 Debug 实例里经 New Agent 对话框（New Worktree 目标）发送同样两条 prompt，pane 中均出现标记。
- 中间位置靠模型调用 Skill 工具，所以 frontmatter 含 `disable-model-invocation: true` 的 Skill 只在开头生效。v1 不区分，保持 `.anywhere`。

## 备选方案

- **静态菜单列 Skill**：Skill 上百个时长菜单不可搜索，且与输入补全形成两套交互。
- **一律扫真实 `~`**：列出专属 HOME 的 agent 看不到的 Skill，违反 ADR 0010。
- **插入自然语言（"Use the X skill"）代替调用 token**：各家都认，但不保证触发；作为 `none` agent 的后续选项保留。
- **用户可编辑的配置表**：`AgentKind` 封闭，配置面增大而收益小。

## 风险

- 各 agent 的目录与语法会随版本变化。表格的出处与核对日期写在本文，变更时更新。
- 插件注册表格式未公开、可能变化。解析失败时只丢弃插件来源，不影响其他来源。
- `SkillInstaller.Target` 与 Skill Location 表重复描述部分目录。后续改为从本表推导。

## 后续

- 远程项目：经 SSH 读取远端 Skill 目录。
- Command Queue 输入框接入 `ComposerSkillCompletion`。
- `SkillInstaller.Target` 改为从 Skill Location 表推导。
