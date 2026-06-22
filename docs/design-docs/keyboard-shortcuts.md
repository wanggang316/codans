# 设计文档：Keyboard Shortcuts（统一管理）

**状态：** 已上线
**作者：** Gump（与 Claude）

## 背景与范围

codans 的应用内快捷键曾散落在三处、各自硬编码：window-scope 的 SwiftUI 绑定（`MainWindowCommands`：`⌘P` Quick Action、`⌘E` Open in Editor、`⌘⇧G` Toggle Git Viewer、`⌘F` Filter Tags、`⌘T` New Tab、`⌘W` Close Tab、Prev/Next Tab、Switch-to-Tab N 等）、侧栏行热键（`HierarchySidebarView` 给每个可见 Worktree 行挂零帧隐形 Button 的 `⌃⌘1`–`⌃⌘9`）、app-scope 的 `⌘,`（Settings 窗口）。另有两个消费者只**显示**和弦提示而不绑定键：Command Palette 的行内提示，与状态栏的激励视图。

本设计用一个**单一 registry** 取代逐调用点硬编码：以稳定 `CommandID` 为键、默认和弦只编码一次；一个持久化的覆盖存储；一个让用户改键 / 禁用 / 重置任意已注册命令的 Settings 面板。它刻意覆盖全部应用内快捷键，使未来新增都走同一条路径，而非再引入逐 feature 的漂移。

## 目标与非目标

**目标**

- 每条用户可绑定的应用内快捷键都在 registry 里，以稳定 `CommandID` 为键，默认和弦编码一次。
- 用户覆盖持久化到**独立文件** `~/.config/codans/shortcuts.json`，与 `settings.json` 分离。
- Settings → Shortcuts 面板：搜索、按分类分组、录制新和弦、禁用、逐行重置、全部重置。
- 三级冲突检测：macOS system-reserved、AppKit-reserved 菜单集、应用内其他用户可配置命令。
- 以用户**活跃键盘布局**显示和弦（AZERTY 上 `⌘[` 渲染物理产出 `[` 的键帽，而非 U.S. 字面量）。
- 绑定以**物理键**（key code + 修饰符 flags）持久化，使同一覆盖在布局切换后存活。
- 迁移既有窗口命令与侧栏热键进 registry，全新安装下不改可观测行为。

**非目标**

- 快捷键 profile 的导入 / 导出（推迟；磁盘格式为未来导出预留，但不建 UI）。
- 全局系统热键（`Carbon.RegisterEventHotKey` 式、别的 app 在前台时仍触发的常驻绑定）。所有绑定经 SwiftUI 限定在 window / app 作用域。
- 模式相关键映射（Vim 式"此和弦在 pane 聚焦下是 X、在侧栏聚焦下是 Y"）。每个 `CommandID` 解析为单一和弦，由 SwiftUI 既有焦点系统规则决定它是否触发。
- 逐 Project 覆盖。快捷键对应用全局。
- 多击和弦（`⌘K ⌘O` 式）。仅单和弦。
- 改 Ghostty 内部的快捷键（终端 scrollback 导航等）——由内嵌终端配置拥有，超范围。

## 设计总览

三层，严格依赖方向：

```
┌─────────────────────────────────────────────────────┐
│  CodansCore/Shortcuts/   (无 SwiftUI / 无 AppKit)    │
│    CommandID enum                                    │
│    ShortcutBinding / ModifierMask                    │
│    ShortcutSchema (defaults, version)                │
│    ShortcutOverrideStore (Codable)                   │
│    ShortcutResolver → ResolvedShortcutMap            │
│    ShortcutResetPlanner                              │
│    Conflict detectors (system / appKit / internal)   │
└──────────────────────┬──────────────────────────────┘
                        │ 纯数据
┌──────────────────────▼──────────────────────────────┐
│  codans/App/Shortcuts/   (SwiftUI + AppKit glue)     │
│    ShortcutsStore (file I/O, debounced)              │
│    ShortcutDisplay (UCKeyTranslate)                  │
│    HotkeyRecorder (NSView + SwiftUI 包装)            │
│    View+appKeyboardShortcut 修饰符                   │
│    EnvironmentKey<ResolvedShortcutMap>               │
└──────────────────────┬──────────────────────────────┘
                        │ environment 注入
┌──────────────────────▼──────────────────────────────┐
│  既有调用点：MainWindowCommands / HierarchySidebarView│
│  / ShortcutsSettingsView（新）/ 各展示型消费者         │
└─────────────────────────────────────────────────────┘
```

