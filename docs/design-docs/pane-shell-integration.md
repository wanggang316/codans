# 设计文档：Pane Shell 集成（command-wrapper）

**状态：** 已实现（本地 pane、远端 pane 的 TERM 回退）
**作者：** Gump（与 Claude）
**实现：** Ghostty fork 补丁（`apps/mac/ThirdParty/ghostty`，见其 `README.tc.md`）、[`SurfaceLaunch`](../../apps/mac/codans/Runtime/Ghostty/SurfaceLaunch.swift)、[`PaneSurface`](../../apps/mac/codans/Runtime/Ghostty/PaneSurface.swift)、[`ZmxAttachCommand.wrapperArgv`](../../apps/mac/codans/Runtime/Ghostty/ZmxAttachCommand.swift)、[`TerminalEngine.ensureSurface`](../../apps/mac/codans/Runtime/TerminalEngine.swift)、[`MasterTerminalController`](../../apps/mac/codans/App/Features/MasterTerminal/MasterTerminalController.swift)、[`RemoteSurfaceCommand.terminfoFallback`](../../apps/mac/codans/Runtime/Ghostty/RemoteSurfaceCommand.swift)、[`ForegroundJobReader.foregroundProcessGroupID`](../../apps/mac/codans/Runtime/ForegroundJobReader.swift)

## 背景与范围

每个本地 pane 的 shell 都跑在一个 zmx 守护进程里，以便 app 退出后会话还在。如果把 `zmx attach <paneUUID>` 直接作为 surface 的 `command` 交给 libghostty，它会按 embedded 模式的约定把这个字符串包成 `/bin/sh -c "<命令>"`，在 macOS 上再在最外层套一层 `login(1)`。这样 libghostty 看到的"要运行的程序"是 zmx，不是用户的 shell，由此带来三个后果：

1. **Ghostty 的 shell 集成从不加载。** libghostty 只在识别出 zsh、bash、fish、elvish、nushell 时，才会注入集成脚本：zsh 通过 `ZDOTDIR` 注入，bash 通过改写成 `--posix` 并设置 `ENV` 注入，fish、elvish、nushell 通过 `XDG_DATA_DIRS` 注入。命令是 zmx 时，这一步被跳过：环境里会有 `GHOSTTY_SHELL_FEATURES`，却没有任何脚本去读它。
2. **依赖集成序列的功能取决于用户自己的 rc 文件。**
   - codans 已经消费 OSC 7（cwd）：pane 重启后回到最后的工作目录（`HierarchyManager.updatePaneWorkingDirectory`）、tab 标题用目录名兜底（`TabBarRowView`）、⌘-click 时解析相对路径。
   - codans 也消费 OSC 133（命令起止）：`commandFinished` 通知（[notifications.md](notifications.md) 把"用户 shell 不发 OSC 133"列为已知限制）。
   - 不加载集成时，这些序列只有在用户自己的 rc 恰好会发出时才有。
3. **在 pane 里 `ssh` 到远端时 TERM 不兼容。** pane 的 `TERM=xterm-ghostty`，ssh 把它带到远端，而远端通常没有这条 terminfo：
   - zsh 主机上，行编辑键（Backspace、←、Delete、Home）缓冲区内容正确，但屏幕显示错乱；
   - bash 主机上，行编辑正常，但 `tput`、`clear`、vim、htop、tmux 不可用。

   Ghostty 用集成里的 `ssh()` 包装来解决这个问题（`ssh-env` 选项），前提是集成已加载。

Server 项目的远端 pane 走另一条路径：本地 zmx 包着 SSH 重连循环，见 [remote-ssh-projects.md](remote-ssh-projects.md)。远端 shell 不经过本地的 shell 解析，所以它的 TERM 兼容由远端脚本自己处理（见下文"远端 pane"）。

codans 自己维护 Ghostty fork（`wanggang316/ghostty`，分支 `v1.3.1-tc`，补丁清单见 fork 内的 `README.tc.md`），可以携带小而独立的补丁。

