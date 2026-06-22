# 设计文档：App Appearance & Terminal Theme

**状态：** 已上线（可见）
**作者：** Gump（与 Claude）

## 背景与范围

codans 的 Settings → General → Appearance picker（`system` / `light` / `dark`）由 `CodansCore/Settings/AppearancePreference.swift` 支撑，值经 `SettingsStore` 持久化。本设计让它真正驱动视觉，并扩展到完整的视觉主题面：

1. **App appearance** — 让 Light / Dark / System picker真正驱动 app 的视觉 chrome，覆盖 SwiftUI 管理的与 AppKit 宿主的两类表面。
2. **Terminal theme** — 新增 Settings → Terminal pane，让用户从 Ghostty 自带的主题目录里各选一个 light-mode 与 dark-mode palette。app 把选择写进用户的 Ghostty config 文件并热重载运行时，使改动即时生效。

两层组合：app 处于 dark 时 Ghostty 渲染用户选的 dark palette，light 时渲染 light palette，system 时跟随 macOS。

### 范围

**In scope：** SwiftUI 管理的 chrome（主窗口 `WindowGroup` 与 `Window("Settings")` 两个 scene）；AppKit 宿主表面（主要是 `Runtime/Ghostty/` 与 `App/PaneHostView.swift` 里的 Ghostty 终端视图——它们不自动继承 SwiftUI 的色彩环境）；Ghostty 终端 palette（前景 / 背景 / ANSI 色，经存于 Ghostty 自身 config 的命名主题控制）；Settings 窗口新增 `Terminal` section。

**Out of scope：** codans 自有 chrome 的 design-token / theme 层（见 Alt 6 的否决）；编辑器集成的语法高亮主题；用户自定义的逐值 palette（用户改用把主题文件丢进 Ghostty themes 目录的方式）；高对比 / 无障碍专用外观；逐 Project / 逐 Worktree 外观覆盖。

### 当前状态

- `AppearancePreference` 是带三个 case（`system` / `light` / `dark`）的 `Codable` 枚举。
- `GeneralSettings.appearance` 经 `SettingsStore` 的防抖写盘持久化；JSON 形状早已发布给用户。
- app 有两个 scene（`WindowGroup` 主窗口、`Window("Settings")`）。
- `GhosttyRuntime` 终端 surface 现按用户全局 Ghostty config 在启动时渲染 palette。
- UI 层 54 处颜色调用点：**绝大多数是系统语义色**（`Color(nsColor: .textBackgroundColor)`、`.secondary`、materials，自动适配），外加少数手调强调色（`Color.red`、`Color.orange.opacity(0.08)`）。

## 目标与非目标

**目标**

- 在 Settings → General 改 Appearance picker，主窗口、Settings 窗口、以及之后新开的任何窗口都即时更新。
- `system` 模式跟随 macOS 当前外观，OS 切换时无需用户操作即响应。
- Ghostty 终端 surface 跟随选定的 app 外观——chrome（滚动条、边框）与 palette（前景 / 背景 / ANSI 色）皆然。
- Settings → Terminal pane 让用户从 Ghostty 自带主题中各选 light / dark palette，实时终端即时生效。
- 主题选择持久化进用户的 Ghostty config 文件（`~/.config/ghostty/config`），使其在 codans 之外用 Ghostty 时也适用。
- codans 不管理的既有 config 行**逐字节保留**。
- 现有 codans `settings.json` 无需迁移。

**非目标**

- codans 自有 UI 的 `Theme` struct / 语义色 token 层（见 Alt 6）。
- app 内手调的逐用户 palette 编辑器。
- 把终端主题选择旁路存进 codans 自己的 `settings.json`——Ghostty config 文件才是唯一事实来源。

## 设计

### 总览

三块协作部件，由**两个独立的事实来源**驱动：

**事实来源 A — `settingsStore.settings.general.appearance`（已存在）。**
选择 app 的整体外观（Light / Dark / System）。

**事实来源 B — 用户的 Ghostty config 文件（`~/.config/ghostty/config`）。**
选择 light-mode 与 dark-mode palette 名。由 Ghostty 拥有；codans 用 **managed-keys** 策略读写一小撮有界指令（见下）。

这两个来源刻意分离，**频率与代价截然不同**：来源 A 是廉价（微秒级）、高频的运行时信号——每次 OS 外观翻转或用户切换都触发，一个 session 可能数十次；来源 B 是重（磁盘 I/O + 解析）、低频的配置写盘——仅当用户显式改 palette 名时才触发（罕见）。把两者并成一条路（如每次外观变化都重写 config 文件）会让每一次 OS 暗色切换都变成一次磁盘写。分开让各自按自然频率运行。