**核心权衡：** 选*封闭 `CommandID` enum + 过程式 defaults 表*，而非*开放注册协议*。codans 的完整快捷键面在编译期可枚举（首版约 25 条，长期 50 以内）；封闭 enum 在路由代码里给出穷尽 switch 覆盖，并在命令改名时给出机器可检的迁移。开放注册表会买来我们无具体需求的 plugin 式扩展性，代价是运行时排序、去重、ID 冲突规则——这些在封闭模型里都是免费的。改名一条命令在每个调用点都是编译错误，重构时无价。若日后真出现 plugin 面，可在封闭 enum 旁引入开放注册表（持久 schema 已带 `version`，加 `customCommands` 扩展是非破坏性的）。

**次级权衡：** 绑定以 **`keyCode` + 修饰符 flags**（物理键）而非 `Character` + 修饰符持久化。这使覆盖在输入源切换后稳定，但复杂化显示层（须对活跃布局跑 `UCKeyTranslate` 渲染键帽）。复杂度在 `ShortcutDisplay` 里一次付清，换来非 US-QWERTY 用户的正确行为而无需逐布局覆盖。

## 数据模型

### `CommandID`

`CodansCore/Shortcuts/CommandID.swift` 中的封闭 enum，`String`-backed、`CaseIterable`、`Codable`。

**raw value 是 API——改 Swift 标识符可以，但必须钉死 raw value。** raw values 是 `shortcuts.json` 里 `ShortcutOverrideStore.overrides` 的持久 JSON 键，是磁盘格式的一部分，一旦发布就不能变——改它会**静默孤儿化**该命令的每一条既有用户覆盖。模式是：重命名 Swift 标识符以反映现实，但用显式 `= "..."` 把 raw value 钉在原字符串上。两个落地案例：

```swift
// Swift 标识符在 Diff inspector 工作中改了名，但 raw value 钉死，
// 否则会孤儿化每一条 ⌘⇧G 的用户覆盖。
case toggleDiffInspector = "toggleGitViewer"
// 标识符缩短，raw value 钉在原字符串。
case openInEditor = "openInDefaultEditor"
```

编号 case（`switchToTab1`…、`selectWorktreeAt1`…）逐个拼出而非参数化，使它们成为一等 JSON 键、参与 `CaseIterable`、并在路由 switch 里保持编译期穷尽。

### `ShortcutBinding` 与三态模型

```swift
public struct ShortcutBinding: Equatable, Hashable, Sendable, Codable {
  public let keyCode: UInt16              // virtual key code (kVK_* values)
  public let modifiers: ModifierMask      // .command / .option / .control / .shift
  public let isEnabled: Bool              // false → user disabled this command
}
```

`ModifierMask` 是同处定义的 `OptionSet`，**刻意不用** SwiftUI 的 `EventModifiers` 或 AppKit 的 `NSEvent.ModifierFlags`——后两者是上层平台类型；本 struct 住在无 SwiftUI / AppKit 依赖的 `CodansCore`，转换在 `ShortcutDisplay` 里是一行。

**三态模型（default / overridden / disabled）是耐久不变量，`disabled ≠ absent`。** `isEnabled == false` 表示*用户显式关掉了这条命令*，与"根本没有绑定"（覆盖存储里无此条目、默认生效）截然不同。这个区分是必须的，因为用户有时想抑制一个继承来的默认却不挑替代——少了 disabled 态就无法表达"我不要这条默认、也不给它新键"。

### `ShortcutScope`

```swift
public enum ShortcutScope: Sendable {
  case configurable        // 用户可改键 / 禁用
  case systemFixed         // UI 中显示但只读（如 ⌘,）
  case localOnly           // 完全不在 UI 露面（如 sheet 里的 ⎋）
}
```

首版只用 `.configurable` 与 `.systemFixed`；`.localOnly` 为未来（模态 Esc/Return、文本框内光标移动）预留，使 registry 能建模它们而不污染可配置面。

### `ShortcutSchema`（defaults 表）

静态值类型，带 `version` 戳。是分类分组与面板排序的**唯一事实点**：UI 不直接枚举 `CommandID.allCases`，而是读 `ShortcutSchema.app.entries`，使新增的、缺 schema 条目的 case 在 code-review 时被审计单测抓住（每个 `CommandID` case 必须恰有一条 schema 条目）。每条 `Entry` 携 `id` / `title` / `category` / `scope` / `defaultBinding`。

### `ShortcutOverrideStore` 与 `ShortcutResolver`

