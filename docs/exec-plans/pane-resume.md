# ExecPlan: Pane Resume

**Status:** Approved
**Author:** Gump
**Date:** 2026-05-24

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

执行后，codans 的每个 Pane 都会有一个独立的 sidecar 守护进程在 app 之外管 PTY；用户 `cmd-Q` 之后 shell 不死，重启自动重连——长跑编译、`tail -f`、CLI agent loop 都不会因为关 app 而中断。Settings 里若关掉 "Resume panes on launch"，quit 时 daemon 把屏幕状态序列化到磁盘再退出；重启后看到的是和退出时一模一样的可见缓冲与 scrollback，只是 shell 是新的。无论哪档，PTY 的所有权都从 libghostty surface 搬到了守护进程，渲染仍由 surface 完成。

具体到可观测：

- `codans pane send <id> $'tail -f /tmp/log\r'`、`cmd-Q`、`open -a Codans` 三步走完，`ps` 显示原来的 shell PID 还在，新窗口里 `/tmp/log` 期间 append 的内容都已经在 pane 里
- Settings 关掉 toggle 之后 quit + relaunch，pane 的 buffer 字节为字节回放，但 `codans pane info` 显示新 PID
- `codans pane close <id>` 2 秒内 daemon 进程、unix socket 文件、`sessions.json` 条目全消失
- 7 天没 attach 过的 daemon 在下次 launch 时自动收尸，pane 走冷启动路径

## Progress

**State:** Draft
**Active worker:** none
**Last handoff:** —

### Handoff log

(none yet)

### Task checklist

- [ ] **M0 Vendor & Build** — zmx submodule + ghostty/zmx patches + 构建打包
  - [ ] T0.1 Vendor zmx submodule + build-zmx.sh + embed-zmx.sh
  - [ ] T0.2 Ghostty External backend patch
  - [ ] T0.3 Zmx patches (`serve` 子命令 + `.Snapshot` IPC + `--restore-from`)
  - [ ] T0.4 Tuist + Makefile wiring
- [ ] **M1 Daemon-backed Pane (vertical slice)** — Pane 走 daemon 路径，行为对齐今天
  - [ ] T1.1 SessionStore + Session model（CodansCore）
  - [ ] T1.2 ZmxClient + 协议 framer（Runtime）
  - [ ] T1.3 PaneSurface 改走 External backend
  - [ ] T1.4 `codans pane close` 走 `.Kill` 路径
- [ ] **M2 Live tier across quit** — quit 不杀 daemon、launch 自动重连
  - [ ] T2.1 Quit 时 `.Detach` 并落 sessions.json
  - [ ] T2.2 Launch 时枚举 + 重连
  - [ ] T2.3 Force-quit 兼容
- [ ] **M3 Snapshot tier** — Settings 关 toggle 时走快照路径
  - [ ] T3.1 Settings toggle（`general.resumePanesOnLaunch`）
  - [ ] T3.2 Quit 路径分支到 `.Snapshot`
  - [ ] T3.3 Launch 路径 fallback 到 snapshot file
- [ ] **M4 Probe surface for VT-fidelity tests** — 暴露 `codans pane info/read` 探针字段
  - [ ] T4.1 `codans pane info --json` 增 cursor + modes
  - [ ] T4.2 `codans pane read --raw` 支持
- [ ] **M5 Reaper & second-instance defense**
  - [ ] T5.1 7-day 回收
  - [ ] T5.2 sessions.json flock（拒绝第二 app 实例双连）
- [ ] **M6 Hardening — durability, defense-in-depth, discoverability, agent state**（2026-05-29 增补）
  - [x] T6.1 SessionCoordinator 抽离，承包所有 catalog 写入（重构，行为零变化）— commit 49fba46b
  - [x] T6.2 写穿持久化：spawn / attach / detach / close 全部触达 coordinator（R14, AC9）— commit 7ee760a0
  - [x] T6.3 文件系统兜底 orphan reaper：扫 socket dir → catalog ∪ hierarchy 都没claim 的就 kill（R15, AC10）— commit 695b6b58
  - [x] T6.4 Settings → General 加 "Resumable sessions: N + Forget all sessions" 控件（R16, AC11）— commit 34975538
  - [x] T6.5 PersistedAgentRecord 落 sessions.json，launch 时 liveness check 后 seed AgentRegistry（R17, AC12）— commit 2945696c

## Surprises & Discoveries

(none yet)

## Decision Log

- **2026-05-24 (planning)** 选 zmx 二进制 sidecar，不做 Swift 重写。理由：zmx 已经在 issue 序列里踩完 serializer + DA1 + redraw 等坑；重写一遍要 1500 LoC + 重新踩。代价：build 多了 zig 编译一次 zmx（约 20s 增量）。
- **2026-05-24 (planning)** External backend 内部走 socketpair proxy，不做 SCM_RIGHTS fd-passing。理由：共享 fd 的 read race 难处理；socketpair 一跳 ~1µs，对终端速率不可见。
- **2026-05-24 (planning)** 第二 app 实例不通过守护进程拒绝（zmx 本身支持多 client，patch 它太冗余）；改成 app 对 `sessions.json` 做 `flock(LOCK_EX | LOCK_NB)`。拿不到锁的第二实例进入"无 resume 模式"：不读 sessions.json、所有 pane 冷启动。简单、纯 Swift。
- **2026-05-24 (planning)** Snapshot tier 不需要 `ghostty_surface_write_vt` C 入口。让 daemon 自己在 `--restore-from` 时预灌进 ghostty-vt Terminal，app 拿到的字节流仍是 `serializeTerminalState` 输出——两档复用同一条 attach 通道。
- **2026-05-29 (M6 planning)** 持续持久化不引入新文件，仍是 `sessions.json`；引入 `SessionCoordinator` 作为单一写入入口。理由：分散在四处的 catalog mutation 是 crash-loss 的结构性根因；先单点收口、再加写穿。这条 refactor 自身行为零变化，使后续 T6.2-T6.5 plumbing 各只动一处。
- **2026-05-29 (M6 planning)** 文件系统 orphan reaper 不复用 `zmx ls`，而是直接扫 `~/Library/Caches/codans/zmx-sessions/*.sock`。理由：socket 目录由我们独占，扫描比子进程更轻量；目录是干净的，不会误杀其他工具的 daemon。
- **2026-05-29 (M6 planning)** Agent 持久化字段（kindRaw / pid / stateRaw）全部存 raw string，不存 enum case。理由：与对方做法一致，让未来 agent 种类增减不破坏旧 catalog 解码。
- **2026-05-29 (M6 planning)** Restore 时 PID 已死的 agent 直接 drop，不 seed `.finished`。理由：launch 时的 finished 行是噪音，用户没法操作；后续若需 history 视图再单独设计。