### App 外观的决议：单写者 `NSApp.appearance`

App 外观只有**一个写者**：`NSApp.appearance`（+ 逐窗口 `NSApp.windows[n].appearance`），它是 AppKit 与 SwiftUI 共同的外观真相源。**不**额外用 SwiftUI 的 `.preferredColorScheme`——单写者与 `.preferredColorScheme` 双写同一窗口会相互覆盖、产生抖动（详见 Alt 2）。

- **单写者**：`NSApp.appearance`（+ 逐窗口）是唯一施加外观处。
- **SwiftUI 派生**：SwiftUI 的 `@Environment(\.colorScheme)` 从**宿主窗口的 `effectiveAppearance`** 派生而来。窗口外观一旦由单写者设定，嵌在其中的 SwiftUI 子树读到的 `colorScheme` 即随之解析，无需 `.preferredColorScheme` 强推。

这样既覆盖了不参与 SwiftUI 色彩环境的 Metal-backed AppKit 宿主（Ghostty 终端视图），又让 SwiftUI 系统语义色与 materials 通过宿主窗口正确重渲染——且只有一个写者，杜绝双路径互覆盖。

### 终端 palette 的桥：运行时色彩方案信号 vs config 写盘

**运行时色彩方案信号 — `GhosttyRuntime.setColorScheme(_:)`。**
一个小 wrapper view 读 `@Environment(\.colorScheme)`（已由窗口外观派生）并调用 `ghostty_app_set_color_scheme` + 逐 surface `ghostty_surface_set_color_scheme`（必要时 `+ ghostty_surface_refresh`）。这告诉 Ghostty 渲染它已配置的两个 palette 中的哪一个（light 还是 dark），**无需重载整份 config**。廉价、内存内、同步。`setColorScheme` 还缓存 `lastColorScheme`，使后建的 `PaneSurface` 注册时能立刻被套上正确方案（否则新 pane 会以错误 palette 打开，直到下一次方案切换）。

**config 写盘 — `GhosttyConfigFile`。**
用户在 Settings → Terminal 选主题时，重写其 Ghostty config 文件的 managed 区域（经临时文件兄弟做原子写），并发一个 notification。`GhosttyRuntime` 监听该 notification 并调 `ghostty_app_update_config`——它从磁盘**重新解析**并把新 config 应用到每一个 live surface。

> **两个 libghostty 入口，职责不同**（关键 C-互操作约束）：`ghostty_app_set_color_scheme` + 逐 surface `ghostty_surface_set_color_scheme`（+refresh）切换**内存内的实时 palette**；而编辑 `~/.config/ghostty/config` 需要 `ghostty_app_update_config` 才能**从盘重新解析**。缓存 `lastColorScheme` 让后建 surface 继承之。

### 系统上下文

```
 事实来源 A                                事实来源 B
 ─────────────────────                     ──────────────────────
 SettingsStore                             ~/.config/ghostty/config
 .general.appearance                       (managed 区: theme/cursor-
 (Light/Dark/System)                        style/font-family/font-size)
       │                                          ▲
       ▼                                          │ atomic write
 ┌─────────────────┐                       ┌──────────────────┐
 │ AppAppearance   │                       │ GhosttyConfigFile│
 │ View            │                       │  load / apply    │
 └────────┬────────┘                       └────────┬─────────┘
   单写者  │ NSApp.appearance                  posts │ .ghosttyRuntime
          │ + windows[n].appearance               │   ReloadRequested
          ▼                                        ▼
 宿主窗口 effectiveAppearance            ┌──────────────────┐
          │  （SwiftUI 由此派生）          │  GhosttyRuntime  │
          └─→ @Environment(\.colorScheme)─┐│  .reloadAppConfig│
                                         ▼││  (ghostty_app_   │
                       ┌──────────────────┐│   update_config) │
                       │ GhosttyColor     │└──────────────────┘
                       │ SchemeSyncView   │        │ applies to all
                       └────────┬─────────┘        │ live surfaces
                                │ setColorScheme    ▼
                                ▼            All Ghostty surfaces
                       GhosttyRuntime        render new palette
                       ghostty_app_set_color_scheme
                       + per-surface refresh
```

### API 设计