持久文档是稀疏 Codable struct，只携与 schema 的差异：空存储 = "全部默认生效"。键是 `CommandID` raw value，使 JSON 人类可 grep：

```json
{
  "version": 1,
  "overrides": {
    "newTab": { "keyCode": 17, "modifiers": ["command", "option"], "isEnabled": true },
    "toggleGitViewer": { "keyCode": 5, "modifiers": ["command"], "isEnabled": false }
  }
}
```

> 注意上例的键 `"toggleGitViewer"` 正是 `CommandID.toggleDiffInspector` 的钉死 raw value——磁盘上看到的是历史字符串，不是当前 Swift 标识符。

`ShortcutResolver` 是纯函数：给定 schema 与覆盖存储，产出每条命令的有效绑定，带供 UI 显示的来源标签（`schemaDefault` / `userOverride`），并把 disabled 态从 `nil` 中独立出来（`binding == nil` ⇒ 无和弦；`isEnabled == false` ⇒ 和弦存在但被抑制）。

## 冲突检测（三级分类）

三个 detector，各为对 `(ResolvedShortcutMap, 候选 ShortcutBinding)` 的纯函数：

- **`SystemReservedDetector`**——启动时从 `CFPreferences` 读 `com.apple.symbolichotkeys / AppleSymbolicHotKeys`，解析 OS 拥有的和弦（Spotlight、Mission Control、输入源切换……）的 keycode/修饰符三元组。每次启动读一次、缓存进程生命周期；UserDefaults 变更通知触发刷新。
- **`AppKitReservedDetector`**——AppKit 标准菜单默认认领的一小撮硬编码菜单和弦（`⌘Q`、`⌘W`、`⌘H`、`⌘M`、`⌘,`、`⌘?`）。静态，无运行时查询。
- **`InternalConflictDetector`**——扫描 resolved map 里其他当前绑到同一 `(keyCode, modifiers)` 且 `isEnabled == true` 的 `.configurable` 命令。

**三级的处置不同（耐久不变量）：** 候选若败给 detector 1（system-reserved）或 2（AppKit-reserved），被 recorder UI 以类型化错误**直接拒绝**；若只败给 detector 3（internal），则**弹确认对话框置换**（"Replace？这会取消 Toggle Git Viewer 的指派。"），确认后把冲突命令的覆盖更新为 disabled 或空绑定。

### 级联重置

把命令 *A* 重置回 schema 默认，可能使 A 的默认与 B 的用户覆盖相撞。朴素重置会留给用户一个静默碰撞。`ShortcutResetPlanner`（纯函数）产出一个计划，携 `target`、`cascadingResets`（被传递清除的覆盖）与 `resultingMap`。Settings 面板在确认对话框里展示该计划（"重置 'New Tab' 也会重置 'Switch to Tab 1'，否则它们会共享 `⌘1`。继续？"）。Reset-all 是退化情形：清空整个覆盖 map、接受纯 schema 解析。

否决 reset-without-cascade：在 swap-conflict（A 的默认 == B 的覆盖、B 的默认 == A 的覆盖）上非级联重置会让 A、B 都绑到同一和弦，且无任何用户可见 UI 浮现这个静默碰撞。级联 planner 加约 30 行 + 一个确认对话框，换来杜绝一类难经用户报告诊断的 bug。

## 双重布局翻译：bind-in-US / display-in-active

这是本设计最易被"简化"掉、却**不可简化**的耐久不变量。持久绑定携 `keyCode`（物理位置），但绑定与显示走**两条相反的布局翻译**：

**显示（display-in-active）。** 键帽字符串在渲染时计算：`ShortcutDisplay` 用 `TISCopyCurrentKeyboardLayoutInputSource()` + `UCKeyTranslate` 问**活跃布局**——某 keyCode 在无修饰符下产出什么 unicode 字符（方向键 / 功能键 / Return / Tab / Esc / Space / 小键盘按 keyCode 特例映射到固定字形），结果大写化为键帽约定。活跃布局可在运行时经输入源切换改变：`ShortcutDisplay` 注册 `kTISNotifySelectedKeyboardInputSourceChanged` 观察者，bump 一个失效 token，使 environment 注入的 map 的显示串在下次读取时重算、SwiftUI 经 view-update 周期重绑菜单项。

**绑定（bind-in-US）。** 把 keyCode 转成 SwiftUI `KeyEquivalent` 时，对字符键跑 `UCKeyTranslate` 用的是 **US-QWERTY 布局**（**不是**用户活跃布局），使菜单绑定与用户选了什么布局无关地稳定——SwiftUI 拿 `KeyEquivalent` 去比对键入的字符，而我们要的是当用户按下键盘上那个*物理* `G` 键（OS 上报为布局翻译后的字符）时绑定触发。

