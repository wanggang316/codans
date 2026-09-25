# 设计文档：Command Suggest（项目命令识别）

**状态：** 已实现
**作者：** Gump（与 Claude）

## 背景与范围

Project 的 Commands（Settings → 项目 → Commands）是用户自定义的 `ScriptDefinition` 列表，驱动 Header 的 Run 按钮、Command Palette 与快捷键。大多数项目已经在自己的清单里写好了入口——`package.json` 的 `scripts`、Makefile 目标、justfile recipe——手工再抄一遍是纯摩擦。

Command Suggest 按来源列出从项目清单识别出的命令，点一下即落成一条普通 `ScriptDefinition`。两个入口共用同一个菜单分节（`CommandSuggestionMenuSection`）：

- Settings → Commands 表格的 `+` 菜单，位于预设类型（Run / Test / …）之下（"From Project"）；
- worktree header Run 按钮的下拉菜单，位于 Project / Global 命令之下（"Add from Project"），扫描的是 header 当前显示的 worktree。

两处点击都只**加入**命令、不运行——header 下拉里其它项点了就执行，但识别出的 `deploy` 不能因为一次误点就跑起来；加入后它出现在上方 Project 列表，再点才运行。

## 目标与非目标

**目标**

- 从常见清单识别可运行入口，一键加入 Project Commands。
- 本地与 Server（SSH）项目行为一致。
- 新增一种生态（构建工具）只需新增一个解析器，读取 / UI / 落库不动。

**非目标**

- 不持久化建议、不与清单保持同步：采纳即复制，之后与清单无关。
- 不执行任何外部工具来识别（如 `just --list`、`npm pkg get`）：只读文件，避免依赖安装状态与副作用。
- 不递归 monorepo 子包；只看扫描目录这一层。
- 不接入 Global Commands（无 Project 上下文）；不在 Command Palette 直接运行未保存的建议。

## 设计

### 分层

```
CodansCore/Settings/CommandSuggestion/        纯逻辑，无 IO
  CommandSuggestionParser (protocol)          每个生态一个解析器
  CommandSuggestionRegistry.standard          有序解析器集合 + 合并请求
  ManifestRequest / ManifestSnapshot          解析器声明要读什么 / 读到了什么
  ScriptKindInference                         入口名 → ScriptKind（只影响图标/颜色）
  CommandSuggestionAdoption                   建议 → ScriptDefinition，守表格不变量
  Parsers/                                    内置解析器

codans/App/Features/CommandSuggestion/        IO
  ManifestReader (protocol)                   Local / Remote(SSH) 两个实现
  CommandSuggestionClient (TCA dependency)    选 reader → 读一次 → registry 解析

ProjectSettingsFeature                        scanCommandSuggestions / commandSuggestionsScanned
CommandSuggestionMenuSection                  共享菜单分节：每来源一个子菜单，已采纳的打勾禁用
ScriptCommandTable.addMenu                    Settings 入口（"From Project"）
WorktreeHeaderFeature / HeaderRunScriptSplitButton  Header 入口（"Add from Project"），按 worktree 扫描
```

### 解析器契约

```swift
protocol CommandSuggestionParser: Sendable {
  var source: CommandSuggestionSource { get }   // id + 菜单标题
  var request: ManifestRequest { get }          // contentPaths + presencePaths
  func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion]
}
```

- **纯函数**：解析器只看 snapshot，不碰文件系统，所以可用字面量 fixture 测试，且对 SSH 项目原样复用。
- **内容 vs 存在**：`contentPaths` 读内容；`presencePaths` 只探测存在。lockfile 放在后者——它们只用来判定包管理器，可能有数 MB，绝不读取或过网。
- **容错**：清单解析失败返回空数组，绝不让整次扫描失败。
- Registry 把所有解析器的 request 合并去重（被读内容的路径不再重复探测存在），一次读取喂给全部解析器；组按 registry 顺序输出，空组丢弃，同组内重名取首个。

### 内置来源

