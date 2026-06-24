# 用户测试模式 — codans

**状态:** 持续维护文档。既定义一条用户测试用例必须遵循的**约定**,也定义 runner(人、脚本或验证子代理)执行用例时使用的**工具**。随着更多 feature 采用该模式持续扩充。

一条用户测试用例是对**用户可观测表面**的黑盒、行为级检查。同一条用例必须无需翻译即可由以下三类执行者运行:

- **人类 dogfooder**(读步骤、照做、肉眼判断结果);
- **确定性脚本**(`codans` CLI + `peekaboo` + shell 断言);
- **验证子代理**(通过工具驱动 App,断言可观测状态)。

本文档分两层。**约定层**(Selectors、Ready Signals、Personas、Out of Scope)约束*用例*怎么写 —— 严格黑盒。**执行层**(Toolbox、Patterns)面向*运行*用例的人 —— runner 可以使用用例断言绝不能出现的基础设施细节(socket 路径、defaults key、版本号)。

---

## Surfaces 与探测工具

codans 有三个面向用户的表面。每个表面有首选工具和允许的选择器词汇。

| 表面 | 探测工具(首选 → 兜底) | 允许的选择器 |
|---|---|---|
| **SwiftUI 窗口 UI**(主窗口、Settings、sheet、alert、右键菜单、toolbar) | **Peekaboo**(`see`/`inspect_ui` → 按 element id 或 label `click`/`type`)→ `XCUITest` → 人工视觉探测 | Accessibility identifier(`accessibilityIdentifier(_:)`),或可见的 role + label(如 `Toggle("Sound", isOn:)` → role=switch, name="Sound"),或无歧义的屏幕文本 |
| **`codans` CLI**(JSON-RPC 客户端 → App) | shell `codans …` 配合 stdout / 退出码断言 | 子命令 + flag;支持处用 `--json` 输出 |
| **持久化状态文件**(`~/.config/codans/{settings,catalog,notifications,detection-rules}.json`,以及日志) | `jq` 查询文件内容;`log stream` / Console 过滤 `subsystem:"com.gumpw.codans.*"` | 文件路径 + JSON key path;日志过滤表达式 |

若一条用例无法用上述任一探测语言表达,说明它的范围划错了 —— 要么断言是实现内部的(移到单元测试),要么该表面需要一个稳定的 accessibility identifier(作为前置条件 / spec 修订提出,不要用脆弱选择器绕过)。

---

## 工具箱 —— 如何真正驱动 App

按可靠性从高到低、通用性从低到高排列。**优先选用能表达该检查的、序号最小的工具。** 这与业界共识一致:结构化 API ＞ accessibility tree ＞ 像素。

### 1. `codans` CLI —— App 自有的 RPC(首选)

codans 通过 Unix socket 暴露了一套 JSON-RPC API,`codans` CLI 是它的客户端。结构化输入输出、无像素、可重放。Project → Worktree → Tab → Pane 领域内的操作都用它。

```bash
codans status                       # App 是否在跑 + 可达性
codans tree                         # 完整层级(projects/worktrees/tabs/panes)
codans worktree new <branch>        # 创建 worktree
codans tab new / tab switch         # tab
codans pane send <pane> 'git status --short'   # 向某个 pane 发送输入
codans pane read <pane>             # 读回该 pane 的渲染输出
codans broadcast ...                # 向一组范围广播输入
```

**指向 Debug 构建:** CLI 默认连生产 socket `/tmp/codans-<uid>.sock`。Debug 构建监听 `/tmp/codans-dev-<uid>.sock`,因此把 CLI 指过去:

```bash
CODANS_SOCKET_PATH=/tmp/codans-dev-$(id -u).sock codans tree
# 或使用 Debug 包内嵌的 codans 二进制(它已默认连 dev socket)
```

### 2. Peekaboo —— CLI 够不到的 GUI 控件(toolbar 按钮、菜单、对话框)