**为何这样拆（why，别简化掉）：** 这个 "bind in US / display in active" 的拆分，正是 AppKit/SwiftUI 菜单项对硬编码 `.keyboardShortcut("g", …)` 的默认行为，也是用户的预期。绑定钉在物理键上、显示跟随活跃布局——二者用不同布局翻译同一个 keyCode 是刻意的，不是 bug。把两边合并成单一布局会让非 US-QWERTY 用户要么显示错键帽、要么按了物理键不触发。复杂度集中在 `ShortcutDisplay` 一处付清。

否决以 `Character` + 修饰符持久化：US 布局上把 `⌘[` 映成键帽、再切到 AZERTY，和弦会移到不同物理位置（AZERTY 上 `[` 要 `⌥(`）。持久 keyCode 使和弦稳定到用户真正训练肌肉记忆的那个*物理键*；复杂度成本被框在 `ShortcutDisplay` 内，UI 从不暴露 keyCode。

recorder UI 反向用同一层：捕获 `NSEvent.keyCode`（物理）并存储；录制中显示的键帽是 `ShortcutDisplay.keycap(for: capturedKeyCode)`。

## 持久化：独立 `shortcuts.json`

Owner 是 `App/Shortcuts/` 里新的 `ShortcutsStore`（`@MainActor @Observable`、`AtomicFileStore`-backed、500 ms 尾随防抖、解码失败时坏文件备份），镜像既有 `SettingsStore` 模式。

**为何独立文件而非并入 `settings.json`（耐久理由，不可"简化"为单文件）：**

- **写入节奏不同。** 快捷键编辑是交互式的（每次和弦捕获即提交），而 `Settings` 多数在每会话内稳定。独立防抖避免相互干扰——一次录制提交若与 Settings 面板编辑交错，会把两者合并成一次写入。
- **避免 schema 耦合。** `settings.json` 已在 v3 且带严格 migrator；加一个 `shortcuts` 字段会为一份生命周期可干净剥离的数据强推一次 v4 bump 与防御性迁移步。
- **契合推迟的导出特性。** 独立文件是导出特性的天然形态——用户已能直接查看 / 拷贝 `shortcuts.json`，无需后加抽取器。

**版本 / 备份策略：** 文档根有显式 `version: 1` 字段。读时版本不匹配触发 side-aside 备份（`shortcuts.json.v{N}-<ts>`）+ 全新默认加载；手编成畸形态导致解码失败则把坏文件备到一旁（`shortcuts.json.broken-<ts>`）+ 空覆盖起步——与 `SettingsStore` 同一套保守策略。路径经 `Settings.defaultURL()` 同款的 `NSHomeDirectory()` + `.config/codans/` 约定发现。

## SwiftUI 集成（要点）

resolved map 经 `@Environment(\.resolvedShortcuts)` 注入到视图树顶端（`Commands` scene 参与 environment 传播，故菜单亦可读）。调用点用 `appKeyboardShortcut(_:in:)` 修饰符施加绑定：取双参形式（显式传 map），因为 `Commands` body 不能直接访问 `@Environment`；另提供读 `@Environment` 的单参 view 重载。`MainWindowCommands` 与 `HierarchySidebarView` 的逐调用点硬编码都改读 registry；侧栏行热键的映射移入 `ShortcutSchema.app`。

`CodansApp` 里 `⌘,` 保持内联（它是 `.systemFixed`，和弦为 `kVK_ANSI_Comma + .command`）：registry 含该条目仅供 Settings 面板*显示*，实际绑定留作既有字面量，以免把 resolver 穿过 App scene。展示型消费者（状态栏激励视图、Command Palette 行）改从 `ResolvedShortcutMap` 拉显示串。

## Recorder 与 Settings 面板（行为契约）

`HotkeyRecorder` 是 `NSView` + SwiftUI `NSViewRepresentable` 包装。用 AppKit 是因为 `NSEvent.addLocalMonitorForEvents` 是不被 SwiftUI 文本输入系统干扰地捕获和弦的唯一可靠途径。属耐久契约（而非具体交互细节）的行为：