## Outcomes & Retrospective

(To be filled at milestone completion)

## Context and Orientation

**Related documents（先读再动手）：**

- Product spec: `docs/product-specs/pane-resume.md`
- Design doc: `docs/design-docs/pane-resume.md`（尤其 §System Context Diagram + §Alternatives Considered + §Risks）
- User tests: `docs/user-tests/pane-resume.md`（8 个用例 UT-PANE-RESUME-001..008）
- Architecture doc: `docs/architecture.md`（特别是 §Persistence + §Architectural Invariants）

**外部参考代码（read-only 引用）：**

- `/Users/wanggang/dev/opensource/zmx/src/main.zig` — `Daemon` struct in main.zig:577；`spawnPty` in :699；`ensureSession`（含 `posix.setsid()`）in :738-780；`handleInit`（含 serializer 调用）in main.zig:933-1000；`daemonLoop` in :2460
- `/Users/wanggang/dev/opensource/zmx/src/util.zig:479` — `serializeTerminalState` 两阶段输出函数
- `/Users/wanggang/dev/opensource/zmx/src/ipc.zig` — `Tag` enum + 协议 framer
- `/Users/wanggang/dev/opensource/ghostty/src/termio/backend.zig:14-100` — `Kind = enum { exec }` + `Backend = union(Kind)`，外加分发样板，要扩 `external` 分支
- `/Users/wanggang/dev/opensource/ghostty/src/termio/Exec.zig:48-156` — `init` / `threadEnter` / `threadExit`，要据其精简成 `External.zig`
- `/Users/wanggang/dev/opensource/ghostty/src/apprt/embedded.zig:456,540-593` — `ghostty_surface_config_s` Zig 端 + surface init 流

**Key source files（本计划要读/改）：**

- `apps/mac/codans/Runtime/Ghostty/PaneSurface.swift:80-153` — 当前 surface 创建路径，T1.3 改成"永远走 external_pty_fd"，把 fork-pty 配置项替换掉
- `apps/mac/codans/Runtime/Ghostty/GhosttyRuntime.swift` — `ghostty_app_t` 管理；External backend 新增的 resize action 通过现有 action decoder 上钩
- `apps/mac/codans/Runtime/Ghostty/GhosttyActionDecoder.swift` — 新增对 `external_resize` action 的解码
- `apps/mac/codans/Runtime/HierarchyRuntime.swift` — Pane 生命周期，T1.3 + T2.x 改这里挂 daemon spawn / detach
- `apps/mac/CodansCore/CatalogStore.swift:1-69` — 参考模式（atomic-rename + 500ms 防抖），SessionStore 镜像它
- `apps/mac/codans/Runtime/PendingOutputBuffer.swift` — 现有输出 batching 模式（参考用）
- `apps/mac/codans/App/Features/Socket/` — `codans pane *` 命令的 server-side handlers 落地处
- `apps/mac/codans-cli/Commands/` — `codans pane *` 子命令落地处
- `apps/mac/CodansIPC/Protocol.swift` — JSON-RPC 信封，新增 `pane.info` / `pane.read` / `pane.close` method
- `apps/mac/scripts/build-ghostty.sh` — fingerprint-cache 构建脚本（参考写 `build-zmx.sh`）
- `apps/mac/scripts/embed-codans.sh` — codans 嵌进 `Contents/Resources/bin/` 的 post-script（参考写 `embed-zmx.sh`）
- `apps/mac/Project.swift` — Tuist 目标定义，加 zmx 构建 + embed phase
- `apps/mac/Makefile` — 加 `mac-build-zmx` target
- `apps/mac/Configurations/Project.xcconfig` — 若需新增 marketing version dep 等

**术语定义：**

- **Sidecar daemon**：本计划里特指 `zmx` 二进制 fork 出的一个长寿子进程，一个 Pane 一个，PaneID 即 zmx session name。fork+setsid 自我 detach，与 app 进程组解耦。
- **External backend**：上游 ghostty `termio.Backend` 的新枚举分支。本计划在 `apps/mac/ThirdParty/ghostty/` submodule 里维护补丁，给 surface 一条"我不 fork PTY，给我一个 fd 就行"的路径。
- **Socketpair proxy**：app 内部 `socketpair(AF_UNIX, SOCK_STREAM)` 拿到的一对 fd——一端塞进 External backend 当 PTY 替身，另一端由 `ZmxClient` 持有、把 daemon `.Output` 字节拆框喂进去 / 把 surface 写出的字节裹进 `.Stdin` 框送往 daemon。
- **Live tier / Snapshot tier**：quit 时按 Settings toggle 分支——前者 `.Detach`、daemon 保留；后者 `.Snapshot`、daemon 写 `<paneID>.snap` 后退出。launch 时优先尝试 live，fallback 到 snapshot，再 fallback 到冷启动。
- **Cold start**：没 sessions.json 条目、没 snapshot 文件、新生 Pane 三种情景共用的路径——`zmx serve <paneID> --cwd <path>`，shell 是 fresh 的，VT 是空的。

