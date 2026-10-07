# 设计文档：回收长期隐藏的 pane surface

**状态：** 已实现
**作者：** Gump（与 Claude）

## 背景

每个 live 的 libghostty surface 持有窗口大小的 Metal 交换链缓冲（IOSurface 与 IOAccelerator），以及 4 个线程（`renderer`、`io`、`io-reader`、`cf_release`）。surface 在 tab 第一次显示时懒创建，之后只有关闭 pane 才会释放：`ghostty_surface_set_occlusion(false)` 只让渲染线程降为 `.utility` 并停止绘制，不释放任何资源。

实测一个运行 1 天 8 小时的实例：53 个 live surface，footprint 3.6 GB（IOSurface 2.0 GB、GPU 缓冲 715 MB），236 个线程，而 RSS 只有 256 MB。内存和线程数随「浏览过的 pane 数」线性增长，不随「正在使用的 pane 数」。

## 方案

pane 的 shell 由 zmx daemon 持有，surface 只是一个 `zmx attach` 客户端。detach surface 不影响 shell；再次显示时重新 attach，与重启后恢复 pane 走的是同一条路径（`ensureSurface`）。因此回收不需要改 libghostty，只在 app 层做：

- `TerminalEngine` 每隔 `sweepInterval`（默认 60 秒）扫描所有 live surface。在窗口内的 surface 刷新 `lastDisplayedAt`；其余交给 `SurfaceReclaimPolicy` 判定。
- 判定为回收时：清掉 `onClose`，`PaneSurface.close()`（只 detach，daemon 保留），从 runtime 注销，停止该 pane 的前台轮询，并记入 `reclaimedPanes`。
- 之后 pane 再次显示，`PaneHostFeature` 的 `.task` 发现 registry 里没有 surface，走 `ensureSurface`。

### 回收条件（全部满足）

| 条件 | 原因 |
|---|---|
| 不在任何窗口内已超过 20 分钟 | 避免来回切换 tab 时反复重建 |
| 画面静止至少 60 秒 | 仍在重绘的 pane 可能有用户在等的输出 |
| 前台是 shell 提示符或 agent，不是运行中的命令 | 命令在跑时输出由 surface 消费 |
| 不是远程 pane | 其 surface 下是 ssh 隧道，回收收益小、风险大 |
| surface 处于 ready | 不碰 crashed / exited 状态 |
| 无 veto：agent 不在回合中，没有排队命令 | 排队命令只在有 surface 时才会发出 |

veto 由 app 层注入（`TerminalEngine.reclaimVeto`），因为 agent 状态和命令队列位于 Runtime 层之上。窗口被遮挡或最小化时 surface 仍视为「在窗口内」，用户回来时不会遇到重新 attach。

### 重新 attach 与已回收状态

- 重新 attach 不重放 `initialCommand`：那会把 `claude` 之类的命令当作键入送进正在运行的 TUI。也不再发 `.paneCreated` / `.paneReady`，pane 从未消失。
- 回收时保留前台快照与进程行，重新 attach 后轮询继续，不会产生一次假的「agent 解绑 / 重绑」。
- 已回收 pane 被关闭或归档时，除了 kill daemon，还补做 `handleSurfaceClose` 的清理。
- `runtimeProbe`（`pane.read`、`pane.info`）对已回收 pane 仍返回探针：daemon 在无 surface 时照常应答。

## 已知取舍

- 已回收期间，agent 若被定时任务唤醒，只有 hooks 能更新其状态；viewport 与 OSC 信号要等 pane 再次显示。
- 已回收 pane 不计入 `runningPaneCount`（force-remove 确认文案中的进程数），会少算。
- 发往已回收 pane 的排队命令要等 pane 再次显示后才发出，与「从未打开过的 pane」一致。
- 阈值是常量，没有设置项。`CODANS_SURFACE_RECLAIM_SECONDS` 只用于冒烟测试（见 [environment.md](environment.md)）。

## 验证

- `SurfaceReclaimPolicyTests` 覆盖判定与环境覆盖的解析。
- 隔离 Debug 实例（`CODANS_SURFACE_RECLAIM_SECONDS=8`），两个 tab 各一个 pane，显示 B 以隐藏 A：线程 17 → 12，A 的 zmx socket 仍在，`pane read` 仍可用；再次显示 A：线程回到 17，shell 里导出的变量仍在，`initialCommand` 的副作用只出现一次。