| 来源 | 识别 | 生成命令 |
|---|---|---|
| `package.json` | `scripts`；包管理器：`packageManager` 字段 → lockfile（pnpm / bun / yarn / npm）→ npm；存在对应基名时隐藏 `pre*`/`post*` 生命周期钩子 | `<pm> run <name>` |
| `deno.json` | `tasks`（字符串或 `{ command }`；`.jsonc` 跳过） | `deno task <name>` |
| `composer.json` | `scripts`（字符串或步骤数组） | `composer run-script <name>` |
| Makefile | 按 GNU make 查找顺序取第一个；列 0 的字面量目标，排除特殊目标/模式规则/赋值；`.PHONY` 声明的排前；行尾 `## 说明` 作 detail | `make <target>` |
| justfile | 公开 recipe（排除 `_name` 与 `[private]`），上方注释作 detail | `just <recipe>` |
| Taskfile | 顶层 `tasks:` 下一级 key，`desc:` 作 detail，隐藏 `internal: true` | `task <name>` |
| mise.toml | `[tasks.<name>]` 与 `[tasks]` 内联两种写法；`description` 优先于 `run` | `mise run <name>` |
| Cargo / Go / SwiftPM | 仅凭清单存在给出固定动词（Go 不给 `go run`：模块根常不是 main 包） | `cargo test` 等 |

入口名只含 shell 惰性字符时原样拼接，否则用 `ShellQuoting` 单引号包裹。

### 读取

- **位置**：Settings pane 的 `lastFocusedWorktreeID` → Project 的 `selectedWorktreeID` → `rootPath`。分支可能带不同的清单，所以优先用户正在用的 checkout。
- **本地**：`FileManager` 读 request 中的固定文件名；单文件上限 1 MiB。
- **Server 项目**：一次 SSH 调用（共享 ControlMaster，`BatchMode`）。远端 `/bin/sh` 脚本以位置参数接收目录与路径（路径不进入脚本解析），输出 `===CODANS-MANIFEST <path>===` / `===CODANS-PRESENT <path>===` 标记分隔的流；首个标记前的登录 shell 横幅被忽略。超时、非零退出或输出溢出都得到空 snapshot——表现为"无建议"，不报错。
- **时机**：Commands pane 每次出现时扫描（`.task(id: projectID)`）；header 在切换 worktree 时扫描（`.task(id: worktreeID)`，挂在 Menu 的 `.id` 之外，脚本编辑触发的 Menu 重建不会重扫）。两处菜单内都有 Refresh。无文件监听。新扫描取消在途扫描；header 的结果带上扫描时的 worktree，切走后迟到的结果直接丢弃。
- 位置解析统一在 `ManifestLocation.resolve`：指定 worktree → Project 选中的 worktree → Project 根目录。

### 采纳（`CommandSuggestionAdoption`）

- 已有脚本的 `command`（trim 后）与建议相同 → 菜单项打勾并禁用，不重复添加。
- 推断为 `.run` 时：若 Run 仍是虚拟内置项，则把它物化到首位并填入命令（保留 ⌘R）；若已有 Run 但命令为空，则就地填入；若已有非空 Run，则按 `.custom` 追加。
- 其他预设类型若已被占用，降级为 `.custom`，保持"每种预设类型至多一条"。
- 名称取清单中的入口名；采纳后选中该行。

### 图标映射（`CommandIconCatalog`）

一张集中维护的「常见命令 → 图标」表，命令建议与前台进程列表共用。对一个清单入口，按从具体到一般的顺序解析：

1. 入口名以工具命名（`storybook`、`docker:up`）→ 该工具的 mark；
2. 入口名含动作词（`build`、`test:unit`）→ 动作的 SF Symbol（build→`hammer.fill`、test→`testtube.2`、lint→`checklist`、typecheck→`checkmark.shield.fill`、migrate/db→`cylinder.split.1x2.fill` …）。**动作优先**，同一清单里的十几个脚本才不会全顶着 npm 图标、无从区分；
3. 脚本体里调用了已知工具（`prisma generate`）→ 该工具的 mark；
4. 执行它的 runner（`pnpm run …`、`make …`、`cargo …`）→ 其 mark。

