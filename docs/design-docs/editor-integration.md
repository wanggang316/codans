# 设计文档：Editor Integration

**状态：** 本地编辑器打开、SSH 编辑器打开和应用内 `$EDITOR` 入口可用；Diff 当前文件跳转和 `editor.*` IPC 可用；`codans open` 提供本地目录入口。

## 范围与入口

Codans 将目录交给外部工具打开。应用内入口包括 Worktree 的 Open 下拉、默认编辑器命令和 Git Viewer 命令。调用方负责解析 Project、Worktree 和默认偏好；`EditorService` 负责发现应用、选择目标和启动。

目录与文件打开具有不同的契约：

| 路径 | 输入与机制 | 边界 |
|---|---|---|
| 本地应用 | 目录 URL，经 Launch Services 启动应用 | 校验本地目录存在；显式目标缺失时报错 |
| SSH 编辑器 | `RemoteHost` 和远程路径，经应用内置 CLI 启动 | 只选择能表达该 SSH host 的编辑器；不做本地目录存在性校验 |
| Diff 当前文件 | Worktree 路径、相对文件路径与可选行号，经 Launch Services 或 bundle 内 CLI 启动 | 只打开当前文件；行定位受比较来源与编辑器能力约束 |
| `$EDITOR` | 应用 feature 提供 Pane/Tab 上下文，在终端中运行 | 由 Pane 的 shell 解析环境变量；不能通过纯目录服务启动 |

`codans open [--in <editor>] [<path>]` 调用本地 `editor.open` IPC。省略路径时使用当前工作目录，相对路径由 CLI 转为绝对路径。此命令不承载 SSH host 或文件行号。应用提供[只读 Diff 窗口](git-diff-viewer.md)，不提供源码编辑、历史文件编辑或自定义编辑器命令模板。

## 组件边界

| 组件 | 职责 |
|---|---|
| `EditorRegistry` | 内建应用 ID、bundle ID、启动类型、菜单序和自动选择优先级 |
| `EditorDescriptor` | 已发现应用的描述，含 `appURL`、备用 bundle ID 和启动类型 |
| `LiveEditorService` | 发现缓存、本地与远程目标解析、打开和错误映射 |
| `AppLauncher` | Launch Services 查询和 `NSWorkspace` 启动的可替换边界 |
| `RemoteEditorOpen` | SSH host 适用性、内置 CLI 相对路径和参数构造 |
| `EditorFileOpen` | 当前文件的路径校验与文件/行号参数 |
| `DiffEditorClient` | Diff 文件跳转的 Project 偏好与 SSH host 解析 |
| `CommandRunner` | 文件与 SSH 编辑器 CLI 的执行、超时与输出限制 |
| `EditorFeature` | Project 上下文、偏好与 UI 结果；`$EDITOR` delegate |
| `EditorHandlers` | `editor.*` IPC 校验、DTO 转换和本地目录打开 |

实现入口：[EditorService.swift](../../apps/mac/codans/App/Clients/Editor/EditorService.swift)、[EditorService+Live.swift](../../apps/mac/codans/App/Clients/Editor/EditorService+Live.swift)、[EditorFeature.swift](../../apps/mac/codans/App/Features/Editor/EditorFeature.swift)。

## 应用发现与配置

`describe()` 返回内建注册表中已安装的应用。每项先查主 bundle ID，再查 `alternateBundleIdentifiers`；查询使用 `NSWorkspace.urlForApplication(withBundleIdentifier:)`。`$EDITOR` 没有 bundle，始终作为可选择项返回。

发现结果缓存在 `LiveEditorService` actor 中，`clearCache()` 使下一次发现重新查询。Settings 的编辑器入口和 IPC `editor.describe` 会刷新缓存；单纯再次 resolve 不保证发现新安装的应用。

完整应用清单与排序由 [EditorRegistry.swift](../../apps/mac/codans/App/Clients/Editor/EditorRegistry.swift) 定义。`defaultPriority` 用于自动选择，Finder 位于末尾；`menuOrder` 控制显示顺序。两者职责不同。`.shellEditor` 的可选性不表示它能经 `EditorService.open` 启动。

### 持久化

所有默认值存放在 `settings.json`：

| 字段 | 用途 |
|---|---|
| `general.defaultEditorID` | 全局默认编辑器 |
| `general.defaultGitViewerID` | 全局 Git Viewer；`"built-in"` 表示内置 Diff 窗口，外部目标使用注册表 ID |
| `projects[ProjectID].defaultEditor` | Project 编辑器覆盖；nil 使用全局解析链 |

`Project` 域模型不保存默认编辑器。存储默认值可以指向未安装应用，打开时按解析规则处理。未知 JSON 字段的宽容解码不构成跨版本双向恢复保证；配置格式和读取策略见 [Settings](settings.md)。

## 本地打开

### 解析链

调用方将用户显式选择直接作为 `preferred` 传入；没有显式选择时，读取 Project 覆盖，只有该目标已安装才传入。`EditorService.resolve` 接着执行：