- **recorder 拒绝单独 `⇧`：** 一个仅以 `⇧` 为唯一修饰符的和弦被拒（它会让用户遮蔽普通键入）；`⌘` / `⌥` / `⌃` 至少要有其一；`⇧` 与另一修饰符并存时才计数。这条在调用冲突 detector**之前**强制。
- 录制中的本地监视器对任何 keyDown 返回 `nil`（吞掉事件），使用户在录制 `⌘W` 时不会意外触发 `⌘W` 关掉当前 tab；监视器在 field 失去 first responder 时移除。
- 成功捕获经 `ShortcutsStore.update(_:to:)` 写穿，触发防抖保存并重算 resolved map，UI 经 `@Observable` 更新。

Settings → Shortcuts 面板取代占位 `ComingSoonPane`：按 `ShortcutSchema` 分类分组、可搜索（按渲染标题与渲染和弦串过滤）；和弦格是可点的 recorder field；`.systemFixed` 行标 `(System)` 徽标且 recorder 不可交互；重置字形仅在行被实际覆盖（`source == .userOverride`）时显示，点击弹含级联重置计划的确认；disabled 命令的和弦显删除线 + "Disabled" 标，由 recorder 上下文菜单 "Disable shortcut" 置 `isEnabled = false` 而不清和弦。

## 与既有系统的交互（耐久不变量）

- **`⌘T` / `⌘W` 在响应链上压过 Ghostty 内部绑定。** 这是菜单绑定优先级——SwiftUI 菜单项在 responder chain 上先于内嵌终端的键绑定，故 New Tab / Close Tab 胜出。这是**预期行为，不是 bug**；不要试图"修复"成让 Ghostty 抢先。
- **`selectAdjacentTab` 必经 `selectTab`。** 相邻 tab 切换（`previousTab` / `nextTab` / 编号切换）的路由必须走 `selectTab`；直接写 `selectedTabID` 会**绕过焦点恢复**，使键盘 tab 切换跳过该 tab 记住的 pane。这是路由不变量，非性能优化。

## 风险

| 风险 | 缓解 |
|---|---|
| 迁移提交时 schema 审计与 `MainWindowCommands` 字面量脱节，某和弦值静默改变 | 迁移拆两提交：(1) 引入 registry + 钉到今日字面量的审计单测，(2) 改写调用点读 registry。步 (1) 测试通过是步 (2) 的闸。 |
| `UCKeyTranslate` 对异常布局上的冷僻 keyCode 返回不可打印字符，UI 现空键帽 | 兜底链：活跃布局翻译 → US-QWERTY 翻译 → 原始 keyCode 十六进制（`<0x4A>`），使行永不空白。 |
| 用户录入一个与我们漏注册的内部命令冲突的和弦 | 审计单测在编译期抓已声明命令的缺项；对未声明 / 未发现的和弦，AppKit-reserved 的硬编码列表是 catch-all，随发现漏洞扩列。 |
| 运行时输入源切换未刷新菜单显示串 | `ShortcutsStore` 暴露随 kTIS 通知 bump 的失效 token；environment 注入的 map 携它，`appKeyboardShortcut` 重渲染；菜单项参与同一 environment。 |
| recorder 的本地监视器在 field 聚焦时干扰 `.keyboardShortcut` 绑定 | 监视器在聚焦期间对 keyDown 返回 `nil`，在事件抵达 responder chain 前吞掉；resign-first-responder 时移除。 |
| `shortcuts.json` 被手编成畸形态、用户下次启动丢覆盖 | 解码失败把坏文件备到 `shortcuts.json.broken-<ts>`（同 `SettingsStore` 策略）+ 空覆盖起步。 |
| 用户录入 `⇧A` 遮蔽到处的键入文本 | recorder 拒绝仅以 `⇧` 为唯一修饰符的绑定，在冲突 detector 前强制。 |

## 参考

- 快捷键原语：`apps/mac/CodansCore/Shortcuts/{CommandID,ShortcutBinding,ShortcutScope,ShortcutSchema,ShortcutOverrideStore,ShortcutResolver,ShortcutResetPlanner}.swift` + `ConflictDetectors/`
- glue 层：`apps/mac/codans/App/Shortcuts/{ShortcutsStore,ShortcutDisplay,ShortcutEnvironment}.swift`、`View+appKeyboardShortcut.swift`、`HotkeyRecorder/`
- 调用点：`apps/mac/codans/App/Commands/MainWindowCommands.swift`、`App/Features/HierarchySidebar/HierarchySidebarView.swift`、`App/Features/Settings/Panes/ShortcutsSettingsView.swift`
- 展示型消费者：`apps/mac/codans/App/Features/CommandPalette/`（见 [command-palette.md](command-palette.md)）、`App/Features/StatusBar/Views/StatusMotivationalView.swift`
