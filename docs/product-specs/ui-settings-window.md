# Product Spec: Settings Window

**状态：** 已上线（可见）
**Author:** Gump (with Claude)

## Summary

codans 提供一个独立的「设置」窗口，承载全局偏好与按 Project 的覆盖设置。窗口
使用左侧侧栏 + 右侧详情的双列布局：侧栏列出全局分段与一个 **Projects** 子树，
详情区渲染当前选中分段的内容。窗口独立于主窗口存在，用户可以一边调整设置一边
观察主窗口中终端、通知、侧栏等表现。

每个 Project 的子行按 `ProjectKind`（`git_repo` / `dir`）裁剪，但 **kind 本身从不
在 UI 暴露**——没有图标、徽章或标签区分两者，唯一信号是可见子行（及详情区内
Section）的集合本身。全部全局分段（General / Notifications / Developer / Shortcuts /
Updates / About，以及 GitHub / Worktrees / Terminal / Global Commands 等）与
Project 分段均已上线，给出可用 UI——外部编辑器、Appearance 主题、代理通知、CLI、
快捷键自定义、Updates 更新通道、per-Project 覆盖与脚本都在对应分段内可交互。

技术设计见 [Settings 设计文档](../design-docs/settings.md)。

## Vocabulary

- **Project** 是 codans 的内部模型：一个 git 仓库绑定（`git_repo`）或一个普通
  文件夹（`dir`）。设置窗口侧栏将这类条目统一展示在 **Projects** 子树下。
- **Section**（分段）指侧栏中的一行。任一时刻最多一个分段被选中。
- **Global section** = 不绑定单个 Project 的分段（General / Notifications /
  Developer / Shortcuts / Updates / About 等）。
- **Project section** = 绑定到一个特定 Project 的分段（其 `ProjectID` 随选中态
  携带）。

## Layout Overview

```
┌──────────────────────┬───────────────────────────────────────────────┐
│  Settings window (independent window, ⌘,)                            │
├──────────────────────┼───────────────────────────────────────────────┤
│ ⚙  General           │  Detail pane for the selected section         │
│ 🔔 Notifications     │                                               │
│ 🔨 Developer         │                                               │
│ ⌨  Shortcuts         │                                               │
│ ⬇  Updates           │                                               │
│ ℹ  About             │                                               │
│                      │                                               │
│ ── Projects ──       │                                               │
│ ▶ codans             │                                               │
│ ▼ some-project       │                                               │
│    General           │                                               │
│    Commands          │                                               │
│ ▶ another-project    │                                               │
└──────────────────────┴───────────────────────────────────────────────┘
  sidebar (≥220pt)        detail (≥530pt)              total ≥750 × ≥500
```

## User Stories

- 作为用户，我希望按 ⌘, 能打开一个独立的设置窗口（而不是阻塞主窗口的模态 sheet），
  这样我可以边改设置边在主窗口观察效果。
- 作为打开了多个 Project 的用户，我希望侧栏下方出现 Projects 子树，展开每个
  Project 都能看到属于它的设置分段，这样我可以只给某一个项目设置不同的默认编辑器、
  worktree 目录或脚本。
- 作为已经在使用外部编辑器配置的用户，我希望原有的默认编辑器选择在新窗口中以
  相同的下拉交互存在（按优先级列出已装编辑器），升级后已有配置不丢失。
- 作为依赖代理通知的用户，我希望在通知分段里能一眼看到系统通知权限的状态，当权限
  被拒时能用一个入口跳到系统设置。
- 作为 `codans` CLI 的用户，我希望在设置窗口里能一键安装 / 卸载 `codans`，不必到
  文档里找 shell 命令。
- 作为已经依赖 `~/.config/codans/` 下手改配置的用户，我希望设置窗口里提供
  "Reveal in Finder" 等逃生入口，让我随时跳到文件原位继续手工编辑。
- 作为使用设置的用户，我希望我做出的改动会被持久化，且不会因为不同功能之间互相
  写入同一份配置文件而丢失其中任何一项。

## Requirements

### 窗口与导航