1. `preferred` 有值：必须命中已安装项，否则抛 `.notInstalled`。
2. 全局默认已安装：选择该目标。
3. 遍历 `EditorRegistry.defaultPriority`：选择第一个已安装项，Finder 位于链尾。
4. 整条优先级链都无法解析：抛 `.launchFailed`。

严格性属于本地服务的 `preferred` 参数。调用方必须先过滤存储的 Project 默认，才能保留“显式选择严格、存储偏好宽容”的行为。

### 启动类型

`open(directory:preferred:)` 先校验本地目录存在，然后按 `launchMode` 分流：

- `.directory`：`NSWorkspace.open(urls:withApplicationAt:configuration:)`，URL 列表只有目标目录。
- `.applicationWithArguments`：`NSWorkspace.openApplication(at:configuration:)`，`configuration.arguments` 为目录路径，`createsNewApplicationInstance = true`。此路径用于 JetBrains 家族。
- `.shellEditor`：抛 `.launchFailed`，因为服务没有创建 Pane 所需的上下文。

Launch Services 路径不通过 `CommandRunner`，没有应用自行设置的进程超时或退出码检查。完成回调表示系统打开请求的结果，不代表外部编辑器已完成项目加载。

## SSH 打开

`openRemote(host:remotePath:preferred:)` 使用同一份已安装应用列表，但对每个候选检查 `RemoteEditorOpen.invocation` 是否能表达该 host。

解析顺序为 `preferred` → 全局默认 → `editorPriority`。每一级都宽容跳过未安装或不支持该 host 的应用，包括显式 `preferred`；没有可用目标时抛 `.launchFailed`。这条路径没有 Finder 兜底。

| 编辑器类别 | 参数与限制 |
|---|---|
| Zed | 内置 `Contents/MacOS/cli` 接收 `ssh://[user@]host[:port]/path`；路径按 URI 规则编码 |
| 支持的 VS Code 家族 | 内置 `Contents/Resources/app/bin/<cli>` 接收 `--remote ssh-remote+<destination>` 和远程路径 |
| Finder、Xcode、JetBrains、终端、Git 客户端 | `RemoteEditorOpen` 不提供 SSH invocation |

VS Code 家族不能在该 remote 参数中表达非默认端口。`RemoteHost.hasNonDefaultPort` 为 true 时，该类别不适用；端口可通过 SSH config 别名表达。支持的具体 ID 和 CLI 名称以 [RemoteEditorOpen.swift](../../apps/mac/codans/App/Clients/Editor/RemoteEditorOpen.swift) 为准。

远程启动经共享 `CommandRunner`：

- executable 位于发现到的应用 bundle 内，不通过 PATH 搜索。
- 参数作为 argv 数组传入，不拼接 shell 命令。
- 环境为 Codans 进程的环境，工作目录为本机用户 home。
- 超时为 30 秒，捕获输出上限为 64 KiB。
- 正常退出且 code 为 0 视为成功；其他结果映射为 `.launchFailed`。非零退出时，非空 stderr 可作为错误原因。

远程路径属于 SSH host，不能作为本机文件 URL 去校验或揭示。应用负责发起编辑器的远程连接，SSH 编辑器自身负责认证和远程项目加载。

## `$EDITOR`

`EditorFeature` 对 `.shellEditor` 分流，经 delegate 请求父级创建带 `initialCommand: "$EDITOR"` 的 Pane。Project、Worktree 和 Tab 由应用层确定，shell 使用该 Pane 的环境解释命令。

`EditorService.open` 和 `editor.open` IPC 都不提供这一 Pane 上下文，选择 `.shellEditor` 时会返回错误。SSH Project 的 `$EDITOR` 走终端路径，不走 `RemoteEditorOpen` 的本地应用 CLI 路径。

## Diff 当前文件跳转

`DiffEditorClient.openFile` 接收 Worktree 目录 URL、相对文件路径、可选行号和 Project ID。Client 读取 Project 覆盖、全局编辑器偏好及 SSH host，再调用 `LiveEditorService.openFile`；渲染组件只发送经过宿主校验的文件/行号意图。

`EditorFileOpen.target` 拒绝绝对路径、空路径段、`.`、`..` 和 NUL。本地文件必须存在、不是目录，且解析符号链接后仍在 Worktree 内。远程路径只做相对路径结构校验，不查询本地文件系统。

历史侧与已删除文件不能作为当前文件打开。Outgoing/Staged 比较打开当前文件时不传历史行号；Uncommitted 当前侧在内容复核一致后才传行号，内容变化或不可预览时省略行号。

VS Code 家族、Zed 和 Sublime Text 使用 bundle 内 CLI；JetBrains 通过 Launch Services application arguments 传文件与行号；其他支持的应用按文件打开，不保证行定位。使用 `path:line` 的 CLI 对含冒号的文件路径省略行号。终端、Git 客户端和 `$EDITOR` 不支持这一文件入口。

