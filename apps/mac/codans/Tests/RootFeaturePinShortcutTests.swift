import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// `toggleCurrentWorktreePinnedRequested` backs the ⌘⌥P menu item and the
/// palette's Pin / Unpin item. It must flip the current Worktree's pin state
/// and refuse the main checkout and an empty selection, like the sidebar row
/// context menu does.
@MainActor
struct RootFeaturePinShortcutTests {
  private static let projectID = ProjectID()
  private static let mainID = WorktreeID()
  private static let pinnedID = WorktreeID()
  private static let unpinnedID = WorktreeID()

  private static let catalog: Catalog = {
    let project = Project(
      id: projectID, name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [
        Worktree(id: mainID, name: "main", path: "/repo"),
        Worktree(id: pinnedID, name: "pinned", path: "/repo-pinned", isPinned: true),
        Worktree(id: unpinnedID, name: "unpinned", path: "/repo-unpinned"),
      ]
    )
    return Catalog(projects: [project])
  }()

  private static func pinCalls(
    selection: HierarchySelection
  ) async -> [(WorktreeID, Bool)] {
    let calls = LockIsolated<[(WorktreeID, Bool)]>([])
    var state = RootFeature.State()
    state.selection = selection
    let store = TestStore(initialState: state) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.setWorktreePinned = { id, isPinned in
        calls.withValue { $0.append((id, isPinned)) }
      }
    }
    store.exhaustivity = .off
    await store.send(.toggleCurrentWorktreePinnedRequested)
    await store.skipReceivedActions(strict: false)
    return calls.value
  }

  @Test
  func unpinnedWorktreeGetsPinned() async {
    let calls = await Self.pinCalls(
      selection: HierarchySelection(projectID: Self.projectID, worktreeID: Self.unpinnedID))
    #expect(calls.map(\.0) == [Self.unpinnedID])
    #expect(calls.map(\.1) == [true])
  }

  @Test
  func pinnedWorktreeGetsUnpinned() async {
    let calls = await Self.pinCalls(
      selection: HierarchySelection(projectID: Self.projectID, worktreeID: Self.pinnedID))
    #expect(calls.map(\.0) == [Self.pinnedID])
    #expect(calls.map(\.1) == [false])
  }

  @Test
  func mainCheckoutIsNotPinned() async {
    let calls = await Self.pinCalls(
      selection: HierarchySelection(projectID: Self.projectID, worktreeID: Self.mainID))
    #expect(calls.isEmpty)
  }

  @Test
  func noSelectionChangesNothing() async {
    let calls = await Self.pinCalls(selection: .empty)
    #expect(calls.isEmpty)
  }

  @Test
  func paletteItemRoutesToTheSameToggle() async {
    var state = RootFeature.State()
    state.selection = HierarchySelection(projectID: Self.projectID, worktreeID: Self.unpinnedID)
    let store = TestStore(initialState: state) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Self.catalog }
      $0.hierarchyClient.setWorktreePinned = { _, _ in }
      // The palette reads per-Project scripts while it builds its items.
      $0.settingsWriter.readSnapshotSync = { .default }
    }
    store.exhaustivity = .off
    await store.send(.commandPaletteToggle(nil))
    await store.send(
      .commandPalette(.presented(.delegate(.activate(.toggleCurrentWorktreePinned)))))
    await store.receive(\.toggleCurrentWorktreePinnedRequested)
  }

  @Test
  func pinnableWorktreeFollowsTheSidebarRule() {
    func pinnable(_ id: WorktreeID?) -> WorktreeID? {
      RootFeature.pinnableCurrentWorktree(
        selection: HierarchySelection(projectID: id == nil ? nil : Self.projectID, worktreeID: id),
        catalog: Self.catalog)?.id
    }
    #expect(pinnable(Self.unpinnedID) == Self.unpinnedID)
    #expect(pinnable(Self.pinnedID) == Self.pinnedID)
    #expect(pinnable(Self.mainID) == nil)
    #expect(pinnable(nil) == nil)
  }
}
