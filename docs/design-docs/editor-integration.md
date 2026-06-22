# 设计文档：Editor Integration

**状态：** 已上线（可见）
**作者：** Gump（与 Claude）

## 背景与范围

codans 刻意不是 IDE。任何读码或改码的需求都是一次向外部编辑器或文件管理器的交接——Cursor、Zed、VSCode、Xcode、Sublime、Finder，以及一众终端 / git 客户端。本文档描述那次交接：检测哪些应用已安装、把一个目录在选定目标里打开、以及解析"用哪个"的默认值。落地代码在 `apps/mac/codans/App/Clients/Editor/`。

检测与启动都经 `NSWorkspace` / Launch Services 按 bundle identifier 走——不碰 `$PATH`、不 spawn `Process`、不拼 argv。macOS GUI 应用继承的是 `launchd` 的最小 `PATH`（`/usr/bin:/bin:/usr/sbin:/sbin`），凡是装进 `/usr/local/bin` 或 `/opt/homebrew/bin` 的编辑器 CLI shim（`code`/`cursor`/`subl`/…）——也就是每一个 Homebrew 风格安装、每一个跑过 "Install 'code' command in PATH" 的用户——都会被 `$PATH` 探测误报为**未安装**，哪怕 `.app` bundle 就躺在 `/Applications`。macOS 的应用发现走 Launch Services 而非调用方的 `PATH`，因此 bundle-id 检测无视那个可选 CLI shim 装没装，都能正确工作（承重理由见 `## 技术决策`）。

这个能力与 Worktree **解耦**："Open in X" 本质是一次 path-open 动作，而非 Worktree 专属动作。调用方（Worktree header、CLI、未来的 deeplink）各自把自身上下文解析成一个 `URL` 再交给服务；服务永远不知道 Worktree 是什么。

## 目标与非目标

**目标**

- 提供一份精选注册表，覆盖编辑器、终端、git 客户端、Xcode、Finder 与 `$EDITOR`，每条钉死一个 bundle identifier。
- 无视 `$PATH`，用 `NSWorkspace.urlForApplication(withBundleIdentifier:)` 可靠检测每个已安装条目。
- 接受任意目录 URL，经 `NSWorkspace` 在解析出的目标里打开它（`.editor` 这一特例除外，它 spawn 一个跑 `$EDITOR` 的 Pane），且每个 UI 表面都显示真实的 `.app` 图标。
- 服务严格面向 path：open API 是 `(directory: URL, preferred: EditorID?)`。签名里不出现 Worktree、Pane、Project 或任何其它域类型。
- Settings UX 是一个**仅列已安装**条目的下拉（未安装的隐藏）；无安装引导、无下载 CTA、无 PATH 排障。
- 默认解析级联：显式请求 → 全局默认 → 优先级自动挑选 → Finder。
- 经一道窄 `AppLauncher` 缝完全可测——单测里不真启动任何应用。

**非目标**

- 文件级 / 行级 / diff 级打开。v1 只开目录。
- 用户自定义命令模板（"Custom editors"）。新增条目是一次代码改动。若日后证明判断错了，再行修订。
- 安装 / 下载 / quarantine 帮助。条目没装就不出现，这就是全部 UX。
- 同一应用多版本（如 Xcode stable vs Xcode-beta）的消歧。Launch Services 的选择即结果，作为已知限制记录。
- 按 codans 自身重叠能力裁剪注册表（如"我们已内置终端，跳过终端应用"）。尊重用户选择，不裁。
- 把编辑器服务耦合到 Worktree / Project / Pane。服务是纯 path-opener；任何 per-Project 语义住在上一层——调用它的 feature / handler 里。

## 技术决策

