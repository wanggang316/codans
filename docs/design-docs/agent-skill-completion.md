# 设计文档：Agent Skill Completion（New Agent 对话框与 Command Queue 的 Skill 补全）

**Availability:** Available: New Agent completion of user-level and project-level skills for Claude Code, Codex, and Pi, of enabled Claude Code and Codex plugin skills, and the Skills button; the Command Queue composer offers the same completion for the agent running in the target pane. Other agents and remote projects get no completion; the Skills button is disabled with the reason (see "探针实测").
**Author:** Gump（与 Claude）
**Implementation:** Entry points: [NewAgentView](../../apps/mac/codans/App/Features/NewAgent/NewAgentView.swift) (Skills button, prompt editor), [NewAgentFeature](../../apps/mac/codans/App/Features/NewAgent/NewAgentFeature.swift) (scan scope, `skillsUnavailableReason`), [CommandQueueView](../../apps/mac/codans/App/Features/CommandQueue/CommandQueueView.swift) and [CommandQueueFeature](../../apps/mac/codans/App/Features/CommandQueue/CommandQueueFeature.swift) (target pane's agent and working directory), [ComposerTextEditor](../../apps/mac/codans/App/Features/Composer/ComposerTextEditor.swift) (prefix and keys), [AgentSkillClient](../../apps/mac/codans/App/Clients/AgentSkillClient.swift) (scan). Supporting: [ComposerSkillCompletion](../../apps/mac/codans/App/Features/Composer/ComposerSkillCompletion.swift), [ComposerSkillCompletionList](../../apps/mac/codans/App/Features/Composer/ComposerSkillCompletionList.swift), [ComposerSkillCompletionPanel](../../apps/mac/codans/App/Features/Composer/ComposerSkillCompletionPanel.swift) (list and description panels), [SkillLocation](../../apps/mac/CodansCore/Agents/SkillLocation.swift), [SkillLocationResolver](../../apps/mac/CodansCore/Agents/SkillLocationResolver.swift), [SkillScanner](../../apps/mac/CodansCore/Agents/SkillScanner.swift), [ClaudePluginRegistry](../../apps/mac/CodansCore/Agents/ClaudePluginRegistry.swift), [CodexPluginRegistry](../../apps/mac/CodansCore/Agents/CodexPluginRegistry.swift), [PiProjectTrust](../../apps/mac/CodansCore/Agents/PiProjectTrust.swift), [NewWorktreeFiles](../../apps/mac/codans/Git/NewWorktreeFiles.swift)

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
| pi | `.pi/agent/skills`（`PI_CODING_AGENT_DIR` 替换 `~/.pi/agent`）、`.agents/skills` | `.pi/skills`（仅 cwd）、`.agents/skills`（向上到仓库根；均需项目已信任，见"项目信任（Pi）"） | `/skill:name` |
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
- **项目级起点**：选中已有分支或 worktree 时，用 agent 启动所在的 worktree 目录（分支名与发送时同一规则：本地分支名优先，否则按 `<remote>/<branch>` 解析）；选 New Worktree 时目录尚不存在，用项目主仓库根建立新 worktree 的视图（见下条；选中的分支没有 worktree 持有时同样会新建 worktree）；Folder 或 Workspace 项目用其唯一工作目录（与启动时一致：选中的行，否则第一个未归档的行）。查找范围按每个项目目录各自的 `search`（例如 Pi 的 `.pi/skills` 只读起点，`.agents/skills` 向上查找）；同一层的目录列完再到上一层。
- **新 worktree 的文件**：目标会新建 worktree 时（New Worktree，或选中的分支没有 worktree 持有），新 worktree 的已跟踪文件来自创建它的 ref，而不是主仓库根的工作区：New Worktree 用选中的 base ref；选中的分支没有 worktree 持有时，本地分支用该分支，否则用新本地分支所基于的远程 ref。此外只有复制选项要复制的主仓库根文件：勾选 Copy ignored files 时有被忽略的文件，勾选 Copy untracked files 时有未跟踪的文件。所以扫描前先在临时目录建一份新 worktree 的视图（`NewWorktreeFiles`），只含 Skill 补全会读的项目路径（`SkillLocationResolver.projectFilePaths`：项目 Skill 目录、项目 settings 文件、相对项目起点的 `--settings` 文件、Codex 的 `.codex/config.toml`）：已跟踪文件用 `git ls-tree -r` 列出、`git archive` 取出；要复制的文件用与 `wt` 相同的 `git ls-files --others [--ignored] --exclude-standard` 逐个列出并从主仓库根复制（符号链接按链接复制）；与不带 `--force` 的 `wt` 一样不覆盖已有路径，ref 跟踪的文件保持 ref 的内容。相对项目起点的 `--settings` 文件在仓库外时（如 `../settings.json`）不进视图（git 拒绝仓库外路径，新 worktree 相对它的位置也未知），此时项目 Skill 照常列出，插件 Skill 不列。视图中的相对符号链接指向仓库内缺失的路径时，按同样的规则补上该路径（最多 8 轮）；跳出仓库或更深的链接保持悬空，其 Skill 不列。然后以视图为项目起点扫描，扫描后删除视图。base ref 尚未确定或 git 失败时不建视图，只列用户级 Skill（项目 Skill 与项目 settings 未知，插件 Skill 也不列，ADR 0010）。修改 base ref 或复制选项会重新扫描；目标为已有 worktree 时它们不影响扫描。已知限制：创建时若先 fetch，远程 ref 可能前移，视图按扫描时的 ref 内容。
- **项目信任（Pi）**：Pi 只在信任的项目中加载项目级 Skill（`.pi/skills` 与项目 `.agents/skills`），未信任时这些 Skill 的调用不生效，同名时还会挡住可用的用户级 Skill。所以 Pi 的项目级目录只在 codans 能确定 Pi 不经询问就信任该项目时列出（`PiProjectTrust`），按 Pi 自己的顺序判断：
  1. 额外参数（须全是普通词）按 Pi 1.5.0 `parseArgs` 的读法：`--` 之后都是消息；取值的参数（`--model`、`--theme`、`--skill`、`-e` 等）吃掉下一个词，即使它以 `-` 开头。其中最后一个 `-a` / `--approve` 为信任，`-na` / `--no-approve` 为不信任，先于扩展判断。
  2. 有 `-e` / `--extension <path>`，或未加 `-ne` / `--no-extensions` 时 `<agent dir>/extensions` 非空、`settings.json` 的 `extensions` / `packages` 非空：扩展可能决定信任，读不准，不列。
  3. `<agent dir>/trust.json` 中起点真实路径（`realpath`）或最近的父目录的保存决定：`true` 列，`false` 不列；文件不是对象或值不是 `true` / `false` / `null` 时不列。
  4. 没有保存决定时按 `settings.json` 的 `defaultProjectTrust`：只有 `always` 列；默认 `ask` 会在启动时询问，结果未知，不列。
  - 目标会新建 worktree 时，新 worktree 的路径还不存在，没有可对应的保存决定，只有 `--approve` 时列出。这与复制选项无关：两项都勾选时也不用主仓库根的保存决定（`directories(projectStartExists: false)`）。
  - `<agent dir>` 为 `~/.pi/agent` 或 `PI_CODING_AGENT_DIR`（相对路径时不列）。用户级 Skill 不受影响。
  - `-ns` / `--no-skills`：Pi 不加载任何 Skill，也不展开 `/skill:name`（实测：调用未展开，模型自己去磁盘找文件），所以用户级与项目级都不列。额外参数不全是普通词时（如 `--no-skills --theme 'dark'`、`--no-skills 2>/dev/null`），shell 仍会把 `--no-skills` 传给 Pi 而 codans 读不准，所以 Pi 的 Skill 一律不列。`enableSkillCommands: false` 只去掉交互模式里 `/skill:` 的自动补全项，首条 prompt 仍会展开（实测：输出标记，会话记录中为展开后的 `<skill>` 块），不影响列表。
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
  - 配置层（后者覆盖前者）：`config.toml`，再加 profile 额外参数里 `-p` / `--profile <name>` 指定的 `<config root>/<name>.config.toml`。每个插件取最后一个显式的 `enabled`；没有 `true` 的不列。
  - `[features] plugins = false`（最后一层说了算）关闭全部插件；额外参数里最后一个 `--enable plugins` / `--disable plugins` 覆盖它。
  - 额外参数与 Claude Code 同一规则：只有整个额外参数都是普通词（`PlainShellWords`）时才解析。`-c` / `--config`、`--remote`、`-C` / `--cd`、重复或名字不是单个目录名的 `--profile`、profile 文件缺失，都视为读不准，不列插件 Skill。
  - 项目层：已信任项目的 `.codex/config.toml` 也是一层。codans 读不到 Codex 的信任状态，所以从项目起点到仓库根，任一 `.codex/config.toml` 提到 plugins（`[plugins.*]` 或 `[features] plugins`）时不列插件 Skill。
  - 只认表头形式 `[plugins."<key>"]` 与 `[features] plugins`。`[plugins]` 表、顶层 `plugins.` / `features.` 点分键、值不是 `true` / `false`、key 中的插件名或 marketplace 不是单个目录名，都视为读不准，不列插件 Skill。`config.toml` 缺失或不可读时同样不列。用户级与项目级不受影响。
  - 同一插件缓存了多个版本时都扫，版本号大的在前，同名时保留新版本。
  - 远程安装的插件（`.codex-remote-plugin-install.json`）如果 `config.toml` 中没有对应表，同样不列：codans 读不到它们是否启用（ADR 0010）。

### 扫描与条目

`SkillScanner` 在后台读取每个目录下的 `*/SKILL.md`，解析 frontmatter 的 `name`、`description` 与 `disable-model-invocation`。frontmatter 损坏的 Skill 仍列出，名称取文件夹名，不显示描述，`disable-model-invocation` 视为 false。

`AgentSkillEntry`：调用名、描述首行、来源（Project / User / Plugin）、路径、是否禁止模型调用（`disablesModelInvocation`）。同名条目按该 agent 的 `precedence` 去重。

扫描时机：对话框打开、切换 agent、切换项目、切换目标，以及目标会新建 worktree 时修改 base ref 或复制选项（worktree 选项加载完成、选定 base ref 后也会再扫描一次）。结果按（profile，项目起点，新 worktree 的来源：ref 与复制选项）对应，任一变化时先清空旧结果。结果存在 `NewAgentFeature.State`；不监听文件，不跨会话缓存。

### 交互

- **触发**：在 token 开头（prompt 开头或空白之后）输入当前 agent 的前缀字符（`/`、`$`、`@`）时弹出列表。`invocationPosition == .leading` 的 agent 只在整个 prompt 开头触发。
- **过滤**：对名称与描述做模糊匹配，名称前缀匹配优先。过滤结果为空时自动收起。
- **禁止模型调用的 Skill**：调用 token 之前只有空白时（prompt 开头）列出；之前有其他文本时（prompt 中间）不列出。Claude Code 只在 prompt 开头由 CLI 直接展开 Skill；中间的调用靠模型的 Skill 工具，而 frontmatter 含 `disable-model-invocation: true` 的 Skill 模型不能调用，插入后不生效（ADR 0010）。
- **按键**：弹出时 Return / Tab 插入、↑↓ 移动、Esc 只关弹窗。收起后 Return 发送、Esc 关对话框，与现在一致。输入法组字期间（有 marked text）这些键都交给输入法（确认、取消或选字），列表与对话框都不处理。
- **插入**：把已输入的前缀和查询替换为 `<调用 token> `（末尾带空格）。点击某一行同样插入。
- **呈现**：列表浮在对话框之上，不占对话框布局，打开和关闭时对话框大小不变。它是输入框所在窗口的子窗口（`ComposerSkillCompletionPanel`：borderless、non-activating、不能成为 key），与 `NSTextView` 的补全相同；不用 `.overlay`（会被分组 `Form` 的滚动视图和 sheet 边界裁掉），也不用 `.popover`（会从输入框拿走焦点）。面板与输入框同宽，贴着输入框上沿向上打开，上方屏幕空间不够时在输入框下方打开。焦点留在输入框，按键仍由修饰符处理。面板随窗口移动；列表关闭、窗口关闭或窗口失去 key 时面板关闭（失去 key 时按 Esc 处理，同一调用不再自动弹出）。外观为原生菜单卡片：菜单材质、圆角、系统阴影；每行只有来源图标（User、Project、Plugin 各不相同）与名称，来源写在行的辅助功能标签里；高亮行用系统选中色；最多显示 9 行，其余滚动。面板宽度取当前匹配项中最宽的行（图标、名称与内边距），不小于 180 pt，不大于输入框宽度，超出时名称中间截断；左边与输入框左边对齐，过滤改变匹配项时宽度随之变化，对话框大小不变。
- **当前行**：列表只有一个当前行（高亮行），与原生菜单一致：↑↓ 移动它；指针移到某一行上时该行成为高亮行，之后 ↑↓ 从它继续。只有指针真的移动才改变高亮：列表在静止的指针下打开、滚动或重新过滤时，高亮仍归键盘（`ComposerSkillCompletionPointer`）；指针离开列表时保留当前高亮。Return / Tab 与点击都插入高亮行。
- **描述提示**：高亮行的完整描述显示在列表旁的另一个子窗口（`ComposerSkillCompletionTooltipPanel`）中：放在面板右侧，右侧放不下时放左侧，顶边与该行对齐；系统提示材质与字体，自动换行，最宽约 320 pt，不截断；高亮每次变化（按键或指针）都立即跟随；没有描述的 Skill 不显示；不接收鼠标、不成为 key，随列表一起关闭。
- **Skills 按钮**：在光标处插入前缀（替换选中文本；光标前紧跟非空白字符时先补一个空格，`invocationPosition == .leading` 时插在 prompt 开头），并把光标移到前缀后，于是弹出同一个弹窗。
- **不可用**：agent 的 `invocationStyle == .none` 或项目为远程时，不弹出，Skills 按钮置灰，tooltip 说明原因（`NewAgentFeature.State.skillsUnavailableReason`）：远程项目为 "Skill suggestions are not available for remote projects"，不支持的 agent 为 "Skill suggestions are not available for <agent>"；未选项目或 agent 时提示先选择。

组件 `ComposerSkillCompletion`、列表面板与 `ComposerTextEditor` 并列放在 `App/Features/Composer/`，不依赖 New Agent，便于后续接入其他输入处。不可用原因中远程项目与不支持的 agent 两条由 `ComposerSkillCompletion.unavailableReason(for:isRemote:)` 统一给出。

### Command Queue 输入框

Command Queue（⌘L）的输入框用同一个组件、同一个修饰符和 Skills 按钮，补全对象是目标 pane 中正在运行的 agent：

- **agent 与目录**：打开时读目标 pane 的 `Pane.agentKind`（由前台进程识别）与 `workingDirectory`，以该目录为项目起点扫描（`AgentSkillClient`，无新 worktree 视图）。pane 不记录启动它的 profile，所以按该 agent 的默认 profile 解析：用户 HOME，没有 profile 的环境变量与额外参数。由专属 HOME 或配置根变量的 profile 启动的 agent，列表可能与其实际可用的 Skill 不一致（已知限制）。
- **不可用**：pane 中没有识别到 agent 时为 "Skill suggestions need an agent running in this pane"；远程项目与不支持的 agent 同 New Agent。此时不弹出，Skills 按钮置灰。
- **按键**：列表弹出时 Return / Tab 插入、Esc 只关列表；收起后与原来一致：Return 发送（草稿为空时吞掉 Return，不换行），⇧Return / ⌥Return 换行，Esc 关闭面板。

`.composerSkillCompletion` 修饰符同时接管输入框的 Return 和 Esc（`onSubmit` / `onCancel`）：SwiftUI 先把按键交给最外层的 `onKeyPress`，宿主另写的处理器会在弹窗之前拿走 Return。弹窗跟随文本与光标一起更新，光标移出调用 token（点击、方向键）即收起；扫描未完成时已输入的前缀保留，结果到达后弹出。切换 profile 时先清空旧结果，只接受属于当前 profile 的扫描结果。

### 探针实测

对本机已装的 Claude Code、Codex、Pi、Gemini、OpenCode：在隔离实例的临时项目里放一个探针 Skill（执行时输出固定标记），用 New Agent 的实际启动路径带调用 token 作为首条 prompt 启动，检查标记是否出现，分别测 prompt 开头和中间两种位置。结果写入 Skill Location 表的 `invocationStyle` / `invocationPosition` 及本节。未通过或未安装的 agent 保持 `none`。

结果（2026-11-09）：

| Agent | 版本 | 写法 | prompt 开头 | prompt 中间 | 结论 |
|---|---|---|---|---|---|
| Claude Code | 2.1.319 | `/name` | 通过：CLI 直接展开 Skill，输出标记 | 通过：模型调用 `Skill(name)` 加载后输出标记 | `.slash`，`.anywhere` |
| Codex | codex-cli 0.167.0 | `$name` | 通过：输出标记 | 通过：输出标记 | `.dollar`，`.anywhere` |
| Pi | 1.5.0 | `/skill:name` | 通过：Pi 展开 `[skill] codans-probe-459` 后输出标记 | 通过（项目已信任时）：模型读取 Skill 后输出标记 | `.slashSkill`，`.anywhere` |
| OpenCode | 1.18.15 | `@name` | 未通过：`opencode --prompt` 只填入输入框，不发送 | 未通过：New Agent 不给 OpenCode 传首条 prompt，TUI 以空输入框启动 | `none` |
| Gemini CLI | 0.67.0 | `/name` | 无法完成：经 New Agent 启动，Gemini 发现了探针（"1 skill"），但模型请求返回 403（API key 所属项目已被停用） | 同左 | `none` |

- 探针：项目内 `.agents/skills/codans-probe-459/SKILL.md`（Codex、Pi、OpenCode 共用的目录），正文要求只回复 `PROBE-MARKER-9C2E`（标记只在正文）。
- 两种实测：先直接运行 CLI（`codex exec`、`pi -p`、`opencode run`）；再在隔离 Debug 实例里经 New Agent 对话框（选中已有 worktree）用补全列表插入调用 token 后发送，读 pane 内容找标记。
- Codex：首次进入目录时 TUI 先询问是否信任该目录，信任后执行首条 prompt。另用临时 `CODEX_HOME` 验证 `$CODEX_HOME/skills` 可用、已启用插件的 `$probeplug:hello` 输出标记、`enabled = false` 的插件不可用。覆盖项实测（2026-11-10，`codex exec`，插件在 `config.toml` 中已启用）：`-p off`（`off.config.toml` 设 `enabled = false`）、`--disable plugins`、`[features] plugins = false`、已信任项目的 `.codex/config.toml` 设 `enabled = false`，四者都使插件不可用；`-c 'plugins."probeplug@probe-market".enabled=false'` 未生效，但 `-c` 能改任意配置，仍视为读不准。
- Pi：TUI 启动时先询问是否信任项目目录；只有信任后才加载项目级 Skill（`pi -p` 在未信任目录中，中间位置的调用失败，因为模型的 Skill 列表里没有项目 Skill；开头的 `/skill:name` 仍由 Pi 直接展开）。中间位置靠模型读取 Skill，所以 `disable-model-invocation: true` 的 Skill 只在开头生效，由补全过滤（见"交互"）。
- OpenCode：`opencode run` 中 `@name` 与 `/name` 在开头和中间都由模型调用 Skill 工具后输出标记；但 OpenCode 的交互式 TUI 没有带首条 prompt 并发送的参数（`--prompt` 只预填输入框），New Agent 因此无法给 OpenCode 发首条 prompt（`AgentDescriptor.promptStyle` 为 `nil`）。等有可发送的启动参数后再启用。调研值保留在上表：用户级 `.config/opencode/skills`、`.claude/skills`、`.agents/skills`，项目级 `.opencode/skills`、`.claude/skills`、`.agents/skills`（向上到仓库根）。
- Gemini CLI：本机未安装，临时装到私有目录并在登录 `PATH` 上临时放一个链接（New Agent 只列登录 `PATH` 上能找到的 agent）。可用的凭据都不可用：OAuth 要浏览器登录，`~/.config/secrets.env` 的 API key 返回 `CONSUMER_SUSPENDED`，其代理地址返回 404。在有可用凭据的机器上重跑后才能决定写法。
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
- Command Queue：pane 记录启动它的 profile 后，按该 profile 解析 Skill。
- `SkillInstaller.Target` 改为从 Skill Location 表推导。
- OpenCode：交互式启动能带首条 prompt 并发送后，重跑探针。
- Gemini CLI：在有可用凭据的机器上重跑探针（[#490](https://github.com/wanggang316/codans/issues/490)）。
