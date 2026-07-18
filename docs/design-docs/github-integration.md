# 设计文档：GitHub Integration

**状态：** 已上线（可见）
**作者：** Gump（与 Claude）

## 背景与范围

GitHub 集成在侧栏把每个 Worktree 关联的 PR 状态（编号、标题、draft、加减行、mergeable、review、CI rollup）呈现为一枚徽标 + popover，并提供 merge / close / mark-ready / rerun-failed-jobs 写操作。用户可见面（侧栏 capsule、popover、命令面板入口、Settings）与取数无关，下文只记录取数与写入模型的耐久决策。

取数模型是 **repository-batched GraphQL**：成本随 **O(Repositories)**（用户开着的仓库数，实践中 ≤ 1）而非 **O(Worktrees)** 缩放。一次 `gh api graphql` 用 per-branch GraphQL alias 覆盖一个 Project 内的全部分支，PR 元数据 + CI rollup 在**一次网络往返**里取回。取数生命周期由 reducer 拥有的 Project 级 effect 驱动，经显式失效事件触发，不依赖 SwiftUI 视图生命周期。

## 目标与非目标

**目标**

- 每个刷新周期的子进程成本从 O(Worktrees) 降到 O(Repositories)，典型 10–40× 减少。
- PR 元数据 + 聚合 check 结果在每仓库**一次网络往返**取回，使 CI 健康度随 PR 快照一同绘制，而非随后到达。
- 取数由 reducer 拥有的 Project 级 effect 发起，经显式失效事件驱动（Worktree 出现、分支变更、写后变更、手动刷新），而非逐行 `.task(id:)`。
- 非功能保证：**零应用内 HTTP、零 Keychain、零 token material 进入 codans、零来自 SwiftUI 视图体的隐藏网络工作**。

**非目标**

- 无直连 GitHub REST/GraphQL HTTP——继续委托 `gh`（具体是 `gh api graphql`，跑在 `gh` 已认证的 HTTP 栈上）；唯一变化的是 query body。
- 无应用内 OAuth。`gh auth login` 是唯一认证路径；token 住在 `gh` 自己的 config store，我们从不读取。
- 无 webhook / 服务端推送 / 后台轮询。失效是事件驱动（见下），非时间驱动。
- 无 review 线程 / 评论 / issues / discussions / actions 仪表盘。范围限于 PR 元数据 + 聚合 check rollup。
- 无 PR 状态落盘。快照仅在内存，应用启动即重置。
- 无 partial-result 渲染：GraphQL query 失败则整 chunk 失败，绝不渲染半填充的侧栏状态（避免「半合并」的视觉混淆）。

## 设计总览

执行模型：

1. **reducer 拥有取数生命周期。** `GitHubFeature` reducer 监听失效事件（Worktree added/removed/branch-changed/post-mutation、Project activated、Manual refresh），对任一事件**只**发一个 effect，请客户端**一次性**取该 Project 下全部 Worktree 的 PR 数据。

2. **客户端发批量 GraphQL query。** `GitHubClient.batchPullRequests(host, owner, repo, branches)` 调一次 `gh api graphql`，传入每分支一个 GraphQL alias 的 query 串（每 chunk ≤ 25 分支，多 chunk 以并发上限 3 并行）。响应在一个 payload 里带回每个分支的 PR 数据，客户端解码为 `[branch: PullRequestSnapshot]` 返回。

3. **reducer 逐 Worktree 分发。** 成功后经本地 catalog 把 `branch → WorktreeID` 映射，写入 `state.snapshotsByProject[P]`，视图照旧从中读取。

4. **失效事件驱动，无 TTL。** 缓存「活到某个已知失效事件发生为止」——这些事件不多，且每个都比对每个 Worktree 盲目按固定窗口重探更便宜也更正确。

5. **check rollup 随快照一起取。** GraphQL query 把 `statusCheckRollup.contexts` 与其余字段一并取回，消费者直接读 `snapshot.checkRollup`，无独立的 `checks(number:)` 调用、无独立的 `state.checks[prNumber]` 映射。

6. **gh 子进程路径不变。** Resolver、env allowlist、超时（20 s）、argv 安全模型全部沿用；仅 output cap 为批量 query 提高到 8 MiB（见 Risks）。

