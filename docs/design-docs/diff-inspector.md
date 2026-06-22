# 设计文档：Diff Inspector

**状态：** 前瞻设计（forward-looking）——契约已定，实现尚未落地。截至本次修订，`apps/mac/codans/App/Features/Diff/` 尚不存在；先行落地的只有 `CommandID.toggleDiffInspector` 标识符及其钉死的 JSON raw value（见下方"重命名"）。本设计描述目标形态与承重不变量。
**作者：** Gump

## 背景

旧的 `GitViewer` 在 360 pt 右缘 overlay 里展示 working / staged / log 三个 scope tab。本设计用一个更窄的两件套替换它：一个 280 pt 右缘 **Diff inspector** 列出当前 Worktree 的变更文件，外加一个按需 **drawer** 用单文件 diff 铺满整个终端区域。

Diff 渲染复用 YiTong 的 WKWebView bundle（Apache-2.0，**vendored**——不作为 Swift package 导入），它包裹了 `@pierre/diffs`（Apache-2.0）+ Shiki + `kpdecker/jsdiff`（BSD-3-Clause）。

## 目标

本变更后用户可观测的行为：

- ⌘⇧G / Header GV 按钮 / Command Palette "Toggle Git Viewer" 显示 per-Worktree 的 Diff inspector。可见性 per-Worktree 持久化。
- Inspector 列出所有工作树变更，带状态 + `+adds / −dels`。
- 点击文件行 → drawer 从右滑入并铺满终端区域。
- Drawer header 带 unified ↔ split 选择器；选择经 `@AppStorage("diffStyle")` 持久化。
- Diff 经 Shiki 语法高亮，带词级 inline 高亮与可选中文本。
- 关 drawer：经 `×` 按钮**或**该行的 ▶ chevron（反向操作）。
- Sidebar / Command Palette / TabBar 在 inspector + drawer 可见时仍可交互。
- Diff 组件自包含，可复用于未来的 commit-detail / blame / stash 表面。

## 非目标

- Commit log / history 视图（推迟）。
- 从 inspector 暂存 / 取消暂存（只读）。
- Schema 向后兼容。`Worktree.gitViewerVisible` **直接**改名为 `Worktree.diffInspectorVisible`，不做 alias 解码。
- 从 npm 打包 `@pierre/diffs`；我们 vendor 预打包好的 JS，无 Node 工具链。
- 跨平台对等。仅 macOS。

## 架构

### 布局

默认（未选文件）：

```
┌────────┬────────────────────────────┬────────────────┐
│        │                            │ Changes (3)    │
│ Side   │  Terminal / Code           │  ─────────     │
│ bar    │                            │   path/A.swift │
│        │                            │   path/B.swift │
└────────┴────────────────────────────┴────────────────┘
```

点击文件 B 后：

```
┌────────┬─────────────────────────────────┬────────────────┐
│        │  TabBar  (visible, unchanged)   │ Changes (3)    │
│        ├─────────────────────────────────┤  ─────────     │
│ Side   │                                 │   path/A.swift │
│ bar    │  Diff drawer for B              │   path/B ◀     │
│        │  (covers entire terminal region)│   path/C.swift │
└────────┴─────────────────────────────────┴────────────────┘
```

**Inspector** — 经 `.inspector(isPresented:)` 挂在 detail-column 子树上（macOS 14+）。宽度固定 280 pt。可见性绑定 `RootFeature.diffInspectorVisible(in:)`。

**Drawer** — 经 `.overlay { ... }` 挂在 `WorktreeDetailView.terminalRegion`，边到边铺满整个终端区域。经 `.move(edge: .trailing).combined(with: .opacity)` + `.spring(response: 0.32, dampingFraction: 0.85)` 滑入。终端在其下保持挂载。Z 序：terminal `0`、drawer `80`、command palette `100`，SwiftUI sheet 在所有之上。

### Diff 组件

```
DiffRendererView (NSViewRepresentable)
        │
        ▼
   DiffWebView (WKWebView)
        │  loads WebAssets/index.html
        │  bridge: WKScriptMessageHandler + evaluateJavaScript
        ▼
   DiffWebViewBridge — encode(document, config) ↔ decode(host event)
        │  protocolVersion: 1
        ▼
   vendored renderer.js (来自 YiTong v0.1.0；包裹 @pierre/diffs + Shiki)
```

Vendored web 资产：

```
apps/mac/codans/App/Features/Diff/WebAssets/
├── index.html
├── renderer.js
├── renderer.css
├── manifest.json
└── LICENSE
```

来源：YiTong v0.1.0 的 `Sources/YiTongWebAssets/Resources/`。**tag 是 `0.1.0`，无 `v` 前缀**。

### Bridge 协议（v1）