- **机制统一在 Launch Services，而非 `Process` + `$PATH`。** 放弃"一切皆 `Process` + argv"的干净叙事，代价是多一道测试缝（`AppLauncher`），换来近 100% 安装率上的正确检测，以及与 macOS 惯例（图标、LS、激活语义）的一致。检测与启动走同一机制，避免"可检测却不可启动"（bundle 在但用户从未装 CLI shim）这一类失败。
- **JetBrains 家族走 `.applicationWithArguments` 而非 `.directory`。** JetBrains IDE 期望目录经 `configuration.arguments` 到达；走 `open(urls:…)` 它们会聚焦上一次打开的窗口、忽略参数，在错误的工程里打开。以空 URL 列表调 `open(urls:…)` 还是未定义行为，且不会把 `configuration.arguments` 转发给被启动应用。故 JetBrains 单列一支。
- **严格性边界放在服务的 `preferred` 参数上，而非 ID 出处。** "已设即 strict"让服务对 ID 来自 project 还是 global 一无所知，同时仍兑现"显式点选缺失则响亮报错、存储默认缺失则静默穿透"的 UX（详见解析链小节）。

## 设计

### 总览

三处机制加一个 UX 后果：

1. **检测 = `NSWorkspace.urlForApplication(withBundleIdentifier:)`。** 每个内建条目钉死其 Apple 分配的 bundle identifier。"已安装" = 每个 bundle id 一次 LS 查询；结果按应用生命周期缓存，并在 Settings 窗口打开或 IPC `editor.describe` 到来时刷新。无 `$PATH`、无 `stat`、无 `which`。

2. **启动 = 按类别分三支。**
   - **`.directory` 模式** — `NSWorkspace.open(urls:withApplicationAt:configuration:)`，传单个目录 URL。覆盖编辑器（Cursor、Zed、VSCode、Windsurf、Antigravity、Sublime、Xcode、…）、终端（Ghostty、WezTerm、Alacritty、Kitty、Warp、Terminal.app）、git 客户端（GitHub Desktop、Sourcetree、Fork、GitKraken、Sublime Merge、SmartGit、GitUp）与 Finder。
   - **`.applicationWithArguments` 模式** — `NSWorkspace.openApplication(at:configuration:)`，置 `configuration.arguments = [dir]` + `createsNewApplicationInstance = true`。**仅 JetBrains 家族**（IntelliJ、WebStorm、PyCharm、RubyMine、RustRover、Android Studio）。**为什么不用 `open(urls:…)`：** JetBrains IDE 期望目录经 `configuration.arguments` 到达；走 `open(urls:…)` 它们会聚焦上一次打开的窗口、忽略参数，在错误的工程里打开。这是承重的——以空 URL 列表调 `open(urls:…)` 是未定义行为，也不会把 `configuration.arguments` 转发给被启动应用。
   - **`.shellEditor` 模式** — `.editor` 这一特例。在目标目录新建一个 Pane 并把 `$EDITOR` 作为输入发出；用户登录 shell 用自己的环境展开 `$EDITOR`。无 bundle id、无 LS 介入。它需要终端 / Pane 侧暴露"在某路径建 Pane 并带初始输入"原语——见下方"`.shellEditor` 的落地姿态"。

   无 `Process` spawn、无 argv 替换、无 env 白名单、无 5 秒超时。干活的是内核（`.directory` / `.applicationWithArguments`）或 Pane 的 shell（`.shellEditor`）。

3. **优先级自动解析。** 未设默认时，沿一条拼接的优先级链（`editorPriority + [xcode] + terminalPriority + gitClientPriority + [finder]`）走，挑第一个已安装的。**Finder 永远在链尾**——若它出现在中段，优先级游走会停在那里（Finder 永远已安装），把其后每个终端 / git 客户端条目都遮掉。每次 resolve 都重算，所以装一个更高优先级的编辑器在下一次打开即生效，无需重启。

4. **UX 后果：一个下拉、仅已安装、固定菜单序。** Settings "Default editor" 面板是单个 `Picker`，按 `menuOrder` 列出已安装条目，每行经 `NSWorkspace.shared.icon(forFile:)` 显示真实 `.app` 图标（`.editor` 用通用终端字形）。无 tab、无 Custom 段、无安装状态列。Project Options sheet 里的 per-Project override 用同一 picker，外加一行"Use global default"。