## Plan of Work

六个 milestone，严格顺序：M0 → M1 → (M2 ∥ M3) → M4 → M5。M2 与 M3 是平级 feature 分支，可并行（前提是 M1 已经把 daemon-backed pane 跑通）。每个 milestone 内部任务尽量 `task ≤ 5 files`。

### Milestone 0 — Vendor & Build

**目的**：让 zmx 二进制和带 External backend 的 ghostty xcframework 都能由 `make mac-build` 一次性产出，且签名嵌入 `Codans.app/Contents/Resources/bin/zmx`。本 milestone 没有用户可见行为变化——app 还在用现有 Exec backend 跑 Pane——只是把后续 milestone 需要的素材全准备好。

**T0.1 Vendor zmx submodule + build pipeline**（≤5 files）

在 `apps/mac/ThirdParty/zmx/` 加一个新 git submodule 指向 `https://github.com/neurosnap/zmx.git`，pin 到 `0.6.0`（具体 commit 在执行时定）。写 `apps/mac/scripts/build-zmx.sh`，结构对齐现有 `build-ghostty.sh`：fingerprint 用 `git submodule HEAD + 当前 patches 目录 + mise.toml hash`，调用 `zig build -Doptimize=ReleaseSafe --prefix .build/zmx`，产物落到 `apps/mac/.build/zmx/bin/zmx`。写 `apps/mac/scripts/embed-zmx.sh` 把产物 `cp` 到 `${BUILT_PRODUCTS_DIR}/Codans.app/Contents/Resources/bin/zmx`。

文件：`.gitmodules`、`apps/mac/ThirdParty/zmx/`（submodule pointer）、`apps/mac/scripts/build-zmx.sh`、`apps/mac/scripts/embed-zmx.sh`、`apps/mac/Makefile`（加 `mac-build-zmx` target + 把它挂进 `mac-build` 依赖）。

验收：`make mac-build-zmx` 退出 0；`.build/zmx/bin/zmx version` 输出 `0.6.0+touchcode`（patch 后自定义版本字符串，T0.3 引入）。

**T0.2 Ghostty External backend patch**（≤5 files，全部在 submodule `apps/mac/ThirdParty/ghostty/src/`）

按 design doc §API Design `1.` 写。在 `apps/mac/ThirdParty/ghostty/src/termio/External.zig` 新建文件 ~180 LoC，模仿 `Exec.zig:1-200` 的结构但去掉 `Subprocess` / `xev.Process` / `termios_timer` 三段：

```
External: {
    fd: posix.fd_t,             // 传入的 socketpair 一端
    resize_dirty: bool = false, // 渲染线程的 resize 经 mailbox 抛过来
}
```

`threadEnter` 只起 read thread（`posix.read(fd, ...)` → `io.processOutput(slice)`），不起 process watcher。`queueWrite` 直接 `posix.write(fd, ...)`。`resize(grid_size, screen_size)` 不调 `TIOCSWINSZ`，改成发 apprt action `.external_pty_resize { cols, rows }`，由嵌入端 (Swift) 接收后通过 `.Resize` 转发给 daemon。`threadExit` 不杀进程、不 close fd（fd 所有权在 Swift `ZmxClient`）。

`apps/mac/ThirdParty/ghostty/src/termio/backend.zig:14-100` 改 `Kind = enum { exec, external }`，给 `Backend` union 加 `external: termio.External` variant，所有方法的 switch 都加 external 分支。

`apps/mac/ThirdParty/ghostty/src/apprt/embedded.zig`：在 `ghostty_surface_config_s`（先看 Zig 这边的定义在 `apps/mac/ThirdParty/ghostty/src/apprt/embedded.zig:444-481`）加 `external_pty_fd: c_int = -1`；在 surface init 流（`embedded.zig:540-593` 附近）检测到 fd>=0 时构造 `.external` backend 而不是 `.exec`。

`apps/mac/ThirdParty/ghostty/include/ghostty.h:468-481` 镜像加 `int external_pty_fd;` 字段，默认值由 `ghostty_surface_config_new` 设为 `-1`。

新增 action 类型：`apps/mac/ThirdParty/ghostty/src/apprt/action.zig`（或对应文件）加 `external_pty_resize: ExternalPtyResize` action，含 `cols: u16, rows: u16`。

文件：`apps/mac/ThirdParty/ghostty/src/termio/External.zig` (new)、`src/termio/backend.zig`、`src/apprt/embedded.zig`、`include/ghostty.h`、`src/apprt/action.zig` —— 5 files。

验收：`cd apps/mac/ThirdParty/ghostty && zig build check` 退出 0；`make mac-build-ghostty` 产出新的 `GhosttyKit.xcframework`，`nm` 能看到新增的 action 符号。

**T0.3 zmx patches**（≤5 files，全部在 submodule `apps/mac/ThirdParty/zmx/src/`）

加三件事：

1. `zmx serve <session> [--cwd path] [--command prog…] [--restore-from file]` 子命令——`apps/mac/ThirdParty/zmx/src/main.zig` 在 :115 起的命令派发处加分支，`ensureSession` 调完就退出，不进 attach 循环。如果 `--restore-from` 给了，daemon 在 spawnPty 之后、PTY 真正 echo 之前调 `vt_stream.nextSlice(restore_bytes)` 把字节灌进 VT。Stdout 打印 socket 路径。
2. 新增 `.Snapshot` IPC tag——`apps/mac/ThirdParty/zmx/src/ipc.zig` 的 Tag enum 加一项；`main.zig` 加 `handleSnapshot`：调 `util.serializeTerminalState(self.alloc, term)`、写到 `$ZMX_DIR/snapshots/<session>.snap`、向 PTY 进程组发 `SIGHUP`、退出 daemon。
3. 把 zmx `version` 输出附加 `+touchcode` 后缀方便诊断（`apps/mac/ThirdParty/zmx/build.zig` 或 `printVersion` 函数处）。

