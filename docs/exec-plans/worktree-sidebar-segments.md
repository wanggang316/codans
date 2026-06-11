# ExecPlan: Sidebar 渲染演化为异构 SidebarRow（task02）

**Status:** Draft
**Author:** Gump (sub-agent B20EC187)
**Date:** 2026-04-26

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

> **沿用主 design doc，不另写 design。** 本任务的高层设计、段语义、渲染合并函数、Component Boundaries 与 Alternatives 均见 [`docs/design-docs/worktree-sidebar-ordering.md`](../design-docs/worktree-sidebar-ordering.md)（commit 1f714b3，已合入 main）。本 ExecPlan 仅展开本任务（task02）切片的实施步骤、对外契约和验证手段。

## Purpose

把 `HierarchySidebarView` 渲染层从"返回 `[Worktree]`"演化为"返回异构 `[SidebarRow]`"，以便 task03 的 pending 段能直接挂入；同时把 pinned / unpinned 段拖拽落到一个新的 reducer forwarder。

完成后用户可见行为变化：

- pinned 段内、unpinned 段内可拖拽重排（依赖 task01 client，task01 未 merge 前 onMove 留 TODO）。
- 右键菜单 Pin / Unpin 行为语义不变（task01 plan 已确定 `setWorktreePinned(WorktreeID, Bool)` 签名保留，落位逻辑下沉到 `HierarchyManager` 内部；task02 不动 `worktreePinToggleTapped`）。
- pending 段在本任务里渲染为空，task03 接管时只需替换占位 view。

## Progress

**Phase A (complete: 2026-04-26 21:45 UTC)**
- [x] M1 — `SidebarRow.swift` 新建（含 `PendingWorktree` / `PendingWorktreeID` stub）（2026-04-26）
- [x] M2 — `HierarchySidebarView.orderedSidebarRows(project:, pendings:)` 实现 + `orderedVisibleWorktrees` 改写为派生 shim（2026-04-26）
- [x] M3 — `HierarchySidebarView` ForEach 拆 main / pinned / pending / unpinned 四段 + `pendingRowPlaceholder(_:)` 占位 + `.onMove` TODO（2026-04-26）
- [x] M5 — 测试：ordering 4 用例 通过（`HierarchySidebarOrderingTests.swift` commit a4da9c4）；lint / build 绿灯（2026-04-26）

**Phase B (complete: 2026-04-27)**
- [x] Rebase on origin/main (task01 a48e406 + task03 7b75042 merged)（2026-04-27）
- [x] M4 — Reducer forwarder：`reorderWorktrees(projectID:, inSpace:, segment:, from:, to:)`（2026-04-27）
- [x] M5b — Reducer forwarder 测试 `reorderWorktreesDispatchesClientCallWithSegment`（2026-04-27）
- [x] Wire pinned/unpinned `.onMove` + plumb live `pendingWorktrees` from `store.state` + replace placeholder with `PendingWorktreeRow` (task03 owns) + drop duplicate `PendingWorktree`/`PendingWorktreeID` from `SidebarRow.swift`（2026-04-27）
- [x] M6 — `make mac-build` 绿灯；ordering tests + reorder forwarder test 通过；task02 文件 lint 净增 0 violations（2026-04-27）
- [ ] M7 — push + `gh pr create --base main`

## Surprises & Discoveries

(None yet)

## Decision Log