## 目标与非目标

**目标**

- 本地交互式 pane 由 libghostty 按用户真实的 shell 完成解析、集成和 `login(1)` 包装，zmx 作为最外层监管进程保留会话持久化。
- 默认情况下，在任一受支持 shell（zsh、bash、fish、elvish、nushell）里 `ssh` 到缺少 `xterm-ghostty` terminfo 的主机，行编辑和全屏程序都正常。
- 所有用户默认获得 OSC 7、OSC 133，codans 依赖这些序列的功能不取决于用户的 rc 文件。
- 尊重用户 Ghostty 配置里的 `command`、`shell-integration`、`shell-integration-features`。
- 保持不变：zmx 会话恢复（含 `--restore-from` 快照）、子进程退出语义、agent 识别（前台进程组）、CLI 调用方 pane 解析（进程祖先链）。
- 远端 pane 在主机缺少 `xterm-ghostty` 时回退到 `xterm-256color`，且不改动用户刻意设置的其他 TERM。

**非目标**

- 远端主机侧的 shell 集成：不把集成脚本部署到主机，远端 pane 的 OSC 7/133 仍取决于主机 rc。
- 默认往远端安装 terminfo（`ssh-terminfo` 选项默认关闭，原因见"默认选项"）。
- 覆盖不经交互式 shell 的 `ssh` 调用：`gcloud compute ssh`、`kubectl exec -it`、`docker exec -it`、脚本里调用的 ssh 等。
- 迁移已在运行的 zmx 会话：它们保留创建时的进程链和环境。
- 提供 codans 自己的设置界面：选项通过 Ghostty 配置调整。
- 现在就把补丁提交到上游。

## 设计

### 概览

在 Ghostty fork 里给 surface 配置增加两项能力：

- **command-wrapper**：一段 argv。libghostty 先照常完成全部启动解析（确定 shell、注入集成、套 `login(1)`），最后把这段 argv 拼到最前面再 exec。被包装的整条命令成为 wrapper 的子进程。
- **按 surface 关闭 shell 集成**：这一个 surface 无视全局配置，固定为 `shell-integration = none`。

codans 的交互式 pane 不设置 `command`，而是传 wrapper `[zmx, attach, <paneUUID>, (--restore-from <path>)]`。zmx `attach` 会把会话名后面的参数当作新会话要执行的命令（`parseAttachArgs`，`--restore-from` 不论出现在哪里都会被消费），所以 libghostty 解析出来的 `login -flp <user> /bin/bash --noprofile --norc -c "exec -l <shell>"` 原样落到守护进程里执行。集成需要的环境变量（`ZDOTDIR`、`GHOSTTY_SHELL_FEATURES`、`GHOSTTY_RESOURCES_DIR` 等）由 libghostty 写进子进程环境，依次传给 zmx 客户端、守护进程，`login -p` 会保留它们。

选这个方案的理由是**集成逻辑只有一份，且在上游手里**。

- 各 shell 怎么注入（zsh 的 `ZDOTDIR` 中转、bash 的 `--posix` 改写、fish 的 `vendor_conf.d`）、`login(1)` 和 hushlogin 的细节、`ssh()`/`sudo()` 包装、OSC 133 的 prompt 标记，全部继续由 libghostty 和随包分发的脚本负责。Ghostty 升级时这些一并跟进。
- codans 只多维护两个小而独立的 fork 补丁（wrapper 与集成开关、选项默认值，合计约 60 行）。代价是每次升级 fork 都要重新挑一遍。

在 pane 里可以直接观察到的结果（zsh；把 Ghostty 配置写成 `command = <bash 5>` 时 bash 结果相同）：