5. **Path 进，别无他物。** 服务 API 是 `(directory: URL, preferred: EditorID?)`。调用方在派发前把自身上下文化成 `URL`——没有域类型穿过服务边界。Per-Project 默认编辑器 override 作为特性**保留**，但在服务**外**解析：调用方（TCA `EditorFeature` reducer 或 IPC handler）查出所属 `Project`、读其 override、过滤到已安装、把结果作为 `preferred` 传给服务。服务只见 `EditorID?`，从不见 `ProjectID`。

### System Context Diagram

```
 ┌──────────────────────────────────────────────────────────────────┐
 │  codans app                                                        │
 │                                                                    │
 │  Callers (resolve context → URL)     Settings · General pane       │
 │  ┌─────────────────────────┐         ┌──────────────────────┐      │
 │  │ Worktree header button  │         │ Default editor:      │      │
 │  │ Git client (⌘⌥G chord)  │◀── same │   🅲 Cursor      ▼   │      │
 │  │ CLI `codans open [path]`│   list  │ (installed only)     │      │
 │  │ Future deeplink handler │         └──────────────────────┘      │
 │  └──────────┬──────────────┘                                       │
 │             │ open(directory: URL, preferred: EditorID? = nil)     │
 │             ▼                                                      │
 │  ┌────────────────────────────────────────────────────────┐       │
 │  │  EditorService (in-app; @Dependency wired)             │       │
 │  │  ├── describe()  → [EditorDescriptor] (installed)      │       │
 │  │  ├── resolve(preferred) → EditorDescriptor             │       │
 │  │  └── open(directory, preferred) async throws           │       │
 │  └────────────┬──────────────────────┬──────────────────┬─┘       │
 │               │                      │                  │         │
 │        ┌──────▼──────────┐    ┌──────▼────────┐    ┌────▼─────┐   │
 │        │  AppLauncher    │    │ SettingsStore │    │  Pane    │   │
 │        │  (NSWorkspace)  │    │ defaultEditor │    │  spawner │   │
 │        │ urlForApp / open│    │ ID (read)     │    │ ($EDITOR)│   │
 │        └──────┬──────────┘    └───────────────┘    └──────────┘   │
 │               ▼                                                    │
 │       macOS Launch Services                                        │
 └──────────────────────────────────────────────────────────────────┘
```

运行时路径上不出现 `Foundation.Process`、`PathProber`、`EditorEnv`、`ProcessSpawner`、`SpawnContract`、`CommandTemplate`、`CustomEditor`——干活的只有 `AppLauncher` 这层对 `NSWorkspace` 的封装。

### API 设计

#### EditorService 协议

```swift
protocol EditorService: Sendable {
  func describe() async -> [EditorDescriptor]                            // installed only
  func resolve(preferred: EditorID?) async throws -> EditorDescriptor
  @discardableResult
  func open(directory: URL, preferred: EditorID?) async throws -> EditorChoice
}
```

`describe()` 的契约：**只返回已安装**编辑器（与"未安装 → 不可见"的 UX 一致，服务自身过滤）。签名里没有 `projectID`、`worktreeID` 或任何 catalog 类型——服务收一个 URL、返回一个选择，这就是全部耦合。`EditorChoice` 带 `id / displayName / binaryPath?`，**不含** `argv: [String]`（经 LS 启动时没有 argv，外部也无消费方）。

#### EditorDescriptor

```swift
struct EditorDescriptor: Identifiable, Equatable, Sendable {
  let id: EditorID                    // "cursor" | "zed" | "editor" | ...
  let displayName: String
  let bundleIdentifier: String        // empty string for .shellEditor
  let launchMode: LaunchMode
  let appURL: URL?                    // nil for .shellEditor; otherwise resolved from LS
  let alternateBundleIdentifiers: [String]
  enum LaunchMode: Equatable, Sendable {
    case directory                    // NSWorkspace.open(urls:withApplicationAt:configuration:)
    case applicationWithArguments     // NSWorkspace.openApplication(at:configuration:) with args
    case shellEditor                  // new Pane, send "$EDITOR" to stdin
  }
}
```