文件：`apps/mac/ThirdParty/zmx/src/main.zig`、`src/ipc.zig`、`src/util.zig`（如需把 serializeTerminalState 做成可以被 handleSnapshot 调用——它已经是 pub 的，可能不用动）、`build.zig` 改 version 字符串。≤5 files。

验收：`zmx serve test-session --cwd /tmp` 退出 0；`$ZMX_DIR/test-session.sock` 是 socket 文件；`zmx kill test-session` 清理；`zmx serve test-session && echo "foo" | zmx send test-session && sleep 0.2 && zmx history test-session | grep foo` 全程绿。手测 `.Snapshot` 路径：用一个 minimal binary 客户端发 `.Snapshot` 包，断言 `<session>.snap` 文件被写、daemon 进程没了。

**T0.4 Tuist + Makefile + .gitignore**（≤3 files）

`apps/mac/Project.swift` 给 `codans` target 加 post-build script "Embed zmx"（mirror "Embed codans"）。`apps/mac/Makefile` 把 `mac-build-zmx` 列为 `mac-build` 的依赖。`apps/mac/.gitignore` 加 `.build/zmx/`。

文件：`apps/mac/Project.swift`、`apps/mac/Makefile`、`apps/mac/.gitignore`。

验收：`make mac-build && ls -la build/Debug/Codans.app/Contents/Resources/bin/zmx` 能看到嵌入的二进制；`codesign --verify --deep build/Debug/Codans.app` 退出 0。

**Exit Gate（M0）：**
- T0.1–T0.4 各自 spec-review pass + code-review approve
- `make mac-build` 端到端绿，xcframework 与 zmx 二进制都签了
- 无 runtime 验证需求（M0 不改 user-visible 行为）
- Handoff log 写齐

### Milestone 1 — Daemon-backed Pane (vertical slice)

**目的**：app 起手就走 daemon 路径。每个新 Pane 都 spawn `zmx serve <paneID>`、通过 socketpair 把 External backend 接到 daemon。行为对齐今天——shell 还是 fork 自 daemon、关 Pane 还是 SIGHUP——但 PTY 拥有权已经迁出。

**T1.1 SessionStore + Session model**（≤3 files）

`apps/mac/CodansCore/Session.swift`（new）定义：

```swift
public struct Session: Codable, Equatable, Sendable {
    public let paneID: PaneID
    public var socketPath: String
    public var pid: Int32
    public var createdAt: Date
    public var lastAttachedAt: Date
    public var command: [String]
    public var cwd: String
    public var zmxVersion: String
}

public struct SessionCatalog: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int = Self.currentVersion
    public var sessions: [String /* PaneID UUID string */: Session] = [:]
}
```

`apps/mac/CodansCore/SessionStore.swift`（new）镜像 `CatalogStore.swift:1-69` 的 500ms-debounce + atomic-rename 模式，提供 `load()` / `scheduleSave(_:)` / `saveNow(_:)` / `flushPending()`。

`apps/mac/CodansCoreTests/SessionStoreTests.swift`（new）round-trip + v1 解码 + 损坏 backup 三个测。

文件：3 个新文件。

**T1.2 ZmxClient + 协议 framer**（≤4 files）

`apps/mac/codans/Runtime/Ghostty/ZmxIPC.swift`（new）实现 length-prefixed `Tag` envelope 编解码——长度头 4 字节 little-endian，tag 1 字节，payload 不定长。Tag enum 用 `enum ZmxTag: UInt8 { case Init = 0, Resize, Stdin, Output, Detach, Kill, Info, Snapshot, History, RestoreAck, ... }`，与 `zmx/src/ipc.zig` 的 Tag 排列严格对齐。给 `Resize`、`Info` 这种定长 payload 提供 `bytesToStruct` / `structToBytes`，与 zmx 端的 `std.mem.bytesToValue` 兼容（注意小端 + 紧凑结构、用 `@MemoryLayout<Resize>.size` 校验对齐）。

`apps/mac/codans/Runtime/Ghostty/ZmxClient.swift`（new）：

```swift
@MainActor
final class ZmxClient {
    // Two fds:
    //   controlFD: unix socket to daemon
    //   plumbingFD: socketpair end we own; external backend sees the OTHER end
    let externalBackendFD: Int32  // give to ghostty_surface_config_s.external_pty_fd
    init(paneID: PaneID, socketPath: String) async throws
    func attach(cols: UInt16, rows: UInt16) async throws  // sends .Init, waits for initial Output
    func resize(cols: UInt16, rows: UInt16)
    func snapshot() async throws -> URL                   // sends .Snapshot; resolves when daemon exits
    func detach()                                          // sends .Detach + closes controlFD; daemon survives
    func kill() async                                      // sends .Kill
    func close()                                           // closes both fds; ZmxClient unusable after
}
```

内部跑一个 Task：从 `controlFD` 读取消息——若 tag==`Output` 就把 payload 字节写到 `plumbingFD`（External backend 那端会读到）；若是 `Info` / `RestoreAck` 等控制类，通知等候方。同时另一个 Task：从 `plumbingFD` 读 surface 写出来的字节，裹成 `.Stdin` 框发给 daemon。

`apps/mac/codans/RuntimeTests/ZmxClientTests.swift`（new）用一个 mock daemon socket 验证 framing 双向。

文件：`ZmxIPC.swift`、`ZmxClient.swift`、`ZmxClientTests.swift`、`ZmxIPCTests.swift`（如要拆）—— 3-4 files。