- `GHOSTTY_SHELL_FEATURES=cursor:blink,ssh-env,sudo`，`ssh` 和 `sudo` 都是函数，shell 里 `ZDOTDIR` 已还原；
- 进程树为"守护进程 → `login`（独立进程组）→ shell（独立进程组）"；
- `ssh -t` 到缺少 terminfo 的主机，远端为 `TERM=xterm-256color`，zsh 主机上 Backspace、←、Home、Delete 显示正确，bash 主机上 `tput` 可用；
- `cd` 之后 pane 的工作目录随之更新（OSC 7），超过阈值的命令结束后产生"命令完成 / 失败"通知（OSC 133）；
- 前台任务检测、agent 识别、不带 `CODANS_PANE_ID` 的 CLI 调用方解析、app 退出重进后重新接上会话，都与集成前一致。

### 系统上下文

```
把 zmx 作为 command（不采用，集成不加载）：
  libghostty ─ login(1) ─ /bin/bash -c "exec -l /bin/sh -c 'zmx attach <id>'"
                                   └─ zmx client ══socket══ zmx daemon ─ -zsh

本设计：
  libghostty（解析 shell + 注入集成 + login 包装，然后前置 wrapper）
    └─ zmx client ══socket══ zmx daemon ─ login(1) ─ zsh/bash/fish…（Ghostty 集成已加载）
                                                       │  OSC 7 / OSC 133 / ssh() / sudo()
                                                       ▼
                         字节流经 zmx 回到 libghostty → action_cb → codans（pwd、commandFinished…）

远端 pane：
  libghostty ─ /bin/sh -c "zmx attach <id> /bin/sh -c '<SSH 重连循环>'"
             └─ ssh host "<terminfoFallback>; 远端登录 shell"
```

### API 设计

**Ghostty fork（C API）：** 在 `ghostty_surface_config_s` 末尾追加字段：

- `const char* const* command_wrapper` 和 `size_t command_wrapper_count`：已分好词的 argv，直接执行，不经 `/bin/sh -c`，路径里有空格也不需要转义。为空表示不包装。
- `bool disable_shell_integration`：只对这一个 surface 生效。

内部流向：embedded `Surface.Options` → surface 的 `Config` → `termio.Exec.Config.command_wrapper` → `Subprocess.init` 在 `execCommand` 之后把 wrapper 拼到最前面。拼接点必须在 `login(1)` 包装和集成改写**之后**，因为 wrapper 要包住解析完成的那整条命令。不新增用户可见的配置项。

**codans：**

- `PaneSurface.init` 接收一个启动描述 `SurfaceLaunch`，两种形态：
  - `interactive(wrapper:)`：本地 pane。`command` 留空，传 wrapper，并**显式设置 `wait_after_command = true`**。embedded 模式只在设置了 `command` 时才自动打开它；codans 依赖"子进程退出后 surface 不自动关闭"，以 `paneInfoChanged(.childExited)` 作为结束信号。
  - `command(_:)`：远端 pane。沿用现有命令字符串，并设置 `disable_shell_integration = true`，让这条本地 SSH 循环的启动方式不受全局集成配置影响。
- `ZmxAttachCommand.wrapperArgv` 生成 wrapper argv，`--restore-from` 在其中；字符串形态的 `build` 只给远端 pane 用。
- `ForegroundJobReader.foregroundProcessGroupID` 用 `sysctl(KERN_PROC_PID)` 读守护进程子进程的 `e_tpgid`。这个子进程是 `login(1)`，它保持 setuid root，`proc_pidinfo(PROC_PIDTBSDINFO)` 对它返回 EPERM；用 `proc_pidinfo` 读会让前台任务检测（tab 的忙碌指示、`pane send --wait`）始终判定为空闲。

### 默认选项

`shell-integration-features` 的解析规则是：每次赋值都**从内置默认值起步**，再逐项应用列出的选项（`cli/args.zig` 的 `parsePackedStruct`）。所以 codans 不能用"先加载一层默认配置、用户配置覆盖在后"的方式设默认：用户只要写一行 `shell-integration-features = no-cursor`，codans 设的其余选项就会被打回内置默认。

