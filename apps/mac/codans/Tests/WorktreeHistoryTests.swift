import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// Browser-style Worktree visit history: the single Back / Forward steps the
/// menu chords take, and the deeper jumps the header control's press-and-hold
/// menu issues.
@MainActor
struct WorktreeHistoryTests {
  /// Four Worktrees in one Project, named a…d, plus a second Project with a
  /// single Worktree so the cross-Project labelling has something to resolve.
  private struct Fixture {
    let projectID = ProjectID()
    let otherProjectID = ProjectID()
    let ids: [WorktreeID]
    let otherWorktreeID = WorktreeID()
    let catalog: Catalog

    init() {
      let ids = (0..<4).map { _ in WorktreeID() }
      self.ids = ids
      let worktrees = zip(ids, ["a", "b", "c", "d"]).map { id, name in
        Worktree(id: id, name: name, path: "/tmp/\(name)", branch: name)
      }
      let project = Project(
        id: projectID, name: "p", rootPath: "/tmp/a",
        worktrees: worktrees, selectedWorktreeID: ids[3]
      )
      let other = Project(
        id: otherProjectID, name: "other", rootPath: "/tmp/other",
        worktrees: [Worktree(id: otherWorktreeID, name: "spike", path: "/tmp/other")],
        selectedWorktreeID: otherWorktreeID
      )
      catalog = Catalog(projects: [project, other])
    }

    func selection(_ index: Int) -> HierarchySelection {
      HierarchySelection(projectID: projectID, worktreeID: ids[index])
    }
  }