**T1.3 PaneSurface 改走 External backend**（≤3 files）

`apps/mac/codans/Runtime/Ghostty/PaneSurface.swift:80-153` 重写——`init` 接受 `ZmxClient`，把 `config.external_pty_fd = client.externalBackendFD`，去掉 `config.working_directory` / `config.command` / `config.env_vars` 那几行（这些参数现在传给 daemon 不是 surface）。`close()` 调 `client.close()`。

`apps/mac/codans/Runtime/Ghostty/GhosttyActionDecoder.swift:319` 附近加 `case .external_pty_resize(let r):` 分支，从 action 里取 cols/rows 路由到对应 pane 的 `ZmxClient.resize`。

`apps/mac/codans/Runtime/HierarchyRuntime.swift` 在 Pane 创建路径加：用 `CommandRunner` spawn `zmx serve <paneID> --cwd <cwd>`，等到 stdout 输出 socket 路径或 1s 超时（视 spike 调整），构造 `ZmxClient(paneID:, socketPath:)`，把 client 注入 `PaneSurface.init`。

文件：`PaneSurface.swift`、`GhosttyActionDecoder.swift`、`HierarchyRuntime.swift` —— 3 files。

**T1.4 `codans pane close` → `.Kill`**（≤3 files）

`apps/mac/codans/App/Features/Socket/` 下找 / 加 PaneHandlers.swift，加 `pane.close` method：lookup ZmxClient → `await client.kill()` → 等 socket 文件消失（poll，2s 超时）→ `SessionStore.scheduleSave`（删除条目）→ 返回。

`apps/mac/CodansIPC/` 加 `PaneClose` request/response。

`apps/mac/codans-cli/Commands/` 加 `codans pane close <id>` 子命令。

文件：3 files。

**Exit Gate（M1）：**
- 每 task spec-review pass + code-review approve
- 每 task 落一次 atomic commit
- Runtime validator 跑 **UT-PANE-RESUME-005** 返回 PASS（explicit close 清理）
- 同时跑既有 codans 终端 smoke tests（`make mac-test`）不退步
- Handoff log 写齐

### Milestone 2 — Live Tier Across Quit

**目的**：cmd-Q 时 daemon 不死、launch 时自动重连。Settings 不存在分支（toggle 默认 on），M3 才补 toggle。

**T2.1 Quit 时 `.Detach` 并落 sessions.json**（≤3 files）

`apps/mac/codans/Runtime/HierarchyRuntime.swift`（或新建 `Runtime/SessionLifecycle.swift`）加 `func detachAllForQuit()`：遍历所有 ZmxClient → 先 `client.detach()`（关 control socket，daemon 保留）→ 收集 PID + socketPath + cwd + lastAttachedAt（now），构造 Session 数组写进 SessionStore.saveNow。

`apps/mac/codans/App/CodansApp.swift` 注册 `NSApplication.willTerminateNotification` 监听者：先调 `SessionLifecycle.detachAllForQuit()`、然后 `CatalogStore.flushPending()`、然后让 `terminate` 继续。

文件：2-3 files。

**T2.2 Launch 时枚举 + 重连**（≤4 files）

`apps/mac/codans/Runtime/SessionReaper.swift`（new）暴露 `static func sweep() async -> SweepResult`：读 SessionStore → 对每个 entry 尝试 `connect(socketPath)` → 成功记录为 `.alive`、失败标记为 `.dead`（reaper 删 socket 文件 + sessions.json 条目；M5 才加 7-day check + kill 残留 pid）。

`apps/mac/codans/Runtime/HierarchyRuntime.swift` 改 Pane 启动流：launch 时先调 reaper sweep，然后按 catalog 创建 Pane 时若 `paneID in sweep.alive` 则**不** spawn `zmx serve`，而是直接 `ZmxClient(paneID:, socketPath:)` + `client.attach()`。daemon 会回送序列化 state 当第一段 Output——External backend 把它写进 surface VT 就是恢复后的画面。

`apps/mac/codans/Runtime/Ghostty/ZmxClient.swift` 加 attach 等待逻辑：发 `.Init` 后等第一个 `.Output` 包到达，作为 "ready"。

文件：3-4 files。

**T2.3 Force-quit 兼容**（无新代码，只验证）

Force-quit 路径与 normal quit 走的是同一个外部进程组分离机制（zmx daemon 已 setsid）。app 被 SIGKILL 后没机会跑 `willTerminate`，所以 sessions.json 不会更新 `lastAttachedAt`——但 daemon 还活着、socketPath 仍在、PID 仍在。下次 launch reaper sweep 一样能识别。

文件：无。验证靠 UT-PANE-RESUME-008。

**Exit Gate（M2）：**
- spec-review + code-review pass
- Runtime validator: **UT-PANE-RESUME-001** + **UT-PANE-RESUME-008** 都 PASS
- `make mac-test` 不退步

### Milestone 3 — Snapshot Tier

**目的**：Settings 关 toggle 时 quit 走 `.Snapshot`、launch 走 `--restore-from`。

**T3.1 Settings toggle**（≤3 files）

`apps/mac/CodansCore/Settings.swift`（或对应文件——按 architecture.md 是 `settings.json` 的 `general` 段）加 `var resumePanesOnLaunch: Bool = true`，bump settings schema 到 v4，写 v3→v4 迁移（旧字段不存在时默认 true）。

`apps/mac/codans/App/Features/Settings/General/` 加 UI toggle "Resume panes on launch"（标题与说明文案见 design doc §Settings UI）。

文件：2-3 files。

**T3.2 Quit 分支到 `.Snapshot`**（≤2 files）

`SessionLifecycle.detachAllForQuit()` 增加读 Settings：toggle off 时改调 `client.snapshot()`（等返回的 snapshot URL）→ 不写 sessions.json 条目（daemon 已退出，没什么可重连的）。Snapshot 文件路径 `~/Library/Caches/codans/snapshots/<paneID>.snap` 由 daemon 自己决定，app 只验证存在。