因此默认值放在 fork 里，直接改 `ShellIntegrationFeatures` 结构体的字段默认值。这样用户配置的每一行都从 codans 的默认起步，按 Ghostty 自己的规则逐项覆盖。补丁清单里登记这一项。

| 选项 | Ghostty 默认 | codans 默认 | 理由 |
|---|---|---|---|
| `cursor` | 开 | 开 | 提示符处显示竖线光标，与 Ghostty 行为一致；用户可写 `no-cursor` 关闭 |
| `sudo` | 关 | **开** | `sudo` 会清掉环境里的 `TERMINFO`，而 `xterm-ghostty` 只能通过 app 包内路径找到，`sudo vim` 等会找不到终端描述；包装会把 `TERMINFO` 显式传过去 |
| `title` | 开 | **关** | tab 标题有自己的优先级：手动名称 > OSC 2 > OSC 0 > pwd 目录名。打开后集成会持续发 OSC 2（提示符处为路径，执行中为命令行），把 tab 名字从紧凑的目录名换成长路径或命令。OSC 7 已足够提供目录名。用户可写 `title` 打开 |
| `ssh-env` | 关 | **开** | 本设计的核心修复：`TERM=xterm-ghostty` 时用 `xterm-256color` 连接，并请求传递 `COLORTERM`、`TERM_PROGRAM(_VERSION)`（是否生效取决于主机的 `AcceptEnv`） |
| `ssh-terminfo` | 关 | 关 | 会往远端 `~/.terminfo` 写文件，并用 `ControlMaster`/`ControlPath` 多建一条连接，可能和用户自己的 ssh 复用配置冲突。它的缓存依赖 `ghostty` 命令行程序，codans 没有分发这个程序，所以每次连接都会重新探测一遍 |
| `path` | 开 | **关** | 会把 `Codans.app/Contents/MacOS` 加进 `PATH`，那里没有 `ghostty` 命令行程序，加进去没有意义。codans 的 CLI 已由 `PaneEnvironment` 放进 `PATH` |

`shell-integration`（默认 `detect`）和 `command` 保持 Ghostty 默认，用户配置原样生效。

### 远端 pane

`RemoteSurfaceCommand` 在每段远端脚本的最前面执行 TERM 回退，条件收窄为：

- 只在 `TERM` 正好是 `xterm-ghostty` 时才探测、才回退，用户刻意设置的其他值（含空值）原样保留；
- 探测 `infocmp` 时，临时把常见的工具目录（Homebrew、MacPorts、Linuxbrew）补进 PATH。补的 PATH 只在探测用的子 shell 里生效，不带进会话。这样 `infocmp` 只装在这些目录的主机不会被误判为没有描述；
- 找不到 `infocmp` 视同没有描述，回退。

### 组件边界

- **Ghostty fork**：负责 shell 解析、集成注入、`login(1)`、wrapper 拼接、选项默认值。不了解 zmx，也不了解 pane。
- **zmx**：执行 `attach` 收到的 argv，负责会话持久化和快照恢复。不了解 shell 集成，本设计不改 zmx。
- **`PaneSurface`**：把启动描述翻译成 `ghostty_surface_config_s`，是 app 内唯一构造 surface 配置的地方。
- **`TerminalEngine`**：决定每个 pane 用哪种启动形态：本地用 `interactive`，远端用 `command`。
- **`PaneEnvironment`**：只写 codans 自己的变量，见 [environment.md](environment.md)。集成相关变量（`ZDOTDIR`、`GHOSTTY_*`）由 libghostty 在启动时写入，`PaneEnvironment` 不碰它们。

## 技术决策