`EditorID` 是 `String`（开放 allowlist 用字符串而非枚举：`Project.defaultEditor` 已是 `String?`，无需让 `CodansCore` 知道 App 层概念）。从 `describe()` 中**缺席**即"未安装"信号——无需 `InstallationStatus` 枚举。`.shellEditor` 永远视为已安装（它回退到 shell 对 `$EDITOR` 的解析）。

#### 内建注册表（34 条）

| `id` | Display | Bundle ID | Launch mode | Category |
|---|---|---|---|---|
| `cursor` | Cursor | `com.todesktop.230313mzl4w4u92` | directory | editor |
| `zed` | Zed | `dev.zed.Zed` | directory | editor |
| `vscode` | Visual Studio Code | `com.microsoft.VSCode` | directory | editor |
| `windsurf` | Windsurf | `com.exafunction.windsurf` | directory | editor |
| `vscodeInsiders` | VSCode Insiders | `com.microsoft.VSCodeInsiders` | directory | editor |
| `vscodium` | VSCodium | `com.vscodium` | directory | editor |
| `sublimeText` | Sublime Text | `com.sublimetext.4`（alt `com.sublimetext.3`） | directory | editor |
| `intellij` | IntelliJ IDEA | `com.jetbrains.intellij` | applicationWithArguments | editor |
| `webstorm` | WebStorm | `com.jetbrains.WebStorm` | applicationWithArguments | editor |
| `pycharm` | PyCharm | `com.jetbrains.pycharm` | applicationWithArguments | editor |
| `rubymine` | RubyMine | `com.jetbrains.rubymine` | applicationWithArguments | editor |
| `rustrover` | RustRover | `com.jetbrains.rustrover` | applicationWithArguments | editor |
| `androidStudio` | Android Studio | `com.google.android.studio` | applicationWithArguments | editor |
| `antigravity` | Antigravity | `com.google.antigravity` | directory | editor |
| `trae` | Trae | `com.trae.app` | directory | editor |
| `traeCN` | Trae CN | `cn.trae.app` | directory | editor |
| `qoder` | Qoder | `com.qoder.ide` | directory | editor |
| `codebuddy` | CodeBuddy | `com.tencent.codebuddy`（alt `com.tencent.codebuddycn`） | directory | editor |
| `xcode` | Xcode | `com.apple.dt.Xcode` | directory | editor |
| `finder` | Finder | `com.apple.finder` | directory | (always) |
| `ghostty` | Ghostty | `com.mitchellh.ghostty` | directory | terminal |
| `wezterm` | WezTerm | `com.github.wez.wezterm` | directory | terminal |
| `alacritty` | Alacritty | `org.alacritty` | directory | terminal |
| `kitty` | Kitty | `net.kovidgoyal.kitty` | directory | terminal |
| `warp` | Warp | `dev.warp.Warp-Stable` | directory | terminal |
| `terminal` | Terminal | `com.apple.Terminal` | directory | terminal |
| `githubDesktop` | GitHub Desktop | `com.github.GitHubClient` | directory | git client |
| `sourcetree` | Sourcetree | `com.torusknot.SourceTreeNotMAS` | directory | git client |
| `fork` | Fork | `com.DanPristupov.Fork` | directory | git client |
| `gitkraken` | GitKraken | `com.axosoft.gitkraken` | directory | git client |
| `sublimeMerge` | Sublime Merge | `com.sublimemerge` | directory | git client |
| `smartgit` | SmartGit | `com.syntevo.smartgit` | directory | git client |
| `gitup` | GitUp | `co.gitup.mac` | directory | git client |
| `editor` | `$EDITOR` | —（空串） | shellEditor | (always) |

合计 34 条：18 编辑器 + Xcode + Finder + 6 终端 + 7 git 客户端 + `$EDITOR`。优先级列表：