实际跨语言词汇以 YiTong renderer.js 真实导出为准（不是早期设计想象的 `setOptions` / `render`）：

| 方向 | 消息 | 载荷 |
|---|---|---|
| host → web | `initialize` | `{ document, configuration }`（含 `resolvedAppearance: "dark" \| "light"`） |
| host → web | `renderDocument` | `DiffDocument` |
| host → web | `updateConfiguration` | `DiffConfiguration`（含 `resolvedAppearance`） |
| host → web | `teardown` | —（销毁渲染态） |
| web → host | `ready` | `{ rendererVersion }` |
| web → host | `renderStateChanged` | `{ phase, fileCount?, error? }` |
| web → host | `lineActivated` | `{ fileIndex, lineNumber, side }` |
| web → host | `selectionChanged` | `{ selection: SelectionRange? }` |

每条消息裹一个 `protocolVersion: 1` 信封；版本不匹配以 `DiffEvent.didFail(code: "protocol_mismatch", ...)` 浮现。`manifest.protocolVersion` 在单测里对 Swift bridge 期望版本断言。

## Public API

`apps/mac/codans/App/Features/Diff/Public.swift`：

```swift
public struct DiffDocument: Equatable, Sendable {
  public let files: [DiffFile]
  public let title: String?
  public let fallbackPatch: String?
  public init(files: [DiffFile], title: String? = nil, fallbackPatch: String? = nil)
}

public struct DiffFile: Equatable, Sendable, Identifiable {
  public var id: String { newPath ?? oldPath ?? "" }
  public let oldPath: String?
  public let newPath: String?
  public let oldContents: String
  public let newContents: String
}

public struct DiffConfiguration: Equatable, Sendable {
  public var appearance: DiffAppearance = .automatic
  public var style: DiffStyle = .unified
  public var indicators: DiffIndicators = .bars
  public var showsLineNumbers: Bool = true
  public var showsChangeBackgrounds: Bool = true
  public var wrapsLines: Bool = false
  public var showsFileHeaders: Bool = true
  public var inlineChangeStyle: InlineChangeStyle = .wordAlt
  public var allowsSelection: Bool = true
  public init() {}
}

public enum DiffAppearance: String, Equatable, Sendable { case automatic, light, dark }
public enum DiffStyle: String, Equatable, Sendable { case unified, split }
public enum DiffIndicators: String, Equatable, Sendable { case bars, classic, none }
public enum InlineChangeStyle: String, Equatable, Sendable { case wordAlt, word, char, none }

public enum DiffEvent: Equatable, Sendable {
  case didFinishInitialLoad
  case didRender(fileCount: Int)
  case didClickLine(fileIndex: Int, lineNumber: Int)
  case didChangeSelection(SelectionRange?)
  case didFail(code: String, message: String)
}

public struct SelectionRange: Equatable, Sendable {
  public let fileIndex: Int
  public let start: Int
  public let end: Int
  public let side: SelectionSide
}

public enum SelectionSide: String, Equatable, Sendable { case additions, deletions, both }

public struct DiffRendererView: View {
  public let document: DiffDocument
  public let configuration: DiffConfiguration
  public let onEvent: ((DiffEvent) -> Void)?
  public init(
    document: DiffDocument,
    configuration: DiffConfiguration = .init(),
    onEvent: ((DiffEvent) -> Void)? = nil
  )
  public var body: some View
}
```

## TCA State

`apps/mac/codans/App/Features/Diff/DiffFeature.swift`：

```swift
@Reducer
struct DiffFeature {
  @ObservableState
  struct State: Equatable {
    var worktreeID: WorktreeID?
    var projectID: ProjectID?
    var worktreePath: String?

    var changedFiles: ChangedFilesState = .idle
    var presentedFilePath: String?
    var diffsByPath: [String: DiffEntryState] = [:]
    var style: DiffStyle = .unified
  }

  enum ChangedFilesState: Equatable {
    case idle, loading, loaded([ChangedFile]), error(GitError)
  }

  enum DiffEntryState: Equatable {
    case loading
    case loaded(DiffDocument)
    case error(GitError)
    case tooLarge(reason: TooLargeReason, copyCommand: String)
  }

  enum TooLargeReason: Equatable {
    case byteCount(Int), lineCount(Int), binary
  }
  // ... Actions: worktreeSelected / refreshRequested / changedFiles{Succeeded,Failed}
  //     / fileRowTapped / drawerCloseRequested / diff{Succeeded,Failed,TooLarge}For / styleChanged
}

struct ChangedFile: Equatable, Identifiable, Sendable {
  var id: String { newPath ?? oldPath ?? "" }
  let oldPath: String?
  let newPath: String?
  let status: ChangeStatus    // modified | added | deleted | renamed
  let addedLines: Int
  let removedLines: Int
  let isBinary: Bool
}
```

