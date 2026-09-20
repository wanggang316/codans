import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// Browser-style Worktree visit history: the single Back / Forward steps the
/// menu chords take, and the deeper jumps the sidebar buttons' press-and-hold
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
    forward: [Int] = []
  ) -> (TestStoreOf<RootFeature>, LockIsolated<WorktreeID?>) {
    var initial = RootFeature.State()
    initial.selection = fixture.selection(3)
    initial.navigationHistoryBack = back.map { fixture.selection($0) }
    initial.navigationHistoryForward = forward.map { fixture.selection($0) }

    let selected = LockIsolated<WorktreeID?>(nil)
    let store = TestStore(initialState: initial) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { fixture.catalog }
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
    #expect(store.state.sidebarVisible)
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
    var stepwise = RootFeature.State()
    stepwise.selection = fixture.selection(3)
    stepwise.navigationHistoryBack = [0, 1, 2].map(fixture.selection)
    for _ in 0..<3 {
      let target = stepwise.navigationHistoryBack.last
      _ = RootFeature.navigateHistory(&stepwise, jump: .back(offset: 0))
      // Stand in for the selection stream echoing the landing back.
      stepwise.selection = target ?? .empty
    }

    var jumping = RootFeature.State()
    jumping.selection = fixture.selection(3)
    jumping.navigationHistoryBack = [0, 1, 2].map(fixture.selection)
    _ = RootFeature.navigateHistory(&jumping, jump: .back(offset: 2))

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
}