三个承重决策（详见 [备选方案](#备选方案)）：

1. **按仓库而非按 Worktree 批量。** 一次 gh 调用覆盖活跃 Project 内每个分支；成本随 Project 数缩放，而非 Worktree 数。
2. **GraphQL alias 模式而非 N 次 REST。** GitHub GraphQL 支持 per-field alias，对单个 `repository(owner, name)` 根查 `branch0: pullRequests(...) branch1: pullRequests(...) ...`，一次往返、一次 rate-limit 计费。
3. **事件驱动失效，无 TTL。** 分支变更可观测（`.git/HEAD` 文件系统监听），Worktree add/remove 已在 `HierarchyManager`，Project 激活可观测。活到相关事件发生的缓存，比周期刷新既便宜又更正确。

### 系统上下文

```
      ┌──────────────────────────────────────────────────────────────────┐
      │  codans app window                                                 │
      │                                                                    │
      │  ┌──────────────────┐   ┌───────────────────────────────────┐     │
      │  │  Sidebar         │   │  GitHubFeature (TCA reducer)      │     │
      │  │  Worktree rows   │──▶│   state:                          │     │
      │  │   + PR badge     │   │   · snapshotsByProject            │     │
      │  │   + overlay      │   │   · inFlightFetchProjects         │     │
      │  └──────────────────┘   │   · queuedRefreshByProject        │     │
      │         ▲    │          │   effects:                        │     │
      │         │    │hover     │   · refreshProject(projectID)     │     │
      │         │    ▼          │   · delayedFullRefresh(postWrite) │     │
      │         │  popover      └────────────────┬──────────────────┘     │
      │         │               ┌─ GitHubClient (DI) ─                    │
      │         │               ▼                                         │
      │  ┌──────────────────┐   ┌────────────────────────────────┐        │
      │  │  Branch watcher  │──▶│  codans/GitHub/                │        │
      │  │  (HEAD filesys)  │   │    · GitHubService (proto)     │        │
      │  └──────────────────┘   │    · LiveGitHubService         │ ───────┼──┐
      │                         │      ├ buildBatchedQuery()     │        │  │
      │                         │      ├ chunk(branches, n=25)   │        │  │
      │                         │      └ TaskGroup (cap=3)       │        │  │
      │  HierarchyManager.catalog                                 │        │  │
      │  (Worktree add/remove,  │    · DynamicKeyedDecoder        │        │  │
      │   selection changes)    │    · PullRequestSnapshot (ext)  │        │  │
      │                         │    · GitHubError (ext)          │        │  │
      │                         └────────────────────────────────┘        │  │
      └──────────────────────────────────────────────────────────────────┘  │
                                                                              │
                                                                              ▼
                                                            ┌───────────────────────────┐
                                                            │ /opt/homebrew/bin/gh       │
                                                            │   gh api graphql \         │
                                                            │     --hostname <host> \    │
                                                            │     -f query='<aliased>' \ │
                                                            │     -f owner=<owner> \     │
                                                            │     -f repo=<repo>         │
                                                            │                            │
                                                            │  One child per chunk,      │
                                                            │  up to 3 concurrent.       │
                                                            │  cwd = project.gitRoot     │
                                                            │  timeout 20s, cap 8 MiB    │
                                                            └──────────┬─────────────────┘
                                                                       │ HTTPS
                                                                       ▼
                                                             api.github.com/graphql
```

外部边界：

- **`gh` CLI**——角色不变；子命令从 `gh pr view / gh pr checks` 改为 `gh api graphql`。仍一请求一子进程，仍 cwd-scoped，使 `gh` 从 project 的 gitRoot 解析 remote。
- **`HierarchyManager`**——现在也被观察 `worktreeAdded` / `worktreeRemoved` / `projectActivated`，驱动缓存失效。
- **文件系统**——`WorktreeBranchWatcher` 轻量监听每个 Worktree 的 `.git/HEAD`，当终端内 `git checkout` 落地时派发 `worktreeBranchChanged(worktreeID, newBranch)`。
- **`SettingsStore`**——不变。

### 执行流

一个 Project 的完整刷新周期（以用户激活该 Project 为例）：

```
 1. 用户在侧栏选中 Project P。
    HierarchyManager.selectedProjectID 翻转，RootFeature 观察到。

 2. RootFeature 派发 GitHubFeature.Action.projectActivated(P)。

 3. reducer 检查 state.snapshotsByProject[P]:
    - 已缓存 + 分支集匹配当前 catalog → no-op。
    - 缺失 或 分支变更 → 排程刷新。

 4. reducer 收集当前分支:
      let branches = project.worktrees
        .filter { !$0.archived && $0.branch != nil }
        .compactMap(\.branch)

 5. reducer 解析 host/owner/repo:
      let remote = try await gitClient.remoteInfo(project.gitRoot)
    （不属于 GitHubClient——这是纯 git-local 操作。）

 6. reducer 调客户端:
      let result = try await gitHubClient.batchPullRequests(
        remote.host, remote.owner, remote.repo, branches
      )

 7. LiveGitHubService.batchPullRequests:
     a. 把 branches 切成 ≤ 25 的 chunk。
     b. 起一个 TaskGroup，并发上限 3。
     c. 每个 chunk:
          - 构造每分支一个 alias 的 GraphQL query。
          - 跑 gh api graphql --hostname <h> -f query=<q> -f owner=<o> -f repo=<r>。
          - 经 DynamicKeyedDecoder 解码。
          - 过滤 fork PR（见 Fork PR 过滤）。
          - 返回 [branch: PullRequestSnapshot]。
     d. 合并各 chunk 结果为单个字典。

 8. reducer 收到 [branch: Snapshot]，经 catalog 的 branch→worktree 索引映射成
    [WorktreeID: Snapshot]，写入 state.snapshotsByProject[P]。

 9. 视图经 @ObservableState 重渲染。Project P 内每行用新数据绘制徽标，CI rollup
    overlay 在同一 pass 绘制——数据从一开始就在快照里。

10. 单个写操作（merge / close / markReady）在 2 秒后触发一次延迟全量刷新（步骤 2），
    以拾取 GitHub 的更新状态而不与最终一致性窗口竞争。
```

全程 effect 为 `.cancellable(id: CancelID.projectFetch(P), cancelInFlight: true)`：背靠背触发坍缩为最后一次，Project 切换取消上一个 Project 的进行中取数。

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

过滤在 `LiveGitHubService.batchPullRequests` 内、返回 `[branch: PullRequestSnapshot]` 前完成；reducer 看到干净映射，不知 fork 存在。`headRepositoryOwner` 为 null（fork 被删）时按「fork，仅当 base ≠ head 才保留」处理。

### 数据模型

- **`PullRequestSnapshot` 带 `checkRollup`。** check 结果是快照上的字段，随 PR 元数据在同一 query 取回。快照还带 `mergeStateStatus`（区分 `.clean` / `.dirty` / `.blocked` / `.behind` / `.draft` / `.hasHooks` / `.unknown`，比裸 `MergeableState` 更细，让 popover 的 merge 按钮能精确解释为何被禁用）、`reviewDecision`、`headRepositoryOwner`（供写时 fork 过滤）。

```swift
public struct PullRequestSnapshot: Equatable, Sendable, Codable {
  public let number: Int
  public let title: String
  public let state: PullRequestState
  public let isDraft: Bool
  public let additions: Int
  public let deletions: Int
  public let commitCount: Int
  public let mergeable: MergeableState
  public let mergeStateStatus: MergeStateStatus
  public let reviewDecision: ReviewDecision?
  public let url: URL
  public let updatedAt: Date
  public let headRefName: String
  public let baseRefName: String
  public let author: String
  public let checkRollup: [CheckResult]
  public let headRepositoryOwner: String
}
```

- **`BatchedPullRequests` 值类型**——`batchPullRequests` 的返回包络，reducer 每 Project 存一份，再按 lookup 派生 `state.snapshots[worktreeID]`：

```swift
public struct BatchedPullRequests: Equatable, Sendable {
  public let host: String
  public let owner: String
  public let repo: String
  public let byBranch: [String: PullRequestSnapshot]    // nil if branch has no PR
  public let fetchedAt: Date
}
```

### 缓存与失效

无 TTL；事件驱动。**缓存键 = `ProjectID`**：一个 Project 的快照共享一条 GraphQL query、共享生命周期；失效粒度是「刷新该 Project」，不细分到单个 Worktree。

**失效事件枚举：**

| 事件 | 来源 | 触发 |
|---|---|---|
| Project 激活（从另一 Project 切入） | `HierarchyManager.selectedProjectID` 增量 | 缓存分支集 ≠ 当前 Worktree 分支则刷新 |
| Worktree added | `HierarchyManager` catalog 增量 | 刷新 Project |
| Worktree removed | `HierarchyManager` catalog 增量 | 从缓存移除；不取数 |
| Worktree 分支变更 | `WorktreeBranchWatcher`（`.git/HEAD` 监听） | 刷新 Project |
| Merge / close / markReady 完成 | `GitHubFeature.*Completed(.success)` | 2 秒延迟刷新 Project |
| 手动刷新 | 用户动作（面板、popover 刷新按钮） | 立即刷新 Project |
| `gh` 从 `.unavailable` 恢复 | `GhAvailabilityCache` | 刷新每个有排队请求的 Project |
| App 变为活跃（可选，behind setting） | `NSApp.didBecomeActiveNotification` | 刷新所有打开的 Project，每 Project 限速 60s |
| 活跃 Project liveness 轮询 | 前台 timer，gated on `NSApp.isActive` × 活跃 Project | 自适应节奏强制刷新活跃 Project（CI 在飞或 merge 未定时 ~15s，settle 后 ~60s）；app resign active 即刻取消，故空闲/后台 app 零轮询 |

**重入模型。** 每 Project 三个状态槽：`snapshotsByProject[P]`（当前缓存，未取过为 nil）、`inFlightFetchProjects`（有活跃子进程链的 Project 集）、`queuedRefreshByProject`（取数在飞时又请求刷新的 Project，排队请求在进行中那次完成后跑）。失效事件检查是否在飞：是则标 queued 并 no-op，否则起取数并加入 in-flight 集；完成时清 in-flight，若 queued 则补发一次。这干净处理 merge-close-markReady-merge 快速连击：首次跑完，后续坍缩成一次最后跑的 queued 取数。

**取消。** queued 刷新在 Project 关闭或用户导航离开时丢弃；in-flight 取数在 Project 失活时经 `.cancellable(id: CancelID.projectFetch(P), cancelInFlight: true)` 取消。

**关于轮询的取舍。** 纯事件驱动的「用户交互时同等新鲜」前提只对*本地*状态成立——用户在终端 pane 打字不是 GitHub 失效事件，故源自 GitHub 侧的 check 完成、review、merge/close 在纯事件驱动下无新鲜保证。补的信号是单条轮询：**只刷活跃 Project**、**只在 app 为前台时**（resign-active 即取消）、**自适应节奏**（仅在真有东西在飞时快）。AFK 用户的 app 不是前台，故零轮询——无持续 rate-limit 消耗、无电量损耗、无常驻后台活动概念。

### 取数排程（reducer）

新增动作与 Project 取数 effect：

```swift
case .projectRefreshRequested(let projectID):
  guard state.inFlightFetchProjects.contains(projectID) == false else {
    state.queuedRefreshByProject.insert(projectID)
    return .none
  }
  state.inFlightFetchProjects.insert(projectID)
  return .run { [client = gitHubClient, gitClient] send in
    do {
      let project = ... // read-only observer of HierarchyManager 或 pass-through
      let remote = try await gitClient.remoteInfo(project.gitRoot)
      let branches = project.worktrees
        .filter { !$0.archived }
        .compactMap(\.branch)
      guard !branches.isEmpty else {
        await send(.projectBatchLoaded(projectID, .success(.empty)))
        return
      }
      let byBranch = try await client.batchPullRequests(
        remote.host, remote.owner, remote.repo, branches
      )
      await send(.projectBatchLoaded(projectID, .success(
        BatchedPullRequests(host: remote.host, owner: remote.owner, repo: remote.repo,
                            byBranch: byBranch, fetchedAt: .now)
      )))
    } catch {
      await send(.projectBatchLoaded(projectID, .failure(error as? GitHubError ?? .other(...))))
    }
  }
  .cancellable(id: CancelID.projectFetch(projectID), cancelInFlight: true)

case .projectBatchLoaded(let projectID, .success(let batched)):
  state.inFlightFetchProjects.remove(projectID)
  state.snapshotsByProject[projectID] = batched
  if state.queuedRefreshByProject.remove(projectID) != nil {
    return .send(.projectRefreshRequested(projectID))
  }
  return .none
```

**写动作完成**派发 `.delegate(.pullRequestMerged(...))` + 一次延迟全量刷新。2 秒延迟是显式的：GitHub API 在 merge 后与自身 UI 非强一致，`gh pr merge` 后立即取数可能返回 merge 前状态；2 秒是实测最小值（3 秒显得迟滞）。

### `GitService.remoteInfo` 辅助

host/owner/repo 从 `git remote get-url origin` 解析。这是纯 git 操作，**属于 `GitService`，不属于 `GitHubClient`**。

```swift
extension GitService {
  public func remoteInfo(at path: URL) async throws -> RemoteInfo {
    let stdout = try await run(arguments: ["remote", "get-url", "origin"], cwd: path)
    return try RemoteInfo.parse(stdout)
  }
}

public struct RemoteInfo: Equatable, Sendable {
  public let host: String   // "github.com" or GHES domain
  public let owner: String
  public let repo: String

  public static func parse(_ urlString: String) throws -> RemoteInfo {
    // 同时接受 SSH 与 HTTPS remote:
    //   git@github.com:owner/repo.git
    //   https://github.com/owner/repo.git
    //   ssh://git@github.com/owner/repo.git
    // 拒绝非 GitHub 风格的 host，除非匹配已注册的 Enterprise host
    // （read from `gh auth status --json hosts`）。
  }
}
```

解析失败抛 `.remoteInfoUnavailable`；reducer 记录为**每 Project** 错误而非每 Worktree——remote 修好前整个 Project 卡住。

### gh 子进程契约

- **env allowlist** 转发 `PATH`、`HOME`、`GH_CONFIG_DIR`、`XDG_CONFIG_HOME`（重定位的 auth store）+ 强制 `LC_ALL`，**剥除 `GH_TOKEN` / `GITHUB_TOKEN`**——codans 不携带、不转发任何 token material。
- 子进程 argv 是 `(executable, [args])`，无 shell 解释。GraphQL query 作为单个 `-f query=<body>` 传（gh 处理 HTTP POST body）；body 内的用户派生分支名在插值前已 GraphQL-字符串转义，转义失败的分支名被丢弃并记日志。
- 超时 20 s；**output cap 8 MiB**（25 分支 × 5 PR × 完整 check rollup 在病态大仓可达 ~4–6 MB；超限抛 `.oversizeResponse`）。
- 最低 `gh` 版本 **2.20+**（稳定 GraphQL + `--hostname` 行为）；可用性探针解析 `gh --version`，过旧则显示 `brew upgrade gh` 横幅。

### UI 层

视图层接线：

- `WorktreeRowIcon` 的 `rollup` 来源是 `PullRequestBadge.CheckRollup.from(checks: snapshot.checkRollup)`。
- `PullRequestPopover` 读 `snapshot.checkRollup` + `snapshot.mergeStateStatus` / `snapshot.reviewDecision`，精确解释 merge-disabled 原因。
- `WorktreeGitHubBadge` 读 `store.snapshots[worktreeID]`，该字典由 reducer 从 `state.snapshotsByProject[P]` 派生。
- 侧栏行不持有发起取数的逐行 `.task`；取数由 reducer 经 Project 级事件发起。

### PR ↔ Worktree 配对

- 匹配键 = `headRefName == Worktree.branch`。
- **平局**（两个 Worktree 同分支）按 worktree mtime 解决：最近激活者胜，输家不显徽标。
- **孤儿**（无法解析的 paneID/branch）从**徽标计数与 popover 行双双排除**，使两者永不发散。

## 备选方案

- **A — per-Worktree 取数（每行 `gh pr view <branch>` + `gh pr checks <number>`），加 3 路 in-flight cap + `statusCheckRollup` 合并。** 否决：成本随 Worktree 数而非仓库数缩放。合并 pr view + pr checks 把子进程从 2N 降到 N 是增量优化，但仍 O(N)——20 个 Worktree 仍要 20 × 150 ms 冷启动；且逐行 `.task(id:)` 依赖 SwiftUI 视图生命周期，当行解析为不挂载的 `EmptyView()` 时无缓存行的取数根本不发生。repository-batched 模型把成本降到 O(Repositories) 并把取数从视图生命周期解耦，故采纳。
- **B — 用 `gh pr list --json ... --state all`。** 否决：`gh pr list --json statusCheckRollup` 受支持，但 gh 内部对每个 PR 另发一次 GraphQL，实为 N 次往返、只是被隐藏，总墙钟与 N-分支最坏情形相同。「直接用 gh pr list」的简洁是个泄漏抽象。
- **C — `URLSession` 直连 GraphQL + Keychain 存 OAuth。** 否决：`gh api graphql` 每 chunk 加 ~100–150 ms 子进程成本，3 并发 chunk 约 200 ms/刷新；付 ~1500 行工程账（OAuth device flow、token 存储/刷新、rate-limit 退避、错误分类、Enterprise host 切换、re-auth 面）去省 ~200 ms 是错的权衡，且重复 `gh` 已正确做的事。仅当 codans 需要实时 PR 更新 / review 线程 / 跨仓聚合时再考虑。
- **D — 周期后台轮询取代事件驱动。** 否决：事件驱动严格更优——交互时同等新鲜、空闲时零成本。罕见的「GitHub 状态自行变了」由手动刷新 + merge 侧延迟刷新覆盖。**注**：一个 scoped、focus-gated、自适应的轮询被采纳（见上「关于轮询的取舍」），它绕开了 D 的三条反对（后台、全 Project、AFK 时仍跑），因为 AFK 用户的 app 不是前台。
- **E — 落盘最后快照以启动即显。** 否决：当前「启动后 ~500 ms 空侧栏再填充」可接受。落盘会带来 stale 数据、「显示 X 又变 Y」类 bug、翻倍文件 IO 面。待用户反馈再议。

## 风险

| 风险 | 缓解 |
|---|---|
| GraphQL query 复杂度预算。25 分支 × 5 PR × ~100 check 节点实测 ~5000 点（上限 10000），但极密 CI 仓可能超。 | 检测到 `complexity` 错误则减半 chunk 重试并记日志。 |
| `gh api graphql` 最低版本（2.20+ 才有稳定 GraphQL + `--hostname`）。 | 可用性探针解析 `gh --version`，过旧显示可操作横幅；Settings「Requirements」钉最低版本。 |
| `WorktreeBranchWatcher` FS watch 耗尽（macOS 每进程 ~2048）。 | 只监听可见侧栏视口内的 Worktree（约 ≤ 50），其余回退到 focus-gained reconcile。 |
| in-flight + queued 状态泄漏（Project 取数中途被移除）。 | Project 移除时经 `CancelID.projectFetch(P)` 取消并从两集移除。 |
| 边缘大仓超 8 MiB 响应。 | `.oversizeResponse` 时减半 chunk 重试；记为未来裁剪响应字段的信号。 |
| `headRepositoryOwner` 在某些 PR 形态为 null（fork 被删）。 | fork 过滤把 null owner 当「fork，仅当 base ≠ head 才保留」。 |
| 事件驱动失效漏掉一个事件（分支变更但 watcher 未监听且未 focus-gained）。 | `HierarchyManager.reconcileDiscoveredWorktrees`（focus-gained 时跑）更新每个 Worktree 的 `branch`，reducer 观察到并失效 Project——以变更到首刷的延迟为代价覆盖该情形。 |

## 参考

- [main-window.md](main-window.md) — UI 层引用的侧栏行组合。
- [docs/architecture.md](../architecture.md) — 模块边界与依赖规则。
- [GitHub GraphQL API reference](https://docs.github.com/en/graphql) — 尤其 `PullRequest`、`StatusCheckRollup`、`CheckRun`、`StatusContext` 类型。
- [`gh api graphql`](https://cli.github.com/manual/gh_api) — gh 手册的 GraphQL 委托章节。
- [GraphQL Alias syntax](https://graphql.org/learn/queries/#aliases) — 此处使用的核心批量技术。