SSH 文件沿用远程编辑器的 host/端口能力约束。CLI 经 `CommandRunner` 执行，超时 30 秒，输出限制 64 KiB；本地工作目录为 Worktree，远程工作目录为本机 home。CLI 非零退出或执行失败返回 `.launchFailed`。

## Git Viewer

Settings → General 的 Default Git Viewer 默认为 **Built-in**，其后列出已安装的外部 Git 客户端。配置缺失、null 或未知注册表 ID 归一为 `GeneralSettings.builtInGitViewerID`（`"built-in"`）；已知但未安装的外部应用 ID 保留。

Toggle Git Viewer 命令（默认 ⌘G）读取 `general.defaultGitViewerID`：Built-in 打开当前 Worktree 的独立只读 Diff 窗口；外部目标存在于 editor descriptors 时派发 `EditorFeature.openRequested`，否则不执行。快捷键设置使用 `CommandID.toggleDiffInspector`，持久化 raw value 为 `"toggleGitViewer"`。

Worktree 右键菜单的 **Show Changes** 始终打开所点击 Worktree 的内置窗口，不受 Default Git Viewer 影响，也不改变主窗口选择。Worktree 菜单和命令面板的 Show Changes 面向当前 Worktree。主窗口 header 没有独立 Diff 按钮。

默认编辑器与 Git Viewer 是两个独立的全局设置。外部 Git Viewer 复用目录打开服务；Built-in 由 `DiffWindowManager` 管理，不进入外部应用服务。SSH Project 的外部目标进入远程编辑器解析；Git 客户端不支持 SSH invocation 时可能回落到能处理该 host 的编辑器。

## IPC

| 方法 | 请求与响应 |
|---|---|
| `editor.describe` | 返回 `{ descriptors: [...] }`，含安装描述，不含执行 argv |
| `editor.open` | `{ path, preferred? }` → `{ choice }`；path 为本地绝对目录路径 |
| `editor.setGlobalDefault` | `{ editorID? }`，写全局默认；null 清除 |
| `editor.setProjectDefault` | `{ projectID, editorID? }`，写 Project 设置；未知 Project 报错 |

`editor.open` 校验并规范化本地路径。`preferred` 缺席时，handler 查找包含该路径的 Project，从 `settings.projects[pid].defaultEditor` 取已安装覆盖项，再调用本地服务。请求没有 `RemoteHost` 字段，不表达 SSH 打开。

协议类型见 [EditorIPCTypes.swift](../../apps/mac/CodansIPC/Editor/EditorIPCTypes.swift)，边界校验见 [EditorHandlers.swift](../../apps/mac/codans/App/Features/Socket/EditorHandlers.swift)。

## 错误与限制

| 错误 | 条件 |
|---|---|
| `.notInstalled` | 本地显式 preferred 未安装或不在注册表中 |
| `.notADirectory` | 本地路径不存在或不是目录 |
| `.launchFailed` | Launch Services 失败、缺少 Pane 上下文、无可用 SSH 编辑器、文件路径校验失败或 bundle CLI 失败 |

应用通过 `EditorFeature.lastOpenResult` 展示打开结果；IPC handler 将服务错误映射为 wire 错误。Swift 服务错误枚举不单列超时或非零退出码，不能据此推断 SSH 路径没有这些失败条件。

同一 bundle ID 对应多个应用安装时，Launch Services 决定使用哪个安装。发现缓存只在明确失效后更新。内置 CLI 的路径或参数与应用版本不匹配时，远程打开可能失败；bundle 被发现不等于远程连接成功。

## 技术决策

- **本地应用以 bundle 为边界。** Launch Services 同时负责发现和本地启动，用户无需先安装编辑器的 PATH shim。
- **远程启动使用编辑器自身协议。** `RemoteEditorOpen` 集中定义 host 适用性与 argv，执行由共享 `CommandRunner` 负责，避免 feature 自建子进程管理。
- **Project 偏好属于调用方。** 服务不读 catalog；本地服务接收 URL，远程服务接收 host 与路径，Pane 创建留在应用层。
- **JetBrains 使用 application arguments。** 目录通过 `OpenConfiguration.arguments` 传入，避免目录打开与应用启动 API 的参数语义混淆。
- **本地与远程严格性不同。** 本地点名目标缺失时报错；远程会跳过不能表达该 host 的目标，以支持配置了本地默认的 SSH Project。

## 验证入口

- `EditorRegistryTests`：ID、bundle ID、菜单序和优先级。
- `EditorServiceResolutionTests` / `EditorServiceLaunchTests`：本地解析、目录验证和 Launch Services 参数。
- `EditorFileOpenTests`：文件边界、行号与 bundle CLI 参数。
- `RemoteEditorOpenTests`：SSH URL、端口适用性和内置 CLI argv。
- `EditorFeatureTests` / `EditorHandlersTests`：应用上下文、默认覆盖和 IPC 边界。

测试替身使用 `AppLauncher` 与 `CommandRunner`，避免单元测试真实启动外部应用。