```swift
static let editorPriority: [EditorID] = [
  "cursor", "zed", "vscode", "windsurf", "vscodeInsiders", "vscodium", "sublimeText",
  "intellij", "webstorm", "pycharm", "rubymine", "rustrover", "androidStudio",
  "antigravity", "trae", "traeCN", "qoder", "codebuddy",
]
static let terminalPriority: [EditorID] = [
  "ghostty", "wezterm", "alacritty", "kitty", "warp", "terminal",
]
static let gitClientPriority: [EditorID] = [
  "githubDesktop", "sourcetree", "fork", "gitkraken", "sublimeMerge", "smartgit", "gitup",
]
// Finder 在链尾——若它出现在中段，优先级游走会停在那里并遮掉其后所有条目。
static let defaultPriority: [EditorID] =
  editorPriority + ["xcode"] + terminalPriority + gitClientPriority + ["finder"]
static let menuOrder: [EditorID] =
  editorPriority + ["xcode"] + ["finder"] + terminalPriority + gitClientPriority + ["editor"]
```

新增条目是两行代码改动（注册表一行 + 优先级插入一行）。

#### 解析链——跨两层拆分

**调用方层**（TCA `EditorFeature` 或 IPC handler）决定传什么作为 `preferred`：

```
userExplicitPick   (下拉点击、`codans open --in …`)
  → 作为 `preferred` 严格传入（未安装则抛错：用户点名要的）
否则若无用户点选：
projectOverride    (经路径做 hierarchy lookup 得 project.defaultEditor)
  → 已安装则作为 `preferred` 传入；未安装则传 nil（宽容：静默穿过）
```

**服务层**（`EditorService.open`）随后级联：

```
preferred (来自调用方)     → nil 则跳过；已设且未安装则抛 .notInstalled
 ↓
Settings.defaultEditorID   → 已安装则用，否则跳过
 ↓
priority 自动挑选          → defaultPriority 链里第一个已安装的
 ↓ 总是收尾于
Finder
```

为何拆分级联：**strict vs lenient** 的区别关乎*一个缺失编辑器如何被处理*，而非*它来自哪个层级*。显式用户点选是 strict（响亮报错："Cursor is not installed"）；任何存储默认（project 或 global）是 lenient（静默穿过）。把严格性边界放在服务的 `preferred` 参数上——"已设即 strict"——让服务对 ID 的出处一无所知，同时仍兑现正确 UX。

#### IPC

- `editor.describe` → `[EditorDescriptor]`（载荷为 `EditorDescriptor` 字段，不含 `argv`）。
- `editor.open { path: String, preferred?: EditorID }` → `EditorChoice`。
  - `path` **必填**，须是绝对目录路径。调用方（含 CLI）各自把上下文解析成路径；`codans open` 无参时用 `$PWD`。
  - `preferred` 可选；用户跑 `codans open --in <editor>` 时给。
  - `preferred` 缺席时，IPC handler 做 `hierarchyClient.project(containing: path)?.defaultEditor`，若该 ID 已安装则作为服务 `preferred` 传入——让 CLI 调用与应用内"点 Open"行为一致，两者都静默尊重 per-Project override。这次 lookup 只发生在 handler 一处，服务自身从不 import `HierarchyClient`。
  - 响应不含 `argv`。
- `editor.setGlobalDefault { editorID? }` → `void`。写 `settings.general.defaultEditorID`；`null` 清除。per-Project 默认住在下面 `editor.setProjectDefault` 上，故全局默认单列此动作。对应方法枚举 case 是 `editorSetGlobalDefault`、字符串值 `"editor.setGlobalDefault"`。
- `editor.setProjectDefault { projectID: UUID, editorID? }` → `void`。经 `HierarchyClient` 写 `Settings.projects[pid].defaultEditor`；由 Project Options sheet 调用，`null` 清除 override。

不提供 `editor.customEditors.*`（custom editors 无 IPC 方法，亦无 settings 表面）。

#### 图标访问

```swift
let icon: NSImage = NSWorkspace.shared.icon(forFile: descriptor.appURL.path)
```

SwiftUI 里 `Image(nsImage:)` 配 `.resizable().frame(...)`。无需缓存——LS 已缓存。

### 数据存储

无新文件，三个字段：

