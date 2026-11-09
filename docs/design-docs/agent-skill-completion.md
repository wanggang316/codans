# 设计文档：Agent Skill Completion（New Agent 对话框的 Skill 补全）

**Availability:** Partly available: New Agent completion of user-level and project-level skills for Claude Code, Codex, and Pi, of enabled Claude Code and Codex plugin skills, and the Skills button. Other agents are `none` (see "探针实测").
**Author:** Gump（与 Claude）
**Implementation:** [SkillLocation](../../apps/mac/CodansCore/Agents/SkillLocation.swift), [SkillLocationResolver](../../apps/mac/CodansCore/Agents/SkillLocationResolver.swift), [ClaudePluginRegistry](../../apps/mac/CodansCore/Agents/ClaudePluginRegistry.swift), [CodexPluginRegistry](../../apps/mac/CodansCore/Agents/CodexPluginRegistry.swift), [SkillScanner](../../apps/mac/CodansCore/Agents/SkillScanner.swift), [ComposerSkillCompletion](../../apps/mac/codans/App/Features/Composer/ComposerSkillCompletion.swift), [ComposerSkillCompletionList](../../apps/mac/codans/App/Features/Composer/ComposerSkillCompletionList.swift), [NewAgentFeature](../../apps/mac/codans/App/Features/NewAgent/NewAgentFeature.swift)

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
  var projectDirectories: [(path: String, search: ProjectSearch)]
                                       // e.g. (".claude/skills", .walkUpToRepoRoot); search per directory
  var configRootEnvVar: String?        // e.g. "CLAUDE_CONFIG_DIR" replaces "~/.claude"
  var plugins: PluginSource?           // .claudeCode | .codex
  var invocationStyle: InvocationStyle // .slash | .slashSkill | .dollar | .none
  var invocationPosition: InvocationPosition // .leading | .anywhere
  var precedence: [SkillSource]        // dedupe order for one name
}
```

调研结果（2026-11，来源见各 agent 官方文档与本机安装）。`invocationStyle` 列是候选值；只有探针实测通过的 agent 在 v1 启用，其余为 `none`（见"探针实测"）：

| AgentKind | 用户级目录 | 项目级目录（查找范围） | 候选调用写法 |
|---|---|---|---|
| claude-code | `.claude/skills` | `.claude/skills`（向上到仓库根） | `/name`，插件 `/plugin:skill` |
| codex | `.agents/skills`、`.codex/skills`（`CODEX_HOME` 替换 `~/.codex`） | `.agents/skills`（向上到仓库根） | `$name`，插件 `$plugin:skill` |
| pi | `.pi/agent/skills`（`PI_CODING_AGENT_DIR` 替换 `~/.pi/agent`）、`.agents/skills` | `.pi/skills`（仅 cwd）、`.agents/skills`（向上到仓库根；均需项目已信任） | `/skill:name` |
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
- **项目级起点**：选中已有分支或 worktree 时，用 agent 启动所在的 worktree 目录（分支名与发送时同一规则：本地分支名优先，否则按 `<remote>/<branch>` 解析）；选 New Worktree 时目录尚不存在，用项目主仓库根（选中的分支没有 worktree 持有时同样会新建 worktree，也用主仓库根）；Folder 或 Workspace 项目用其唯一工作目录（与启动时一致：选中的行，否则第一个未归档的行）。查找范围按每个项目目录各自的 `search`（例如 Pi 的 `.pi/skills` 只读起点，`.agents/skills` 向上查找）；同一层的目录列完再到上一层。
- **向上查找**：`walkUpToRepoRoot` 从起点逐级向上，到第一个含 `.git`（目录或 worktree 的 `.git` 文件）的目录为止，近的在前；一路找不到仓库根时只读起点目录。
- **去重**：同名条目按 `precedence` 保留一个。Claude Code 为 User 优先于 Project（个人 Skill 覆盖项目 Skill），Plugin 最后（插件 Skill 名带 `<plugin>:` 前缀，不与其他来源同名）；Pi 先找到的保留（Project 优先于 User），Codex 同为 Project、User、Plugin；同一来源内近的目录优先。
- **远程项目**：不解析，补全关闭。

### 插件 Skill

- **Claude Code**：读 `<config root>/plugins/installed_plugins.json` 得到每个插件的 `installPath`，只保留 `enabledPlugins` 合并结果为 true 的插件。合并顺序同 Claude Code 的 settings 优先级（后者覆盖前者）：`<config root>/settings.json`、项目起点下的 `.claude/settings.json`、`.claude/settings.local.json`、profile 额外参数里的 `--settings <file>`、`/Library/Application Support/ClaudeCode/managed-settings.json`。Skill 在 `<installPath>/skills/*/SKILL.md`；个别插件放在 `<installPath>/.claude/skills`，两处都要扫。调用名为 `<plugin>:<skill>`。
  - Config root 与用户级目录同一规则：有效 HOME 下的 `.claude`，或 `CLAUDE_CONFIG_DIR` 的值（相对路径时不列插件）。
  - 插件清单 `.claude-plugin/plugin.json` 的 `skills` 字段声明了路径时，扫 `skills/` 与声明的路径（路径本身含 `SKILL.md` 则为单个 Skill），不再整体扫 `.claude/skills`：Claude Code 只加载声明的 Skill（例：ui-ux-pro-max 2.5.0 的 `.claude/skills` 有 7 个 Skill，只声明 1 个）。离开 install path 的路径丢弃。
  - 注册表 key 为 `<plugin>@<marketplace>`，`<plugin>` 取 `@` 之前部分。`installPath` 只接受绝对路径或 `~/` 开头的路径。
  - 额外参数是原样拼接的 shell 片段，由 shell 而非 codans 解析。codans 不解读 shell 语法：只有整个额外参数都是普通词时才解析，即每个字符是字母、数字、空格/Tab 或 `/._-+,@:%=~`，且没有词以 `=` 开头、没有词以 `~` 开头（`~/` 除外，按用户 HOME 展开）。其余一律视为读不准，不列插件 Skill；用户级与项目级 Skill 不受影响（ADR 0010）。
  - 普通词中只解析 `--settings <path>`（绝对路径、`~/`、或相对项目起点）与 `--settings=<path>`（值不以 `~` 或 `=` 开头）；重复的 `--settings`、`--setting-sources`、`--plugin-dir` 同样视为读不准。
  - 取舍：额外参数里用了任何 shell 语法（引号、转义、`$`、重定向、`;` 等）的 profile 看不到插件 Skill，即使它没有设置相关参数。按 ADR 0010 宁可少列，不列 agent 解析不到的 Skill。
  - 项目起点见"目录解析"。切换目标（分支）会改变起点，因此重新扫描。
  - 注册表缺失、不是 JSON、结构不符时，不列插件 Skill；某个 settings 文件缺失或无法解析时跳过该文件（Claude Code 也忽略无效的 settings 文件）。用户级与项目级 Skill 不受影响。
  - 列表行的来源标记为 Plugin，插入 `/<plugin>:<skill> `。
- **Codex**：`<config root>/plugins/cache/<marketplace>/<plugin>/<version>/skills/*/SKILL.md`，以 `<config root>/config.toml` 的 `[plugins."<plugin>@<marketplace>"] enabled = true` 过滤。调用名为 `<plugin>:<skill>`，插入 `$<plugin>:<skill> `。
  - Config root 为有效 HOME 下的 `.codex`，或 `CODEX_HOME` 的值（相对路径时不列插件）。
  - 只认表头形式 `[plugins."<key>"]` 下的 `enabled = true`；没有 `enabled`、值不是 `true`、或 key 中的插件名或 marketplace 不是单个目录名的，不列。`config.toml` 缺失或不可读时不列插件 Skill，用户级与项目级不受影响。
  - 同一插件缓存了多个版本时都扫，版本号大的在前，同名时保留新版本。
  - 远程安装的插件（`.codex-remote-plugin-install.json`）如果 `config.toml` 中没有对应表，同样不列：codans 读不到它们是否启用（ADR 0010）。

### 扫描与条目

`SkillScanner` 在后台读取每个目录下的 `*/SKILL.md`，解析 frontmatter 的 `name`、`description` 与 `disable-model-invocation`。frontmatter 损坏的 Skill 仍列出，名称取文件夹名，不显示描述，`disable-model-invocation` 视为 false。

`AgentSkillEntry`：调用名、描述首行、来源（Project / User / Plugin）、路径、是否禁止模型调用（`disablesModelInvocation`）。同名条目按该 agent 的 `precedence` 去重。

扫描时机：对话框打开、切换 agent、切换项目、切换目标。结果按（profile，项目起点）对应，起点变化时先清空旧结果。结果存在 `NewAgentFeature.State`；不监听文件，不跨会话缓存。

### 交互

- **触发**：在 token 开头（prompt 开头或空白之后）输入当前 agent 的前缀字符（`/`、`$`、`@`）时弹出列表。`invocationPosition == .leading` 的 agent 只在整个 prompt 开头触发。
- **过滤**：对名称与描述做模糊匹配，名称前缀匹配优先。过滤结果为空时自动收起。
- **禁止模型调用的 Skill**：调用 token 之前只有空白时（prompt 开头）列出；之前有其他文本时（prompt 中间）不列出。Claude Code 只在 prompt 开头由 CLI 直接展开 Skill；中间的调用靠模型的 Skill 工具，而 frontmatter 含 `disable-model-invocation: true` 的 Skill 模型不能调用，插入后不生效（ADR 0010）。
- **按键**：弹出时 Return / Tab 插入、↑↓ 移动、Esc 只关弹窗。收起后 Return 发送、Esc 关对话框，与现在一致。
- **插入**：把已输入的前缀和查询替换为 `<调用 token> `（末尾带空格）。
- **Skills 按钮**：在光标处插入前缀（替换选中文本；光标前紧跟非空白字符时先补一个空格，`invocationPosition == .leading` 时插在 prompt 开头），并把光标移到前缀后，于是弹出同一个弹窗。
- **不可用**：agent 的 `invocationStyle == .none` 或项目为远程时，不弹出，Skills 按钮置灰，tooltip 说明原因（`NewAgentFeature.State.skillsUnavailableReason`）：远程项目为 "Skill suggestions are not available for remote projects"，不支持的 agent 为 "Skill suggestions are not available for <agent>"；未选项目或 agent 时提示先选择。

组件 `ComposerSkillCompletion` 与 `ComposerTextEditor` 并列放在 `App/Features/Composer/`，不依赖 New Agent，便于后续接入其他输入处。

`.composerSkillCompletion` 修饰符同时接管输入框的 Return 和 Esc（`onSubmit` / `onCancel`）：SwiftUI 先把按键交给最外层的 `onKeyPress`，宿主另写的处理器会在弹窗之前拿走 Return。弹窗跟随文本与光标一起更新，光标移出调用 token（点击、方向键）即收起；扫描未完成时已输入的前缀保留，结果到达后弹出。切换 profile 时先清空旧结果，只接受属于当前 profile 的扫描结果。

### 探针实测

对本机已装的 Claude Code、Codex、Pi、Gemini、OpenCode：在隔离实例的临时项目里放一个探针 Skill（执行时输出固定标记），用 New Agent 的实际启动路径带调用 token 作为首条 prompt 启动，检查标记是否出现，分别测 prompt 开头和中间两种位置。结果写入 Skill Location 表的 `invocationStyle` / `invocationPosition` 及本节。未通过或未安装的 agent 保持 `none`。

结果（2026-11-09）：

| Agent | 版本 | 写法 | prompt 开头 | prompt 中间 | 结论 |
|---|---|---|---|---|---|
| Claude Code | 2.1.319 | `/name` | 通过：CLI 直接展开 Skill，输出标记 | 通过：模型调用 `Skill(name)` 加载后输出标记 | `.slash`，`.anywhere` |
| Codex | codex-cli 0.167.0 | `$name` | 通过：输出标记 | 通过：输出标记 | `.dollar`，`.anywhere` |
| Pi | 1.5.0 | `/skill:name` | 通过：Pi 展开 `[skill] codans-probe-459` 后输出标记 | 通过（项目已信任时）：模型读取 Skill 后输出标记 | `.slashSkill`，`.anywhere` |
| OpenCode | 1.18.15 | `@name` | 未通过：`opencode --prompt` 只填入输入框，不发送 | 同左 | `none` |
| Gemini CLI | — | `/name` | 未测：本机未安装；临时安装的 0.67.0 首次运行要求浏览器 OAuth 登录，无人值守会话无法完成 | 未测 | `none` |

- 探针：项目内 `.agents/skills/codans-probe-459/SKILL.md`（Codex、Pi、OpenCode 共用的目录），正文要求只回复 `PROBE-MARKER-9C2E`（标记只在正文）。
- 两种实测：先直接运行 CLI（`codex exec`、`pi -p`、`opencode run`）；再在隔离 Debug 实例里经 New Agent 对话框（选中已有 worktree）用补全列表插入调用 token 后发送，读 pane 内容找标记。
- Codex：首次进入目录时 TUI 先询问是否信任该目录，信任后执行首条 prompt。另用临时 `CODEX_HOME` 验证 `$CODEX_HOME/skills` 可用、已启用插件的 `$probeplug:hello` 输出标记、`enabled = false` 的插件不可用。
- Pi：TUI 启动时先询问是否信任项目目录；只有信任后才加载项目级 Skill（`pi -p` 在未信任目录中，中间位置的调用失败，因为模型的 Skill 列表里没有项目 Skill；开头的 `/skill:name` 仍由 Pi 直接展开）。中间位置靠模型读取 Skill，所以 `disable-model-invocation: true` 的 Skill 只在开头生效，由补全过滤（见"交互"）。
- OpenCode：`opencode run` 中 `@name` 与 `/name` 在开头和中间都由模型调用 Skill 工具后输出标记；但 OpenCode 的交互式 TUI 没有带首条 prompt 并发送的参数（`--prompt` 只预填输入框），New Agent 因此无法给 OpenCode 发首条 prompt（`AgentDescriptor.promptStyle` 为 `nil`）。等有可发送的启动参数后再启用。调研值保留在上表：用户级 `.config/opencode/skills`、`.claude/skills`、`.agents/skills`，项目级 `.opencode/skills`、`.claude/skills`、`.agents/skills`（向上到仓库根）。
- 切换 agent：同一草稿中从 Codex 切到 Pi，`$` 不再弹出，`/` 弹出 Pi 的列表，插入 `/skill:codans-probe-459`。

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
- OpenCode：交互式启动能带首条 prompt 并发送后，重跑探针。
- Gemini CLI：在已登录的机器上跑探针。