**大 diff 上限：** `maxFileBytes = 500_000`、`maxFileLines = 5_000`、二进制永远视为 too-large。超过上限的 drawer 渲染一个占位 + Copy-command 按钮（而非把巨型 diff 灌进 WebView）。

**`Equatable` 与引用包裹（承重）。** TCA State 是个 enum，父级每次重估都对其 payload 走全量 `Equatable`。把大 diff 值（≤500 KB 上限）**用引用类型包裹**，使身份等值变成 O(1)——否则每次 reducer 重估都要逐字节比较整份 diff。

## 组件边界

### 新模块 — `apps/mac/codans/App/Features/Diff/`

```
Diff/
├── DiffFeature.swift                ← TCA reducer
├── Public.swift                     ← public surface
├── Internal/
│   ├── DiffWebView.swift            ← NSViewRepresentable wrapper
│   ├── DiffWebViewBridge.swift      ← JS ↔ Swift bridge codec
│   └── DiffWebViewCoordinator.swift ← WKScriptMessageHandler
├── Views/
│   ├── DiffInspectorView.swift      ← inspector column body
│   ├── DiffFileRow.swift            ← one file row
│   ├── DiffDrawerView.swift         ← drawer container + close button
│   └── DiffStylePicker.swift        ← unified ↔ split toggle
└── WebAssets/
    ├── index.html
    ├── renderer.js
    ├── renderer.css
    ├── manifest.json
    └── LICENSE
```

**`updateNSView` 与稳定 document id（承重）。** `DiffRendererView` 作为 `NSViewRepresentable`，其 `updateNSView` 在每次重估（几何变化、colorScheme tick）都会触发。WebView bridge 因此需要一个**确定性的 document id**（**不是**每次调用 `UUID()`），外加一个 send-cache，避免在每个几何 / 配色变化 tick 上重新 tokenize 整份 diff。

### 重命名（无 schema alias；Codable key 与 Swift 标识符一起改）

| Before | After |
|---|---|
| `Worktree.gitViewerVisible` | `Worktree.diffInspectorVisible` |
| `HierarchyClient.setWorktreeGitViewerVisible` | `setWorktreeDiffInspectorVisible` |
| `RootFeature.gitViewerOverlayVisible(in:)` | `diffInspectorVisible(in:)` |
| `RootFeature.Action.gitViewerToggledForCurrentWorktree` | `diffInspectorToggledForCurrentWorktree` |
| `RootFeature.Action.toggleGitViewer` | `toggleDiffInspector` |
| `WorktreeHeaderFeature.Action.gitViewerToggleTapped` | `diffInspectorToggleTapped` |
| `.delegate(.gitViewerToggleRequested)` | `.delegate(.diffInspectorToggleRequested)` |
| `HeaderGitViewerToggle` view | `HeaderDiffInspectorToggle` |
| ⌘⇧G shortcut catalog command-id `toggleGitViewer` | Swift 标识符 `toggleDiffInspector`；**JSON raw value 钉死为 `toggleGitViewer`**，以免孤立既有用户快捷键 override——override store 以 `CommandID.rawValue` 为持久化 key。**模式：改 Swift 标识符，钉死 raw value。** |
| `RootFeature.State.gitViewer` | `RootFeature.State.diff` |
| `RootFeature.Action.gitViewer(...)` | `RootFeature.Action.diff(...)` |

用户可见字符串（"Git Viewer"、菜单项标签）v1 不变。

> 落地状态注记：上表里**仅** `CommandID.toggleDiffInspector`（标识符 + 钉死的 raw value `toggleGitViewer`）已在代码中落地（`CommandPaletteItem`/`RootFeature`/`MainWindowCommands` 等引用它）。其余重命名连同整个 `Diff/` 模块尚未落地。

## 备选方案（Alternatives）