| Owner | Key | 形态 |
|---|---|---|
| `settings.json` | `general.defaultEditorID: EditorID?` | 全局默认编辑器，仅内建注册表 ID |
| `settings.json` | `general.defaultGitViewerID: EditorID?` | 全局默认 git 客户端（供 `⌘⌥G` chord 在外部 git 客户端打开当前 Worktree），仅内建注册表 ID |
| `settings.json` / catalog | `Project.defaultEditor: EditorID?` | per-Project override；不在注册表的 ID 加载时归一为 `nil` |

`general.customEditors`（旧版 custom-editor 模板）不再写出；若旧 `settings.json` 里存在则宽容解码并忽略（迁移语义见下）。

**迁移**（启动 decode 后跑一次）：忽略任何旧 `general.customEditors`（`.info` 记录，不告警用户）；`general.defaultEditorID` 若不在新内建注册表则置 `nil`（下次解析穿透到优先级自动挑选）；任何 `Project.defaultEditor` 若不在注册表则置 `nil`。不升 schema 版本（codans 的 settings/catalog 读取器对未知键宽容）。**两个方向回滚都安全**——容忍式迁移。

### 组件边界

```
apps/mac/codans/App/Clients/Editor/
├── EditorService.swift          ─ protocol
├── EditorService+Live.swift     ─ live：用 AppLauncher + NSWorkspace
├── EditorService+Test.swift     ─ test double
├── EditorRegistry.swift         ─ 内建 allowlist + bundle IDs + 优先级
├── EditorModels.swift           ─ EditorDescriptor, EditorChoice, EditorID, LaunchMode
├── EditorError.swift            ─ .notInstalled / .launchFailed / .notADirectory
└── AppLauncher.swift            ─ protocol + LiveAppLauncher (NSWorkspace facade)
```

`AppLauncher` 是新的缝，暴露三个方法（probe + 两种启动）：

```swift
protocol AppLauncher: Sendable {
  func urlForApplication(bundleIdentifier: String) async -> URL?
  func open(urls: [URL], withApplicationAt appURL: URL,
            configuration: NSWorkspace.OpenConfiguration) async throws
  func openApplication(at appURL: URL,
            configuration: NSWorkspace.OpenConfiguration) async throws
}
```

Live 实现包 `NSWorkspace.shared`。测试用 `RecordingAppLauncher`，逐编辑器校验 `(appURL, urls, configuration.arguments, configuration.createsNewApplicationInstance)` 与预期一致。`LiveEditorService` 是个 `actor`，用以廉价地为 `describe()` 缓存加互斥锁；`clearCache()` 在 Settings 面板 appear 与 IPC `editor.describe` 时调用，使新装编辑器无需重启即可浮现。

**职责：** `EditorService` 管解析逻辑、`describe()` 结果缓存、回退链；`AppLauncher` 是 `NSWorkspace` 抽象——**唯一**在测试代码外 import `NSWorkspace` 的地方；`EditorRegistry` 是静态条目模板表。**不负责：** 服务不管 UI、不管存选择、不管 IPC 传输、不管图标渲染；`AppLauncher` 不管业务逻辑或解析——它只打开被告知的东西。

### `.shellEditor` 的落地姿态

`.editor` 经 `describe()` 出现在 picker 里（永远已安装），但**经本服务实际启动 `$EDITOR` 当前会抛 `.launchFailed`**。原因是结构性的：`.shellEditor` 需要一个 `(spaceID, projectID, worktreeID, tabID)` 元组交给 `HierarchyManager.openPane`，而服务签名刻意排除域类型（见"Path 进，别无他物"）。Pane 侧原语本身已就绪——`TerminalEngine.ensureSurface` 已把 `pane.initialCommand` 转发给新 spawn 的 shell——缺的只是让这个 path-only 服务去寻址一个 Pane 的途径。

落地选择：保留注册表条目的形状（让 picker 列出它），但经服务打开时抛一个描述性错误，把这个未解的设计问题浮现出来，而非静默 no-op。想让 `.shellEditor` 端到端工作的调用方应走 Pane/Tab 感知的代码路径（如 Worktree header "Open in ▾"，或未来一个接到 `hierarchy.openPane` 的 `codans open --in editor`，把 `initialCommand` 设为 `"$EDITOR"`）。

