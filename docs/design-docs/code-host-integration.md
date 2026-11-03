# 设计文档：Code Host Integration

**状态：** 已上线（可见）
**作者：** Gump（与 Claude）

## 背景与范围

Code Host 集成在侧栏把每个 Worktree 关联的 Pull Request 状态（编号、标题、draft、加减行、merge 状态、review、CI rollup）呈现为一枚徽标 + popover，并提供 merge / close / mark-ready / rerun-failed-jobs 写操作。Code Host 有 GitHub（经 `gh`）和 GitLab（经 `glab`）两个；UI 标签为 "PR" / "MR"（`CodeHostKind.pullRequestLabel`）。决策见 [ADR 0004](../adr/0004-gitlab-support-through-glab.md)，术语见 [GLOSSARY § Code hosts](../../GLOSSARY.md#code-hosts)。

本文先记录各 Code Host 共用的部分（接口、选择、排程、缓存、失效、UI，只写一次），再按 Code Host 记录 query 形态、字段映射、fork 过滤和 CLI 契约。

取数模型是 **repository-batched GraphQL**：成本随 **O(Repositories)** 而非 **O(Worktrees)** 缩放。一次 CLI 调用覆盖一个仓库内一个 chunk 的全部分支，Pull Request 元数据 + CI rollup 在**一次网络往返**里取回。取数生命周期由 reducer 拥有的取数单元级 effect 驱动，经显式失效事件触发，不依赖 SwiftUI 视图生命周期。

## 目标与非目标

**目标**

- 每个刷新周期的子进程成本从 O(Worktrees) 降到 O(Repositories)，典型 10–40× 减少。
- PR 元数据 + 聚合 check 结果在每仓库**一次网络往返**取回，使 CI 健康度随 PR 快照一同绘制，而非随后到达。
- 取数由 reducer 拥有的 Project 级 effect 发起，经显式失效事件驱动（Worktree 出现、分支变更、写后变更、手动刷新），而非逐行 `.task(id:)`。
- 非功能保证：**零应用内 HTTP、零 Keychain、零 token material 进入 codans、零来自 SwiftUI 视图体的隐藏网络工作**。

**非目标**

- 无直连 Code Host REST/GraphQL HTTP——GitHub 委托 `gh`，GitLab 委托 `glab`（[ADR 0004](../adr/0004-gitlab-support-through-glab.md) item 3）。
- 无应用内 OAuth。`gh auth login` / `glab auth login` 是唯一认证路径；token 住在各 CLI 自己的 config store，我们从不读取。
- 无 webhook / 服务端推送 / app 在后台时的轮询。本地变化走事件驱动失效（见下）；Code Host 侧变化由 app 在前台时的分档轮询补充。
- 无 review 线程 / 评论 / issues / discussions / actions 仪表盘。范围限于 PR 元数据 + 聚合 check rollup。
- 磁盘快照只用于启动时预填（`PullRequestSnapshotCache`）；解码失败的缓存快照被丢弃，由下一次取数替换。
- 无 partial-result 渲染：GraphQL query 失败则整 chunk 失败，绝不渲染半填充的侧栏状态（避免「半合并」的视觉混淆）。

## 设计总览

执行模型：

1. **reducer 拥有取数生命周期。** `CodeHostFeature` reducer 监听失效事件（Worktree added/removed/branch-changed/post-mutation、Project activated、Manual refresh），对任一事件**只**发一个 effect，请客户端**一次性**取该 Project 下全部 Worktree 的 PR 数据。

2. **客户端发批量 query。** `CodeHostClient.batchPullRequests(repository, branches)` 选择该仓库 kind 的实现，由它调用自己的 CLI（GitHub：每 chunk 一次 `gh api graphql`，见 [GitHub 实现](#github-实现)；GitLab：每 chunk 一次 `glab api graphql`，见 [GitLab 实现](#gitlab-实现)）。实现把响应解码为 `[branch: PullRequestSnapshot]` 返回。

3. **reducer 逐 Worktree 分发。** 成功后经本地 catalog 把 `branch → WorktreeID` 映射，写入 `state.snapshotsByProject[P]`，视图照旧从中读取。

4. **失效事件驱动，无 TTL。** 缓存「活到某个已知失效事件发生为止」——这些事件不多，且每个都比对每个 Worktree 盲目按固定窗口重探更便宜也更正确。

5. **check rollup 随快照一起取。** GraphQL query 把 `statusCheckRollup.contexts` 与其余字段一并取回，消费者直接读 `snapshot.checkRollup`，无独立的 `checks(number:)` 调用、无独立的 `state.checks[prNumber]` 映射。

6. **子进程契约统一。** 两个 CLI 都经共享 `CommandRunner`，只用 argv、env allowlist 剥除 token、超时 20 s、读取 output cap 8 MiB；各自的差异见 [gh 子进程契约](#gh-子进程契约) 与 [glab 子进程契约](#glab-子进程契约)。

三个承重决策（详见 [备选方案](#备选方案)）：

1. **按仓库而非按 Worktree 批量。** 一次 CLI 调用覆盖活跃 Project 内每个分支；成本随 Project 数缩放，而非 Worktree 数。
2. **每仓库一次 GraphQL 而非 N 次 REST。** GitHub 用 per-branch alias（`branch0: pullRequests(...) branch1: ...`）；GitLab 用 `mergeRequests(sourceBranches: [...])`。两者都是一次往返覆盖一个 chunk 的全部分支。
3. **事件驱动失效，无 TTL。** 分支变更可观测（`.git/HEAD` 文件系统监听），Worktree add/remove 已在 `HierarchyManager`，Project 激活可观测。活到相关事件发生的缓存，比周期刷新既便宜又更正确。

## 共享层

### Code Host 接口

reducer（`CodeHostFeature`）、快照缓存和视图只用 `CodeHost` 协议（`codans/CodeHost/CodeHost.swift`）和 `CodansCore/CodeHost/` 的 provider-neutral 模型。协议每个 Code Host 一个实现（`GitHubCodeHost`、`GitLabCodeHost`）：可用性、登录过的 host、一个仓库 + 一组分支的批量读取、merge / close / mark ready / rerun failed checks、仓库与 Pull Request 的 web URL。协议没有可选方法；能力差异是快照上的数据（`mergeOptions` 带启用状态和原因、`canRerunFailedChecks`）。只有各实现的解码层知道自己的 wire 值（`GitHubWire`、`GitLabWire`）。

- 仓库是 (kind, host, full path)（`CodeHostRepository`）。full path 保留每一段，GitLab 嵌套 group（`group/sub/repo`）可用。
- 写操作接收 `PullRequestReference`（仓库 + 编号；GitLab 为 `iid`），不依赖 Worktree 工作目录。
- `CodeHostClient` 是唯一按 kind 选择实现的地方；reducer 和视图只在选择 UI 标签时看 kind。
- merge 状态是中立的 `PullRequestMergeState`（clean / conflicted / behind / blocked / draft / unknown + 原因）。依赖 CLI 的错误（未安装、未登录、过旧）带 kind（`CodeHostError`）。
- 批量读取因 CLI 缺失、未登录或过旧而失败时，该单元的每一行在徽标位置显示可操作的错误（`CodeHostError.isCLIError`），popover 给出 `brew install` / `auth login` / `brew upgrade` 提示；其余批量错误只记在单元上。下一次成功取数清除所有行的错误。

### Code Host 选择

每个取数单元在取数开始时读 `origin`，由 `CodeHostResolver` 按以下顺序解析 Code Host（ADR 0004 item 2）：

1. `github.com` 或 `gh` 已登录的 host → GitHub。
2. `gitlab.com` 或 `glab` 已登录的 host → GitLab。
3. Project 设置里的 "Code Host" 选择（`GitProjectSettings.codeHost`：Auto / GitHub / GitLab）。
4. 否则无 Code Host：不取数、无徽标、无错误；该单元记入 `unitsWithoutCodeHost`，轮询跳过它。

两个 CLI 都认识的 host 归 GitHub。Project 选择只在两个 CLI 都不认识 host 时生效（例如 `~/.ssh/config` 里的 SSH 别名），所以它不能把一个 CLI 认识的 host 改成另一种 Code Host。各 CLI 登录过的 host 每个 kind 只问一次并缓存；Settings 的 Re-check 清除缓存（`CodeHostClient.invalidateResolution`）。

`ProjectCodeHostChoiceClient` 在取数时给出单元的选择：

- git Project 的单元以 Project ID 为键，用该 Project 自己的设置。
- Workspace 的单元以派生 ID 为键，用单元仓库所对应的已注册 Project（本地、非 Workspace、规范化 `gitRoot` 相同）的设置；没有对应 Project 时为 Auto。

因为每个单元各自解析 Code Host，一个 Workspace 可以同时有 GitHub 成员和 GitLab 成员（ADR 0004 item 16）。每个成员只显示自己 Code Host 的 Pull Request；不同成员上同名的分支不会混淆，因为单元的缓存、取消、排队和写操作都按单元的仓库隔离。

选择变更时 `CodansApp` 发送 `refreshAllRequested`，所以下一次取数立即使用新选择。"Open Project on Code Host" 命令走同一个解析顺序。

### Settings

- 全局 "Code Hosts" 面板（`CodeHostsSettingsView`）：`gh` 和 `glab` 各一块，显示可用性（已连接的 host 和用户，或可操作的原因）、Re-check 和文档链接；下面是所有 Code Host 共用的默认值：默认 merge 策略和 merge 后的 Worktree 动作。GitLab 上项目的 merge method 生效，`rebase` 策略按 Merge 处理（ADR 0004 item 6）。面板文字说明 Code Host 与 "Hosts" 面板（运行 Project 的机器，ADR 0003）不同。
- Project 设置的 "Code Host" 区：Code Host 选择（Auto / GitHub / GitLab）以及 merge 策略、merge 后动作的 Project 覆盖。只对 git Project 显示；Workspace 成员使用其 Project 的选择。

### 执行流

一个取数单元的完整刷新周期（以用户激活一个 Project 为例）：

```
 1. 用户在侧栏选中 Project P。RootFeature 观察到选择变化。

 2. RootFeature 为 P 的每个取数单元（git Project 一个；Workspace 每个成员仓库一个）
    派发 CodeHostFeature.Action.projectActivated(unit, gitRoot, worktreeBranches)。

 3. reducer 检查 state.snapshotsByProject[unit]:
    - 已缓存 + 分支集匹配 → no-op。
    - 缺失 或 分支变更 → 起取数（遵守 in-flight / queued 重入模型）。

 4. effect 读 remote:  gitService.remoteInfo(gitRoot) → RemoteInfo(host, path)
    （纯 git-local 操作，不属于 CodeHostClient。失败 → .remoteInfoUnavailable）

 5. effect 读 Project 选择:  codeHostChoice.choice(unit, gitRoot) → CodeHostKind?

 6. effect 解析:  codeHost.resolveRepository(remote, choice) → CodeHostRepository?
    nil → .codeHostUnresolved(unit)：清掉该单元的快照和错误，不取数。

 7. effect 取数:  codeHost.batchPullRequests(repository, branches)
    CodeHostClient 按 repository.kind 选实现；实现分 chunk、并发调用自己的 CLI、
    解码、做 fork 过滤，返回 [branch: PullRequestSnapshot]。

 8. reducer 收到 BatchedPullRequests(repository, byBranch, seenBranches, fetchedAt)，
    写入 state.snapshotsByProject[unit]，并按 branch → WorktreeID 投影到
    state.snapshots；整份 map 写回磁盘缓存。

 9. 视图经 @ObservableState 重渲染，徽标与 CI rollup 同一 pass 绘制。

10. 写操作（merge / close / markReady / rerun）成功后 2 秒触发一次该单元的延迟刷新，
    以拾取 Code Host 的新状态。
```

全程 effect 为 `.cancellable(id: CancelID.projectFetch(unit), cancelInFlight: true)`：背靠背触发坍缩为最后一次。

### 数据模型

- **`PullRequestSnapshot`**（`CodansCore/CodeHost/`）是 provider-neutral 快照：编号、标题、state、draft、head / base ref、作者、加减行、commit 数、URL、更新时间、`checkRollup`、`mergeState`（`PullRequestMergeState`）、`reviewDecision`、`mergeOptions`、`canRerunFailedChecks`、`baseRepositoryURL`。check 结果随元数据在同一 query 取回。
- **`BatchedPullRequests`** 是 `batchPullRequests` 的返回包络，reducer 每单元存一份：解析出的 `repository`、`byBranch`（无 Pull Request 的分支不出现）、`seenBranches`、`fetchedAt`。写操作和 web URL 从这里的 `repository` 得到目标仓库。

`baseRefName` 与 `baseRepositoryURL` 一起描述 Pull Request 的目标仓库和分支，供内置 Diff Viewer 定位本地 remote-tracking ref。两字段可选，缺失时不能仅凭分支名猜测目标仓库，尤其是 fork PR。快照更新经 `RootFeature` 同步到已打开的 Diff 窗口，见 [Git Diff Viewer](git-diff-viewer.md)。

### 缓存与失效

**缓存键是取数单元的 `ProjectID`。** 普通 Git Project 使用自身 ID；Workspace 按成员的源仓库分组，每组用 Workspace ID 与规范化仓库根路径派生稳定 ID。缓存、取消和排队刷新都按这个单元隔离，不会把不同成员仓库的同名分支配成同一 PR。Workspace 激活时刷新各组；轮询覆盖每个组，选中 Workspace 的所有组都按选中档节奏。

无基于 TTL 的过期策略；本地事件负责失效，应用处于前台时的自适应轮询补充 Code Host 服务端变更。磁盘快照可用于启动时预填，catalog 清理同时保留仍存活的 Workspace 取数单元。

Source: [RootFeature.swift](../../apps/mac/codans/App/Features/Root/RootFeature.swift) (`codeHostFetchUnits`, `workspaceFetchGroupID`) and [CodeHostFeature.swift](../../apps/mac/codans/App/Features/CodeHost/CodeHostFeature.swift).

**失效事件枚举：**

| 事件 | 来源 | 触发 |
|---|---|---|
| Project 激活（从另一 Project 切入） | `HierarchyManager.selectedProjectID` 增量 | 缓存分支集 ≠ 当前 Worktree 分支则刷新 |
| Worktree added | `HierarchyManager` catalog 增量 | 刷新 Project |
| Worktree removed | `HierarchyManager` catalog 增量 | 从缓存移除；不取数 |
| Worktree 分支变更 / commit | `WorktreeHeadWatcher`（`.git/HEAD` + reflog 监听） | 刷新该 Worktree 所属取数单元（不是选中 Project）；取数返回前，分支已变的行按缓存改投新分支的 PR 或清空徽标 |
| Merge / close / markReady 完成 | `CodeHostFeature.*Completed(.success)` | 2 秒延迟刷新 Project |
| 手动刷新 | 用户动作（面板、popover 刷新按钮） | 立即刷新 Project |
| 侧栏「刷新全部」 | `refreshAllProjectsRequested` | 所有取数单元排队刷新，经并发上限依次执行 |
| pane 内 `git` / `gh` 命令结束 | 前台作业 trailing edge（不含 agent） | 1.5 s 后刷新该 pane 所属取数单元 |
| 远端跟踪 ref 变更 | `RemoteRefsWatcher`（FSEvents 监听公共 git 目录下的 `refs/remotes/` 与 `packed-refs`） | 2 s 后刷新该取数单元，并在 3 min 内按 hot 档轮询。覆盖任意进程的 `git push` / `gh pr create` / `git fetch`，包括前台作业检测看不到的 agent |
| Project 的 Code Host 选择变更 | `SettingsStore` 观察（`CodansApp.observeCodeHostChoices`） | 所有取数单元排队刷新；无 Code Host 的单元（轮询跳过）立即重新解析 |
| App 变为活跃 | `NSApp.didBecomeActiveNotification` | reconcile 后，所有超过 30 s（`focusRefreshDebounce`）未取数的单元排队补刷，选中 Project 优先 |
| liveness 轮询 | 前台 timer，gated on `NSApp.isActive` × 所有取数单元 | 按单元分档节奏强制刷新（见下表）；app resign active 即刻取消，故后台 app 零轮询 |

**重入模型。** 每 Project 三个状态槽：`snapshotsByProject[P]`（当前缓存，未取过为 nil）、`inFlightFetchProjects`（有活跃子进程链的 Project 集）、`queuedRefreshByProject`（取数在飞时又请求刷新的 Project，排队请求在进行中那次完成后跑）。失效事件检查是否在飞：是则标 queued 并 no-op，否则起取数并加入 in-flight 集；完成时清 in-flight，若 queued 则补发一次。这干净处理 merge-close-markReady-merge 快速连击：首次跑完，后续坍缩成一次最后跑的 queued 取数。

**取消。** queued 刷新在 Project 关闭或用户导航离开时丢弃；in-flight 取数在 Project 失活时经 `.cancellable(id: CancelID.projectFetch(P), cancelInFlight: true)` 取消。

**关于轮询的取舍。** 纯事件驱动的「用户交互时同等新鲜」前提只对*本地*状态成立——用户在终端 pane 打字不是 GitHub 失效事件，agent 在 pane 里跑的 `git push` / `gh pr create` 只能靠远端跟踪 ref 监听发现，故源自 Code Host 侧的 check 完成、review、merge/close、新 PR 在纯事件驱动下无新鲜保证。补的信号是一个调度器：**覆盖所有 Project 的取数单元**、**只在 app 为前台时**（resign-active 即取消）、**按单元分档**（选中 Project 更快，有东西在飞时更快）。应用失去前台状态时停止轮询；仅离开键盘但应用仍为前台时，轮询继续。

| 档位（按最近一次批量结果） | 选中 Project | 其他 Project |
|---|---|---|
| hot：有 open PR 的 check 在跑或 merge 状态 unknown | 10 s | 30 s |
| warm：有 open PR，均已 settle | 30 s | 2 min |
| cold：无 open PR，或尚未取数 | 60 s | 5 min |

远端跟踪 ref 变更后 3 min（`remoteRefsHotWindow`）内，该单元不论批量结果如何都按 hot 档：push 之后 agent 常隔一段时间才 `gh pr create`，CI 也随后才启动。

调度器单 timer：睡到最早到期的单元（夹在 1–60 s），到期单元按「选中优先、上次取数最早优先」启动，轮询发起的取数最多 2 个并发；某次取数完成即把空出的槽交给下一个到期单元。节奏以「上次取数开始时间」计，任何来源的取数（事件、手动、轮询）都会重置该单元的节奏。

Source: [CodeHostFeature.swift](../../apps/mac/codans/App/Features/CodeHost/CodeHostFeature.swift) (`pollInterval`, `runPollScheduler`).

### 取数排程（reducer）

`enqueueProjectFetch` 写入单元的 gitRoot、分支对和 Worktree → 单元反查表，然后按重入模型起 [执行流](#执行流) 步骤 4–7 的 effect。`projectBatchLoaded` 清 in-flight，成功时写快照、失败时记单元错误（CLI 错误同时投到每一行），若有排队请求则补发一次。`codeHostUnresolved` 清 in-flight 并把单元记入 `unitsWithoutCodeHost`。

**写动作完成**派发 `.delegate(.pullRequestMerged(...))` + 一次延迟刷新。2 秒延迟是显式的：Code Host API 在 merge 后与自身 UI 非强一致，立即取数可能返回 merge 前状态。

### `GitService.remoteInfo` 辅助

`RemoteInfo(host, path)` 从 `git remote get-url origin` 解析，接受 SCP（`git@host:group/sub/repo.git`）、HTTPS 和 `ssh://` 形式，保留 path 的每一段；host 可带端口。这是纯 git 操作，**属于 `GitService`，不属于 `CodeHostClient`**。解析失败抛 `.remoteInfoUnavailable`，记为单元错误。host 归哪个 Code Host 由 [Code Host 选择](#code-host-选择) 决定，不由 parser 决定。

### UI 层

视图层接线：

- `WorktreeRowIcon` 的 `rollup` 来源是 `PullRequestBadge.CheckRollup.from(checks: snapshot.checkRollup)`。
- `PullRequestPopover` 读 `snapshot.checkRollup` + `snapshot.mergeStateStatus` / `snapshot.reviewDecision`，精确解释 merge-disabled 原因。
- `WorktreePullRequestBadge` 读 `store.snapshots[worktreeID]`，该字典由 reducer 从 `state.snapshotsByProject[P]` 派生。
- 侧栏行不持有发起取数的逐行 `.task`；取数由 reducer 经取数单元事件发起。侧栏 PR 徽标不显示取数 spinner；popover 在有无缓存的刷新期间均可显示 loading。

### PR ↔ Worktree 配对

- 匹配键 = `headRefName == Worktree.branch`。
- 同一取数单元内的多个 Worktree 可以映射到同一个分支快照；不同 Workspace 成员仓库使用不同取数单元。
- **孤儿**（无法解析的 paneID/branch）从**徽标计数与 popover 行双双排除**，使两者永不发散。

## GitHub 实现

`codans/CodeHost/GitHub/` 通过 `gh` 实现 `CodeHost`；只有这里知道 GitHub 的 wire 值（`GitHubWire`）。写操作以 `--repo HOST/OWNER/REPO` 定位仓库。

- "Rerun failed" 的显示条件与执行目标来自同一份数据：PR head commit 的 `statusCheckRollup` 中失败的 GitHub Actions CheckRun（`detailsUrl` 含 `/actions/runs/<id>/`），由 `GitHubWire.failedWorkflowRunIDs` 选出。快照的 `canRerunFailedChecks` 为该集合非空；执行时 `GitHubCodeHost.rerunFailedChecks` 重新读取 `gh pr view <n> --json statusCheckRollup`，对每个失败的 run 调用 `gh run rerun <id> --failed`。这样即使另一个 workflow 在分支上有更新且成功的 run，也不会重跑错的 run。外部 CI 的 StatusContext 失败不显示该按钮。popover 打开时不再单独取 workflow run。

### GraphQL Query 形态

query 被**程序化拼成原始字符串**——不用类型化 query builder：GitHub 的 GraphQL schema 足够稳定、query 很小，维护一套类型化 DSL 的成本大于收益。

一个 ≤ 25 分支的 chunk 产一条 query：

```graphql
query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    branch0: pullRequests(
      first: 5,
      states: [OPEN, MERGED],
      headRefName: "<branch-name-0>",
      orderBy: {field: UPDATED_AT, direction: DESC}
    ) {
      nodes { ...PRFields }
    }
    branch1: pullRequests(first: 5, states: [OPEN, MERGED],
      headRefName: "<branch-name-1>", orderBy: {...}) { nodes { ...PRFields } }
    ...
    branch24: pullRequests(...) { nodes { ...PRFields } }
  }
}
```

`PRFields` 内联为一个 inline fragment——**不用 GraphQL fragment**，因为 `gh api graphql` 把整条 query 作为单个 `-f query=` 参数传，内联使 wire payload 留在 argv 体积上限内。字段：

```graphql
number
title
state
isDraft
additions
deletions
mergeable
mergeStateStatus
reviewDecision
url
updatedAt
headRefName
baseRefName
baseRepository { url }
commits { totalCount }
author { login }
headRepository { name owner { login } }
statusCheckRollup {
  contexts(first: 100) {
    nodes {
      ... on CheckRun {
        name
        status
        conclusion
        startedAt
        completedAt
        detailsUrl
      }
      ... on StatusContext {
        context
        state
        targetUrl
        createdAt
      }
    }
  }
}
```

**为何每分支 `first: 5`。** 一个分支历史上可能有多个 PR（reopen、二次 push、合并后再开）。取最近 5 个，挑过 fork 过滤后最近更新的那个；5 是安全上限，实践中极少超过，超过则展示最近 5 个并 `.debug` 记录截断。

**为何 `states: [OPEN, MERGED]`。** Closed（非合并）PR 罕见且通常是有意的死端，在侧栏展示徒增噪声、价值近零。需要看 closed 时点「Open on GitHub」。

**为何 `orderBy: UPDATED_AT DESC`。** 在 5-PR 切片内要把最近活跃的置顶；`UPDATED_AT`（而非 `CREATED_AT`）正确处理 reopen-after-close。

**分支名转义。** `feat/"weird"name` 或含反斜杠的分支名会破坏 query。按 GraphQL 字符串规则转义反斜杠、`"`、控制字符；含换行的分支拒绝，抛 `.malformedBranchName(branch)`，reducer 记录并从取数排除。

**为何 alias 名格式 `branch{index}`。** 纯整数索引避免与用户分支名冲突（GraphQL alias 须匹配 `/[_a-zA-Z][_a-zA-Z0-9]*/`，否则需各自转义）。解码器维护独立的 `[alias: branchName]` 映射把结果配回。

### 响应解码

单 chunk 的响应形态：

```json
{
  "data": {
    "repository": {
      "branch0": { "nodes": [ { ... PR fields ... } ] },
      "branch1": { "nodes": [] },
      "branch2": { "nodes": [ {...}, {...} ] },
      ...
    }
  }
}
```

两个非显然的解码模式：

#### 1. alias 的动态键

`repository` 对象有 N 个任意字符串键（`branch0`、`branch1`…），集合不固定。标准 `CodingKeys` 枚举不支持，需自定义解码器：

```swift
struct DynamicKey: CodingKey {
  let stringValue: String
  init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
  let intValue: Int?
  init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

struct RepositoryResponse: Decodable {
  let pullRequestsByAlias: [String: PullRequestConnection]

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: DynamicKey.self)
    var out: [String: PullRequestConnection] = [:]
    for key in c.allKeys {
      out[key.stringValue] = try c.decode(PullRequestConnection.self, forKey: key)
    }
    self.pullRequestsByAlias = out
  }
}
```

上游调用方保留 query 构造时的 `[alias: originalBranch]` 映射，返回前把解码后的字典 zip 回分支名。

#### 2. union 类型归一

`statusCheckRollup.contexts.nodes` 是 GraphQL union `CheckRun | StatusContext`。两者用途重叠（CI 状态）但字段名不同：`CheckRun` 有 `name`/`detailsUrl`/`status`/`conclusion`，`StatusContext` 有 `context`/`targetUrl`/`state`。在解码时归一成单一 `CheckNode`，携带行实际拥有的字段：

```swift
struct CheckNode: Decodable, Equatable, Hashable {
  let name: String?          // CheckRun.name OR StatusContext.context
  let detailsUrl: String?    // CheckRun.detailsUrl OR StatusContext.targetUrl
  let status: String?        // CheckRun only
  let conclusion: String?    // CheckRun only
  let state: String?         // StatusContext only

  enum CodingKeys: String, CodingKey {
    case name, context, detailsUrl, targetUrl, status, conclusion, state
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let n = try c.decodeIfPresent(String.self, forKey: .name)
    let ctx = try c.decodeIfPresent(String.self, forKey: .context)
    self.name = n ?? ctx
    let dUrl = try c.decodeIfPresent(String.self, forKey: .detailsUrl)
    let tUrl = try c.decodeIfPresent(String.self, forKey: .targetUrl)
    self.detailsUrl = dUrl ?? tUrl
    self.status = try c.decodeIfPresent(String.self, forKey: .status)
    self.conclusion = try c.decodeIfPresent(String.self, forKey: .conclusion)
    self.state = try c.decodeIfPresent(String.self, forKey: .state)
  }
}
```

下游 `CheckRollup.from(nodes:)` 把 `status` + `conclusion` + `state` 坍缩成单一语义枚举（passing / failing / pending / skipped）。**rollup 把 `.cancelled` / `.timedOut` / `.actionRequired` / `.stale` / `.startupFailure` 全部计为 FAILING**——这些都是「这个 PR 现在不能干净合并」的同义状态，不应被当成中性或通过。Check JSON 的时间字段以 `.iso8601WithFractionalSeconds` 解码。

### Fork PR 过滤

**陷阱。** GitHub 的 `pullRequests(headRefName: "main")` 匹配任何 head-ref 字面等于 `main` 的 PR——包括源分支恰好同名的 **fork PR**。常见情形：fork 上的贡献者把特性分支命名为 `main`，向上游 `main` 开 PR；此时对上游本地 `main` 的查询会返回该 PR，尽管上游 `main` 是**目标**而非源。这是一个非显然的正确性陷阱。

**规则**（对每个分支的结果数组，顺序判定）：

1. 先保留所有 `headRepository.owner.login == <project remote 的 owner>` 的条目——上游到上游的 PR，常见且总是正确。
2. 若步骤 1 产出零条，保留 `baseRefName != headRefName` 的条目——这让我们浮现 head 是我们分支的 fork PR（有效），同时拒绝目标是我们分支的（无效）。
3. 从幸存者里挑第一个（按 `orderBy` 即最近更新）。
4. 零幸存者 → 该分支无 PR。

过滤在 `GitHubCodeHost.batchPullRequests` 内、返回 `[branch: PullRequestSnapshot]` 前完成；reducer 看到干净映射，不知 fork 存在。`headRepositoryOwner` 为 null（fork 被删）时按「fork，仅当 base ≠ head 才保留」处理。

### gh 子进程契约

- **env allowlist** 转发 `PATH`、`HOME`、`GH_CONFIG_DIR`、`XDG_CONFIG_HOME`（重定位的 auth store）+ 强制 `LC_ALL`，**剥除 `GH_TOKEN` / `GITHUB_TOKEN`**——codans 不携带、不转发任何 token material。
- 子进程 argv 是 `(executable, [args])`，无 shell 解释。GraphQL query 作为单个 `-f query=<body>` 传（gh 处理 HTTP POST body）；body 内的用户派生分支名在插值前已 GraphQL-字符串转义，转义失败的分支名被丢弃并记日志。
- 超时 20 s；**output cap 8 MiB**（25 分支 × 5 PR × 完整 check rollup 在病态大仓可达 ~4–6 MB；超限抛 `.oversizeResponse`）。
- 最低 `gh` 版本 **2.20+**（稳定 GraphQL + `--hostname` 行为）；可用性探针解析 `gh --version`，过旧则显示 `brew upgrade gh` 横幅。

## GitLab 实现

`codans/CodeHost/GitLab/` 通过 `glab` 实现同一个 `CodeHost` 协议；UI 标签为 "MR"（`CodeHostKind.pullRequestLabel`），菜单 / 命令面板 / 侧栏右键菜单写作 "Open MR on GitLab" / "Open Project on GitLab"。

- **读取**：每个 chunk（20 个分支）用 `glab api graphql` 读 `project(fullPath:) { mergeRequests(sourceBranches: $branches, first: 100, after: $after, sort: UPDATED_DESC) }`（`GitLabMergeRequestQuery`），按 `pageInfo.endCursor` 读完所有页后才生成快照：后一页可能有某分支自己的 MR（前一页只有 fork 的同名 MR）。head pipeline 的 job 也分页，首页之外的 job 按 MR 用 `jobsQuery` 补读，后续页里失败的 job 也能进 rollup 和 "Rerun failed"。每个列表最多读 `maxPages`（20）页，超出就报错，不显示不完整的列表；响应缺 `pageInfo` 同样报错。分支名以 JSON 数组变量传入（`-F branches=[...]`），不进入 query 文本，因此无需转义。
- **CE 兼容**：只用 CE 有的字段。CE 没有 `approvalsLeft` / `approvalsRequired` / `squashOption`；"还需审批" 来自 `detailedMergeStatus == NOT_APPROVED`，squash 规则来自 MR 的 `squashReadOnly` + `squashOnMerge`。
- **GitLab 已知问题**：列表中选 `diffStatsSummary` 会让 GitLab 把可合并 MR 的 `detailedMergeStatus` 报为 `CONFLICT`，所以加减行由 `diffStats` 逐文件求和。重试过的 job 仍在 `jobs` 里，所以用 `jobs(retried: false)`。
- **未登录检测**：GitLab 对匿名 GraphQL 请求也正常应答，所以 query 带 `currentUser`；为 `null` 即抛 `.notAuthenticated(.gitlab, host:)`。
- **映射**（`GitLabWire`）：
  - `detailedMergeStatus`：`MERGEABLE` → clean；`CONFLICT` → conflicted；`NEED_REBASE` → behind；`DRAFT_STATUS` → draft；`NOT_APPROVED` / `DISCUSSIONS_NOT_RESOLVED` / `CI_MUST_PASS` / `CI_STILL_RUNNING` / `BLOCKED_STATUS` 等 → blocked + 原因；`CHECKING` / `UNCHECKED` / `PREPARING` → unknown；`NOT_OPEN` → unknown 无原因；未知值 → blocked。
  - head pipeline 的 job → check：失败且 `allow_failure` → neutral；`MANUAL`（未运行的手动 job）→ skipped；`SCHEDULED` → waiting。
  - review decision：有 reviewer `REQUESTED_CHANGES` → changes requested；`NOT_APPROVED` → review required；`approved` 且有审批人 → approved；否则无。
  - 合并选项："Merge"（`mergeCommit`，项目的 merge method 生效）与 "Squash and merge"。项目 squash 为 never 时后者禁用并给原因；为 always 时前者禁用。默认策略 `mergeCommit` / `rebase` → Merge，`squash` → Squash and merge（`PullRequestSnapshot.mergeStrategy(preferring:)`）。
  - fork 过滤：与 GitHub 规则相同，以 source project 的 full path 代替 head repository owner；在保留的 MR 中 open / merged 优先于 closed。
  - Diff Viewer：`baseRefName` = target branch，`baseRepositoryURL` = target project 的 web URL。
- **写操作**：merge 为 `glab api --method PUT projects/<id>/merge_requests/<iid>/merge -F squash=<bool>`；close 为 `... -f state_event=close`；mark ready 为 GraphQL mutation `mergeRequestSetDraft(draft: false)`，只有返回的 payload 无 errors 且 `mergeRequest.draft == false` 才算成功；rerun 先读 MR 的 `head_pipeline.id`，再 `POST projects/<id>/pipelines/<id>/retry`（GitLab 只重跑失败和取消的 job）。`<id>` 是 URL 编码的 full path，嵌套 group 可用。
- **Web URL**：scheme 取自 `glab auth status` 报告的 `api_protocol`（自托管实例可能是 `http`），未知时用 `https`。

### glab 子进程契约

- 与 `gh` 相同：共享 `CommandRunner`，只用 argv，cwd 为 home 目录，超时 20 s，读取 output cap 8 MiB、写操作 2 MiB。
- **host**：每次调用都设置 `GITLAB_HOST=<host>`；host 不含端口时另加 `--hostname <host>`。`glab --hostname` 不接受 `host:port`，所以带端口的自托管实例只走环境变量。
- **env allowlist** 转发 `PATH`、`HOME`、`GLAB_CONFIG_DIR`、`XDG_CONFIG_HOME`，强制 `LC_ALL`、`NO_COLOR`、`GLAB_NO_PROMPT`、`GLAB_CHECK_UPDATE=false`、`GLAB_SEND_TELEMETRY=false`、`GLAB_SHOW_WHATS_NEW=false`；剥除 `GITLAB_TOKEN` / `GITLAB_ACCESS_TOKEN` / `OAUTH_TOKEN` 及用户自设的 `GITLAB_HOST` / `GITLAB_REPO`。
- **最低 `glab` 版本 1.122.0**：首个带 `glab auth status --output json` 的版本（resolver 与可用性探针依赖它）。每个可执行文件（按路径 + 修改时间）只跑一次 `glab version`；过旧抛 `.cliOutdated`。`glab auth status --all --output json` 在任一 host 校验失败时退出码为 1，stdout 仍是 JSON，两者都解析。
- **错误**：`glab api` 在 GraphQL `errors` 或 REST 错误时退出 1，body 在 stdout。GraphQL errors → `.graphQLError`；401 → `.notAuthenticated`；`dial tcp` / TLS / 解析失败 → `.network`；merge 的 405 / 406 / 409 → `.mergeConflict`。
- 已知限制：`glab` 过旧或未装时无法得知它登录过的自托管 host，此类 remote 解析为无 Code Host（无徽标）；`gitlab.com` 仍解析为 GitLab 并显示可操作错误。

## 备选方案

- **A — per-Worktree 取数（每行 `gh pr view <branch>` + `gh pr checks <number>`），加 3 路 in-flight cap + `statusCheckRollup` 合并。** 否决：成本随 Worktree 数而非仓库数缩放。合并 pr view + pr checks 把子进程从 2N 降到 N 是增量优化，但仍 O(N)——20 个 Worktree 仍要 20 × 150 ms 冷启动；且逐行 `.task(id:)` 依赖 SwiftUI 视图生命周期，当行解析为不挂载的 `EmptyView()` 时无缓存行的取数根本不发生。repository-batched 模型把成本降到 O(Repositories) 并把取数从视图生命周期解耦，故采纳。
- **B — 用 `gh pr list --json ... --state all`。** 否决：`gh pr list --json statusCheckRollup` 受支持，但 gh 内部对每个 PR 另发一次 GraphQL，实为 N 次往返、只是被隐藏，总墙钟与 N-分支最坏情形相同。「直接用 gh pr list」的简洁是个泄漏抽象。
- **C — `URLSession` 直连 GraphQL + Keychain 存 OAuth。** 否决：`gh api graphql` 每 chunk 加 ~100–150 ms 子进程成本，3 并发 chunk 约 200 ms/刷新；付 ~1500 行工程账（OAuth device flow、token 存储/刷新、rate-limit 退避、错误分类、Enterprise host 切换、re-auth 面）去省 ~200 ms 是错的权衡，且重复 `gh` 已正确做的事。仅当 codans 需要实时 PR 更新 / review 线程 / 跨仓聚合时再考虑。
- **D — app 在后台时也轮询。** 否决：后台 app 无人看徽标，轮询只付子进程与 API 成本；回到前台时的 30 s 防抖补刷足以在用户看到前更新。前台时所有 Project 都按分档节奏轮询——只轮询选中 Project 会让其他 Project 的徽标在切换前一直陈旧，而 agent 正在其他 Project 里开 PR 是常态。前台判定是 `NSApp.isActive`，不是用户是否正在操作。
- **E — 落盘最后快照以启动即显。** 否决：当前「启动后 ~500 ms 空侧栏再填充」可接受。落盘会带来 stale 数据、「显示 X 又变 Y」类 bug、翻倍文件 IO 面。待用户反馈再议。

## 风险

| 风险 | 缓解 |
|---|---|
| GraphQL query 复杂度预算。25 分支 × 5 PR × ~100 check 节点实测 ~5000 点（上限 10000），但极密 CI 仓可能超。 | 固定按最多 25 个分支分块；复杂度错误会使该次 Project 批量刷新失败，没有自动减半重试。 |
| `gh api graphql` 最低版本（2.20+ 才有稳定 GraphQL + `--hostname`）。 | 可用性探针解析 `gh --version`，过旧显示可操作横幅；Settings「Requirements」钉最低版本。 |
| `WorktreeBranchWatcher` FS watch 耗尽（macOS 每进程 ~2048）。 | 只监听可见侧栏视口内的 Worktree（约 ≤ 50），其余回退到 focus-gained reconcile。 |
| in-flight + queued 状态泄漏（Project 取数中途被移除）。 | Project 移除时经 `CancelID.projectFetch(P)` 取消并从两集移除。 |
| 边缘大仓超 8 MiB 响应。 | 超过上限抛出 `.oversizeResponse`，该次 Project 批量刷新失败；没有自动减半重试。 |
| `headRepositoryOwner` 在某些 PR 形态为 null（fork 被删）。 | fork 过滤把 null owner 当「fork，仅当 base ≠ head 才保留」。 |
| 事件驱动失效漏掉一个事件（分支变更但 watcher 未监听且未 focus-gained）。 | `HierarchyManager.reconcileDiscoveredWorktrees`（focus-gained 时跑）更新每个 Worktree 的 `branch`，reducer 观察到并失效 Project——以变更到首刷的延迟为代价覆盖该情形。 |

## 参考

- [main-window.md](main-window.md) — UI 层引用的侧栏行组合。
- [docs/architecture.md](../architecture.md) — 模块边界与依赖规则。
- [GitHub GraphQL API reference](https://docs.github.com/en/graphql) — 尤其 `PullRequest`、`StatusCheckRollup`、`CheckRun`、`StatusContext` 类型。
- [`gh api graphql`](https://cli.github.com/manual/gh_api) — gh 手册的 GraphQL 委托章节。
- [GraphQL Alias syntax](https://graphql.org/learn/queries/#aliases) — 此处使用的核心批量技术。