- **M1 — 独立窗口。** 设置是一个独立窗口，标题 "Settings"。⌘, 打开；若已打开则
  聚焦原窗口，不再开第二个。关闭主窗口不影响设置窗口。Esc 不关闭（符合 macOS
  非模态窗口惯例）。macOS 应用菜单出现 Settings… 项，对应 ⌘,。
- **M2 — 双列布局。** 左侧侧栏 + 右侧详情，两列默认都可见；窗口最小 750 × 500，
  侧栏最小宽度 220pt。
- **M3 — 全局分段。** 侧栏顶部固定列出全局分段，顺序稳定：General、GitHub、
  Worktrees、Terminal、Notifications、Developer、Global Commands、Shortcuts、
  Updates、About。
- **M16 — 选中状态。** 关闭窗口会清空当前选中分段，但不清掉各分段里已填写/已编辑
  的数据。再次打开默认回到 General；各分段内容（未提交的对话框草稿除外）与上次
  一致。

### General 分段

- **M4** 承载：(1) **Appearance**（System / Light / Dark）——选择持久化并实际驱动
  全 app 外观，经 `AppAppearanceView` 同时作用于 SwiftUI 的 `.preferredColorScheme`
  与 AppKit 的 `NSApp.appearance`（覆盖 Ghostty 终端宿主）；footer 提供跳往 Terminal
  分段的链接，在那里设好 light/dark 终端主题后即随此选择同步切换；(2) **Default
  editor**——下拉，按优先级列出所有已装编辑器（含 Finder），全局默认，可被 Project
  级覆盖。打开分段时刷新检测缓存，运行期间新装的编辑器在下次打开设置时出现。

### Notifications 分段

- **M5 — 四个控件。** (1) **In-app notifications**——总开关；(2) **System
  notifications**——开关，打开时若系统权限被拒，弹对话框含 "Open System
  Settings" 直达；(3) **Sound**——开关；(4) **Dock badge**——开关。静音规则
  （`NotificationsSettings.mute`）持久存于 `settings.json`，但其专用规则编辑
  Section 在规则编辑器落地前暂不在分段内呈现（当前 per-pane 静音直接走
  `Pane.labels`）。
