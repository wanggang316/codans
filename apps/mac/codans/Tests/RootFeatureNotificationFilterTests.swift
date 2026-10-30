import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// Which rows the sidebar notification filter lists: the worktrees with
/// unread notifications, plus the selected row whose entries were read
/// while it was selected.
@MainActor
struct RootFeatureNotificationFilterTests {
  private let selected = Worktree(name: "selected", path: "/repo")
  private let other = Worktree(name: "other", path: "/repo-other")

  private var catalog: Catalog {
    let project = Project(
      name: "repo", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [selected, other], selectedWorktreeID: selected.id)
    var catalog = Catalog(projects: [project])
    catalog.selectedProjectID = project.id
    return catalog
  }

  private func makeStore() -> TestStore<RootFeature.State, RootFeature.Action> {
    let catalog = self.catalog
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  func listsOnlyUnreadRowsWhenNothingWasReadWhileSelected() async {
    let store = makeStore()
    // The selected row never had unread entries, so it is not listed.
    await store.send(.unreadWorktreesChanged([other.id]))
    #expect(store.state.notifiedWorktreeIDs == [other.id])
  }

  @Test
  func keepsTheSelectedRowWhenItsEntriesAreRead() async {
    let store = makeStore()
    await store.send(.unreadWorktreesChanged([selected.id, other.id]))
    await store.send(.unreadWorktreesChanged([other.id]))
    #expect(store.state.notifiedWorktreeIDs == [selected.id, other.id])
  }

  @Test
  func dropsTheKeptRowWhenTheSelectionMovesOn() async {
    let store = makeStore()
    await store.send(.unreadWorktreesChanged([selected.id]))
    await store.send(.unreadWorktreesChanged([]))
    #expect(store.state.notifiedWorktreeIDs == [selected.id])
    await store.send(.selectionChanged(.empty))
    #expect(store.state.notifiedWorktreeIDs.isEmpty)
  }

  @Test
  func reopeningTheFilterDropsTheKeptRow() async {
    let catalog = self.catalog
    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.setSidebarFilter = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.unreadWorktreesChanged([selected.id]))
    await store.send(.unreadWorktreesChanged([]))
    await store.send(.sidebar(.sidebarFilterSelected(.all)))
    await store.send(.sidebar(.sidebarFilterSelected(.notifications)))
    #expect(store.state.notifiedWorktreeIDs.isEmpty)
  }

  @Test
  func readingAnotherRowKeepsNothing() async {
    let store = makeStore()
    await store.send(.unreadWorktreesChanged([other.id]))
    await store.send(.unreadWorktreesChanged([]))
    #expect(store.state.notifiedWorktreeIDs.isEmpty)
  }
}
