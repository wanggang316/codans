# Product Spec: Settings Window

**Status:** Draft — amended 2026-04-25 (Project Settings refactor)
**Author:** Gump (with Claude)
**Date:** 2026-04-21

> **Amendment 2026-04-25** — 后续 `docs/design-docs/project-settings.md` 落地后，
> 词汇与子分段做了重大调整：侧栏分段名由 "Repositories" 改为 "Projects"；每个
> Project 下的子行按 `ProjectKind`（`git_repo` / `dir`）动态裁剪；
> Kind 本身不以任何图标、徽章或标签形式在 UI 暴露，唯一信号是可见子行集合本身。
> v3 schema 将 `Project.defaultEditor` / `Project.worktreesDirectory` 从
> `catalog.json` 迁到 `settings.json.projects[pid]`；GitHub 覆盖从
> `repositories[pid].{defaultMergeStrategy, postMergeAction, githubDisabled}`
> 迁到 `projects[pid].git.*` 子对象。下方原文中未对齐的部分以 design doc 为准。

## Summary

codans 提供一个独立的「设置」窗口，承载全局偏好与按 Project 的覆盖设置。
窗口使用左侧侧栏 + 右侧详情的双列布局：侧栏列出全局分段（General /
Notifications / Developer / Shortcuts / Updates / About）与 Projects 子树，
详情区渲染当前选中分段的内容。每个 Project 的子行按 kind 条件渲染：
`git_repo` 暴露 6 个（General / Git & Worktree / GitHub / Scripts / Hooks /
Environment），`dir` 暴露 4 个（省略 Git & Worktree、GitHub）。
窗口独立于主窗口存在，用户可以一边调整设置一边观察主窗口中终端、通知、
侧栏等表现。

本次交付的范围是「设置窗口的基础版本」：框架 + 骨架完整，已落地能力（外部编辑器、
代理通知、CLI、Hooks 只读）对应的分段给出可用 UI；尚未落地的能力（Shortcuts
自定义、Updates 更新通道、Appearance 主题引擎）以占位分段出现，保证导航形状
与未来扩展槽位到位。

## Vocabulary

- **Project** 是 codans 内部模型（见 `docs/product-spec.md` 的 C2）中的一个
  git 仓库绑定。**设置窗口** UI 中，侧栏将这类条目展示为 **Repositories**；
  两者指的是同一类对象。
- **Section**（分段）指侧栏中的一行。任一时刻最多一个分段被选中。
- **Global section** = 不绑定单个 Repository 的分段（General / Notifications /
  Developer / Shortcuts / Updates / About）。
- **Repository section** = 绑定到一个特定 Project 的分段（Repository
  General / Repository Hooks）。

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
│ ── Repositories ──   │                                               │
│ ▶ codans         │                                               │
│ ▼ some-project       │                                               │
│    General           │                                               │
│    Hooks             │                                               │
│ ▶ another-project    │                                               │
└──────────────────────┴───────────────────────────────────────────────┘
  sidebar (≥220pt)        detail (≥530pt)              total ≥750 × ≥500