**`AppearancePreference` — 两个投影。**
`var colorScheme: ColorScheme?`（`.system → nil`）与 `var appearance: NSAppearance?`（`.system → nil`、`.light → .aqua`、`.dark → .darkAqua`）。因 `CodansCore` 必须 `AppKit`-free（被非 UI target 消费），`NSAppearance` 投影放在 `apps/mac/codans/App/Theme/` 下的 app 模块扩展里；`ColorScheme` 投影与之并置，保持 Core 纯净。`colorScheme` 投影供需要读色彩方案的下游（如 `GhosttyColorSchemeSyncView`）解析使用，**不**经 `.preferredColorScheme` 回推给 SwiftUI。

**`AppAppearanceView<Content>` — scene wrapper。**
包住每个 scene 的内容，经既有 `@Environment` 注入响应式读 `SettingsStore`。它**只**经 AppKit 路径施加外观——在 `.background { }` 里挂一个 `WindowAppearanceSetter`，由后者写 `NSApp.appearance`；**不**用 `.preferredColorScheme`（避免与 `NSApp.appearance` 打架）。放在*每个* scene 根，确保 `viewDidMoveToWindow` 每次 scene 挂载至少触发一次，自动接住新开窗口。

**`WindowAppearanceSetter` — `NSViewRepresentable`（单写者本体）。**
薄 `NSView` 包装。`viewDidMoveToWindow`（与 `preference` 的 `didSet`）触发 `applyAppearance()`：

```swift
private func applyAppearance() {
  guard window != nil else { return }
  let appearance = preference.appearance
  NSApp.appearance = appearance
  for window in NSApp.windows {
    window.appearance = appearance
    window.contentView?.needsLayout = true
    window.contentView?.needsDisplay = true
    window.invalidateShadow()
  }
}
```

遍历 `NSApp.windows` 逐个重赋是 belt-and-suspenders：`NSApp.appearance` 单设本应传播，但在全局被设定之前创建 / 配置的窗口可能变陈旧。显式逐窗循环 + `invalidateShadow()` 强制 chrome（标题栏、红绿灯、窗口阴影）即时重渲染。

**`GhosttyColorSchemeSyncView<Content>` — 终端运行时同步 wrapper。**
读 `@Environment(\.colorScheme)`（由宿主窗口的 `effectiveAppearance` 派生而来），在其变化时调 `ghostty.setColorScheme(new)`。`initial: true`，使新建 Ghostty surface 立即继承当前方案。包在 `ContentView` / `PaneHostView` 中 `GhosttyRuntime` 可达处。

**`GhosttyRuntime` — 两个新方法。**
`setColorScheme(_:)`（切实时 palette + 缓存 `lastColorScheme`）与 `reloadAppConfig()`（从 `configPath` 经 Ghostty 默认加载路径重建 `ghostty_config_t`，再 `ghostty_app_update_config`）。后者由 `init` 中注册的 notification 监听器调用，从而把 config 写者与 runtime 解耦——写者不持引用，任何未来的 config 编辑源只需 post notification。

**`GhosttyConfigFile` — config 读 / 写（`@MainActor`）。**
`load() -> GhosttyTerminalSettings`（快照 + 可用主题）与 `apply(_ draft:)`（原子写 + notify）。

### Managed-keys 策略

config 文件是用户写的行与 codans 拥有的行的混合。`apply` 定义一组 **managed keys**——`theme` / `cursor-style` / `font-family` / `font-size`，共用同一套 managed-keys 机制（进一步扩展是自然延伸）。写盘时：

1. 以 UTF-8 按行读取。
2. 逐行扫描：键在 managed 集内则丢弃，否则**逐字节原样保留**（注释、空白、未知键、其他用户指令）。
3. 记住第一个被丢弃的 managed 行的索引——那是插入点。
4. 从 draft 构建规范 managed 块。
5. 在记住的索引处（或若先前无 managed 行则在文件末）插入 managed 块。
6. 写到临时文件兄弟，再 `replaceItem` 原子替换真实路径。
7. post `.ghosttyRuntimeReloadRequested`。

managed 块无论 draft 顺序如何，**总以同一顺序与格式**输出，使 app-edit 间的 diff 最小、可读。若用户尚无 config 文件，`ensureConfigFile` 在 `~/.config/ghostty/config` 创建（含目录）。

**主题目录发现。** `load` 从 Ghostty resources bundle 与 / 或 `$XDG_CONFIG_HOME/ghostty/themes` 枚举主题文件，把每个文件解析到刚够读其 `background` 色，按背景亮度（`Y = 0.299R + 0.587G + 0.114B > 0.5` → light）分类为 light / dark，返回字母序排列的 `availableLightThemes` / `availableDarkThemes`。若用户已选的主题不在目录中（旧名 / 已删），前置插入它使 Picker 仍显示当前值。