- 四个开关正交（in-app 与 system 独立，可实现「仅后台」）。System 关时 Sound 行
  禁用但持久值保留。被拒状态下开启 System 会弹信息性 alert 含深链，而开关保持
  开启（捕获意图，不代表 OS 拦截状态）。各开关的精确门控语义见
  [设计文档](../design-docs/settings.md#notification-gating-notificationssettings)。

### Developer 分段

- **M6** 承载：(1) **`codans` CLI**——显示安装状态（Installed / Not installed /
  Failed），提供 Install / Uninstall 按钮，失败显示错误摘要与重试；(2) **Hooks**
  ——只读列出用户 hook 的名称、启用状态、匹配条件摘要，提供 "Reveal hooks.json in
  Finder"；(3) **Diagnostics**——Reveal settings.json / Reveal hooks.json /
  Copy app version 三个按钮。

### Shortcuts / Updates / About

- **M7 — Shortcuts。** 按类别分组列出 `ShortcutSchema.app` 的每条快捷键，支持录制
  新组合键、禁用某条、单行重置与全部恢复默认；录制时的冲突反馈内联呈现，级联重置前
  弹确认对话框。布局遵循 macOS 系统设置惯例（带分组标题的层级 `Table`）。
- **M8 — Updates。** 承载 Sparkle 更新通道与节奏：通道选择（stable / tip）、后台
  检查开关与节奏、是否自动下载安装，以及一个 "Check for Updates…" 按钮立即探测。
  每次改动写入 `settings.json` 并即时回放给运行中的 Sparkle 实例，启动时同样应用一次。
- **M8b — About。** 显示 App 名称、版本号（短版本 + Build 号）、版权声明、官网链接。

### Projects 子树与 Project 分段

- **M9 — Projects 子树。** 全局分段下方固定 "Projects" 标题。其下每个当前打开的
  Project 作为一个可展开行，按名称字典序排序。行的显示名即 Project 名，不加载
  远端 avatar 或图标。无打开的 Project 时标题出现但其下为空。
- **M10 — Project 子行。** 每个 Project 展开后展示其子行；点击任一子行选中该
  Project 的对应分段。未展开时点击 Project 名默认选中并展开其第一个子行。子行集合
  按 `ProjectKind` 条件裁剪，但 kind 不以任何图标/徽章/标签暴露——唯一信号是可见
  子行集合本身。**实际落地的子行为两个：General 与 Commands**
  （`SettingsSection.projectGeneral` + `.projectScripts`，后者 UI 标题为
  "Commands"）。
- **M11 — Project General 分段。** 承载该 Project 的覆盖控件，按 kind 条件渲染为
  General 详情区内的多个 Section：
  - **Default editor override**（两种 kind 均有）——下拉：Use global default
    （默认，不存覆盖值）、Finder、所有已装编辑器。
  - **Worktree base directory override**（仅 `git_repo`）——路径选择器 + 清除
    按钮；清除等价于回退全局默认。
  - **GitHub 覆盖**（仅 `git_repo`）——合并策略 / 合并后动作 / 禁用 GitHub 集成
    等，每项可"使用全局默认"。
  - **Environment variables**（两种 kind 均有）——键/值编辑。
  - 这些覆盖均存于 `settings.json` 的 `projects[ProjectID]`；`nil` 表示继承全局
    默认。详见设计文档。
- **M12 — Project Commands 分段。** 承载该 Project 的脚本：worktree 生命周期脚本
  （`git_repo` only：setup / archive / delete）与用户自定义脚本列表。生命周期
  脚本内联阻塞地围绕对应 worktree 动作执行（setup 失败阻断创建；archive / delete
  失败仅告警），与异步 fire-and-forget 的 `worktree.*` hook 订阅语义不同。

### 持久化与一致性

- **M13 — 持久化与互不覆盖。** 任一分段所做改动在合理延迟内持久化到磁盘，关闭
  窗口后仍保留。不同分段之间的设置不会互相覆盖或丢失（改 Notifications 不会覆盖
  General，反之亦然）。崩溃恢复或进程终止时当前改动不丢失超过最近一次操作。这由
  「单写者 `SettingsStore` 拥有整棵 `Settings`」保证（见设计文档
  "The single-writer invariant"）。
- **M14 — 配置升级与兼容。** 既有用户历史版本已写盘的设置（默认编辑器、自定义
  编辑器、通知偏好、per-Project 覆盖）在首次启动新版本后全部被保留和正确读取；
  升级自动进行，不要求用户手动操作。迁移会把原文件保留在旁（`*.v1-<ts>` /
  backup）以便恢复。

### 授权

- **PM1** 首次横幅时按需弹窗（非启动时）；**PM2** Settings 显示状态 + Request /
  打开系统设置 的恢复路径。

## Acceptance Criteria

### 窗口生命周期

- app 运行时按 ⌘, → 出现标题 "Settings"、至少 750 × 500、左右两列都可见的窗口。
- 窗口已可见时再按 ⌘, → 聚焦该窗口，不新开第二个。
- 窗口打开时关闭主窗口 → 设置窗口保持打开并可继续操作。
- 关闭设置窗口后再次按 ⌘, → 默认选中 General。

### 侧栏与导航

- 没有打开任何 Project 时打开设置 → "Projects" 标题出现但其下为空。
- 已打开两个 Project `A`、`B` 时打开设置 → Projects 下出现两个可展开条目，按
  字典序排列，均折叠态。
- 正在看 Project `A` 的某子分段时主窗口新增 Project `C` → 侧栏立即反映 `C`，
  当前选中不变。
- 正在看 Project `A` 的某子分段时主窗口关闭 `A` → 选中自动回落到全局 General
  （不停留在已消失的条目上）。

### General 分段

- 升级前历史配置里 `defaultEditorID` 为某具体编辑器 → 首次打开新版本设置窗口，
  General 的 Default editor 下拉展示该编辑器为选中项。
- Appearance 设为 Dark → 主窗口（含 Ghostty 终端宿主）即时切换为深色；关闭再打开
  设置仍显示 Dark。

### Notifications 分段

- 系统通知权限为拒绝时打开 System notifications → 弹对话框含 "Open System
  Settings"，点击跳转系统设置相应位置；开关保持开启。
- In-app notifications 关闭时某 Pane 中的代理完成 → 主窗口不出现应用内未读
  指示，Dock 角标保持 0。
- Sound 与 System 都开且权限已授予时代理完成 → 系统通知伴随声音出现。
- Dock badge 关闭时存在未读通知 → Dock 图标不显示角标。

### Developer 分段

- `codans` 未安装 → CLI 行显示 "Not installed" 和 Install 按钮。
- 点击 Install 成功 → 该行变 "Installed"，按钮变 Uninstall。
- 点击 Install 失败 → 显示错误摘要与重试按钮；重试成功后回到 "Installed"。
- 点击 Reveal hooks.json 而本地尚无该文件 → 创建一个默认空文件并在 Finder 中
  显示它。
- 点击 Copy app version → 剪贴板出现形如 "0.x.y (Build N)" 的字符串。

### Project General 分段

- Project `A` 之前未设默认编辑器覆盖，在 `A` 的 General 中选择某具体编辑器 →
  该选择在合理延迟内持久化到 `settings.json` 的 `projects[A]`。
- `A` 已设默认编辑器覆盖，切换为 "Use global default" → 该覆盖被清除；从外部打开
  `A` 的行为立即回到全局默认编辑器。
- 在 `A` 的 Worktree base directory override 选择某目录后点击清除 → 该值被清除，
  `A` 的 worktree 创建行为回到全局默认目录。

### Project Commands 分段

- 在 `A` 的 Commands 中设置一个非空 `setupScript`，随后创建 worktree 且脚本以
  非零码退出 → 创建被阻断（on-disk 目录留存，catalog 行不添加）。
- `archiveScript` / `deleteScript` 非零退出 → 对应动作仍继续，失败仅记录告警。

### 持久化与升级

- 先在 Notifications 改动 In-app 开关，再在 General 改默认编辑器，关闭设置窗口
  并重启 app → 两处改动均保留。
- 手动编辑磁盘上的 `settings.json` 后重启 app，只要格式合法 → 设置窗口完整反映
  磁盘上的值。
- 历史版本已有默认编辑器 + 通知偏好 + per-Project 覆盖，升级到本版本并打开设置 →
  全部可见且可编辑，历史已写盘的任意条目不在升级中丢失。

### Shortcuts / Updates 分段

- 点击 Shortcuts → 详情区按类别列出全部快捷键；录制一个与现有项冲突的组合键 →
  内联冲突反馈出现；点击全部恢复默认 → 弹确认对话框。
- 点击 Updates → 详情区出现通道选择、后台检查/自动下载开关与 "Check for Updates…"
  按钮；切换通道 → 写入 `settings.json` 且立即触发一次后台检查。

## Out of Scope

- 静音规则的窗口内可视化编辑器（`NotificationsSettings.mute` 已持久化，但规则编辑
  Section 尚未呈现）。
- 仓库 avatar 获取、贡献者信息展示。
- Skill 安装器 UI（codans Agent Skill 的安装由 CLI 驱动，不进入设置窗口）。
- 侧栏顶部搜索框；设置的 JSON 导入/导出。
- 按 Project hook 的在窗口内可视化新建/编辑（仅 "Reveal in Finder" 逃生入口）。
- 每-Worktree 级覆盖（覆盖层级为 global → Project；详见设计文档 Non-Goals）。
- 移除某 Project 后其 per-Project 覆盖值的自动垃圾回收（保留以备重新添加；空
  条目在保存时由 GC 折叠，不污染磁盘）。

## References

- 设计文档：[settings.md](../design-docs/settings.md)
- 通知门控语义：[notifications.md](../product-specs/notifications.md)
- Project 模型：[project-management.md](./project-management.md)