工具 mark 是 `ToolMark` 枚举（56 个），资源为 `tool-<raw>.imageset`：单色、24×24 viewBox、模板渲染，**跟随脚本颜色**，与 SF Symbol 同一套着色；来源与许可登记在 [tool-marks](../references/tool-marks.md)（Simple Icons CC0，`mise` 为自绘；Playwright 用 SF `theatermasks.fill`）。小尺寸下读成噪点的插画/细线/纯文字标（Composer、GNU、Maven、.NET）不收录。

**存储**：沿用已有字符串字段——`ScriptDefinition.systemImage` 存 SF 名或 `mark:<tool>`，与 `Tab.icon` 的 `agent:` 前缀同构（运行脚本时该串原样写进 `Tab.icon`）。无 schema 变更：旧构建把 `mark:npm` 当作未知 symbol，只是不画；本构建遇到未知 mark 回退到类型默认图标。采纳建议时只在映射图标 ≠ 类型默认图标时写入，且不覆盖用户已给空 Run 选的图标。

**渲染**：所有画命令图标的地方都经 `CommandIconGlyph`（`CommandIconRef`）/ `StoredIconGlyph`（存储串，含 `agent:`）——Commands 表格、`+` 菜单、Header Run 按钮与其菜单、Command Palette、Tab chip、进程列表。菜单与 toolbar 会把 asset 图重新模板化并丢色，因此经 `CommandIconImage.tinted` 把颜色烘焙进非模板 `NSImage`。图标弹窗在 SF 网格下增加 Tools 网格。

### 菜单呈现

每项 = 图标（映射图标，按推断类型着色；已采纳为对勾）+ 入口名 + 副标题（`<命令> — <脚本体>`，整体截断到 44 字符避免 AppKit 折行）。副标题依赖按钮 label 为"Image + Text + Text"的平铺结构——用 `Label` 包裹两个 `Text` 时 AppKit 菜单会丢掉副标题。

## 扩展一个新生态

1. 在 `CodansCore/Settings/CommandSuggestion/Parsers/` 新增实现 `CommandSuggestionParser` 的类型：声明 `request`、在 `suggestions(in:)` 中纯解析。
2. 追加到 `CommandSuggestionRegistry.standard`（顺序即菜单顺序）。
3. 在 `CodansCoreTests/Settings/CommandSuggestion/` 用字面量 fixture 覆盖。
4. 若该生态有新的 runner / 工具，在 `CommandIconCatalog.toolIcons` 登记可执行名；需要新 mark 时按 [tool-marks](../references/tool-marks.md) 的「Adding a mark」添加。

读取层、SSH 协议、UI、采纳逻辑均无需改动。

## 验证

- `CodansCoreTests`：各解析器、registry 合并 / 分组、类型推断、采纳不变量；`CommandIconCatalogTests` / `CommandIconRefTests`（优先级、`mark:` 往返、未知 mark 回退、每个 `ToolMark` 都可由映射表到达）。
- `CodansTests`：`ToolMarkAssetTests`（每个 mark 都随包带模板资源）、`WorktreeProcessIconTests`（进程列表走同一映射）。
- `CodansTests`：`CommandSuggestionScanTests`（扫描位置解析、Server 项目走 host、项目缺失清空）、`RemoteManifestReaderTests`（流解析、远端脚本在本机 `/bin/sh` 实跑往返、失败得空）、`LocalManifestReaderTests`。
- `CodansTests`：`WorktreeHeaderCommandSuggestionTests`（按 header 的 worktree 扫描、切换后丢弃迟到结果、加入只写 Project 命令不走运行路径、已加入的不重复写）。
- 隔离实例上检查过 header 下拉：菜单结构、子菜单图标与已加入打勾、点 `build` 后进入 Project 列表且未产生任何 tab/pane（未运行）。
- 隔离实例上检查过菜单外观（含映射图标）、"点 dev → 填入内置 Run"、采纳后写入 `mark:docker` / `mark:prisma`、图标弹窗 Tools 网格，以及打开弹窗不会冲掉已选 mark。