### Settings → Terminal

`SettingsSection` 增 `.terminal` case。新 reducer `SettingsTerminalFeature`（state：`snapshot` / `isLoading` / `isApplying` / `errorMessage` / `warningMessage`；actions：`onAppear` 异步加载、`lightThemeSelected` / `darkThemeSelected`、`applyResult`；reducer 节流 apply——快速重选取代在飞调用）依赖 `GhosttyTerminalSettingsClient`（TCA `DependencyKey`，`liveValue` 在 `MainActor` 绑 `GhosttyConfigFile`，test value 内存 fixture）。UI 为并排两个 `Picker`（nil 时显 "Select Theme"，`isApplying || isLoading` 时禁用），warning / error 渲染于控件上方。

**不变：** `SettingsStore`、`AppearancePreference.CodingKeys`、`GeneralSettings`、`SettingsGeneralView` 的 `Picker` 绑定。General pane 的 caption 不宣称 "preview only"——Appearance 选择真正驱动 chrome。

### 组件边界

```
CodansCore/Settings/
  AppearancePreference.swift           Codable 枚举
  GeneralSettings.swift                不变

apps/mac/codans/App/Theme/         (新文件; ThemeGit.swift 的兄弟)
  AppearancePreference+UI.swift        ColorScheme + NSAppearance 投影
  AppAppearanceView.swift              scene wrapper（仅 AppKit 路径）
  WindowAppearanceSetter.swift         NSViewRepresentable（单写者 NSApp.appearance）
  GhosttyColorSchemeSyncView.swift     ghostty 运行时色彩方案同步
  AppearanceDiagnostics.swift          结构化日志

apps/mac/codans/App/
  CodansApp.swift                   两个 scene 内容均包进 AppAppearanceView { }
  ContentView.swift                    终端子树包进 GhosttyColorSchemeSyncView

apps/mac/codans/Runtime/Ghostty/
  GhosttyRuntime.swift                 +setColorScheme(_:) / reloadAppConfig() / init 注册监听
  GhosttyConfigFile.swift              新 — load/apply config 文件 managed 区
  GhosttyThemeCatalog.swift            新 — 枚举 + 分类自带主题

apps/mac/codans/App/Features/Settings/
  SettingsSection.swift                +.terminal
  SettingsWindowView.swift             侧栏行 + .terminal pane 分支
  Panes/SettingsGeneralView.swift      Appearance picker（caption 不含 "preview only"）
  Panes/SettingsTerminalView.swift     新 pane
  SettingsTerminalFeature.swift        新 TCA reducer + client

apps/mac/codans/App/Clients/
  GhosttyTerminalSettingsClient.swift  新 — 包 GhosttyConfigFile 的 Dependency
```

依赖方向：`App/Theme/` 依赖 `CodansCore` + `AppKit`/`SwiftUI`，绝不反向；`CodansCore` 保持 `AppKit`-free；`GhosttyConfigFile` 不依赖 Settings feature（它定义被 Settings import 的数据类型），notification 是写者与 runtime 的唯一耦合。

### 数据存储

**codans `settings.json`：** 无 schema 变化，`GeneralSettings.appearance` 已持久化，默认 `.system`，旧文件原样解码。

**Ghostty config 文件：** 用 Ghostty 自身约定解析路径（`$XDG_CONFIG_HOME/ghostty/config`，否则 `$HOME/.config/ghostty/config`）；只重写 managed keys，其余逐字节保留。并发编辑风险（用户在编辑器里开着 config 而 codans 写盘）由原子替换缓解：`replaceItem` 在覆盖时保持 inode 身份，并发读到的要么旧、要么新，绝无半态；若用户在我方写后保存，其保存胜出（last-write-wins，对罕改的 config 可接受）。

## 备选方案（Alternatives）

### Alt 1 — 仅 SwiftUI `.preferredColorScheme`
仅给每个 scene 内容加 `.preferredColorScheme(preference.colorScheme)`，不碰 AppKit。
**否决：** Ghostty 终端视图是 Metal-backed 的 AppKit `NSView` 子类，不观察 SwiftUI 的 `@Environment(\.colorScheme)`；chrome 与 palette 绑在 `NSAppearance` 上，而 `.preferredColorScheme` 在每个嵌套 AppKit 宿主上的行为跨 macOS 版本不一致。它够不到非 SwiftUI 表面。