文件：1-2 files。

**T3.3 Launch fallback to snapshot**（≤2 files）

`SessionReaper.sweep()` 增加分支：sessions.json 没条目但 `~/Library/Caches/codans/snapshots/<paneID>.snap` 存在 → 状态标 `.snapshot(snapURL)`。`HierarchyRuntime` 看到此状态时 spawn `zmx serve <paneID> --cwd <cwd> --restore-from <snapURL>`，正常 attach。

文件：2 files。

**Exit Gate（M3）：**
- spec-review + code-review pass
- Runtime validator: **UT-PANE-RESUME-002** PASS
- M1+M2 既得不退步

### Milestone 4 — Probe Surface for VT-Fidelity Tests

**目的**：暴露 `codans pane info --json` 和 `codans pane read --raw`，让 UT-PANE-RESUME-003/004 跑得起来。本 milestone 不改 daemon / surface 行为，只补 CLI 表面。

**T4.1 `codans pane info --json`**（≤3 files）

`apps/mac/codans/App/Features/Socket/PaneHandlers.swift`（或并入 T1.4 的文件）加 `pane.info` method：返回 `{ paneID, shellPid, pwd, cursor: { row, col }, modes: { altScreen, applicationKeypad, kittyKeyboard, ... } }`。`shellPid` / `pwd` 通过 `client.info()` IPC（zmx `.Info` tag 已现成）；cursor + modes 需要 zmx daemon 暴露——直接复用 zmx `.Info` payload（先看 zmx ipc.zig 里 `Info` struct 字段，必要时 T0.3 时已经把 cursor/modes 加上）。

`CodansIPC/` 加 PaneInfo request/response。`codans-cli/Commands/Pane.swift` 加子命令。

文件：3 files。**依赖** T0.3 时如果 zmx `.Info` 没带 cursor/modes，要在 M4 这里回到 T0.3 文件补——回头看不超过 5 files。

**T4.2 `codans pane read --raw / --tail / --range`**（≤3 files）

通过 zmx `.History` tag（已有，输出格式可选 plain/vt/html）拿到 daemon 端 `serializeTerminal` 的输出，按 `--raw` 透传或按 `--tail N` 取最后 N 行。`--range visible|scrollback|all` 也走同一 history 接口的不同参数。

文件：3 files。

**Exit Gate（M4）：**
- spec-review + code-review pass
- Runtime validator: **UT-PANE-RESUME-003** + **UT-PANE-RESUME-004** PASS
- 之前所有用例不退步

### Milestone 5 — Reaper & Second-Instance Defense

**目的**：把 reaper 升级到完整 7-day 策略；给 `sessions.json` 上 flock 防止第二 app 实例双连。

**T5.1 7-day reaper**（≤3 files）

`SessionReaper.sweep()` 扩展：对 `.alive` 的 session，若 `now - session.lastAttachedAt > 7d` → 发 `.Kill` IPC → 等 daemon 退出 → 删 socket + sessions.json 条目 + 可能存在的 snapshot 文件。

阈值常量提到 `CodansCore/SessionConfig.swift`（new），默认 `staleAfter: Duration = .days(7)`，方便测试覆盖（注入短时长）。

文件：2-3 files。

**T5.2 `sessions.json` flock（拒绝第二 app 实例）**（≤2 files）

`apps/mac/CodansCore/SessionStore.swift` 改 `load()`：先 `open(path, O_RDWR | O_CREAT)`、`flock(fd, LOCK_EX | LOCK_NB)`、拿不到锁就 `throw .alreadyHeld`。app 持有 lock fd 直到 `willTerminate`。

`apps/mac/codans/App/CodansApp.swift` 启动捕获 `.alreadyHeld`：进入"无 resume 模式"——所有 pane 走冷启动、quit 时不写 sessions.json、UI 顶部 banner 提示"Another Codans instance is running; panes will not resume."（可省略 banner，留 OQ）。

文件：2 files。

**Exit Gate（M5）：**
- spec-review + code-review pass
- Runtime validator: **UT-PANE-RESUME-006** + **UT-PANE-RESUME-007** PASS
- 完整 8 个用例全 PASS（AC5 perf 由 perf-gate 单独跑）

## User Test Coverage

| Task | User-test cases covered |
|---|---|
| T0.1 | — infra (build pipeline) |
| T0.2 | — infra (libghostty External backend) |
| T0.3 | — infra (zmx patches) |
| T0.4 | — infra (Tuist + Makefile) |
| T1.1 | — infra (SessionStore) |
| T1.2 | — infra (ZmxClient framer) |
| T1.3 | — infra (PaneSurface rewire; covered indirectly by every M2+ case) |
| T1.4 | UT-PANE-RESUME-005 |
| T2.1 | UT-PANE-RESUME-001（quit 端） |
| T2.2 | UT-PANE-RESUME-001（launch 端）, UT-PANE-RESUME-008 |
| T2.3 | UT-PANE-RESUME-008 |
| T3.1 | UT-PANE-RESUME-002（toggle UI 端） |
| T3.2 | UT-PANE-RESUME-002（quit→snapshot 端） |
| T3.3 | UT-PANE-RESUME-002（launch→restore 端） |
| T4.1 | UT-PANE-RESUME-003, UT-PANE-RESUME-004（probe surface） |
| T4.2 | UT-PANE-RESUME-003, UT-PANE-RESUME-004（probe surface） |
| T5.1 | UT-PANE-RESUME-006 |
| T5.2 | UT-PANE-RESUME-007 |

AC5（perf）按 spec + user-test 文档约定，由 perf-gate 单独验证，不进 runtime user-test。

## Concrete Steps

