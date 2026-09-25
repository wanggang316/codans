# 设计文档：Command Suggest（项目命令识别）

**状态：** 已实现
**作者：** Gump（与 Claude）

## 背景与范围

Project 的 Commands（Settings → 项目 → Commands）是用户自定义的 `ScriptDefinition` 列表，驱动 Header 的 Run 按钮、Command Palette 与快捷键。大多数项目已经在自己的清单里写好了入口——`package.json` 的 `scripts`、Makefile 目标、justfile recipe——手工再抄一遍是纯摩擦。

Command Suggest 在 Commands 表格的 `+` 菜单里，于预设类型（Run / Test / …）之下，按来源列出从项目清单识别出的命令；点一下即落成一条普通 `ScriptDefinition`。

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
ScriptCommandTable.addMenu                    "From Project" 分节 + 每来源一个子菜单
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
- **时机**：Commands pane 每次出现时扫描（`.task(id: projectID)`），菜单内有 Refresh。无文件监听。新扫描取消在途扫描。

### 采纳（`CommandSuggestionAdoption`）

- 已有脚本的 `command`（trim 后）与建议相同 → 菜单项打勾并禁用，不重复添加。
- 推断为 `.run` 时：若 Run 仍是虚拟内置项，则把它物化到首位并填入命令（保留 ⌘R）；若已有 Run 但命令为空，则就地填入；若已有非空 Run，则按 `.custom` 追加。
- 其他预设类型若已被占用，降级为 `.custom`，保持"每种预设类型至多一条"。
- 名称取清单中的入口名；采纳后选中该行。

### 菜单呈现

每项 = 图标（按推断类型着色；已采纳为对勾）+ 入口名 + 副标题（`<命令> — <脚本体>`，整体截断到 44 字符避免 AppKit 折行）。副标题依赖按钮 label 为"Image + Text + Text"的平铺结构——用 `Label` 包裹两个 `Text` 时 AppKit 菜单会丢掉副标题。

## 扩展一个新生态

1. 在 `CodansCore/Settings/CommandSuggestion/Parsers/` 新增实现 `CommandSuggestionParser` 的类型：声明 `request`、在 `suggestions(in:)` 中纯解析。
2. 追加到 `CommandSuggestionRegistry.standard`（顺序即菜单顺序）。
3. 在 `CodansCoreTests/Settings/CommandSuggestion/` 用字面量 fixture 覆盖。

读取层、SSH 协议、UI、采纳逻辑均无需改动。

## 验证

- `CodansCoreTests`：各解析器、registry 合并 / 分组、类型推断、采纳不变量。
- `CodansTests`：`CommandSuggestionScanTests`（扫描位置解析、Server 项目走 host、项目缺失清空）、`RemoteManifestReaderTests`（流解析、远端脚本在本机 `/bin/sh` 实跑往返、失败得空）、`LocalManifestReaderTests`。
- 隔离实例上检查过菜单外观与"点 dev → 填入内置 Run"的端到端写入。