### Alt 2 — 双路径（`.preferredColorScheme` + `NSApp.appearance` 都写）
SwiftUI 侧 `.preferredColorScheme` 与 AppKit 侧 `NSApp.appearance` 各写一遍，期望两路覆盖各自的表面。
**否决：** 同一窗口同时被两个写者写外观会相互覆盖、产生抖动。采用的方案是**单写者 `NSApp.appearance`**，SwiftUI 从宿主窗口的 `effectiveAppearance` 派生 `colorScheme`——既覆盖 AppKit 宿主，又让 SwiftUI 正确重渲染，且无双写互覆盖。Alt 1 够不到 AppKit、Alt 2 两写打架，故均否决。

### Alt 3 — 把终端主题选择存进 codans 的 `settings.json`
**否决：** 用户期望终端 palette 横跨所有 Ghostty 使用、而不止 codans。拆分事实来源（codans JSON 管 app 内、Ghostty config 管独立运行）会在用户改了其一未改其二时立刻漂移。写 Ghostty config 正是 Ghostty 自身期望此状态被拥有的方式——一份文件、一个真相。

### Alt 4 — 调 Ghostty 自身 CLI / IPC 设主题
**否决：** 我们嵌入的 Ghostty 版本无此命令；即便有，规范持久化仍是 config 文件，CLI 只是替我们写它。跳过中间件避免对跨版本可能不同的 Ghostty CLI 行为的依赖。

### Alt 5 — apply 时重写整份 Ghostty config
**否决：** Ghostty config 格式含用户刻意维护的注释、空行、指令顺序（分组、`config-file = ...` 条件块）。规范化重序列化摧毁意图。managed-keys 策略——保留除 codans 拥有的有界集合外的一切——是最小扰动方案。

### Alt 6 — 引入 codans `Theme` struct / design-token 层
定义 `Theme`（`accent` / `surface` / `warning` 等）经 `@Environment(\.theme)` 注入，迁移 54 处颜色。
**否决：** 现有 54 处颜色**绝大多数是系统语义色、已自动适配**；token 的边际价值（品牌定制 / 备选 palette / 高对比）当前都不是产品需求。它把范围从"几个新文件"推到"视觉审计每个 view"——为零即时用户可见收益冒大回归风险。**复议条件**：品牌定制、备选 palette、或高对比模式成为真实需求时，应触发后续设计文档而非直接重构。既有 `App/Theme/ThemeGit.swift`（受限的 git-diff 命名空间）是正确先例：*在具体 feature 需要协调色彩之处*建小命名空间，而非预先建全局层。

### Alt 7 — 预览卡式 Appearance picker
用三块大图块（各含 Light/Dark 变体）替换三选项 `Picker`。
**推迟，未否决。** 需设计 / 导出每外观三张图。先发功能性 `Picker`，卡片留作后续，保持初始改动可审。

## 横切关注点

**可观测性。** `AppearanceDiagnostics.log(_:)` 在以下时刻发单行结构化记录：用户发起的外观切换；`viewDidMoveToWindow` 与逐窗 `NSApp.appearance` 施加；Ghostty 运行时方案切换（前 / 后、surface 计数）；Ghostty config 读 / 写（路径、managed-key diff、解析告警）。字段含当前 preference、解析出的 `NSAppearance` 名、`NSApp.effectiveAppearance`、窗口标识。当用户报"某个窗口没更新"或"我的 Ghostty palette 没变"时可据日志诊断哪条路径对哪个目标触发了。

**测试策略。** 可单测：`AppearancePreference → ColorScheme?` / `→ NSAppearance?` 映射（各三断言）；`GhosttyConfigFile.updatedContents(from:settings:)` 纯字符串变换（空文件→加块、仅无关指令→追加并保留、已有 managed 行→就地替换、多 managed 行交错→全丢并归一到最早位置、注释/空行混 managed→保留注释空行折叠 managed、尾换行保留）；主题亮度分类；`SettingsTerminalFeature` reducer（`TestStore` + fake client）。不可有效单测：`WindowAppearanceSetter` 副作用与 wrapper view body（手动视觉走查：`light`/`dark`/`system` × {主窗口、Settings 窗口、新开 sheet、`system` 模式下 OS Appearance 切换}）；live Ghostty 运行时重应用（开真实终端手验）。