- **codans 不自己实现各 shell 的启动垫片。** 用 codans 自己的 `ZDOTDIR` 垫片也能只为 zsh 补上 `ssh()`，但存在三个问题：
  - 只覆盖一种 shell，每多一种就要再写一套；
  - 和 libghostty 的 `ZDOTDIR` 中转机制会叠在一起；
  - 垫片文件丢失时后果很重：`ZDOTDIR` 指向不存在的目录，zsh 会跳过用户的 `.zshrc`，而且 `ZDOTDIR` 会一直留在环境里（已实测）。

  集成脚本只用随 app 包分发的那一份：只读，路径随包走。
- **默认值写在 fork 里，不写在 codans 的配置覆盖层。** 理由见"默认选项"：feature 列表的解析方式决定了覆盖层无法和用户的逐项写法共存。

## 备选方案

**A. 每种 shell 由 codans 自己写启动垫片（zsh 用 `ZDOTDIR`，fish 用 `XDG_DATA_DIRS`……）**

不改 Ghostty 就能修 ssh。否决理由：
- 要逐个 shell 复刻 Ghostty 已有的注入逻辑；
- bash 无法只靠环境变量注入，必须改启动命令，而命令目前由 zmx 决定；
- 拿不到 OSC 133 等完整集成，除非再复刻一遍；
- 垫片放在缓存目录时，有上面"技术决策"里说的"文件丢失则跳过用户 rc"的风险。

**B. 保持 `command = zmx attach …`，用 `shell-integration = <shell>` 强制注入**

libghostty 支持强制指定 shell 类型。否决理由：
- codans 得自己判断用户用的是哪种 shell，并跟着用户的 `$SHELL` 变化同步；
- bash 的注入要改写命令，对 `/bin/sh -c 'zmx attach …'` 这种命令不适用；
- 这样做依赖"注入时环境和命令对不上"这种上游没有承诺过的行为；
- 用户自己配置的 `command` 依然被忽略。

**C. 让 zmx 在启动 shell 时完成集成注入**

否决理由：
- zmx 要了解 Ghostty 的资源目录和各 shell 的注入方式，等于把 libghostty 的逻辑复制进另一个 fork；
- `login(1)` 和 hushlogin 的处理也得一并搬过去；
- 维护面比 A 还大。

**D. 把 pane 的 `TERM` 全局改成 `xterm-256color`**

一次覆盖所有绕过交互式 shell 的场景（`docker exec`、`gcloud ssh`、脚本）。否决作为默认，理由：
- 和 `xterm-ghostty` 相比少约 50 项能力，包括真彩色（`setrgbf`/`setrgbb`）、带样式和颜色的下划线（`Smulx`/`Setulc`，neovim 的波浪下划线要用）、同步刷新（`Sync`）、焦点事件、删除线；
- 不提供 OSC 7/133。

用户需要时可以在 Ghostty 配置里写 `term = xterm-256color` 自行选择。

**E. codans 在命令字符串里自己拼出"`login(1)` + 集成"的完整启动行**

否决理由：要复刻 `execCommand` 的 `login(1)` 与 hushlogin 逻辑和各 shell 的注入，和 A、C 一样是逻辑复制，而且会随 Ghostty 版本漂移。

## 跨领域关注点

**兼容性与迁移**

- 只有新建的 zmx 会话使用新进程链。已存在的会话（会跨 app 重启存活）保持原样，用户关闭 pane 再新建后才生效；发布说明里写明。不做自动迁移，因为替换在跑的会话会丢掉里面的工作。
- 用户 Ghostty 配置里的 `command`（例如 nushell 或 `tmux`）在 codans pane 里开始生效。这是有意的，codans 和 Ghostty.app 共用这份配置（见 [app-appearance.md](app-appearance.md)）。发布说明里提醒设置了 `command = tmux` 一类的用户。
- 用户若在 rc 里手动 source 了 Ghostty 的集成脚本，可能重复加载。验收时用这种配置验证幂等性。

**测试与验证**