  /// Builds a store sitting on `d` with `a → b → c` behind it, capturing
  /// whichever Worktree the navigation ends up selecting.
  private static func makeStore(
    _ fixture: Fixture,
    back: [Int] = [0, 1, 2],
    forward: [Int] = [],
    backTop: HierarchySelection? = nil,
    backEntries: [HierarchySelection]? = nil,
    current: Int = 3,
    catalog: Catalog? = nil,
    filters: LockIsolated<[SidebarFilter]> = LockIsolated([])
  ) -> (TestStoreOf<RootFeature>, LockIsolated<WorktreeID?>) {
    var initial = RootFeature.State()
    initial.selection = fixture.selection(current)
    initial.navigationHistoryBack =
      backEntries ?? (back.map { fixture.selection($0) } + [backTop].compactMap { $0 })
    initial.navigationHistoryForward = forward.map { fixture.selection($0) }

    let selected = LockIsolated<WorktreeID?>(nil)
    let catalog = catalog ?? fixture.catalog
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.setSidebarFilter = { filter in filters.withValue { $0.append(filter) } }
      $0.hierarchyClient.selectProject = { _ in }
      $0.hierarchyClient.selectWorktree = { worktreeID, _ in
        selected.withValue { $0 = worktreeID }
      }
    }
    store.exhaustivity = .off
    return (store, selected)
  }

  @Test
  func backStepsOneEntryAndFeedsForward() async {
    let fixture = Fixture()
    let (store, selected) = Self.makeStore(fixture)

    await store.send(.worktreeHistoryBackRequested)
    await store.receive(\.sidebar.worktreeRowTapped)

    #expect(selected.value == fixture.ids[2])
    #expect(store.state.navigationHistoryBack == [fixture.selection(0), fixture.selection(1)])
    #expect(store.state.navigationHistoryForward == [fixture.selection(3)])
    // The step must not re-record itself as a fresh visit when the
    // selection stream echoes it back.
    #expect(store.state.suppressHistoryPush)
  }

  @Test
  func navigatingLeavesAHiddenSidebarHidden() async {
    let fixture = Fixture()
    let (store, selected) = Self.makeStore(fixture, forward: [0])
    await store.send(.toggleSidebarRequested)
    #expect(!store.state.sidebarVisible)

    await store.send(.worktreeHistoryBackRequested)
    await store.receive(\.sidebar.worktreeRowTapped)
    await store.send(.worktreeHistoryJumpRequested(.forward(offset: 0)))
    await store.receive(\.sidebar.worktreeRowTapped)

    // No selection stream echoes the Back here, so `d` is still current and
    // the Forward step passes it to land on `a`.
    #expect(selected.value == fixture.ids[0])
    #expect(!store.state.sidebarVisible)
  }

  @Test
  func backJumpMovesSkippedEntriesOntoForwardNewestLast() async {
    // Jumping from `d` straight to `a` must leave the same stacks behind as
    // pressing Back three times would: forward reads d, c, b with `b` — the
    // next Forward step — on top.
    let fixture = Fixture()
    let (store, selected) = Self.makeStore(fixture)

    await store.send(.worktreeHistoryJumpRequested(.back(offset: 2)))
    await store.receive(\.sidebar.worktreeRowTapped)

    #expect(selected.value == fixture.ids[0])
    #expect(store.state.navigationHistoryBack.isEmpty)
    #expect(
      store.state.navigationHistoryForward == [
        fixture.selection(3), fixture.selection(2), fixture.selection(1),
      ]
    )
  }

  /// The property the jump has to hold: landing three entries back in one
  /// go must leave exactly the stacks that three single steps would.
  /// Exercised against the reducer helper directly — driving three rounds
  /// of navigate-then-observe-the-selection-stream through a TestStore
  /// would test the stream plumbing, not the stack arithmetic.
  @Test
  func backJumpIsEquivalentToRepeatedBackSteps() {
    let fixture = Fixture()
    let landable = WorktreeHistoryLanding.landableWorktreeIDs(in: fixture.catalog)
    var stepwise = RootFeature.State()
    stepwise.selection = fixture.selection(3)
    stepwise.navigationHistoryBack = [0, 1, 2].map(fixture.selection)
    for _ in 0..<3 {
      let target = stepwise.navigationHistoryBack.last
      _ = RootFeature.navigateHistory(&stepwise, jump: .back(offset: 0), landable: landable)
      // Stand in for the selection stream echoing the landing back.
      stepwise.selection = target ?? .empty
    }

    var jumping = RootFeature.State()
    jumping.selection = fixture.selection(3)
    jumping.navigationHistoryBack = [0, 1, 2].map(fixture.selection)
    _ = RootFeature.navigateHistory(&jumping, jump: .back(offset: 2), landable: landable)

    #expect(stepwise.navigationHistoryBack == jumping.navigationHistoryBack)
    #expect(stepwise.navigationHistoryForward == jumping.navigationHistoryForward)
    #expect(jumping.navigationHistoryForward.count == 3)
  }

  @Test
  func forwardJumpMirrorsBackJump() async {
    let fixture = Fixture()
    // Sitting on `d` with `a → b → c` ahead of it: forward's top is `c`.
    let (store, selected) = Self.makeStore(fixture, back: [], forward: [0, 1, 2])

    await store.send(.worktreeHistoryJumpRequested(.forward(offset: 1)))
    await store.receive(\.sidebar.worktreeRowTapped)

    #expect(selected.value == fixture.ids[1])
    #expect(store.state.navigationHistoryForward == [fixture.selection(0)])
    #expect(store.state.navigationHistoryBack == [fixture.selection(3), fixture.selection(2)])
  }

  /// The Workspace category lists only the `other` Project, marked as a
  /// workspace here; the `p` Worktrees are listed under All only.
  private static func workspaceFilteredCatalog(_ fixture: Fixture) -> Catalog {
    var catalog = fixture.catalog
    catalog.projects[1].isWorkspace = true
    catalog.sidebarFilter = .workspace
    return catalog
  }

  @Test
  func backToAWorktreeOutsideTheCategoryShowsAll() async {
    let fixture = Fixture()
    let filters = LockIsolated<[SidebarFilter]>([])
    let (store, selected) = Self.makeStore(
      fixture, catalog: Self.workspaceFilteredCatalog(fixture), filters: filters
    )

    await store.send(.worktreeHistoryBackRequested)
    await store.receive(\.sidebar.worktreeRowTapped)

    #expect(selected.value == fixture.ids[2])
    #expect(filters.value == [.all])
  }

  @Test
  func backToAWorktreeInsideTheCategoryKeepsIt() async {
    let fixture = Fixture()
    let filters = LockIsolated<[SidebarFilter]>([])
    let (store, selected) = Self.makeStore(
      fixture,
      backTop: HierarchySelection(projectID: fixture.otherProjectID, worktreeID: fixture.otherWorktreeID),
      catalog: Self.workspaceFilteredCatalog(fixture),
      filters: filters
    )

    await store.send(.worktreeHistoryBackRequested)
    await store.receive(\.sidebar.worktreeRowTapped)

    #expect(selected.value == fixture.otherWorktreeID)
    #expect(filters.value.isEmpty)
  }

  @Test(arguments: [3, 99, -1])
  func jumpOutsideTheStackChangesNothing(offset: Int) async {
    let fixture = Fixture()
    let (store, selected) = Self.makeStore(fixture)

    await store.send(.worktreeHistoryJumpRequested(.back(offset: offset)))
    await store.finish()

    #expect(selected.value == nil)
    #expect(store.state.navigationHistoryBack.count == 3)
    #expect(store.state.navigationHistoryForward.isEmpty)
    #expect(!store.state.suppressHistoryPush)
  }

  @Test
  func emptyStackNavigationIsANoOp() async {
    let fixture = Fixture()
    let (store, selected) = Self.makeStore(fixture, back: [])

    await store.send(.worktreeHistoryBackRequested)
    await store.send(.worktreeHistoryForwardRequested)
    await store.finish()

    #expect(selected.value == nil)
    #expect(store.state.navigationHistoryBack.isEmpty)
    #expect(store.state.navigationHistoryForward.isEmpty)
  }

  // MARK: - Landable entries

  /// The fixture catalog with `b` archived.
  private static func catalogArchivingB(_ fixture: Fixture) -> Catalog {
    var catalog = fixture.catalog
    catalog.projects[0].worktrees[1].archived = true
    return catalog
  }

  @Test
  func landableRuleRejectsRemovedArchivedAndCurrentEntries() {
    let fixture = Fixture()
    let landable = WorktreeHistoryLanding.landableWorktreeIDs(in: Self.catalogArchivingB(fixture))
    let current = fixture.selection(3)
    let removed = HierarchySelection(projectID: fixture.projectID, worktreeID: WorktreeID())

    #expect(WorktreeHistoryLanding.isLandable(fixture.selection(0), landable: landable, current: current))
    #expect(!WorktreeHistoryLanding.isLandable(removed, landable: landable, current: current))
    #expect(!WorktreeHistoryLanding.isLandable(fixture.selection(1), landable: landable, current: current))
    #expect(!WorktreeHistoryLanding.isLandable(fixture.selection(3), landable: landable, current: current))
    #expect(!WorktreeHistoryLanding.isLandable(.empty, landable: landable, current: current))
  }

  @Test
  func backPassesARemovedWorktreeAndForwardRetracesIt() async {
    // History a → X → d with X removed: Back from d lands on a.
    let fixture = Fixture()
    let removed = HierarchySelection(projectID: fixture.projectID, worktreeID: WorktreeID())
    let (store, selected) = Self.makeStore(fixture, backEntries: [fixture.selection(0), removed])

    #expect(store.state.navigationHistoryBack.count == 2)
    await store.send(.worktreeHistoryBackRequested)
    await store.receive(\.sidebar.worktreeRowTapped)

    #expect(selected.value == fixture.ids[0])
    #expect(store.state.navigationHistoryBack.isEmpty)
    // The passed entry stays in history, nearest last, above the left selection.
    #expect(store.state.navigationHistoryForward == [fixture.selection(3), removed])

    // Forward from a passes X again and returns to d.
    var state = store.state
    state.selection = fixture.selection(0)
    let landable = WorktreeHistoryLanding.landableWorktreeIDs(in: fixture.catalog)
    let target = RootFeature.navigateHistory(&state, jump: .forward(offset: 0), landable: landable)
    #expect(target == fixture.selection(3))
    #expect(state.navigationHistoryBack == [fixture.selection(0), removed])
    #expect(state.navigationHistoryForward.isEmpty)
  }

  @Test
  func backPassesAnArchivedWorktree() async {
    let fixture = Fixture()
    let (store, selected) = Self.makeStore(
      fixture, back: [0, 1], catalog: Self.catalogArchivingB(fixture)
    )

    await store.send(.worktreeHistoryBackRequested)
    await store.receive(\.sidebar.worktreeRowTapped)

    #expect(selected.value == fixture.ids[0])
    #expect(store.state.navigationHistoryForward == [fixture.selection(3), fixture.selection(1)])
  }

  @Test
  func anUnarchivedWorktreeIsLandableAgain() async {
    let fixture = Fixture()
    // `b` was archived while in history, then unarchived: the fixture catalog.
    let (store, selected) = Self.makeStore(fixture, back: [0, 1])

    await store.send(.worktreeHistoryBackRequested)
    await store.receive(\.sidebar.worktreeRowTapped)

    #expect(selected.value == fixture.ids[1])
  }

  @Test
  func backPassesTheCurrentWorktreeToTheNextDifferentOne() async {
    // History c → a → X → a with X removed: Back passes X and a, lands on c.
    let fixture = Fixture()
    let removed = HierarchySelection(projectID: fixture.projectID, worktreeID: WorktreeID())
    let (store, selected) = Self.makeStore(
      fixture,
      backEntries: [fixture.selection(2), fixture.selection(0), removed],
      current: 0
    )

    await store.send(.worktreeHistoryBackRequested)
    await store.receive(\.sidebar.worktreeRowTapped)

    #expect(selected.value == fixture.ids[2])
    #expect(store.state.navigationHistoryBack.isEmpty)
    #expect(
      store.state.navigationHistoryForward == [fixture.selection(0), removed, fixture.selection(0)])
  }

  @Test
  func backWithNoLandableEntryIsDisabledAndANoOp() async {
    // History a → X → a with X removed: nothing different to go back to.
    let fixture = Fixture()
    let removed = HierarchySelection(projectID: fixture.projectID, worktreeID: WorktreeID())
    let (store, selected) = Self.makeStore(
      fixture, backEntries: [fixture.selection(0), removed], current: 0
    )

    var gate = store.state
    gate.historyLandableWorktreeIDs = WorktreeHistoryLanding.landableWorktreeIDs(in: fixture.catalog)
    #expect(!gate.canNavigateHistoryBack)
    #expect(!gate.canNavigateHistoryForward)

    await store.send(.worktreeHistoryBackRequested)
    await store.finish()

    #expect(selected.value == nil)
    #expect(store.state.navigationHistoryBack == [fixture.selection(0), removed])
    #expect(store.state.navigationHistoryForward.isEmpty)
    #expect(!store.state.suppressHistoryPush)
  }

  @Test
  func canNavigateFollowsTheLandableRule() {
    let fixture = Fixture()
    var state = RootFeature.State()
    state.selection = fixture.selection(3)
    state.navigationHistoryBack = [fixture.selection(1)]
    state.navigationHistoryForward = [fixture.selection(0)]
    state.historyLandableWorktreeIDs = WorktreeHistoryLanding.landableWorktreeIDs(
      in: Self.catalogArchivingB(fixture))

    #expect(!state.canNavigateHistoryBack)
    #expect(state.canNavigateHistoryForward)
  }

  @Test
  func menuJumpToANowStaleEntryLandsOnTheNextLandableOne() async {
    // A menu row picked after its Worktree was archived must not blank the
    // detail: the jump moves on to the next landable entry past it.
    let fixture = Fixture()
    let (store, selected) = Self.makeStore(
      fixture, back: [0, 1, 2], catalog: Self.catalogArchivingB(fixture)
    )

    await store.send(.worktreeHistoryJumpRequested(.back(offset: 1)))
    await store.receive(\.sidebar.worktreeRowTapped)

    #expect(selected.value == fixture.ids[0])
  }

  // MARK: - Menu rows

  @Test
  func entriesDropArchivedAndCurrentWorktrees() {
    let fixture = Fixture()
    // Stack, oldest first: a, b (archived), d (current), c.
    let stack = [fixture.selection(0), fixture.selection(1), fixture.selection(3), fixture.selection(2)]

    let entries = WorktreeHistoryEntry.resolve(
      stack: stack, catalog: Self.catalogArchivingB(fixture), current: fixture.selection(3)
    )

    #expect(entries.map(\.branchTitle) == ["c", "a"])
    #expect(entries.map(\.offset) == [0, 3])
  }

  @Test
  func entriesResolveNearestFirstWithTrueOffsets() {
    let fixture = Fixture()
    let stack = [fixture.selection(0), fixture.selection(1), fixture.selection(2)]

    let entries = WorktreeHistoryEntry.resolve(stack: stack, catalog: fixture.catalog, current: fixture.selection(3))

    #expect(entries.map(\.branchTitle) == ["c", "b", "a"])
    #expect(entries.map(\.offset) == [0, 1, 2])
    // Worktree names restate their branches, so the caption is just the
    // Project — the header's suppression rule.
    #expect(entries.allSatisfy { $0.worktreeName == nil && $0.projectName == "p" })
  }

  @Test
  func entriesMirrorTheHeaderIdentity() {
    let feature = Worktree(name: "Menu work", path: "/tmp/codans-menu", branch: "feat/menu")
    let reviewed = Worktree(name: "review", path: "/tmp/codans-review", branch: "review")
    let main = Worktree(name: "main", path: "/tmp/codans", branch: "main")
    let project = Project(
      name: "codans", rootPath: "/tmp/codans", gitRoot: "/tmp/codans",
      worktrees: [feature, reviewed, main], color: .orange
    )
    let folder = Project(
      name: "notes", rootPath: "/tmp/notes",
      worktrees: [Worktree(name: "notes", path: "/tmp/notes")]
    )
    let catalog = Catalog(projects: [project, folder])
    let stack = [
      HierarchySelection(projectID: folder.id, worktreeID: folder.worktrees[0].id),
      HierarchySelection(projectID: project.id, worktreeID: main.id),
      HierarchySelection(projectID: project.id, worktreeID: reviewed.id),
      HierarchySelection(projectID: project.id, worktreeID: feature.id),
    ]
    let pullRequest = PullRequestSnapshot(
      number: 7, title: "Review", state: .merged, isDraft: false, headRefName: "review",
      author: "me", additions: 1, deletions: 0, commitCount: 1,
      url: URL(string: "https://example.com/pr/7")!, updatedAt: Date()
    )

    let entries = WorktreeHistoryEntry.resolve(
      stack: stack, catalog: catalog, current: .empty, pullRequests: [reviewed.id: pullRequest]
    )

    #expect(
      entries.map(\.glyph) == [
        .branch, .pullRequest(.merged, isDraft: false), .defaultBranch, .folder,
      ])
    #expect(entries.map(\.branchTitle) == ["feat/menu", "review", "main", "(detached)"])
    #expect(entries.map(\.worktreeName) == ["Menu work", nil, nil, "notes"])
    #expect(entries.map(\.projectName) == ["codans", "codans", "codans", "notes"])
    #expect(entries.first?.projectColor == .orange)
  }

  @Test
  func entriesDropWorktreesThatLeftTheCatalogAndKeepStackOffsets() {
    let fixture = Fixture()
    let deleted = HierarchySelection(projectID: fixture.projectID, worktreeID: WorktreeID())
    // Stack, oldest first: a, <deleted>, c.
    let stack = [fixture.selection(0), deleted, fixture.selection(2)]

    let entries = WorktreeHistoryEntry.resolve(
      stack: stack, catalog: fixture.catalog, current: .empty
    )

    #expect(entries.map(\.branchTitle) == ["c", "a"])
    // `a` keeps offset 2 — the stack still holds the dead entry, so a jump
    // has to count past it.
    #expect(entries.map(\.offset) == [0, 2])
  }

  @Test
  func entriesStopAtTheMenuLimit() {
    let fixture = Fixture()
    let stack = (0..<40).map { fixture.selection($0 % 4) }

    let entries = WorktreeHistoryEntry.resolve(
      stack: stack, catalog: fixture.catalog, current: .empty
    )

    #expect(entries.count == WorktreeHistoryEntry.menuLimit)
    #expect(entries.first?.offset == 0)
    #expect(entries.last?.offset == WorktreeHistoryEntry.menuLimit - 1)
  }
}