### 错误处理

| Error | Cause | UI |
|---|---|---|
| `.notInstalled(id, bundleID)` | 显式 preferred 编辑器在 LS 上找不到 | Toast："Cursor is not installed." |
| `.launchFailed(reason)` | `NSWorkspace.open` 回调返回 `Error`，或 `.shellEditor` 无 Tab 上下文 | Toast："Could not open in Cursor: <reason>" |
| `.notADirectory(path)` | 目标路径不存在或非目录（`open` 前以 `FileManager.fileExists(isDirectory:)` 校验） | Toast："Directory not found: <path>" |

错误集合仅此三个。没有 `.nonZeroExit` / `.timedOut` / `.spawnFailed` / `.badTemplate` / `.unresolvedWorktree`：LS 路径无超时（内核异步打开 bundle，调用在 LS 派发后即返回）、无退出码，CLI 也总是发路径（默认 `$PWD`），不存在 CLI 专属失败模式。

## 备选方案（Alternatives）

- **A1 — `Process`+`PATH` 探测，加常见前缀回退**（`/opt/homebrew/bin`、`/usr/local/bin`、in-bundle shim 硬编码路径）。否决：只对跑过 "Install 'code' command" 的用户修好检测；新装 VSCode 没 shim；Cursor / Zed 有版本相关的自有 shim；路径硬编码会腐烂；对 JetBrains（无 CLI shim 模型）与 Xcode 毫无帮助。修了可见症状，留下结构问题。
- **A2 — 混合：NSWorkspace 检测，Process 启动。** 否决：检测与启动走不同机制意味着一个编辑器可"被检测"（bundle 存在）却"不可启动"（用户从未装 shim）——正是当前 bug 的反转版。无消费方需要 `argv`。每编辑器两种失败模式。
- **A3 — 注册表只留代码编辑器**，砍掉终端 / git 客户端（理由：codans 自带终端 Pane）。否决：抢先替用户做选择。有人就想要 Warp 的 AI、第二屏上的 Ghostty、或 GitHub Desktop 的 PR UI。保留它们的成本是 Swift 枚举里约 20 行，收益是"没人需要问 X 去哪了"。全部保留。
- **A4 — 在 NSWorkspace 旁并存 CustomEditor 模板。** 当前否决：会引入一整套复杂度（custom 二进制的 PATH 探测、Process spawner、超时契约、env 白名单、模板校验器、"是不是 shell"启发式），服务对象尚未真正提出诉求。若日后需求浮现，作为单独的"Advanced"面板加回。
- **A5 — 单下拉但无自动默认，用户必须先选。** 否决：每次全新安装都摩擦。优先级游走对约 99% 用户是对的（Cursor/Zed/VSCode 里装了哪个几乎就是他们会选的）；那 1% 选错只需一次下拉点击改正。

## Cross-Cutting Concerns

### 安全

- **攻击面缩小。** 无 `Process`、无 argv 替换、无 env 白名单、无 shell 顾虑。剩下的面是"LS 在一个由字符串标识的 bundle 里打开一个目录"——一条踏实的 macOS 路径。
- **Quarantine / Gatekeeper。** LS 代 codans 处理 quarantine 提示；bundle 被隔离时用户见到 OS 标准对话框而非 codans 错误。
- **Deeplink 风险。** 若未来 `codans://` URL 请求 `editor.open` 带一个不在内建注册表的 `preferred` ID，服务拒绝它——没有用户提供的模板可被武器化。封闭 allowlist 本身即是这条边界。

### 可观测性

- `os.Logger` category `com.gumpw.codans.editor`。每次 resolve（编辑器 ID + 目录路径）与每次启动（成败）记 `.info`；迁移异常（未知 `defaultEditorID`、出现旧 `customEditors`）记 `.error`。
- 无启动 wall-clock signpost——LS 近乎即时返回，有意义的延迟在编辑器自身冷启动，这里测不到。

### 可测试性