下列命令统一在 worktree root `/Users/wanggang/.prowl/repos/codans/feat/resume-with-zmx` 下执行（除非另注 working directory）。`mise trust .` 与 `make bootstrap` 已假定在 quickstart 时跑过。

```bash
# M0.T0.1 Vendor zmx (one-time)
git submodule add https://github.com/neurosnap/zmx.git apps/mac/ThirdParty/zmx
git -C apps/mac/ThirdParty/zmx checkout <pinned-sha>          # 在 T0.1 决定具体 sha
make mac-build-zmx                                            # 首跑会拉 ~3MB Zig deps + 编译 zmx ~15-25s
ls -la apps/mac/.build/zmx/bin/zmx                            # expect: -rwxr-xr-x ... zmx
apps/mac/.build/zmx/bin/zmx version                           # expect: 0.6.0+touchcode

# M0.T0.2 Ghostty patch compile-check
cd apps/mac/ThirdParty/ghostty
zig build check                                                # expect: no output, exit 0
cd -

# M0.T0.4 Embed verify
make mac-build
ls -la build/Debug/Codans.app/Contents/Resources/bin/
# expect both `codans` and `zmx` listed, mode -rwxr-xr-x

# M1 ad-hoc test (between T1.2 and T1.3)
# Spawn a manual daemon and let a smoke binary attach
apps/mac/.build/zmx/bin/zmx serve manualtest --cwd /tmp
ls -la "$ZMX_DIR"/manualtest.sock || ls -la "${TMPDIR%/}/zmx-$(id -u)/manualtest.sock"
# expect: socket file present
echo "hi from outside" | apps/mac/.build/zmx/bin/zmx send manualtest
apps/mac/.build/zmx/bin/zmx history manualtest | tail
# expect: 看到 hi from outside
apps/mac/.build/zmx/bin/zmx kill manualtest

# Runtime user-test invocation (per milestone exit gate)
# Subagent: /hs-user-test path=docs/user-tests/pane-resume.md cases=UT-PANE-RESUME-005
# (Driven by the controller, not by hand)
```

## Validation and Acceptance

两层验证：

**Static**（每个 task 都跑）：
- `make mac-lint`（swiftlint + swift-format，配 strict mode）
- `make mac-test`（XCTest 全套，含本计划新增的 SessionStoreTests / ZmxClientTests / ZmxIPCTests）
- `make mac-build`（end-to-end build，签名通过）
- zmx 改动跑 `zig build test` 在 `apps/mac/ThirdParty/zmx/` 下

**Runtime**（milestone 出口处由独立 verifier 跑）：
- Spawn 一个独立 `/hs-user-test` subagent，喂 `docs/user-tests/pane-resume.md` 的对应 case 子集
- 该 subagent **不读** 任何实现源码——只跑 Preconditions / Steps / Assertions
- 对每个 case 收集 Artifacts on FAIL；FAIL 时回写 `Surprises & Discoveries`

最终全计划完成的 acceptance：8 个 UT-PANE-RESUME-* 在一次端到端 launch 中按下列顺序全 PASS：

1. UT-PANE-RESUME-005（explicit close） — 干净
2. UT-PANE-RESUME-001（quit→relaunch live tier）
3. UT-PANE-RESUME-008（kill -9 后 relaunch）
4. UT-PANE-RESUME-002（toggle off → snapshot tier）
5. UT-PANE-RESUME-003 + UT-PANE-RESUME-004（VT 字节级 + 模式 + cursor 保真）
6. UT-PANE-RESUME-006（7-day stale 回收）
7. UT-PANE-RESUME-007（第二实例不双连）

期间无 console error 报红，`runtime` / `runtime.reaper` / `runtime.zmx` 三个 os.Logger category 的 error level 无新增。

## Idempotence and Recovery

- `make mac-build-zmx` 与 `make mac-build-ghostty` 都是 fingerprint-cached——重复跑等价于 no-op。
- `git submodule update` 是幂等的；submodule 跑去未知分支时用 `git -C <sub> checkout <pinned-sha> && git -C <sub> clean -fdx` 强制对齐。
- SessionStore 写入用 atomic-rename（写 `sessions.json.tmp`、`fsync`、`rename(2)`）；中断不会损坏旧文件。
- 调试遇到 stale daemons：`pgrep -f 'zmx serve'` 看 PID，`kill -SIGHUP <pid>`；socket 残留就 `rm ~/Library/Caches/codans/zmx-sessions/*.sock`，下次 launch reaper 会兜底。
- 想完全回滚到 M0 之前的状态：把 `sessions.json` 删掉、把 `~/Library/Caches/codans/zmx-sessions/` + `~/Library/Caches/codans/snapshots/` 清空、设 `general.resumePanesOnLaunch=false`、`make mac-build`——app 行为退化为今天的"开新 shell 在 cwd"。

每个 Milestone 完成都落一个 atomic commit（按 codans 既有提交习惯，conventional-commit prefix `feat(resume): ...`）。Submodule bump 单独一个 `chore(submodule): ...`。

## Artifacts and Notes

- 设计阶段两个 spike 的结果记录在 design-doc §Context and Scope 与 §Risks：libghostty Backend 可扩、libghostty-vt 自带 xcframework target、zmx `setsid()` 在 main.zig:780 已对。
- zmx 上游 README 已声明 "upgrading versions of zmx where we make changes to the underlying IPC communication will kill all your sessions"——我们对此的对策是 sessions.json 里记 `zmxVersion`，启动 reaper 看到不匹配就 cold-start（不试图迁移）。
- 性能数据（design doc §Performance）：socketpair 一跳 ~1µs，~30 daemon × ~3-5MB = <150MB 后台常驻；不需要 launchd。

## Interfaces and Dependencies

**Swift 端**

在 `apps/mac/CodansCore/Session.swift` 定义：

