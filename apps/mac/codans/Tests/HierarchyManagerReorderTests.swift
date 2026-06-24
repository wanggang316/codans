import Foundation
import Testing
import CodansCore

@testable import Codans

/// Coverage for the worktree-sidebar-ordering catalog primitives:
/// - `HierarchyManager.reorderWorktrees(in:segment:from:to:)`
/// - `HierarchyManager.createWorktree`'s unpinned-segment-top insertion
/// - `HierarchyManager.setWorktreePinned`'s boundary-aware repositioning
@MainActor
struct HierarchyManagerReorderTests {
  var fakeRuntime: FakeHierarchyRuntime!
  var store: CatalogStore!
  var manager: HierarchyManager!

  init() {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    fakeRuntime = FakeHierarchyRuntime()
    store = CatalogStore(fileURL: tempURL)
    manager = HierarchyManager(catalog: .default, store: store, runtime: fakeRuntime)
  }

  // MARK: - createWorktree insertion

  @Test
  func createWorktreeLandsAtUnpinnedSegmentTop() throws {
    let pid = try makeProject()
    let p1 = try makePinned(name: "p1", path: "/repo/p1", in: pid)
    let p2 = try makePinned(name: "p2", path: "/repo/p2", in: pid)
    let u1 = try manager.createWorktree(in: pid, name: "u1", path: "/repo/u1", branch: "u1")
    let u2 = try manager.createWorktree(in: pid, name: "u2", path: "/repo/u2", branch: "u2")
    let u3 = try manager.createWorktree(in: pid, name: "u3", path: "/repo/u3", branch: "u3")
    let beforeIDs = worktrees(in: pid).map { $0.id }
    let mainID = beforeIDs[0]
    #expect(beforeIDs == [mainID, p1, p2, u3, u2, u1])

    let u4 = try manager.createWorktree(in: pid, name: "u4", path: "/repo/u4", branch: "u4")
    let after = worktrees(in: pid).map { $0.id }
    #expect(after == [mainID, p1, p2, u4, u3, u2, u1])
    #expect(after[3] == u4)
  }

  @Test
  func createWorktreeFirstUnpinnedRowLandsAfterMain() throws {
    let pid = try makeProject()
    let w1 = try manager.createWorktree(in: pid, name: "w1", path: "/repo/w1", branch: "w1")
    let ids = worktrees(in: pid).map { $0.id }
    #expect(ids.count == 2)
    #expect(ids[1] == w1)
  }

  @Test
  func createWorktreeSkipsPastArchivedRows() throws {
    let pid = try makeProject()
    let archived = try manager.createWorktree(
      in: pid, name: "old", path: "/repo/old", branch: "old"
    )
    try manager.setWorktreeArchived(worktreeID: archived, archived: true)
    let beforeCount = worktrees(in: pid).count
    #expect(beforeCount == 2)

    let fresh = try manager.createWorktree(in: pid, name: "new", path: "/repo/new", branch: "new")
    let ids = worktrees(in: pid).map { $0.id }
    #expect(ids.count == 3)
    #expect(ids[2] == fresh)
  }

  // MARK: - setWorktreePinned positioning

  @Test
  func pinMovesRowToPinnedSegmentEnd() throws {
    let pid = try makeProject()
    let p1 = try makePinned(name: "p1", path: "/repo/p1", in: pid)
    let p2 = try makePinned(name: "p2", path: "/repo/p2", in: pid)
    let u1 = try manager.createWorktree(in: pid, name: "u1", path: "/repo/u1", branch: "u1")
    manager.setWorktreePinned(worktreeID: u1, isPinned: true)
    let ids = worktrees(in: pid).map { $0.id }
    let mainID = ids[0]
    #expect(ids == [mainID, p1, p2, u1])
    let pinnedSegment = pinnedView(in: pid)
    #expect(pinnedSegment == [p1, p2, u1])
  }

  @Test
  func pinIdempotentDoesNotReposition() throws {
    let pid = try makeProject()
    let p1 = try makePinned(name: "p1", path: "/repo/p1", in: pid)
    let p2 = try makePinned(name: "p2", path: "/repo/p2", in: pid)
    let snapshot = worktrees(in: pid).map { $0.id }
    manager.setWorktreePinned(worktreeID: p1, isPinned: true)
    manager.setWorktreePinned(worktreeID: p2, isPinned: true)
    let after = worktrees(in: pid).map { $0.id }
    #expect(after == snapshot)
  }

  @Test
  func unpinMovesRowToUnpinnedSegmentTop() throws {
    let pid = try makeProject()
    let p1 = try makePinned(name: "p1", path: "/repo/p1", in: pid)
    let p2 = try makePinned(name: "p2", path: "/repo/p2", in: pid)
    let u1 = try manager.createWorktree(in: pid, name: "u1", path: "/repo/u1", branch: "u1")
    let u2 = try manager.createWorktree(in: pid, name: "u2", path: "/repo/u2", branch: "u2")

    manager.setWorktreePinned(worktreeID: p2, isPinned: false)
    let unpinned = unpinnedView(in: pid)
    #expect(unpinned.first == p2)
    #expect(unpinned == [p2, u2, u1])
    #expect(pinnedView(in: pid) == [p1])
  }

  @Test
  func unpinAlreadyUnpinnedIsNoOp() throws {
    let pid = try makeProject()
    let u1 = try manager.createWorktree(in: pid, name: "u1", path: "/repo/u1", branch: "u1")
    let snapshot = worktrees(in: pid).map { $0.id }
    manager.setWorktreePinned(worktreeID: u1, isPinned: false)
    let after = worktrees(in: pid).map { $0.id }
    #expect(after == snapshot)
  }