- **A — 手搓纯 SwiftUI diff 渲染器。** 否决：到达功能对等（split + 语法高亮 + 词级 inline + selection + 主题集成）估计 9–10 人日；Swift/WebKit 在语法高亮上差距大（需 Splash 管 Swift、Highlightr 管其余，后者本就在 WKWebView 里嵌 highlight.js），且 `AttributedString` 只部分支持逐 token 处理。相对 vendor 现成 JS bundle 净多约 7 人日，day 0 还更糙。
- **B — 把 YiTong 当 Swift package 依赖。** 否决：① Tuist 的 SPM 集成虽健康，但每个新产品依赖是一笔小小的构建系统税，vendor 资产零构建系统影响；② 钉版重要——YiTong v0.1.0 是 supacode 验证过的版本，我们要对跑在 WebView 里的 JS 有 bit-exact 控制；③ 反正我们已要写一个 Swift host/bridge 层（YiTong 的 host 层带自己的命名与协议约定），复用 web 资产、重写 Swift 侧即可在不重做难活（`@pierre/diffs` 集成）的前提下保持命名空间整洁。
- **C — 直接经 npm 打包 `@pierre/diffs`。** 否决：① 给 Swift 工程引入 Node 工具链（Mise + Tuist 需要 `node_modules` 故事，CI 多一步 npm install）；② 会重新踩 YiTong renderer.js 已解决的问题（selection clamping、hunk regex 健壮性、主题切换）；③ `@pierre/diffs` 的 peer-dependency 模型（React 18+ peer dep）意味着还得打包 React 或用 web-components 导出，二者皆非文档化的稳定面。我们因此直接 vendor YiTong 的 `renderer.js`；若 YiTong 日后与上游 `@pierre/diffs` 分叉到伤及我们，再重新评估。
- **D — 模态 overlay / 居中呈现。** 否决（早先 `git-viewer-modal-overlay` 尝试，已废）：居中模态盖住整窗，评审流程变成"开模态→看→关模态→看终端→重复"，持续丢上下文。inspector + drawer 保留连续上下文：文件列表常钉、diff 只盖终端区域（不盖 sidebar / tab bar）、⌘⇧G 切 inspector 而不 dismiss diff。
- **E — inspector 内嵌 inline 手风琴。** 否决：280 pt inspector 列对 unified diff 太窄（约 600 pt 才舒适），且多行展开会把文件列表滚出视野。drawer 模式让文件列表始终钉住。
- **F — NavigationSplitView 三栏、文件列表当中栏。** 否决（supacode 模式）：我们已用第三栏做 inspector 槽，再在 inspector 里套一层 split 在常见窗宽下是视觉混乱。drawer-over-terminal 布局给 diff 的横向空间比中栏文件列表更多。

## Vendoring & License

Vendored from YiTong v0.1.0（Apache-2.0）。`apps/mac/codans/App/Features/Diff/WebAssets/LICENSE` 含 Apache-2.0 许可证全文 + 一份 NOTICE，列出：

- Portions derived from YiTong (https://github.com/onevcat/YiTong), © onevcat, Apache-2.0
- renderer.js bundles `@pierre/diffs` (Apache-2.0)
- renderer.js bundles `kpdecker/jsdiff` (BSD-3-Clause)

**许可证姿态：** vendored bundle 是 NOTICE-clean 的，v1 **不得修改** vendored 文件；任何未来 patch 须按 Apache-2.0 §4 标注。顶层 `NOTICES.md`（创建或追加）指向该 LICENSE 文件。

## Git 子进程加固（承重）

变更文件列举与单文件 diff 都经 git 子进程，必须按下述硬化（否则在含特殊字符的路径、非 repo 目录、SHA-vs-path 歧义、不可解析日期上出错）：

- **repo 判定**经 `git rev-parse --is-inside-work-tree` 的退出码，而非匹配 stderr。
- 用**绝对 `/usr/bin/git`**（不是 `/usr/bin/env`），去掉 PATH 攻击面。
- 每个返回路径的 argv 加 `-c core.quotePath=false`（输出 UTF-8 而非八进制转义）。
- `git show <sha>` 追加 `--`（消解 SHA-vs-path 歧义）。
- 不可解析的 commit 日期 **throw `.unparsable`**（不是退化成 epoch-0）。
- `git diff --numstat` 的二进制检测：parser 同时处理 `-\t-\tpath` 与 `-\t-\told\tnew` 两种形状。

## 风险

- **WebView 启动延迟**：首次开 drawer 命中 Shiki 主题加载路径（M1 约 150–250 ms）。若实测 >300 ms，在 inspector 挂载时预热 WebView。
- **WebView 内存**：每个 WebView 约 25–30 MB JS heap。一次只挂一个 drawer；关 drawer 即销毁 WebView（下次开重建）以避免泄漏；若首载延迟变痛再重审。
- **主题漂移**：Shiki 提供 `pierre-light` / `pierre-dark`；bridge 在 `@Environment(\.colorScheme)` 变化时发 `updateConfiguration({ resolvedAppearance })`。视觉匹配是"够接近"，非精确。
- **Selection 剪贴板怪癖**：跨行 WebKit 选择会把 `+`/`-` 前缀带进剪贴板。v1 可接受。
- **Drawer 在 Worktree 切换时重挂**：`worktreeSelected` 重置 `presentedFilePath`，清掉前一个 Worktree 的 diff。
- **Inspector 路径截断**：路径 >32 字符走头部截断（`.lineLimit(1).truncationMode(.head)`），hover tooltip 显示全路径。