[Peekaboo](https://peekaboo.sh) 通过 **Accessibility tree + ScreenCaptureKit** 驱动任意 macOS App,而非裸坐标。它既是 **CLI** 又是 **MCP server**(子代理可直接拿到 `see` / `inspect_ui` / `click` / `type` / `menu` / `dialog` 等工具)。安装:`brew install steipete/tap/peekaboo`;需要 **Screen Recording + Accessibility** 权限(`peekaboo permissions`)。

标准的 observe → act → verify 循环(每次都重新 observe;element id 只对当前可见状态有效):

```bash
peekaboo list permissions                        # 先确认权限
peekaboo see --app Codans --path /tmp/s.png      # 截图 + 标注 → element id(B1, T2, …)
peekaboo inspect-ui --app Codans                 # 仅 AX:id / role / label,无像素
peekaboo click --on B1                           # 按 id 点击 element(取自最近一次 see/inspect-ui)
peekaboo click "Add Project"                     # …或按可见 label / query
peekaboo type "feat/x"                           # 输入文本
peekaboo hotkey cmd,shift,u                      # 发送快捷键(⌘⇧U)
peekaboo menu click --app Codans --path "File > Close"   # 菜单栏项
peekaboo dialog click --button "Later"           # 系统 sheet/alert 按钮(如 Sparkle 升级框)
```

为何用 Peekaboo 而非手搓 `screencapture`+`osascript`:它定位的是 **element 而非像素**(满足下文"禁止坐标"规则),能在**不抢焦点、不与 Spaces 较劲**的前提下驱动**后台** App,并通过 MCP 暴露同一套原语。运行 `peekaboo learn` 看面向 agent 的完整指南,`peekaboo <cmd> --help` 看精确 flag。

### 3. `osascript` —— 兜底的 GUI 微操

仅当 Peekaboo 做不到(或只需一行按键)时用。发**键盘快捷键**是最稳的形式;按坐标点击最不稳。

```bash
osascript -e 'tell application "System Events" to keystroke "u" using {command down, shift down}'  # ⌘⇧U
osascript -e 'tell application "System Events" to key code 53'   # Escape(关闭 sheet)
```

优先用 Peekaboo 的 `hotkey` / `dialog` / `menu` 替代这些 —— 它们 element 感知,且不依赖哪个窗口是 key window。

### 4. `screencapture` —— 取证,不用于交互

macOS 内置。用于捕获 **FAIL 产物**,不用于驱动 UI。优先截特定窗口而非屏幕矩形(矩形会截到最上层的内容 —— 窗口重叠时会截错):

```bash
screencapture -x -l <windowid> -o /tmp/fail.png        # 特定窗口(稳定)
screencapture -x -R x,y,w,h -o /tmp/fail.png           # 矩形(仅在你掌控 z-order 时用)
```

### 5. 状态注入 —— 不经 UI 直达前置条件

很多时候,直接写底层状态比一路点过去更便宜、更可靠。

```bash
# App 启动前播种状态(见 Fixture Seeding)
cp fixture.json ~/.config/codans/settings.json

# 通过 NSUserDefaults 驱动 Sparkle / 偏好场景
defaults write com.gumpw.codans SUSkippedVersion <build>   # 模拟"Skip This Version"
defaults delete com.gumpw.codans SUSkippedVersion          # 用完清理

# 触发"仅当 appcast 比当前构建新时才走"的代码路径:
# 临时下调 apps/mac/Configurations/Project.xcconfig 里的 CURRENT_PROJECT_VERSION,
# 重新构建,完事用 `git checkout` 还原。
```

---

## 执行模式(Execution Patterns)

从真实 codans 用户测试中提炼的可复用配方,可组合使用。

**P1 —— 优先走 App 自有的 RPC。** 凡是能用 `codans` CLI 表达的(worktree/tab/pane/tree/send/read),都先走 CLI 再考虑 GUI 工具。结构化、确定、无焦点博弈。

**P2 —— 定位 element,绝不用裸坐标。** 用 accessibility id 或 label 解析控件(`peekaboo inspect-ui` → `click --on <id>`),不要用像素。坐标会因窗口移动、缩放、主题、Retina 倍率而失效 —— 而且在用例选择器里是被禁止的。

**P3 —— 等就绪信号,绝不 `sleep`。** 动作前等一个可观测信号(见 *Ready Signals*);动作后**重新 observe** 并断言变化。绝不用 `sleep N` 当作"大概好了吧"的替身。

**P4 —— 注入状态以直达前置条件。** 优先写状态(fixture 文件、`defaults`、版本号下调)而非一路点进某场景。务必记录并还原你改过的东西。例:测"有可用更新",下调 `CURRENT_PROJECT_VERSION`、重新构建,再 `git checkout`;测"用户已跳过",`defaults write … SUSkippedVersion` 再 `defaults delete`。

**P5 —— 安全地让 Debug 构建与生产并存。** Debug 与 Release 用**独立 socket**(`/tmp/codans-dev-<uid>.sock` vs `/tmp/codans-<uid>.sock`),因此 Debug 构建能与用户正在跑的生产 App 共存 —— 无需退出生产。同 bundle id,故用 `open -n <path>/Codans.app` 启动指定构建,并把 CLI 指向 dev socket。注意:两个 *Debug* 实例共享 dev socket 会冲突;先退掉陈旧的那个(`rm -f /tmp/codans-dev-<uid>.sock` 可清掉残留的 socket 文件)。

**P6 —— FAIL 时留证据。** 在第一条失败断言处,捕获窗口截图(`screencapture -l <windowid>` 或 `peekaboo image`)、相关的 `log stream` 片段,以及用例触碰过的任何状态文件的快照。见 *Artifacts on FAIL*。

**P7 —— 靠重新 observe 来验证,而非假设。** 动作返回成功 ≠ UI 真的变了。每次 mutating 动作后,重新拉取状态(CLI `tree`/`read`、Peekaboo `inspect-ui`、文件 `jq`、或一行日志)并据此断言。computer-use 类工具会**静默失败** —— 不要假设任何事。

---

## 选择器(Selectors)

**允许**(稳定、黑盒):

- Accessibility identifier / role + label / 无歧义屏幕文本(窗口 UI)。
- CLI 子命令 + flag;`--json` 字段路径。
- 状态文件路径 + JSON key path;日志过滤表达式。

**禁止**(脆弱 / 白盒):

- **屏幕坐标**(`click at (314, 220)`)—— 除非用例明确针对 Accessibility tree 无法表示的窗口 chrome 行为。Peekaboo 的 element 定位正是为了让你不需要坐标。
- 内部符号名 —— 在*用例*里绝不出现 Swift 类型、函数、文件路径或模块名。(上文 Toolbox 里的 runner 基础设施豁免;用例断言不豁免。)
- 临时发明、未被源码以稳定且有文档的名字声明的 `data-test-*` id。
- 用 `sleep` 当状态替身 —— 改为等可观测信号(见 P3)。

---

## 就绪信号(Ready Signals)

每条驱动 App 的用例,在执行步骤前都要等一个就绪信号。

| 表面 | 就绪信号 |
|---|---|
| App 已启动 | Dock 图标可见 且 主窗口的 worktree 状态栏包含 bell 按钮 |
| Settings 窗口已开 | `Settings → <section>` 标题可见 且 任何异步权限行已 resolve(如 `Authorized` / `Denied` / `Not yet asked`) |
| Pane 已挂载 | Pane chrome 显示 prompt 光标 或 "Spinning up shell…" spinner 已消失 |
| 后台更新检查完成 | `defaults read com.gumpw.codans` 中出现 `SULastCheckTime`,或 `subsystem:"com.gumpw.codans.ui" category:"updates"` 下有一行 appcast 加载日志 |
| 通知已发出 | Dock badge label 变化,或 `subsystem:"com.gumpw.codans.notifications" category:"coordinator"` 下出现含已知动词(`posted`、`drop`)的日志行,或 `notifications.json` 的 `entries` 中新增一行(以用例所指为准) |

---

## Fixture 播种(Fixture Seeding)

文件在 App 启动前放入 `~/.config/codans/`。每条用例指明它播种的确切文件;runner 负责在用例前后备份并还原用户的真实文件。

```
~/.config/codans/
  settings.json            — 归 SettingsStore 所有;可在启动前播种
  catalog.json             — 归 CatalogStore 所有;可在启动前播种
  notifications.json       — 归 NotificationStore 所有;可在启动前播种
  detection-rules.json     — 归 mute-rules 表面所有
```

跨用例共享的 fixture 放在 `docs/user-tests/_shared/fixtures/`;用例本地 fixture 放在 `docs/user-tests/<feature>/fixtures/`。基于 NSUserDefaults 的场景(Sparkle skip 状态等)用 `defaults write` 播种(见 P4)而非文件,并同样还原。

---

## 时间与时钟

用例不假设真实墙钟时间。当用例需要"此刻"语义(1 秒按键窗口、30 秒空闲阈值)时,通过可观测信号或注入的 fake clock 来等待 —— 绝不 `sleep 30`。对于确实需要时长推进的用例(某命令运行 ≥10 秒以跨过阈值),指明下界等待,并把断言绑到可观测事件(Dock badge 出现)而非墙钟值。

---

## FAIL 时的产物(Artifacts on FAIL)

每条用例列出 FAIL 时要捕获什么。除非另行覆盖的默认项:

- `screenshot.png` —— 第一条失败断言处的窗口截图:`screencapture -x -l <windowid>` 或 `peekaboo image --app Codans --path screenshot.png`。
- `console.log` —— 失败前后的 `log stream --predicate 'subsystem == "com.gumpw.codans.*"' --last 5m` 输出。
- 对触碰过状态文件的探测:失败时刻该文件的副本,命名为 `<file>.snapshot.json`。

---

## Personas

Persona 跨 feature 复用。共享注册表为 `docs/user-tests/_shared/personas.yaml`。一个 persona 是一个稳定身份(name + role + 典型配置),用例引用它而无需重述。编写期间新增的 persona 记录在用例的 "Personas / Fixtures Added" 小节。

---

## 范围之外(deferred)

- 视觉回归 / 像素快照 diff。用例断言可观测状态,而非像素保真。(截图是 FAIL 证据,不是判定 pass/fail 的依据。)
- 性能预算。需要 perf SLO 的用例引用既有的 perf-budget 闸,并把该 AC 标为"非用户可观测"。
- 超出 fixture 播种所能表达的跨版本迁移。迁移覆盖归相关模块的单元套件。