  // MARK: - reorderWorktrees

  @Test
  func reorderPinnedSegmentMovesWithinSection() throws {
    let pid = try makeProject()
    let p1 = try makePinned(name: "p1", path: "/repo/p1", in: pid)
    let p2 = try makePinned(name: "p2", path: "/repo/p2", in: pid)
    let p3 = try makePinned(name: "p3", path: "/repo/p3", in: pid)
    let u1 = try manager.createWorktree(in: pid, name: "u1", path: "/repo/u1", branch: "u1")
    try manager.reorderWorktrees(
      in: pid, segment: .pinned,
      from: IndexSet(integer: 0), to: 3
    )
    #expect(pinnedView(in: pid) == [p2, p3, p1])
    #expect(unpinnedView(in: pid) == [u1])
  }

  @Test
  func reorderUnpinnedSegmentMovesWithinSection() throws {
    let pid = try makeProject()
    _ = try makePinned(name: "p1", path: "/repo/p1", in: pid)
    let u1 = try manager.createWorktree(in: pid, name: "u1", path: "/repo/u1", branch: "u1")
    let u2 = try manager.createWorktree(in: pid, name: "u2", path: "/repo/u2", branch: "u2")
    let u3 = try manager.createWorktree(in: pid, name: "u3", path: "/repo/u3", branch: "u3")
    try manager.reorderWorktrees(
      in: pid, segment: .unpinned,
      from: IndexSet(integer: 2), to: 0
    )
    #expect(unpinnedView(in: pid) == [u1, u3, u2])
  }

  @Test
  func reorderOutOfRangeFromIsNoOp() throws {
    let pid = try makeProject()
    _ = try makePinned(name: "p1", path: "/repo/p1", in: pid)
    _ = try makePinned(name: "p2", path: "/repo/p2", in: pid)
    let snapshot = worktrees(in: pid).map { $0.id }
    try manager.reorderWorktrees(
      in: pid, segment: .pinned,
      from: IndexSet(integer: 5), to: 0
    )
    #expect(worktrees(in: pid).map { $0.id } == snapshot)
  }

  @Test
  func reorderOutOfRangeToIsNoOp() throws {
    let pid = try makeProject()
    _ = try makePinned(name: "p1", path: "/repo/p1", in: pid)
    _ = try makePinned(name: "p2", path: "/repo/p2", in: pid)
    let snapshot = worktrees(in: pid).map { $0.id }
    try manager.reorderWorktrees(
      in: pid, segment: .pinned,
      from: IndexSet(integer: 0), to: 99
    )
    #expect(worktrees(in: pid).map { $0.id } == snapshot)
  }

  @Test
  func reorderEmptyIndexSetIsNoOp() throws {
    let pid = try makeProject()
    _ = try makePinned(name: "p1", path: "/repo/p1", in: pid)
    let snapshot = worktrees(in: pid).map { $0.id }
    try manager.reorderWorktrees(
      in: pid, segment: .pinned,
      from: IndexSet(), to: 0
    )
    #expect(worktrees(in: pid).map { $0.id } == snapshot)
  }

  @Test
  func reorderUnknownProjectThrows() throws {
    _ = try makeProject()
    let bogus = ProjectID()
    #expect(throws: HierarchyError.self) {
      try manager.reorderWorktrees(
        in: bogus, segment: .pinned,
        from: IndexSet(integer: 0), to: 0
      )
    }
  }

  @Test
  func reorderDoesNotDisturbArchivedRows() throws {
    let pid = try makeProject()
    let p1 = try makePinned(name: "p1", path: "/repo/p1", in: pid)
    let p2 = try makePinned(name: "p2", path: "/repo/p2", in: pid)
    let archived = try manager.createWorktree(
      in: pid, name: "old", path: "/repo/old", branch: "old"
    )
    try manager.setWorktreeArchived(worktreeID: archived, archived: true)
    let beforeArchivedIdx = worktrees(in: pid)
      .firstIndex { $0.id == archived }
    try manager.reorderWorktrees(
      in: pid, segment: .pinned,
      from: IndexSet(integer: 0), to: 2
    )
    let afterArchivedIdx = worktrees(in: pid)
      .firstIndex { $0.id == archived }
    #expect(beforeArchivedIdx == afterArchivedIdx)
    #expect(pinnedView(in: pid) == [p2, p1])
  }

  // MARK: - Helpers

  private func makeProject() throws -> ProjectID {
    let pid = manager.addProject(name: "p", rootPath: "/repo", gitRoot: "/repo")
    _ = try manager.createWorktree(
      in: pid, name: "main", path: "/repo", branch: "main"
    )
    return pid
  }

  private func makePinned(
    name: String, path: String, in pid: ProjectID
  ) throws -> WorktreeID {
    let id = try manager.createWorktree(
      in: pid, name: name, path: path, branch: name
    )
    manager.setWorktreePinned(worktreeID: id, isPinned: true)
    return id
  }

  private func worktrees(in pid: ProjectID) -> [Worktree] {
    manager.catalog.projects.first { $0.id == pid }!.worktrees
  }

  private func pinnedView(in pid: ProjectID) -> [WorktreeID] {
    let project = manager.catalog.projects.first { $0.id == pid }!
    let root = project.rootPath
    return project.worktrees
      .filter { !$0.archived && $0.isPinned && $0.path != root }
      .map { $0.id }
  }

  private func unpinnedView(in pid: ProjectID) -> [WorktreeID] {
    let project = manager.catalog.projects.first { $0.id == pid }!
    let root = project.rootPath
    return project.worktrees
      .filter { !$0.archived && !$0.isPinned && $0.path != root }
      .map { $0.id }
  }
}