- **fork 侧**：wrapper 为空时 argv 不变；wrapper 非空时拼接位于 `login(1)` 包装之后；`disable_shell_integration` 覆盖全局配置。
- **codans 单元测试**：启动描述到 surface 配置的映射，包括 wrapper argv、`--restore-from` 的位置、`wait_after_command`、远端形态的 `disable_shell_integration`。
- **隔离实例端到端测试**：沿用现有的 GUI / CLI 回归测试工具，配置、缓存、socket 全部私有。对 zsh、bash、fish 各验证：
  - `whence ssh` 或 `type ssh` 是函数；
  - `ssh -t` 到缺少 terminfo 的主机，Backspace、←、Delete、Home 的显示和 `tput` 都正常；
  - OSC 7 能驱动 pane cwd 持久化；
  - 跑一条长命令能触发 `commandFinished` 通知；
  - 在 pane 里执行 `exit` 后，pane 照常关闭并从 catalog 移除；
  - 退出 app 再启动后能重新接上会话，`--restore-from` 快照能正常恢复；
  - CLI 不带 `CODANS_PANE_ID` 时，调用方解析仍能命中正确的 pane；
  - agent 识别：shell 处于提示符时前台进程组只有 shell（`login` 在自己的进程组里），运行 `claude` 时能识别出来。
- **macOS 登录会话**：`login(1)` 从客户端侧挪到守护进程侧。需验证 pane 里访问钥匙串的 CLI（如 `claude` 的登录态）行为不变。

**回滚**

- codans 改回传 `command` 字符串即可回到原进程链。fork 补丁在不传 wrapper 时什么也不做，可以留着。
- 默认值补丁可以单独撤回。

## 风险

| 风险 | 缓解 |
|---|---|
| C 头文件和 Zig 实现不一致：在 `ghostty_surface_config_s` 上加字段时，header 和 Zig 侧对不上，而 C 编译器不会报错（fork 曾有过 `ghostty_surface_free_text` 参数个数不一致导致内存泄漏的先例） | 字段只追加在结构体末尾；`ghostty.h` 和 xcframework 从同一个 fork 提交构建；写一个端到端检查：打开 wrapper 后，守护进程的子进程是 `login`、孙进程是用户的 shell |
| 不设置 `command` 时，`wait-after-command` 不会自动打开，shell 退出时 surface 直接关闭，绕过 codans 的退出处理 | 交互式形态显式设置 `wait_after_command = true`；端到端测试覆盖 `exit` 和"结束后关闭"策略 |
| 守护进程侧多了一层 `login(1)`，影响三处：`.info` 报告的 PID、前台进程组判定、CLI 祖先链 | `.info` 的 PID 是 `login`：它和 shell 共用同一个 tty，`e_tpgid` 就是 pane 的前台进程组，但 `login` 是 root 进程，必须经 `sysctl` 读（见 API 设计）；`login` 在 CLI 的祖先链上，祖先链遍历照样能命中；`login` 与 shell 分属不同进程组，提示符处的前台组只有 shell。均有端到端验证 |
| 集成脚本和用户的 rc（oh-my-zsh、starship、其他终端的集成）互相干扰 | 集成脚本由 Ghostty 维护，已经在 Ghostty.app 用户群里广泛使用；验收时覆盖 oh-my-zsh、starship 和手动 source Ghostty 集成这几种配置 |
| 升级 Ghostty 时补丁冲突 | 补丁只改 embedded options、`Exec.Config` 和 `Subprocess` 拼接点三处，逻辑独立；登记进 `README.tc.md`，按 fork 的升级流程逐个挑补丁 |
| 集成脚本发出的 OSC 2 改写 tab 标题 | 默认关闭 `title`（见"默认选项"） |
| 已在运行的会话没有修复，用户以为没修好 | 发布说明写明需要关闭 pane 再新建；`codans doctor` 或 pane 菜单的诊断可以显示该 pane 是否已加载集成（`GHOSTTY_SHELL_FEATURES` 加上 OSC 133 是否出现过），作为后续可选项 |
