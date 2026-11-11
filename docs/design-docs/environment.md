# 设计文档：环境管理（构建通道、路径、环境变量）

**状态：** 已实现
**作者：** Gump（与 Claude）

## 背景与范围

codans 有两种构建同时存在于一台机器上：从 `/Applications` 运行的 Release 包，和从 DerivedData 运行的 Debug 包。两者共用一个 bundle id，却各自拥有一套 catalog、settings、zmx 守护进程和 IPC socket。一旦其中任何一样串了，症状都是静默的：两个 app 对同一个 PTY 各挂一个 attach 客户端，输入在两边来回串；dev pane 里跑的 CLI 被生产 app 应答；handoff 指令让 agent 去找一个不存在的子命令。

这些决定原本散落在四处 `#if DEBUG`、五处 `"CODANS_SOCKET_PATH"` 字面量、两份逐字节相同的 socket 路径字符串和一条「必须保持同步」却无人执行的注释里。本文档记录收敛后的结构：**通道决定一次，变量名拼写一次，pane 环境构建一次**，以及哪些资源刻意不隔离。

范围是 `apps/mac` 下四个 Swift target 之间的环境契约：CodansCore（叶子）、CodansKit（CLI 侧库）、`codans-cli`、app。不涉及 Ghostty 自身的配置解析。

## 目标与非目标

**目标**

- 一个 Debug 包和一个 Release 包能同时运行、互不干扰，且不依赖用户做任何配置。
- 每个跨进程边界的名字（环境变量、socket 路径、目录名、命令名）在代码里只有一个拼写点。
- 从 pane 里启动的 CLI 一定回连到生成它的那个 app。
- 测试与冒烟运行能把整个配置根搬到临时目录。

**非目标**

- 按分支或 worktree 隔离。所有 Debug 构建共用 `codans-dev`；需要时用 `CODANS_CONFIG_DIR` 手动隔离。
- 给两个通道不同的 bundle id。这会拆开通知中心身份、Sparkle 状态和 URL scheme 注册，代价大于收益。
- 子进程环境的白名单卫生（git、gh、glab 的 env 转发）。它有自己的机制（`GitProcessEnv`、各平台的 `makeEnv`），不属于 Pane 环境组装契约；本文只记录这些命令经 login shell 启动的方式（见「后台命令经 login shell 启动」）。

## 设计

### 总览

三个类型，各负责一件事，都在 `CodansCore/Environment/`，因为它是 kit、cli、app 唯一的公共依赖：

| 类型 | 负责 | 消费者 |
|---|---|---|
| `BuildChannel` | 构建通道判定；`slug`（`codans-dev` / `codans`）和 `socketPath(uid:)` | `AppDirectories`、`CLIInvocation`、`SocketDiscovery`、`SocketPaths`、CLI 帮助文本 |
| `CodansEnvironment.Key` | codans 读或写的每一个环境变量名，附写者、读者、生命周期 | 所有读写点；类型化持有者（`BuiltinEnvVar`、`TermProgramEnv`、`CLIBundleLocator.EnvKey`、`HandoffKickoff.requestIDEnvironmentKey`）保留 API、从它取值 |
| `HandoffLayout` | `.codans/handoff/` 的文件与目录名 | `HandoffStore`（URL）、`HandoffKickoff`（给接收方的相对路径字符串） |

app 层再加一个 `PaneEnvironment`（`codans/Runtime/`），把「一个 pane 的 shell 以什么环境启动」收成两个阶段，所有 surface 共用。

### 通道隔离了什么

`BuildChannel.current.slug` 派生出全部按通道分开的资源：

```
                     Debug                               Release
config root          ~/.codans-dev/config/               ~/.codans/config/
state root           ~/.codans-dev/state/                ~/.codans/state/
runtime root (ZMX_DIR) ~/.codans-dev/run/                ~/.codans/run/
cache root           ~/Library/Caches/codans-dev/        ~/Library/Caches/codans/
IPC socket           /tmp/codans-dev-<uid>.sock          /tmp/codans-<uid>.sock
CLI 名               codans-dev                          codans
  包内文件           Contents/Resources/bin/codans-dev   Contents/Resources/bin/codans
  安装软链           /usr/local/bin/codans-dev           /usr/local/bin/codans
  自称               --help / 报错提示 / 握手 clientBinary 都用本名
```