**回滚。** 纯增量改动。`AppAppearanceView` 出问题→回退 `CodansApp.swift` 里的包裹，被包内容继续以 macOS 默认外观工作；Terminal pane 出问题→回退 `.terminal` `SettingsSection` case。`setColorScheme` / `reloadAppConfig` 是增量、仅由新接线调用。config 文件失败模式：写入坏 managed 块（如未知主题名）会让 Ghostty 拒绝解析回退默认——已由"先写临时文件→用 Ghostty 解析器校验→仅校验通过才覆盖真实路径"守住，校验失败时真实文件不动、用户在 Settings pane 见错误。

**性能。** `NSApp.appearance` 赋值每开窗触发一次重布局、每用户发起改动一次——非热路径。`GhosttyColorSchemeSyncView.onChange` 挂载时一次、每次真实变化一次，每次是常数时间 libghostty 调用。`GhosttyConfigFile.apply` 是文件 I/O + 解析 + notify——毫秒级，仅用户显式改 picker 时发生。

**安全 / 隐私。** 读写 `~/.config/ghostty/config` 是用户作用域文件活动，无提权或外部 I/O；主题名是已知目录里的不透明字符串，无注入面，config 行式 key=value 无 shell 解释。

## 风险

**Risk 1 — `ghostty_*_set_color_scheme` 行为不如预期。** 运行时方案切换可能不刷新就无可见 palette 变化，或与 config 指定的主题对交互怪异。*缓解：* 首步先对 live surface 原型验证 `setColorScheme`；必要时每 surface 加 `ghostty_surface_refresh`；若运行时切换不可行或太粗，回退到每次方案变化重应用 config（更吵但仍正确）。

**Risk 2 — Ghostty 主题目录位置与预期不符。** *缓解：* 目录发现局部化于 `GhosttyThemeCatalog`，误判会以错 / 缺主题名立刻在手测显现；原型步先列真实安装的 themes 目录；亮度分类对少数主题分错可细化启发式或让 Ghostty 自身主题元数据驱动。

**Risk 3 — 用户既有 Ghostty config 形状意外。** *缓解：* managed-keys 严格**行级**——每行非 managed 即不透明，绝不深解析；`config-file = ...` include 逐字节保留（非 managed key）；临时文件校验步（写候选→Ghostty 解析器→仅成功才覆盖）兜住任何产生不可解析文件的重写。

**Risk 4 — 手调颜色在某一外观下看错。** `Color.red`（未读徽标）、`Color.orange.opacity(0.08)`（Developer 警告）等本应两模式都读对——未测假设。*缓解：* 接线后手动走查 Settings panes、header bell、tab bar、git viewer 两模式；逐个开 follow-up，均不应阻塞外观 feature；若系统性问题浮现，带具体失败案例复议 Alt 6。

**Risk 5 — 改 preference 后新开的窗口漏掉 AppKit 外观。** `applyAppearance` 在触发时遍历 `NSApp.windows`，接住既有窗口但会漏掉之后新开的（若 setter 只在主 scene）。*缓解：* 把 `AppAppearanceView` 放在*每个* scene 根，各 scene representable 的 `viewDidMoveToWindow` 在新窗口诞生时接住；之后新增而未包裹的 scene 类型，退化模式是"跟随上次设定的 `NSApp.appearance`"，可接受。

**Risk 6 — 单写者未覆盖某个窗口。** 某窗口未被 `NSApp.appearance` 单写者触达（如在外观设定前创建、且未走 `viewDidMoveToWindow` 路径），渲染出陈旧外观。*缓解：* 单写者本就遍历 `NSApp.windows` 逐窗重赋并 `invalidateShadow()`；`AppAppearanceView` 置于每个 scene 根使每次挂载都重跑一遍；diagnostics 日志每事件记录 `NSApp.effectiveAppearance` 与 preference，使任何漏窗可见。**注意**：单写者模型下不存在"AppKit 与 SwiftUI 两路径漂移"的失败模式——SwiftUI 从窗口外观派生，没有第二个写者可与之分叉。

**Risk 7 — Ghostty config 文件并发编辑。** *缓解：* `FileManager.replaceItem` 原子替换确保任何读者见到完整旧文件或完整新文件，绝无半态；last-write-wins。

**Risk 8 — 未来工程师重提 Theme 层决策。** 有人看 54 处未集中颜色提 token 重构。*缓解：* 从任何此类提案链回本文 Alt 6；否决理由显式并列出复议条件（品牌定制 / 备选 palette / 高对比）；其中任一成为真实需求应触发后续设计文档而非直接重构。