```swift
public struct Session: Codable, Equatable, Sendable {
    public let paneID: PaneID
    public var socketPath: String
    public var pid: Int32
    public var createdAt: Date
    public var lastAttachedAt: Date
    public var command: [String]
    public var cwd: String
    public var zmxVersion: String
}

public struct SessionCatalog: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int = Self.currentVersion
    public var sessions: [String: Session] = [:]
}
```

在 `apps/mac/CodansCore/SessionStore.swift`：

```swift
@MainActor
public final class SessionStore {
    public init(fileURL: URL = SessionCatalog.defaultURL()) throws  // throws .alreadyHeld if flock fails
    public func load() throws -> SessionCatalog
    public func scheduleSave(_: SessionCatalog)                     // 500ms debounce
    public func saveNow(_: SessionCatalog) throws
    public func flushPending()
    public func release()                                            // closes flock fd
}

public enum SessionStoreError: Error { case alreadyHeld, decode(Error), write(Error) }
```

在 `apps/mac/codans/Runtime/Ghostty/ZmxClient.swift`：

```swift
@MainActor
public final class ZmxClient {
    public let externalBackendFD: Int32   // pass into ghostty_surface_config_s.external_pty_fd

    public init(paneID: PaneID, socketPath: String) async throws
    public func attach(cols: UInt16, rows: UInt16) async throws    // sends .Init; resolves on first Output
    public func resize(cols: UInt16, rows: UInt16)
    public func snapshot() async throws -> URL                      // sends .Snapshot; resolves when daemon exits & file present
    public func detach()                                            // sends .Detach; daemon survives
    public func kill() async                                        // sends .Kill; awaits socket gone
    public func close()                                             // closes both fds; idempotent
    public var info: AsyncStream<DaemonInfo>                        // .Info reply changes (pid / cmd / cwd / cursor / modes)
}

public struct DaemonInfo: Sendable {
    public let pid: Int32
    public let cwd: String
    public let cursor: CursorPosition?     // populated when M4.T4.1 lands
    public let modes: TerminalModes?
}
```

**Zig 端（External backend in apps/mac/ThirdParty/ghostty/src/termio/External.zig）**

```zig
const External = @This();

fd: posix.fd_t,
// no Subprocess, no xev.Process, no termios_timer

pub fn init(alloc: Allocator, cfg: Config) !External
pub fn deinit(self: *External) void
pub fn initTerminal(self: *External, term: *terminal.Terminal) void
pub fn threadEnter(self: *External, alloc: Allocator, io: *termio.Termio, td: *termio.Termio.ThreadData) !void
pub fn threadExit(self: *External, td: *termio.Termio.ThreadData) void
pub fn resize(self: *External, grid_size: terminal.size.GridSize, screen_size: renderer.Size.PixelSize) !void  // emits external_pty_resize action
pub fn queueWrite(self: *External, alloc: Allocator, td: *termio.Termio.ThreadData, data: []const u8, linefeed: bool) !void
pub fn childExitedAbnormally(_: *External, _: *termio.Termio.ThreadData, _: u32, _: std.time.Instant.Duration) void {}  // no-op for external
pub fn getProcessInfo(_: *External, comptime _: ProcessInfo) ?... { return null; }
```

`apps/mac/ThirdParty/ghostty/src/termio/backend.zig` 处的 `Kind` enum 加 `.external`；`Backend` union 加 `external: termio.External`；分发 switch 全部覆盖。

`apps/mac/ThirdParty/ghostty/include/ghostty.h` 的 `ghostty_surface_config_s` 末尾加：

```c
// When >= 0, surface uses an externally-owned PTY fd; the embedder is
// responsible for proxying bytes and forwarding resize via the
// external_pty_resize action.
int external_pty_fd;
```

`ghostty_surface_config_new()` 默认填 `-1`。

**Zig 端（zmx patches in apps/mac/ThirdParty/zmx/src/）**

```zig
// main.zig — subcommand dispatch
"serve" => {
    // parse --cwd, --command, --restore-from
    // ensureSession (forks daemon if needed, daemon自身已 setsid)
    // print socket_path to stdout
    // exit 0
},

// ipc.zig — Tag enum
.Snapshot,         // client → daemon: serialize state to <session>.snap, exit
.RestoreAck,       // daemon → client: prepopulation done (currently unused by app; reserved)

// main.zig — handleSnapshot
fn handleSnapshot(self: *Daemon, client: *Client) !void {
    const snap_path = try buildSnapshotPath(self.alloc, self.cfg.socket_dir, self.session_name);
    const bytes = util.serializeTerminalState(self.alloc, term) orelse return error.SerializeFailed;
    defer self.alloc.free(bytes);
    try writeAtomic(snap_path, bytes);     // .tmp + rename(2)
    posix.kill(-self.pid, posix.SIG.HUP) catch {};
    self.shutdown();
}
```

`zmx serve --restore-from <file>` 实现：在 `spawnPty` 之后、`daemonLoop` 之前，把文件字节通过 `vt_stream.nextSlice(bytes)` 喂给 `term`。

**Build outputs**

- `apps/mac/.build/zmx/bin/zmx` — Zig 编译产物，签名后嵌入
- `Codans.app/Contents/Resources/bin/zmx` — 运行时位置
- `~/.config/codans/sessions.json` — SessionStore 持久化
- `~/Library/Caches/codans/zmx-sessions/<paneID>.sock` — 每 Pane unix socket（dir mode 0700）
- `~/Library/Caches/codans/snapshots/<paneID>.snap` — snapshot tier 字节文件

**Dependencies added**

- New submodule: `apps/mac/ThirdParty/zmx` → `github.com/neurosnap/zmx`，pin to `0.6.0` 或更新
- `mise.toml` 已锁 `zig 0.15.x`（与 ghostty 共用），不需要再 bump