测试矩阵大幅收缩：`EditorRegistry` 表驱动（每 ID 唯一 bundle id、无冲突、`defaultPriority` 顺序符合预期）；`EditorService` 解析（fake `AppLauncher.urlForApplication` 返回受控子集，覆盖各层 + stale-default 穿透 + stale-explicit 抛错）；`EditorService` 启动（fake `open` / `openApplication`，校验 JetBrains 分支用 `configuration.arguments + createsNewApplicationInstance=true`，非 JetBrains 分支用 `open(urls:withApplicationAt:)` 传目录 URL）；迁移（解码带旧 `customEditors` + stale `defaultEditorID` 的 settings，校验归一）；集成冒烟（门控于 `TC_RUN_EDITOR_INTEGRATION_TESTS=1`，真问 LS `com.apple.finder` 并 `open` 一个临时目录）。

## 风险

- **R1 — ToDesktop 式 bundle id 漂移。** Cursor 的 bundle id 是 ToDesktop 哈希（`com.todesktop.230313mzl4w4u92`）；若未来 Cursor 改 ID 重新发布，检测会漏。**缓解：** 每条 descriptor 带 `alternateBundleIdentifiers: [String]`，先探主、再穿透备选；shim 移动时更新列表（代码改动）。
- **R2 — JetBrains 特例漂移。** 若 JetBrains 改变其应用经 `configuration.arguments` 接收 folder-open 的方式，这一支会静默失效（应用启动、目录被忽略）。**缓解：** 每次发布在一个 JetBrains IDE 上手动冒烟；若实践中脆弱，改用 `ides-openFolder` URL scheme 作为逐编辑器 override。
- **R3 — LS 挑错 Xcode 版本。** 用户同时装 Xcode 与 Xcode-beta，LS 挑"默认"那个。**缓解：** 记为已知限制；后续考虑单独的 `xcodeBeta` descriptor（bundle id `com.apple.dt.Xcode-beta`）。
- **R4 — 首装竞态。** 用户在 codans 运行中装了 Cursor，缓存的 `describe()` 仍说它缺。**缓解：** `describe()` 在 Settings 面板可见与 IPC `editor.describe` 时重探（`clearCache()`），够用且避免轮询。
- **R5 — niche 编辑器无逃生口。** 没有 custom-editor 模板，注册表外的编辑器（如 Helix）无法配置。**缓解：** 有诉求就把它加进内建注册表（两行改动）。`customEditors` 表面据日志无已知用户，缺失这条逃生口的影响半径近零。
- **R6 — `NSWorkspace.open` 异步回调吞错。** 回调式 API 经 completion handler 返回错误，接线失误可能静默丢错。**缓解：** 用 `withCheckedThrowingContinuation` 包裹；单测断言成功与失败路径下 continuation 恰好 resume 一次。

## 已锁定的不变量

1. **机制。** NSWorkspace / Launch Services 用于检测**与**启动。无 `Process`、无 `$PATH`、无 CLI shim。
2. **发现。** 逐内建条目 `NSWorkspace.urlForApplication(withBundleIdentifier:)`，缓存；Settings-appear 与 IPC `editor.describe` 时刷新。
3. **内建 allowlist。** 34 条——18 编辑器 + Xcode + Finder + 6 终端 + 7 git 客户端 + `$EDITOR`。新增是代码改动。
4. **回退顺序（跨两层）。** 显式 → Project override → 全局默认 → Finder。
5. **显式 preferred 不静默穿透。** 缺失的显式 preferred 抛错，UI 浮现错误而非打开另一个编辑器；任何存储默认（project/global）才宽容穿透。
6. **解析级联——跨两层拆分。** 调用方把 `userExplicitPick ?? (projectOverride if installed)` 解析成单个 `preferred`；服务随后级联 `preferred`（strict）→ `Settings.defaultEditorID`（lenient）→ 优先级自动挑选 → Finder。
7. **范围。** 仅 Worktree 目录。无文件级、行级、diff 级打开。
8. **存储。** `settings.json` 的 `defaultEditorID` + `Project.defaultEditor` 的 per-Project override；无 `customEditors`。

不存在 5 秒超时或 SIGTERM/SIGKILL spawn 契约——LS 路径无 `Process` spawn。