```

## User Stories

- 作为用户，我希望按 ⌘, 能打开一个独立的设置窗口（而不是阻塞主窗口的模态 sheet），
  这样我可以边改设置边在主窗口观察效果。
- 作为打开了多个 Repository 的用户，我希望侧栏下方出现 Repositories 子树，
  展开每个 Repository 都能看到属于它的设置分段，这样我可以只给某一个项目
  设置不同的默认编辑器或 Hooks。
- 作为已经在使用外部编辑器配置的用户，我希望原有的默认编辑器、内置编辑器列表、
  自定义编辑器配置在新窗口中以相同的交互存在，已有配置不丢失。
- 作为依赖代理通知的用户，我希望在通知分段里能一眼看到系统通知权限的状态，
  当权限被拒时能用一个入口跳到系统设置。
- 作为 `codans` CLI 的用户，我希望在设置窗口里能一键安装 / 卸载 `codans`，不必到
  文档里找 shell 命令。
- 作为已经依赖 `~/.config/codans/` 下手改配置的用户，我希望设置窗口里
  提供 "Reveal in Finder" 等逃生入口，让我随时跳到文件原位继续手工编辑。
- 作为使用设置的用户，我希望我做出的改动会被持久化，且不会因为不同功能
  之间互相写入同一份配置文件而丢失其中任何一项。

## Requirements

### Must have

- [ ] **M1 — 独立窗口。** 设置是一个独立的窗口，标题为 "Settings"。⌘, 打开
  该窗口；若已打开则聚焦原窗口，不再开第二个。关闭主窗口不影响设置窗口。
- [ ] **M2 — 双列布局。** 左侧侧栏 + 右侧详情，两列默认都可见；窗口最小尺寸
  750 × 500，侧栏最小宽度 220pt。
- [ ] **M3 — 六个全局分段。** 侧栏顶部固定列出 General、Notifications、
  Developer、Shortcuts、Updates、About 六个分段，顺序如列出。
- [ ] **M4 — General 分段。** 承载以下控件：
  1. **Appearance**（外观）— 单选：System / Light / Dark。当前版本选择后会
     持久化，但不实际改变主窗口外观（外观引擎尚未实装）。控件需在标题旁
     加 "Preview" 字样提示用户其未生效。
  2. **Default editor**（默认编辑器）— 下拉选择：Finder + 所有已安装的
     编辑器。此为全局默认值，可被 Repository 级别的设置覆盖。
  3. **Built-in editors**（内置编辑器列表）— 只读；每行显示已装 / 未装
     状态、显示名、命令路径或预期位置。提供 "Refresh detection" 按钮。
  4. **Custom editors**（自定义编辑器列表）— 可新增 / 删除；新增时弹窗采集
     ID、显示名、可执行文件、参数模板；实时校验。
- [ ] **M5 — Notifications 分段。** 承载以下控件：
  1. **In-app notifications**（应用内通知）— 总开关。
  2. **System notifications**（系统通知）— 开关；打开时若系统权限被拒，
     弹出对话框提示并提供 "Open System Settings" 按钮直达系统偏好。
  3. **Sound**（通知声音）— 开关。
  4. **Dock badge**（Dock 角标未读数）— 开关。
  5. **Mute rules**（静音规则摘要）— 只读展示当前生效的静音规则计数；
     "Reveal rules.json in Finder" 入口让用户手改。
- [ ] **M6 — Developer 分段。** 承载以下控件：
  1. **`codans` CLI** — 显示当前安装状态（Installed / Not installed / Failed）；
     提供 Install / Uninstall 按钮。操作失败时显示错误摘要与重试按钮。
  2. **Hooks**（Hook 列表）— 只读列出用户 Hook 的名称、启用状态、匹配
     条件摘要；提供 "Reveal hooks.json in Finder" 入口让用户手改。
  3. **Diagnostics**（诊断入口）— 三个按钮：
     - Reveal settings.json
     - Reveal hooks.json
     - Copy app version（复制到剪贴板）
- [ ] **M7 — Shortcuts 与 Updates 分段。** 进入后显示统一的占位面板：
  "Coming in a later release." 选中仍高亮，不产生空态闪烁。
- [ ] **M8 — About 分段。** 显示 App 名称、版本号（短版本 + Build 号）、
  版权声明、官网占位链接。本版本不包含 "Check for updates"（归属 Updates，
  未交付）。
- [ ] **M9 — Repositories 子树。** 全局分段下方固定 "Repositories" 标题。
  其下每个当前打开的 Project 作为一个可展开行，按名称字典序排序。
  行的显示名即 Project 名，不在本版本加载远端 avatar 或图标。
- [ ] **M10 — Repository 展开后的两个子分段。** 每个 Repository 展开后
  展示 **General** 与 **Hooks** 两行，点击任一行选中该 Repository 的对应
  分段。未展开时点击 Repository 名默认选中并展开该条目的 General。
- [ ] **M11 — Repository General 分段。** 承载以下控件：
  1. **Default editor override** — 下拉选择：Use global default（默认）、
     Finder、以及所有已安装的编辑器。选中 "Use global default" 时不存任何
     覆盖值。
  2. **Worktree base directory override** — 路径选择器 + 清除按钮。
     清除按钮等价于回退到全局默认。
- [ ] **M12 — Repository Hooks 分段。** 只读列出该 Repository 当前生效的
  Hooks（全局 Hooks 与 Repository 级别 Hooks 的合并结果），每行标注来源
  为 "Global" 或 "Repository"；提供 "Reveal hooks.json in Finder" 入口。
  v1 不在窗口内提供编辑。
- [ ] **M13 — 持久化与一致性。** 用户在任一分段所做改动都会在合理延迟内
  被持久化到磁盘，并在设置窗口关闭后仍然保留。不同分段之间的设置不会
  互相覆盖或丢失（即：改 Notifications 不会覆盖 General 的值，反之亦然）。
  崩溃恢复或进程终止时当前改动不丢失超过最近一次操作。
- [ ] **M14 — 配置升级与兼容。** 对于既有用户，历史版本已经写入磁盘的
  设置（默认编辑器、自定义编辑器、通知偏好）必须在首次启动新版本后全部
  被保留和正确读取。升级过程不要求用户手动操作。
- [ ] **M15 — 菜单与快捷键。** macOS 应用菜单中出现 Settings… 项，对应
  快捷键 ⌘,。Esc 不关闭设置窗口（符合 macOS 非模态窗口惯例）。
- [ ] **M16 — 选中状态保留。** 关闭设置窗口会清空当前选中分段，但不会
  清掉窗口各分段里的已填写/已编辑数据。再次打开时默认回到 General；
  各分段内容（包括未持久化的草稿，如 Custom editor 添加对话框的未提交
  内容除外）与上次一致。

### Nice to have

- [ ] **N1** — 侧栏顶部搜索框，按名称模糊过滤全局分段与 Repository 条目。
- [ ] **N2** — Diagnostics 增加 "Export settings…" / "Import settings…"
  的 JSON 导入导出。
- [ ] **N3** — Repository Hooks 分段支持 enable / disable 单条 Hook 的
  最小编辑，不涉及新建 / 删除。
- [ ] **N4** — About 分段显示 licensing / acknowledgements。

### Out of scope (v1)

- Shortcuts 自定义（快捷键录制、键位冲突检测、覆盖存储）— 占位分段。
- Appearance 主题引擎（光/暗/跟随系统的全 app 渲染）— 控件可交互但不生效。
- Updates 更新通道（自动检查、通道切换、自动下载）— 占位分段。
- GitHub 集成、仓库 avatar 获取、贡献者信息展示。
- 分析 / 崩溃上报 开关。
- Skill 安装器 UI（codans Agent Skill 的安装 / 卸载由 CLI 驱动，
  不进入设置窗口）。
- Worktree 创建策略（是否自动 fetch、是否拷贝 ignored / untracked 文件、
  PR 合并策略等）。
- Hook 的可视化编辑与新建（仅提供 "Reveal in Finder"）。
- 设置文件格式的跨版本升级路径（v1 以上未来版本的兼容策略）。

## Acceptance Criteria

### 窗口生命周期

- 给定 app 正在运行，当用户按 ⌘,，则一个标题为 "Settings" 的窗口出现，
  大小至少 750 × 500，左右两列都可见。
- 给定设置窗口已可见，当用户再按 ⌘,，则该窗口被聚焦，不会新开第二个窗口。
- 给定设置窗口已打开，当用户关闭主窗口，则设置窗口保持打开并可继续操作。
- 给定用户关闭设置窗口，当用户再次按 ⌘, 打开，则窗口默认选中 General
  分段。

### 侧栏与导航

- 给定当前没有打开任何 Project，当用户打开设置，则 "Repositories" 标题出现
  但其下没有任何条目。
- 给定已打开两个 Project `A`、`B`，当用户打开设置，则 Repositories 下
  出现两个可展开条目，按字典序排列，均为折叠态。
- 给定用户正在看 Project `A` 的 General 分段，当主窗口新增 Project `C`，
  则侧栏立即反映出 `C` 的出现，且当前选中不变。
- 给定用户正在看 Project `A` 的 General 分段，当主窗口关闭 Project `A`，
  则选中自动回落到全局 General（不留在已消失的条目上）。

### General 分段

- 给定升级前的历史配置里 `defaultEditorID` 为某具体编辑器，当用户首次打开
  新版本的设置窗口，则 General 的 Default editor 下拉展示该编辑器为选中项。
- 给定升级前已有若干自定义编辑器，当用户打开设置，则 Custom editors 列表
  完整展示所有历史条目。
- 给定用户在 Custom editors 中新增一个合法模板，当用户关闭窗口再次打开，
  则新增条目仍在列表中。
- 给定 Appearance 被设为 Dark，当用户关闭窗口再次打开，则 Appearance
  仍显示 Dark（即便主窗口并未实际变暗）。

### Notifications 分段

- 给定系统通知权限为拒绝状态，当用户打开 System notifications 开关，
  则弹出对话框，包含 "Open System Settings" 按钮，点击后跳转到系统
  设置的相应位置。
- 给定 In-app notifications 被关闭，当某个 Pane 中的代理完成，则
  主窗口不出现应用内通知横幅。
- 给定 Sound 与 System notifications 都开启且权限已授予，当代理完成，
  则系统通知伴随声音出现。
- 给定 Dock badge 被关闭，当存在未读通知，则 Dock 图标不显示角标。

### Developer 分段

- 给定 `codans` 未安装，当用户进入 Developer，则 CLI 行显示 "Not installed"
  和一个 Install 按钮。
- 给定用户点击 Install 且安装成功，则该行变为 "Installed"，按钮变为
  Uninstall。
- 给定用户点击 Install 且安装失败，则该行显示错误摘要与重试按钮；
  重试成功后回到 "Installed" 状态。
- 给定用户点击 Reveal hooks.json 而本地尚无该文件，则创建一个默认
  空文件并在 Finder 中显示它。
- 给定用户点击 Copy app version，则剪贴板内出现形如 "0.x.y (Build N)"
  的字符串。

### Repository General 分段

- 给定 Project `A` 之前未设置默认编辑器覆盖，当用户在 `A` 的 General
  中选择某个具体编辑器，则该选择在合理延迟内被持久化。
- 给定 Project `A` 已设置默认编辑器覆盖，当用户切换为 "Use global default"，
  则该 Project 的覆盖值被清除；从外部打开该 Project 的行为立即回到
  全局默认编辑器。
- 给定用户在 `A` 的 Worktree base directory override 中选择了某个目录，
  当用户点击清除按钮，则该值被清除，`A` 的 worktree 创建行为回到全局
  默认目录。

### Repository Hooks 分段

- 给定全局 Hooks 有两条、Project `A` 未添加任何 Hook，当用户进入
  `A` 的 Hooks 分段，则两条均以 Global 来源出现。
- 给定 Project `A` 的 Hooks 配置文件中存在一条 Hook，当用户进入 `A`
  的 Hooks 分段，则列表在合并视图中显示该 Hook，来源标注为 Repository。

### 持久化与一致性

- 给定用户在 Notifications 分段改动了 In-app notifications 开关，随后
  在 General 分段改动了默认编辑器，当设置窗口关闭再重新启动 app，
  则两处改动均保留。
- 给定设置窗口打开，用户改动若干项后未手动保存直接关闭窗口（或
  system 强制重启）并在合理时间窗口后返回，则改动不丢失。
- 给定用户手动编辑了磁盘上的设置文件然后重启 app，只要文件格式合法，
  则设置窗口完整反映磁盘上的值。

### 升级兼容

- 给定用户历史版本已有默认编辑器 + 自定义编辑器 + 通知偏好，当用户
  升级到包含本规范的版本并打开设置，则三类设置全部可见且可编辑；
  历史上已被写盘的任意条目不会在升级过程中丢失。

### 占位分段

- 给定用户点击 Shortcuts 或 Updates，则详情区显示统一的 "Coming in
  a later release." 文案；侧栏选中高亮正常；再切回 General 正常恢复。

## Design

详细的模块划分、数据模型、持久化与迁移策略、TCA 状态树等技术设计将在
`docs/design-docs/settings-base.md` 中展开（Phase 3），由 `/hs-design`
或对应的 design 阶段产出。

## Open Questions

1. **CLI 安装目标路径** — `codans` 安装到系统路径（需要系统授权对话框）还是
   用户级路径（无授权但需要 PATH 配合）？将影响 Developer 分段中 Install
   按钮的授权提示与错误处理方式。
2. **Appearance 控件视觉状态** — 既然 Appearance 引擎未实装，控件是以
   可交互 + "Preview" 标签的方式出现，还是以禁用 + "Themes coming soon"
   提示的方式出现？本规范当前选用前者。
3. **Repository 条目的垃圾回收** — 当用户在主窗口移除一个 Project 后，
   其过往在设置中产生的 per-Repository 覆盖值是立即清除还是保留以备
   重新添加？
4. **Hooks 的可编辑范围** — 本规范当前将 Hooks 分段定为只读 + Reveal in
   Finder；是否在同一个版本里补一个最小可编辑（enable / disable 单条
   Hook）版本，取决于对范围的取舍。