- **保留旧 `orderedVisibleWorktrees(in:)` 的 hotkey 枚举路径**：现有 `treeBody` 用它构造 `hotkeyIndex: [WorktreeID: Int]`。task02 内不动 hotkey 语义，只把它的实现改成 `orderedSidebarRows(...)` 的 worktree-only 派生（filter 掉 pending case），保证 `⌃⌘1`–`⌃⌘9` 仍跳过 pending 行（design doc §pending 段 用户操作 已明确）。
- **pending 占位 view 在 task02 是 `EmptyView()` 包一个内部 inline helper**，不新建 `PendingWorktreeRow.swift`（design doc §Component Boundaries 列出该文件由 task03 owns）。helper 命名 `pendingRowPlaceholder(_:)` 便于 task03 grep 替换。
- **`PendingWorktree` 字段最小化**：本任务只放 `id` / `projectID` / `displayName` 三个 stub 字段；`spaceID` / `spec` / `status` / `lastProgressLine` / `startedAt` 由 task03 补齐。在 `PendingWorktree.swift` 里加注释 `// stub — task03 will replace with full schema; see worktree-sidebar-ordering.md §pending 段`。
- **`worktreePinToggleTapped` 不动**：task01 plan 已确定保留 `HierarchyClient.setWorktreePinned(WorktreeID, Bool)` 签名不变，落位逻辑（pin → pinned 段尾；unpin → unpinned 段顶）下沉到 `HierarchyManager.setWorktreePinned` 内部。task02 视图层与 reducer 对该路径无任何改动。
- **task01 未 merge 时的工作切分**：M1–M3、M5 的 ordering 测试可独立完成；M4 forwarder + 对应测试需要 task01 暴露 `reorderWorktrees` 闭包与 `WorktreeSegment` enum 后才能编译；那之前在 view 端把 `.onMove` 闭包注释成 `// TODO(task01): wire reorderWorktrees forwarder once HierarchyClient exposes it.` 并保留 ForEach 段落结构。Phase 切换详见 §Plan of Work / §Validation。
- **ordering 测试单独成文件**：新建 `apps/mac/codans/Tests/HierarchySidebarOrderingTests.swift`，与现有 `HierarchySidebarFeatureTests.swift` 同 target；理由是 ordering 用例只测 `HierarchySidebarView.orderedSidebarRows` 这个纯静态函数，不依赖 `TestStore`，单文件聚焦更容易给 task03 扩展。reducer forwarder 测试仍补在 `HierarchySidebarFeatureTests.swift`，因为它需要 `TestStore` 与 `HierarchyClient` mock，跟现有用例同质。
- **PR 形态：等 Phase B 完成再开单 PR**（不开 [Phase A only] WIP PR）。理由：Phase A 净增 < 200 行，等 Phase B 再开能让 codex 一次评审完整切片，避免两轮 review 噪音；task03 在 task01 / task02 都未 merge 时也无法实际接入，提早开 WIP PR 不解锁下游。如 task01 长时间不动（> 1 工作日）再回来重新评估。

## Outcomes & Retrospective

(To be filled at milestone completion)

## Context and Orientation

Related documents:

- Main design doc: [`docs/design-docs/worktree-sidebar-ordering.md`](../design-docs/worktree-sidebar-ordering.md) — §段语义详述、§渲染合并、§Component Boundaries、§Alternatives Considered 第 4 处。
- Repo 顶层指引：[`CLAUDE.md`](../../CLAUDE.md)、[`docs/golden-rules.md`](../golden-rules.md)。
- 协调协议：`/tmp/codans-bootstrap-02.md`（master ↔ sub-agent，本 ExecPlan 即对应 bootstrap §你的任务）。

Key source files (touched 或被读):

- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift` — 当前包含 `orderedVisibleWorktrees(in:)`（行 50–56）和 `treeBody / projectSection / worktreeRow` 渲染链；本任务把渲染层切换到 `[SidebarRow]`。
- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift` — TCA reducer；新增 `reorderWorktrees(projectID:segment:from:to:)` action，改造 `worktreePinToggleTapped` 派发路径。
- `apps/mac/codans/App/Features/HierarchySidebar/SidebarRow.swift` — **新建**。承载 `enum SidebarRow` + `PendingWorktree` / `PendingWorktreeID` stub。
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — **task01 owns**，本任务只读。task02 假设 task01 新增：`reorderWorktrees: @MainActor @Sendable (_ projectID: ProjectID, _ inSpace: SpaceID, _ segment: WorktreeSegment, _ from: IndexSet, _ to: Int) throws -> Void` 与 `enum WorktreeSegment: Sendable { case pinned; case unpinned }`。`inSpace: SpaceID` 与现有 `reorderProjects(_ inSpace:, _ from:, _ to:)` / `removeWorktreeWithGit(_, _ inProject:, _ inSpace:, _ force:)` 等"动 worktree/project 必带 inSpace"的约定对齐。**`setWorktreePinned: @MainActor @Sendable (_ worktreeID: WorktreeID, _ isPinned: Bool) -> Void` 签名保留不变**（grep 自 `HierarchyClient.swift:194` 与 `HierarchyManager.swift:366`），落位逻辑由 task01 在 `HierarchyManager.setWorktreePinned` 内部完成；task02 不消费该接口。
- `apps/mac/codans/Tests/HierarchySidebarFeatureTests.swift` — 现有 reducer 测试集，扩展 ordering + forwarder 用例。
- `apps/mac/CodansCore/Worktree.swift` / `Project.swift` — 模型只读，schema 不变。

Term:

- **段（segment）**：design doc 定义的四段 main / pinned / pending / unpinned 之一；本任务关心的拖拽段只有 pinned 与 unpinned。
- **forwarder**：reducer action 把视图层的 `IndexSet → Int` 直接转交到 `HierarchyClient` 闭包的薄包装，不带本地状态变更，与现有 `reorderProjects` 对称。
- **stub**：本任务为占位最小定义；task03 会扩展字段而不重命名 / 移动文件。