config 根放用户会手改的文件，state 根放只有 app 写的文件，runtime 根放 zmx 的 daemon socket、快照与日志，cache 根放可重建的数据。socket 不能放在 cache 根下：清理工具会整目录删掉 `~/Library/Caches/<slug>`，daemon 还活着却再也连不上，下一次 `zmx attach` 会在原地新建会话，pane 里的 shell 和 agent 就"消失"了（见 [lessons-learned](../lessons-learned/2026-10-20-cache-cleaner-wiped-zmx-sockets.md)）。0.7.11 及更早版本把 socket 放在 cache 根下，启动时 `SessionReaper.migrateLegacySocketDirectory` 把还活着的 daemon 的 socket 挪进 runtime 根（已绑定的 AF_UNIX socket 改名后仍可连接）。0.7.8 及更早版本把 config 与 state 都放在 `~/.config/<slug>/`，首次启动由 `LegacyConfigMigrator` 一次性迁入新根（见 [Architecture › Persistence](../architecture.md#persistence)）。`~/.codans/` 下的 `repos/`、`workspaces/`、`sources/` 是用户的 git 工作区，不按通道区分，两个构建共用。

两个构建是**两个应用**：名字本身携带通道，一个通道的 CLI 只拨自己通道的 socket（见下文两节）。包内文件名由 `Project.swift` 的 `CODANS_CLI_NAME` 构建设置给出（Debug `codans-dev`，Release `codans`），`embed-codans.sh` 按它落盘，`CLIBundleLocator` 按 `CLIInvocation.commandName` 查找；两者必须与 `BuildChannel.slug` 一致。

用构建类型而不是 bundle 身份做判别是刻意的：`codans` CLI 链接同一个 CodansCore，Debug 构建的 CLI 必须和 Debug 构建的 app 算出同一组路径，编译期常量能保证；读 `Bundle.main` 则会分叉，因为 CLI 的 bundle 是它自己。

### 通道没隔离什么

两个构建的 bundle id 都是 `com.gumpw.codans`，凡按 bundle id 寻址的系统资源都是共享的，使用时要知道：

- `UserDefaults.standard`：`@AppStorage` 的面板状态、Command Palette 最近使用、遥测 install-id、Sparkle 的全部状态。
- 系统通知按 bundle id 归属。`codans://focus` 深链**不是**注册的 URL scheme，它只在通知 payload 里由本进程解析，所以不经 LaunchServices。
- Sparkle 在 Debug 里不启动（`UpdatesEnvironment.isEnabled` 按 `BuildChannel` 判定），`UpdatesClient` 也不写它的偏好：Debug 包的版本与 appcast 无关，检查只会弹出把它"升级"成正式版的弹窗，且 Sparkle 状态在共享的 UserDefaults 里，Debug 写入会串到已安装的 app。Sentry 在 Debug 里同样不启动（`CrashReporting` 提前返回）。

### Socket 解析的两种语义

socket 路径的拼写只有一份，但**解析规则故意有两份**，因为两侧回答的问题不同：

```
CLI（SocketDiscovery.resolve）                      app（SocketPaths.resolve）
  --socket 标志                                       $CODANS_SOCKET_PATH
  → $CODANS_SOCKET_PATH                               → 若等于「对方通道」的默认值：丢弃，用自己的
      等于对方通道默认值时：                            → 否则采用
        release `codans` 在 dev pane → 拒绝（exit 15） → 未设置：本通道默认值
        dev `codans-dev` 在 release pane → 忽略，用自己的
      否则采用
  → 本通道默认值
```

app 侧的守卫处理「从 Release 的 pane 里 `make mac-run-app`」：子 app 继承了宿主注入的 `CODANS_SOCKET_PATH`，若照单全收会去绑宿主的 socket，报 `alreadyInUse`，自己的 server 起不来，还把错误的 socket 广告给自己的 pane。

CLI 侧的规则是**名字即通道**：`codans` 只驱动 release app，`codans-dev` 只驱动 dev app，`$CODANS_SOCKET_PATH` 只能在通道内细化目标。它等于对方通道的默认 socket，说明这个 pane 里敲了错的 CLI，两个方向处理不同：release 的 `codans` 出现在 dev pane 里**拒绝**（`CLIExitCode.wrongChannel` = 15，提示改用 `codans-dev`），因为 dev pane 里 agent 敲的任何东西都不允许误触生产 app；dev 的 `codans-dev` 出现在 release pane 里**忽略**继承值、拨 dev socket，因为开发者就是在生产 pane 里调 dev app 的。显式 `--socket` 永远生效，是有意跨通道的出口；其他任何值视为自定义 socket，两个通道都照用。`codans doctor` 把拒绝报成 `socketStatus wrong-channel` 而不退出。

可选 socket override 为 `nil` 时，解析器仍需在函数体内读取环境变量。环境读取不能仅依赖可被显式 `nil` 覆盖的默认参数，否则会跳过 `CODANS_SOCKET_PATH` 并落到构建默认值。

### Pane 环境的两个阶段

```
processBase(inheriting:overrides:socketPath:marketingVersion:)
  1. 继承进程环境
  2. 剥掉 TERM / TERMCAP / TERMINFO / COLORTERM / TERM_PROGRAM(_VERSION)
     —— 让 libghostty 在 PTY 时写入的值生效；从 make → open 启动的 app
        会带着 TERM=dumb，透传下去会弄坏 starship 一类 TUI
  3. 叠加项目 envVars
  4. 最后写 CODANS_SOCKET_PATH、CODANS_CLI、TERM_PROGRAM、TERM_PROGRAM_VERSION，
     并把本 app 内置 CLI 的目录放到 PATH 最前
     —— 写在最后，所以项目自定义的同名变量（包括自己重建的 PATH）永远遮不住它们

forSurface(base, paneID:, zmxDirectory:)
  5. ZMX_DIR      钉死到本通道的缓存目录
  6. ZMX_SESSION  清空 —— 从 zmx pane 里启动的 app 会继承父会话名，attach 会当作
                  「切换到那个会话」而失败，表现为 tab 一闪就没
  7. CODANS_PANE_ID  pane 自己的 id
```

worktree pane 在 4 和 5 之间还会由 `HierarchyManager.injectingBuiltins` 写入 `CODANS_WORKTREE_PATH` / `CODANS_ROOT_PATH`。

只注入 `CODANS_PANE_ID` 而不注入 tab / worktree / project id 是有意的：pane id 终生不变，烘进环境是安全的；其余三个会随 pane 被移动而过期，所以由服务端从进程祖先解析。CLI 的 `AliasResolver` 仍认这五个键，是为了让调用方手动导出时能就地短路，但 app 只写 pane 那一个。

### pane 里的 CLI 叫什么

pane 里 agent 或脚本执行的 codans 命令，必须落到**生成这个 pane 的 app** 自带的 CLI。做法是让名字携带通道：Debug 构建把 CLI 内嵌为 `bin/codans-dev`，Release 为 `bin/codans`；`PaneEnvironment` 把内置 `bin/` 目录（同目录还有 `zmx`）加进 `PATH`，并导出 `CODANS_CLI` 为绝对路径。两者都在项目 overrides 之后写入；同一目录在 `PATH` 里只保留一份。

靠 `PATH` **顺序**是不够的，这是前一版的错误：pane 的 shell 是 login shell，macOS 的 `/etc/zprofile` 会运行 `path_helper`，把 `/etc/paths` 里的系统目录（含 `/usr/local/bin`）排到最前，app 前置的目录被挤到后面。同名的 `codans` 永远输给 `/usr/local/bin/codans`，也就是生产包。唯一的名字不需要顺序：系统里没有第二个 `codans-dev`，目录排在哪都能找到；找不到时是 command not found，而不是悄悄打到另一个 app——失败的方向是对的。

由 codans 自己生成的命令（handoff 的 kickoff 那行）由 `CLIInvocation.command` 拼写：`/usr/local/bin` 下没有该名字的条目、或该条目就指向本构建 → 写短名；条目指向别处（含失效软链）→ 写内置二进制的绝对路径。安装器把指向别的构建或已不存在的内置二进制的软链判为 stale，Install 直接替换。

agent 按 skill 敲裸 `codans` 的情况仍会发生，所以 CLI 自己再守一道（上一节）：release 的 `codans` 发现所在 pane 属于 dev 构建就拒绝并指出该用 `codans-dev`。需要确定二进制身份的脚本使用 `"$CODANS_CLI"`；裸命令的结果仍取决于调用方的 PATH。

### 后台命令经 login shell 启动

从 Dock 或 Finder 打开的 app 由 launchd 启动，`PATH` 只有 `/usr/bin:/bin:/usr/sbin:/sbin`。app 直接启动的 git 找不到 Homebrew、mise 一类工具装的程序，也就找不到 git 再启动的程序：仓库本地配置的 `credential.<url>.helper = !glab auth git-credential` 报 `glab: command not found`，随后 `could not read Username`。同一条命令在 codans 终端里能成功，因为 Ghostty 把每个终端作为 login shell 启动。

所以会访问远端、可能启动用户 helper 的后台命令（访问远端的 git、`gh`、`glab`）**每次**都经用户的 login shell 启动，不在启动时读一次 `PATH`：shell 配置的改动对下一条命令生效，不需要重启 app。高频的本地命令直接启动，只在报告「找不到命令」时用 login shell 重试一次（见下表）。一次 login shell 调用的形状（`LoginShellLaunch`，`codans/Process/`）：

```
/bin/sh -c 'exec 3>&1 4>&2 >/dev/null 2>&1; exec "$0" "$@"' \
  <shell> -l -c '<script>' -- <cwd> KEY=VALUE… <executable> <arguments…>

/bin/sh:  captured stdout/stderr -> fds 3/4; fds 1/2 -> /dev/null; exec the login shell
script:
  save "$@" (cwd, then argv); set --        rc cannot see or change the command
  source rc  </dev/null 3>&- 4>&-            rc gets neither the output nor the pipes
  builtin cd -- <cwd> || exit 125            after the rc, which may cd
  exec /usr/bin/env -i "PATH=$PATH" KEY=VALUE… <executable> <arguments…> 1>&3 2>&4 3>&- 4>&-
```

- **shell**：用户数据库里的 login shell（`getpwuid`），是 zsh、bash、fish 之一时用它，其他一律 `/bin/zsh`。每次调用都重新读。
- **rc**：`-l` 读 profile（`/etc/zprofile` 的 `path_helper`、`brew shellenv`）；`-c` 不是交互式，不读 rc，所以显式 source：zsh `${ZDOTDIR:-$HOME}/.zshrc`，bash `~/.bashrc`。fish 例外：fish 对每个 `-c` 都自己加载 `config.fish` 与 `conf.d`（在脚本之前，且看不到 `$argv`），再 source 一次会执行两遍，所以不再 source。
- **输出**：命令之前 shell 执行的一切（profile、rc、fish 自动加载的配置）都可能打印 banner，而 profile 和 fish 配置在脚本之前运行，脚本里的重定向管不到。所以由外层 `/bin/sh` 先把捕获用的 stdout / stderr 移到 fd 3 / 4，把 1 / 2 指向 `/dev/null`，再 exec login shell；只有最后的 `exec` 把 3 / 4 还给命令，命令不持有 3 / 4。rc 自己启动的后台进程也拿不到这两个管道。
- **环境**：rc 执行完后，命令拿到的**恰好**是调用方给的环境，只有 `PATH` 取自 login shell（`env -i` 加上逐个 `KEY=VALUE`）。所以每个调用方的环境契约在 rc 之后依然成立：`GitProcessEnv` 的白名单与剥掉的 `GIT_*`、强制的 `LC_ALL`、`GIT_TERMINAL_PROMPT=0`、`gh` / `glab` 剥掉的 token 变量。rc 导出的被剥键（例如 `GIT_DIR`、`GITLAB_TOKEN`）到不了命令。每个 git 调用方因此必须自己给出 git 的环境：`LiveGitService` 的本地读取用 `GitProcessEnv.build`（只有 `PATH`、`HOME` 与 `LC_ALL`）；`GitWorktreeShell`（worktree、clone、fetch、push、`wt`）与 `GitWorktreeCLI` 用 `GitProcessEnv.inheriting`：保留父环境（`ssh` 要 `SSH_AUTH_SOCK`，代理要它的变量），去掉**所有** `GIT_*`，强制 `LC_ALL=C.UTF-8` 与 `GIT_TERMINAL_PROMPT=0`。
- **工作目录**：`Process` 以 `/` 启动 shell，由脚本在 rc 之后 `builtin cd`。目录不存在时退出码 125（`LoginShellLaunch.directoryFailureStatus`），表示「命令没有启动」，不与 git 自己的失败混淆。
- **进程**：`/bin/sh` exec login shell，login shell exec 命令，pid 不变，runner 的超时与取消直接杀到真实进程。`Process` 把子进程放进独立进程组，超时或取消时 runner 向整个进程组发 SIGTERM、1 秒后 SIGKILL，rc 里还没结束的命令和 git 启动的 helper 也一起结束。
- **前置检查**：可执行文件不存在时，不启动 shell，直接返回 `binary not found`，与直接启动时相同。路径含 `=` 时报错（`env` 会把它当作赋值）。

每个调用点通过 `CommandRunner.run(…, launch:)` 选择 `CommandLaunch`：

- `.direct`：直接启动。
- `.loginShell`：经 login shell 启动。
- `.directThenLoginShell`：直接启动；退出码 127，或非零退出且 stderr 含 `command not found`（git 把 helper 的这句原样转出，自己以 128 退出），就经 login shell 再跑一次。只重试一次，每次尝试各有完整的超时。

`GitWorktreeCLI`（Clone Repository、Add Project 的仓库识别）同样经共享的 `CommandRunner` 执行：clone 的超时为 30 分钟，其余 60 秒；超时或调用方任务取消时，runner 结束 git 及其进程组。

git 的选择集中在 `GitLaunch.mode(for:)`（`codans/Git/`）：跳过 `-C`、`-c` 一类全局选项后，子命令是 clone、fetch、push、pull、ls-remote，或 `remote show`（不带 `-n`）/ `update` / `prune` 时走 login shell，其余走 `.directThenLoginShell`。`GitWorktreeShell.runStream`（`wt sw`、clone 的流式输出）自己持有 `Process`，用同一个 `CommandLaunch` 与 `ProcessLaunch.make`，不另写一套。

| 命令 | 启动方式 | 原因 |
|---|---|---|
| 访问远端的 git：clone、fetch、push、pull、ls-remote、`remote show`（`LiveGitService`、`GitWorktreeShell`、`GitWorktreeCLI.clone`；创建 worktree 前的 fetch 也在内） | login shell | git 会再启动 credential helper、git-lfs、ssh helper，它们要用户的 `PATH` |
| `gh`、`glab`（`GitHubGitPlatform`、`GitLabGitPlatform`） | login shell | 同上；可执行文件本身仍由 `CLIExecutableResolver` 解析为绝对路径 |
| 本地 git：status、diff、log、rev-parse、show-ref、branch、worktree list / add 等，`GitEnvironmentProbe` 的 `--version` | 直接；报告找不到命令时 login shell 重试一次 | 状态、diff 刷新很频繁，每次都付 rc 的代价不可接受；本地命令很少需要用户 `PATH`，需要时由重试兜底（例如本地 hook 调用 Homebrew 工具） |
| 内置 `wt` | 直接；报告找不到命令时 login shell 重试一次 | 同上；`wt` 调用的工具不在 launchd `PATH` 上时以 127 退出，触发重试。重试会把两次尝试的输出都流给调用方 |
| worktree 的 setup 脚本（`bash -lc`） | 直接 | 自己启动 login bash |
| 终端 | 不包装 | Ghostty 已经以 login shell 启动 |
| 内置二进制（`zmx`、编辑器 CLI 等） | 直接 | 路径是绝对的，不依赖用户 `PATH` |
| 远程命令（`ssh`，含远程 git、`ssh -G`） | 直接 | 远端已在远程 login shell 里执行；本地 ssh 需要的是 launchd 的 `SSH_AUTH_SOCK` |
| `gh`、`glab` 与 Agent CLI 的查找（`CLIExecutableResolver` 的 `/usr/bin/which`、`AgentInstallationStore` 的 `<账户 shell> -i -c 'command -v …'`） | login shell | 与之后运行这些 CLI 的命令用同一个 shell 与 `PATH`；不读 app 环境里的 `$SHELL`，否则 Dock 启动的 app 可能查错 shell。`which` 用该 CLI 自己运行时的环境（`makeEnv`），login shell 的结果优先，查不到才回退到 app 的 `PATH` 与 Homebrew 路径。Agent 探测在 login shell 里再起交互式账户 shell，看得到 rc 定义的 alias 与函数（pane 里输入的 agent 命令同样看得到） |
| 自己启动 shell 的命令（workflow 的 `/bin/sh -c`） | 直接 | 由调用方决定 shell |

**代价**：每条经 login shell 的命令多一次 shell 启动和一次 rc 执行，耗时取决于用户的 rc；这正是本地命令不包装的原因。在一台 Apple Silicon Mac mini 上，`git --version` 21 次的中位数：直接启动 6.7 ms，空 rc 14.2 ms（约 +7 ms，含外层 `/bin/sh`），加载 oh-my-zsh、pyenv、starship、nvm 的 rc 667.5 ms（约 +660 ms；机器繁忙时约 2 秒）。rc 越重，后台 git 越慢。

### 覆盖点（隔离缝）

| 变量 | 作用 | 典型用法 |
|---|---|---|
| `CODANS_CONFIG_DIR` | 搬走配置根；未设 `CODANS_STATE_DIR` 时状态根也平铺进同一目录，所有 JSON store 跟着走 | 冒烟 / 集成测试，或给某个 worktree 的 dev 构建单独一套数据 |
| `CODANS_STATE_DIR` | 单独搬走状态根（catalog、sessions、inbox 等），优先于 `CODANS_CONFIG_DIR` | 只隔离状态、共用配置 |
| `CODANS_RUNTIME_DIR` | 单独搬走 runtime 根（zmx socket、快照与日志） | 只隔离 daemon |
| `CODANS_CACHE_DIR` | 搬走缓存根；未设 `CODANS_RUNTIME_DIR` 时 runtime 根为 `<cache>/run`，老的隔离脚本不用改就拿到私有 daemon | 配合配置目录和 RPC socket 隔离 GUI / 集成测试 |
| `CODANS_SOCKET_PATH` | 指定 IPC socket | pane 内由 app 注入；手动指定实例 |
| `CODANS_CLI` | 生成该 pane 的 app 自带 CLI 的绝对路径 | pane 内由 app 注入；`PATH` 被 rc 重建时用 `"$CODANS_CLI"` |
| `CODANS_CLI_BINARY` | 安装器指向 `.app` 外新编的 CLI | dev |
| `CODANS_GHOSTTY_RESOURCES` | libghostty 资源树的替代根 | 未打包的 `xcodebuild run` |
| `CODANS_DISABLE_ACTION_ROUTING` / `CODANS_DISABLE_THEME_DEV_FALLBACK` | 诊断与测试开关 | 值为 `"1"` 生效 |
| `CODANS_SURFACE_RECLAIM_SECONDS` | 空闲 surface 回收的隐藏时长（秒，默认 1200） | 仅冒烟测试用；非正数或无法解析时保持默认 |

完整清单、写者与读者见 `CodansEnvironment.Key` 的逐条注释；那里是唯一真相来源，本表只列覆盖用途的。

### 组件边界

- `BuildChannel`、`CodansEnvironment`、`HandoffLayout` 只依赖 Foundation，无副作用，可在任何 target 使用。
- `SocketDiscovery`（CodansKit）与 `SocketPaths`（app）是两个门面：拼写委托给 `BuildChannel`，各自只保留本侧的解析语义。
- `PaneEnvironment` 属 `codans/Runtime/`，是 app 内唯一写 pane 环境的地方；`HierarchyManager.resolvedEnv` 是它的 Settings 感知封装。
- 新增按通道区分的东西，应从 `BuildChannel.current` 派生，不再新增 `#if DEBUG`。新增环境变量，先在 `CodansEnvironment.Key` 里登记。

## 备选方案

- **按 configuration 给不同 bundle id。** 隔离最彻底，但通知中心、Sparkle、URL scheme 全部一分为二，Debug 包会失去与真实安装一致的系统行为，测的就不再是要发的东西。否决。
- **把两个 socket resolver 合并成一个。** 会丢掉那条故意的不对称，或者要在一个函数里塞两个开关。保留两个门面、共享拼写，成本更低也更诚实。
- **让 `HandoffKickoff` 直接引用 `HandoffStore` 的 URL 再取相对路径。** 会把 prompt 文本和文件系统绑在一起，而 prompt 只需要名字。独立的纯 `HandoffLayout` 更小。
- **注入全部四个层级 id。** tab / worktree / project id 会随 pane 移动而失效，注入即埋雷。只注入不变的那一个。

## Cross-Cutting

- **测试**：`GitProcessEnvTests`（`inheriting` 去掉所有 `GIT_*`）、`GitWorktreeCLITests`（clone 的启动方式、超时与环境，父环境的 `GIT_DIR` 不影响真实 git，取消挂起的 clone 不留子进程）、`GitLaunchTests`（每条 git 路由的启动方式、重试条件）、`LiveGitServiceLaunchTests`（status / diff 刷新直接启动）、`LoginShellLaunchTests`（调用构造）、`LoginShellRunnerIntegrationTests`（临时 `HOME` 下的真实 zsh / bash，装了 fish 或设了 `CODANS_TEST_FISH` 时也跑 fish：rc 加的 `PATH`、rc 与 profile 的 banner、`set --`、`cd /`、125、超时与取消不留子进程、rc 导出的 `GIT_*` 到不了 git、本地 status / diff 不执行 rc、找不到命令时直接启动的 git 与流式脚本各重试一次）；`BuildChannelTests`、`CodansEnvironmentTests`、`HandoffLayoutTests`（CodansCore）；`SocketDiscoveryTests`（CodansKit）；`SocketPathsTests`、`PaneEnvironmentTests`、`HierarchyManagerResolvedEnvTests`（app）。`CodansEnvironmentTests` 把类型化持有者钉在目录上，任何一处拼写漂移都会在这里失败。
- **可观测性**：`codans doctor` 打印它解析到的 socket 与 `socketFromEnvironment`；「命令跑到别的 app」先看这个。
- **调用方身份**：pane 导出 `CODANS_PANE_ID`；服务端由该 Pane 推导所属 Tab、Worktree 和 Project。

## 风险

- **跨分支共享 `codans-dev`。** 一个分支的 Debug 构建写入新枚举值或新字段，老分支的构建读不出来或剥掉。本设计不解决（非目标）；缓解是 `CODANS_CONFIG_DIR`，以及让 catalog 解码对未知枚举值宽容（另行处理）。
- **`ProcessInfo` 默认参数陷阱再次出现。** 缓解：`CodansEnvironment` 的注释与本文档明确禁止；code review 检查。

- **`/usr/local/bin` 之外的同名二进制。** `CLIInvocation.command` 只检查安装目录，`/opt/homebrew/bin/codans` 一类不会被察觉。两个通道都可能遇到 PATH 中同名二进制遮蔽；需要确定身份时使用 `CODANS_CLI` 的绝对路径。
- **`CODANS_CLI_NAME` 与 `BuildChannel.slug` 分叉。** 两处各写一份；`CLIBundleLocator` 在真实 bundle 上找不到二进制时安装器会报 bundleMissing，是最早的信号。
- **重 rc 拖慢远端命令。** 每条经 login shell 的命令都执行一次 rc。高频的本地命令因此直接启动，只有访问远端的 git 与 `gh`、`glab` 付这个代价；远端命令本身是网络往返，rc 的耗时占比较小。
- **重试只认 127 与 `command not found`。** git 直接执行不含 shell 元字符的 helper（`!helper` 不带参数）时报 `cannot run …: No such file or directory`，不触发重试；带参数或经 shell 的 helper（例如 `!glab auth git-credential`）会。
- **第三方键的语义漂移。** `ZMX_*`、`GHOSTTY_*` 由外部工具定义；目录里登记的是 codans 对它们的用法，不是它们的规范。

## 参考

- `docs/architecture.md` 的 IPC 与 Persistence 小节
- `docs/design-docs/cli.md` 的 socket 解析优先级与 pane 注入变量
- `docs/design-docs/agent-handoff.md`