## Plan of Work

工作切成两段 Phase。Phase A 不依赖 task01，可立即开始；Phase B 在 task01 merge 进 main 并 fetch 之后完成剩余 forwarder。

### Phase A — 独立部分（可立即开始）

1. **新建 `SidebarRow.swift`**（M1）。文件位置 `apps/mac/codans/App/Features/HierarchySidebar/SidebarRow.swift`。内容三块：
   - `struct PendingWorktreeID: Hashable, Sendable { let raw: UUID; init(raw: UUID = UUID()) { self.raw = raw } }`
   - `struct PendingWorktree: Equatable, Identifiable { let id: PendingWorktreeID; let projectID: ProjectID; let displayName: String }` — 加文件头 doc-comment 标注 `// stub — task03 replaces with full schema (see worktree-sidebar-ordering.md §pending 段).`
   - `enum SidebarRow: Identifiable { case worktree(Worktree); case pending(PendingWorktree); var id: String { switch self { case .worktree(let w): return "wt:\(w.id.raw)"; case .pending(let p): return "pending:\(p.id.raw)" } } }`

2. **实现 `orderedSidebarRows(project:, pendings:)`**（M2）。在 `HierarchySidebarView` 内加 static 函数，签名见 design doc §渲染合并。同文件保留旧 `orderedVisibleWorktrees(in:)`，改写其 body 为 `orderedSidebarRows(project: project, pendings: []).compactMap { row in if case .worktree(let w) = row { return w } else { return nil } }`，使 hotkey 枚举路径不变（`treeBody.hotkeyIndex` 仍能编译并产生与今天等价的结果）。

3. **`projectSection` ForEach 改造**（M3）。把 `ForEach(Self.orderedVisibleWorktrees(in: project)) { worktree in worktreeRow(...) }` 替换为：

   ```swift
   ForEach(Self.orderedSidebarRows(project: project, pendings: []), id: \.id) { row in
     switch row {
     case .worktree(let worktree):
       worktreeRow(worktree, in: project, space: space, paneIndex: paneIndex, inbox: inbox, hotkeySlot: hotkeyIndex[worktree.id])
     case .pending(let pending):
       pendingRowPlaceholder(pending)
     }
   }
   ```

   `pendingRowPlaceholder(_:)` 暂返回最小占位（`Text(pending.displayName).foregroundStyle(.secondary).listRowSeparator(.hidden)`），加注释 `// TODO(task03): replace with PendingWorktreeRow`。

4. **拆 pinned / unpinned 段并挂 `.onMove`**（M3 续）。在 `projectSection` 内把单个 ForEach 拆成三段（main / pinned / unpinned）+ pending 内嵌于 pinned 与 unpinned 之间：
   - 实现路径：在 `projectSection` 里把 `orderedSidebarRows(...)` 拆成两个 worktree-only 切片（`pinnedRows`、`unpinnedRows`）和一个 `pendingRows`（task02 内永远为空数组），分别挂三个 `ForEach`。pinned 和 unpinned 的 `ForEach` 各调用 `.onMove { source, destination in store.send(.reorderWorktrees(projectID: project.id, inSpace: space.id, segment: .pinned/.unpinned, from: source, to: destination)) }`。
   - **task01 未 merge 时**：`.onMove` 闭包写为 `// TODO(task01): wire reorderWorktrees forwarder once HierarchyClient exposes it; SidebarRow + ForEach 已就位.`，保留 ForEach 结构使 layout 等同于今天（不引入 visual regression）。

5. **Ordering 测试**（M5 第 1 部分）。**新建** `apps/mac/codans/Tests/HierarchySidebarOrderingTests.swift`（与 `HierarchySidebarFeatureTests.swift` 同 target）加：
   - `orderedSidebarRowsReturnsSixRowsAndCorrectSegmentOrder`：构造 1 main + 2 pinned + 3 unpinned + 0 pending 的 Project，期望 6 行且段顺序 `[main, pinned, pinned, unpinned, unpinned, unpinned]`。
   - `orderedSidebarRowsPlacesPendingBetweenPinnedAndUnpinned`：1 main + 1 pinned + 2 pending（projectID 命中）+ 2 unpinned，期望 6 行；pending 行 `id` 前缀为 `"pending:"`，worktree 行前缀 `"wt:"`（验证契约）。
   - `orderedSidebarRowsFiltersOutOtherProjectPending`：传入两个 pending，一个 projectID 命中、一个不命中，期望只渲染命中那条。
   - `orderedSidebarRowsExcludesArchived`：archived worktree 不出现于任何段。

### Phase B — task01 merge 之后

6. **Fetch + rebase**：`git fetch origin main && git rebase origin/main`，解决冲突（预期只有 `HierarchyClient.swift` 的 testValue / liveValue 段被 task01 扩了字段，本分支不该有冲突；如果有冲突则停下来 push `BLOCKED`）。

7. **新增 reducer action `reorderWorktrees(projectID:, inSpace:, segment:, from:, to:)`**（M4）。在 `HierarchySidebarFeature.Action` 加 case；coreReduce 加分支：

   ```swift
   case .reorderWorktrees(let projectID, let spaceID, let segment, let from, let to):
     try? hierarchyClient.reorderWorktrees(projectID, spaceID, segment, from, to)
     return .none
   ```

   把 Phase A 中暂留 TODO 的 `.onMove` 闭包改成实际派发该 action（`store.send(.reorderWorktrees(projectID: project.id, inSpace: space.id, segment: .pinned/.unpinned, from: source, to: destination))`）。

8. **Reducer 测试**（M5 第 2 部分，扩 `HierarchySidebarFeatureTests.swift`）：
   - `reorderWorktreesActionForwardsToHierarchyClient`：mock `hierarchyClient.reorderWorktrees` 闭包，断言 `(projectID, spaceID, segment, from, to)` 五个参数透传。

9. **构建 + Lint + Test + PR**（M6 / M7）。命令见 §Concrete Steps。

### 对外契约（task03 会消费）

务必保留以下契约，task03 接管时只补字段、不动签名：

1. **`SidebarRow` 形状与 `id` 前缀**：
   ```swift
   enum SidebarRow: Identifiable {
     case worktree(Worktree)
     case pending(PendingWorktree)
     var id: String { /* "wt:<uuid>" / "pending:<uuid>" */ }
   }
   ```
2. **渲染合并签名**：
   ```swift
   static func orderedSidebarRows(project: Project, pendings: [PendingWorktree]) -> [SidebarRow]
   ```
3. **pending 占位渲染回调点**：`HierarchySidebarView.pendingRowPlaceholder(_:)`，task03 会替换 body。
4. **`PendingWorktree` / `PendingWorktreeID` 已存在但字段最小**；task03 在不破坏 `id` / `projectID` / `displayName` 的前提下扩 `spaceID` / `spec` / `status` / `lastProgressLine` / `startedAt`。
5. **Reducer reorder action 形状**：`reorderWorktrees(projectID: ProjectID, inSpace: SpaceID, segment: WorktreeSegment, from: IndexSet, to: Int)`，参数顺序与 `HierarchyClient.reorderWorktrees` 闭包一致。

## Concrete Steps

工作目录：`/Users/wanggang/.worktree/repos/codans/feat/worktree-sidebar-segments`

```bash
# Phase A 完成后：
make mac-lint                    # swiftlint --quiet，期望 0 violation
make mac-build                   # tuist build；首次需 mac-generate
swift test --filter HierarchySidebarFeatureTests   # 期望全绿，含本任务新增用例

# Phase B（task01 merge 后）：
git fetch origin main
git rebase origin/main
# 解冲突后重跑 lint / build / test
git push -u origin feat/worktree-sidebar-segments
gh pr create --base main \
  --title "feat(sidebar): heterogeneous SidebarRow + segment-scoped reorder forwarder (task02)" \
  --body-file - <<'EOF'
## Summary

- Sidebar 渲染层从 `[Worktree]` 演化为 `[SidebarRow]`，挂段内拖拽 forwarder（`reorderWorktrees(projectID:inSpace:segment:from:to:)`）。
- pending 段在本 PR 用空数组占位，task03 接管。
- Pin / Unpin 路径不变（`setWorktreePinned` 落位逻辑由 task01 在 `HierarchyManager` 内部完成）。

主 design doc：`docs/design-docs/worktree-sidebar-ordering.md`（commit 1f714b3）。
ExecPlan：`docs/exec-plans/worktree-sidebar-segments.md`。

## Test plan

- [x] `make mac-lint`
- [x] `make mac-build`
- [x] `swift test --filter HierarchySidebarFeatureTests`
- [ ] 手动：拖拽 pinned / unpinned 段内 row，断言顺序保留
- [ ] 手动：右键 Pin → 落 pinned 段尾；Unpin → 落 unpinned 段顶
EOF
```

## Validation and Acceptance

Phase A 完成定义：

- `swift test` 通过新增的 ordering 测试（4 个用例）；
- `make mac-build` 编译通过（含 `SidebarRow.swift`）；
- 手动跑 app（`make mac-run-app`）：sidebar 视觉与今天等价（pending 段为空，main / pinned / unpinned 顺序与原 `orderedVisibleWorktrees` 一致），ForEach 行 identity 切换不引发动画跳变。

Phase B 完成定义：

- 上述 + 新增 1 个 reducer 测试（`reorderWorktreesActionForwardsToHierarchyClient`）通过；
- 手动：拖拽 pinned 段内两条 row，断言 catalog 顺序变化（重启后仍生效）；
- 手动：unpinned 段内拖拽同上；
- 手动（不属于本任务但顺手回归）：右键 Pin / Unpin 行为不变（task01 在 `HierarchyManager.setWorktreePinned` 内部完成落位，task02 视图层与 reducer 该路径未改）。
- `make mac-lint` 0 violation；
- PR 已创建，描述里带 design doc + ExecPlan 路径。

## Idempotence and Recovery

- 所有步骤都在 `feat/worktree-sidebar-segments` 分支，可任意 reset / amend。
- M1–M3 完成后即便不进 Phase B 也能 `git stash` 切其他工作不影响 main。
- Phase B rebase 冲突若涉及 `HierarchyClient.swift`：因 task02 不动该文件，应是无冲突 fast-forward；如出现冲突 → 推 `BLOCKED: task01 client 文件被 task02 误改 / rebase 冲突未预期` 给 master 决策。

## Artifacts and Notes

预期 diff 体量（粗估）：

- `SidebarRow.swift` 新增 ~30 行
- `HierarchySidebarView.swift` 改 ~40 行（新增 orderedSidebarRows、ForEach 拆段、pendingRowPlaceholder、保留 orderedVisibleWorktrees compat shim）
- `HierarchySidebarFeature.swift` 改 ~8 行（新增 reorder action case + coreReduce 分支）
- `HierarchySidebarOrderingTests.swift` 新增 ~90 行（4 个 ordering 用例）
- `HierarchySidebarFeatureTests.swift` 增 ~30 行（1 个 reorder forwarder 用例）

合计 ~5 个文件、< 200 行净增。

## Interfaces and Dependencies

In `apps/mac/codans/App/Features/HierarchySidebar/SidebarRow.swift`, define:

```swift
import Foundation
import CodansCore

struct PendingWorktreeID: Hashable, Sendable {
  let raw: UUID
  init(raw: UUID = UUID()) { self.raw = raw }
}

// stub — task03 replaces with full schema; see
// docs/design-docs/worktree-sidebar-ordering.md §pending 段.
struct PendingWorktree: Equatable, Identifiable {
  let id: PendingWorktreeID
  let projectID: ProjectID
  let displayName: String
}

enum SidebarRow: Identifiable {
  case worktree(Worktree)
  case pending(PendingWorktree)

  var id: String {
    switch self {
    case .worktree(let w): return "wt:\(w.id.raw)"
    case .pending(let p):  return "pending:\(p.id.raw)"
    }
  }
}
```

In `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift`, add:

```swift
static func orderedSidebarRows(
  project: Project,
  pendings: [PendingWorktree]
) -> [SidebarRow]
```

实现按 design doc §渲染合并 原文（main + pinned + projectPending + rest）。`orderedVisibleWorktrees(in:)` 改写为 `orderedSidebarRows(project: project, pendings: []).compactMap { ... }` 以兼容 hotkey 枚举路径。

In `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift`, add:

```swift
case reorderWorktrees(
  projectID: ProjectID,
  inSpace: SpaceID,
  segment: WorktreeSegment,
  from: IndexSet,
  to: Int
)
```

并在 coreReduce 中转发到 `try? hierarchyClient.reorderWorktrees(projectID, inSpace, segment, from, to)`。`inSpace: SpaceID` 与 `reorderProjects(_ inSpace:, _ from:, _ to:)`、`removeWorktreeWithGit(_, _ inProject:, _ inSpace:, _ force:)` 等"动 worktree/project 必带 inSpace"的现有约定对齐。`WorktreeSegment` 由 task01 在 `HierarchyClient.swift` 暴露（`enum WorktreeSegment: Sendable { case pinned; case unpinned }`），task02 不定义、不重命名。

`worktreePinToggleTapped` **不动**：task01 plan 已确定保留 `HierarchyClient.setWorktreePinned(WorktreeID, Bool)` 签名（grep 自 `HierarchyClient.swift:194` 与 `HierarchyManager.swift:366`）；落位逻辑（pin → pinned 段尾；unpin → unpinned 段顶）由 task01 在 `HierarchyManager.setWorktreePinned` 内部完成，对调用方透明。
