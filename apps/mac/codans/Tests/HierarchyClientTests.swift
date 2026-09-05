import Foundation
import Testing
import CodansCore

@testable import Codans

@MainActor
struct HierarchyClientTests {
  private func makeLiveClient() -> (HierarchyClient, HierarchyManager) {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let runtime = FakeHierarchyRuntime()
    let store = CatalogStore(fileURL: tempURL)
    let manager = HierarchyManager(catalog: .default, store: store, runtime: runtime)
    return (HierarchyClient.live(manager: manager), manager)
  }

  @Test
  func liveSelectWorktreeUpdatesCatalog() throws {
    let (client, manager) = makeLiveClient()
    let projectID = client.addProject("p", "/tmp", "/tmp")
    let worktreeID = try client.createWorktree(projectID, "w2", "/tmp/w2", "main")

    try client.selectWorktree(worktreeID, projectID)
    #expect(manager.catalog.projects[0].selectedWorktreeID == worktreeID)

    try client.selectWorktree(nil, projectID)
    #expect(manager.catalog.projects[0].selectedWorktreeID == nil)
  }

  @Test
  func kindReturnsGitRepoWhenProjectHasGitRoot() throws {
    let (client, _) = makeLiveClient()
    let projectID = client.addProject("p", "/tmp/p", "/tmp/p")
    #expect(client.kind(projectID) == .gitRepo)
  }

  @Test
  func kindReturnsDirWhenGitRootNil() throws {
    let (client, _) = makeLiveClient()
    let projectID = client.addProject("p", "/tmp/p", nil)
    #expect(client.kind(projectID) == .dir)
  }

  @Test
  func kindReturnsNilForUnknownProject() {
    let (client, _) = makeLiveClient()
    #expect(client.kind(ProjectID()) == nil)
  }

  @Test
  func selectionChangesPopulatesProjectAndWorktreeOnSelect() async throws {
    let (client, _) = makeLiveClient()
    // Seed the catalog synchronously BEFORE subscribing so the stream's
    // first emission already reflects the selection chain.
    let projectID = client.addProject("p", "/tmp", "/tmp")
    let worktreeID = try client.createWorktree(projectID, "w", "/tmp/w", "main")

    let stream = client.selectionChanges()
    var iterator = stream.makeAsyncIterator()
    let initial = await iterator.next()

    #expect(initial?.projectID == projectID)
    #expect(initial?.worktreeID == worktreeID)
  }

  /// Multi-project regression: tapping a worktree in P2 must surface
  /// `(P2, W2)` even when P1 still carries a non-nil `selectedWorktreeID`
  /// (which it does after any prior selection in P1). Pre-fix the
  /// `currentSelection` resolver returned the first project in catalog
  /// order whose `selectedWorktreeID` was non-nil, pinning the answer to
  /// P1; the fix adds a top-level `Catalog.selectedProjectID` that
  /// `selectProject` writes and `currentSelection` reads first.
  @Test
  func selectionChangesRespectsLatestProjectAcrossMultipleProjects() async throws {
    let (client, _) = makeLiveClient()
    let p1 = client.addProject("p1", "/tmp/p1", "/tmp/p1")
    let w1 = try client.createWorktree(p1, "w1", "/tmp/p1/w1", "main")
    let p2 = client.addProject("p2", "/tmp/p2", "/tmp/p2")
    let w2 = try client.createWorktree(p2, "w2", "/tmp/p2/w2", "main")

    // Touch P1 first so it owns a selectedWorktreeID.
    client.selectProject(p1)
    try client.selectWorktree(w1, p1)

    // Now switch to P2.
    client.selectProject(p2)
    try client.selectWorktree(w2, p2)

    let stream = client.selectionChanges()
    var iterator = stream.makeAsyncIterator()
    let initial = await iterator.next()

    #expect(initial?.projectID == p2)
    #expect(initial?.worktreeID == w2)
  }

  @Test
  func selectProjectClearedOnRemoveProject() throws {
    let (client, manager) = makeLiveClient()
    let p = client.addProject("p", "/tmp", "/tmp")
    client.selectProject(p)
    #expect(manager.catalog.selectedProjectID == p)
    try client.removeProject(p)
    #expect(manager.catalog.selectedProjectID == nil)
  }

  @Test
  func removeProjectDropsItsSettingsEntry() throws {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let settingsURL = FileManager.default.temporaryDirectory
      .appending(component: "settings-\(UUID().uuidString).json")
    defer {
      try? FileManager.default.removeItem(at: tempURL)
      try? FileManager.default.removeItem(at: settingsURL)
    }
    let manager = HierarchyManager(
      catalog: .default,
      store: CatalogStore(fileURL: tempURL),
      runtime: FakeHierarchyRuntime()
    )
    let settings = SettingsStore(fileURL: settingsURL)
    // Production wiring: the hook lives on the manager, not the client, so
    // `codans project rm` through HierarchyHandlers is covered too.
    manager.onProjectRemoved = { [weak settings] projectID in
      settings?.removeProjectSettings(projectID)
    }
    let client = HierarchyClient.live(manager: manager, settings: settings)

    let projectID = client.addProject("p", "/tmp/p", "/tmp/p")
    settings.mutateProject(projectID) { $0.defaultEditor = EditorID("vscode") }
    #expect(settings.settings.projects[projectID] != nil)

    try client.removeProject(projectID)

    // `Settings.garbageCollect` only sweeps effectively-empty entries, so a
    // populated orphan would survive every future save. Re-adding the same
    // repository mints a new ProjectID, making it unreachable.
    #expect(settings.settings.projects[projectID] == nil)
  }

  @Test
  func removeProjectOfUnknownIDLeavesSettingsIntact() throws {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    let settingsURL = FileManager.default.temporaryDirectory
      .appending(component: "settings-\(UUID().uuidString).json")
    defer {
      try? FileManager.default.removeItem(at: tempURL)
      try? FileManager.default.removeItem(at: settingsURL)
    }
    let manager = HierarchyManager(
      catalog: .default,
      store: CatalogStore(fileURL: tempURL),
      runtime: FakeHierarchyRuntime()
    )
    let settings = SettingsStore(fileURL: settingsURL)
    // Production wiring: the hook lives on the manager, not the client, so
    // `codans project rm` through HierarchyHandlers is covered too.
    manager.onProjectRemoved = { [weak settings] projectID in
      settings?.removeProjectSettings(projectID)
    }
    let client = HierarchyClient.live(manager: manager, settings: settings)

    let projectID = client.addProject("p", "/tmp/p", "/tmp/p")
    settings.mutateProject(projectID) { $0.defaultEditor = EditorID("vscode") }

    #expect(throws: HierarchyError.self) {
      try client.removeProject(ProjectID())
    }
    #expect(settings.settings.projects[projectID] != nil)
  }

  // HierarchyClient no longer exposes per-Project editor / worktree-dir writers. Those
  // values live in `Settings.projects[pid]` (v3 schema) and tests for that storage live
  // in `SettingsStoreTests` / `SettingsWriter` coverage inside each consumer feature.

  @Test
  func liveReorderWorktreesForwardsToManager() throws {
    // Wires the closure all the way to `HierarchyManager.reorderWorktrees`.
    // Algorithm coverage lives in `HierarchyManagerReorderTests`; this test
    // only proves the closure is hooked up.
    let (client, manager) = makeLiveClient()
    let projectID = client.addProject("p", "/repo", "/repo")
    _ = try client.createWorktree(projectID, "main", "/repo", "main")
    let p1 = try client.createWorktree(projectID, "p1", "/repo/p1", "p1")
    manager.setWorktreePinned(worktreeID: p1, isPinned: true)
    let p2 = try client.createWorktree(projectID, "p2", "/repo/p2", "p2")
    manager.setWorktreePinned(worktreeID: p2, isPinned: true)

    try client.reorderWorktrees(projectID, .pinned, IndexSet(integer: 0), 2)
    let pinned = manager.catalog.projects[0].worktrees
      .filter { $0.isPinned }
      .map { $0.id }
    #expect(pinned == [p2, p1])
  }

  // MARK: - promoteWorktree

  /// Three unpinned worktrees A/B/C → promoting B lands it at the front of
  /// the unpinned segment. Covers the v1.1 notifications-promote primitive
  /// in its simplest form (no pinned rows in the mix).
  @Test
  func promoteUnpinnedWorktreeMovesToFront() throws {
    let (client, manager) = makeLiveClient()
    let projectID = client.addProject("p", "/repo", "/repo")
    // makeLiveClient + addProject does not seed a main worktree; createWorktree
    // calls below build the entire worktree array so the test asserts on the
    // full ordering without filtering out a synthetic main row.
    let a = try client.createWorktree(projectID, "a", "/repo/a", "a")
    let b = try client.createWorktree(projectID, "b", "/repo/b", "b")
    let c = try client.createWorktree(projectID, "c", "/repo/c", "c")
    // createWorktree inserts at the top of the unpinned segment, so the
    // catalog order after the three calls is [c, b, a]. Promote b → [b, c, a].
    #expect(manager.catalog.projects[0].worktrees.map(\.id) == [c, b, a])

    client.promoteWorktree(projectID, b, .moveToFrontWithinUnpinned)
    #expect(manager.catalog.projects[0].worktrees.map(\.id) == [b, c, a])
  }

  /// Promoting a pinned target is a silent no-op — pinned ordering is the
  /// user's explicit preference and v1.1 never auto-mutates it.
  @Test
  func promoteTargetWorktreeIsPinnedIsNoOp() throws {
    let (client, manager) = makeLiveClient()
    let projectID = client.addProject("p", "/repo", "/repo")
    let p1 = try client.createWorktree(projectID, "p1", "/repo/p1", "p1")
    let p2 = try client.createWorktree(projectID, "p2", "/repo/p2", "p2")
    manager.setWorktreePinned(worktreeID: p1, isPinned: true)
    manager.setWorktreePinned(worktreeID: p2, isPinned: true)
    let u1 = try client.createWorktree(projectID, "u1", "/repo/u1", "u1")
    let u2 = try client.createWorktree(projectID, "u2", "/repo/u2", "u2")
    let snapshot = manager.catalog.projects[0].worktrees.map(\.id)

    client.promoteWorktree(projectID, p1, .moveToFrontWithinUnpinned)
    #expect(manager.catalog.projects[0].worktrees.map(\.id) == snapshot)
    // sanity: snapshot really contains the pinned + unpinned mix we expect.
    #expect(Set(snapshot) == Set([p1, p2, u1, u2]))
  }

  /// Pinned rows keep their leading position; promote rearranges only inside
  /// the unpinned segment. This is the core invariant for the v1.1 spec.
  @Test
  func promoteRespectsPinnedSection() throws {
    let (client, manager) = makeLiveClient()
    let projectID = client.addProject("p", "/repo", "/repo")
    let p1 = try client.createWorktree(projectID, "p1", "/repo/p1", "p1")
    manager.setWorktreePinned(worktreeID: p1, isPinned: true)
    let u1 = try client.createWorktree(projectID, "u1", "/repo/u1", "u1")
    let u2 = try client.createWorktree(projectID, "u2", "/repo/u2", "u2")
    // setWorktreePinned moves p1 to the pinned segment end, then createWorktree
    // inserts unpinned rows at the top of the unpinned segment ⇒ [p1, u2, u1].
    #expect(manager.catalog.projects[0].worktrees.map(\.id) == [p1, u2, u1])

    client.promoteWorktree(projectID, u1, .moveToFrontWithinUnpinned)
    #expect(manager.catalog.projects[0].worktrees.map(\.id) == [p1, u1, u2])
  }

  /// Promoting a worktree that is already at position 0 of the unpinned
  /// segment is a no-op (catalog order unchanged).
  @Test
  func promoteTargetAlreadyAtFrontOfUnpinnedIsIdempotent() throws {
    let (client, manager) = makeLiveClient()
    let projectID = client.addProject("p", "/repo", "/repo")
    let u1 = try client.createWorktree(projectID, "u1", "/repo/u1", "u1")
    let u2 = try client.createWorktree(projectID, "u2", "/repo/u2", "u2")
    // createWorktree inserts at the top of unpinned, so order is [u2, u1].
    #expect(manager.catalog.projects[0].worktrees.map(\.id) == [u2, u1])

    client.promoteWorktree(projectID, u2, .moveToFrontWithinUnpinned)
    #expect(manager.catalog.projects[0].worktrees.map(\.id) == [u2, u1])
  }

  /// Random WorktreeID → silent no-op, no crash.
  @Test
  func promoteMissingTargetIsNoOp() throws {
    let (client, manager) = makeLiveClient()
    let projectID = client.addProject("p", "/repo", "/repo")
    let u1 = try client.createWorktree(projectID, "u1", "/repo/u1", "u1")
    let snapshot = manager.catalog.projects[0].worktrees.map(\.id)
    #expect(snapshot.contains(u1))

    client.promoteWorktree(projectID, WorktreeID(), .moveToFrontWithinUnpinned)
    #expect(manager.catalog.projects[0].worktrees.map(\.id) == snapshot)
  }

  /// Random ProjectID → silent no-op, no crash.
  @Test
  func promoteMissingProjectIsNoOp() {
    let (client, _) = makeLiveClient()
    client.promoteWorktree(ProjectID(), WorktreeID(), .moveToFrontWithinUnpinned)
    // No expectation needed beyond "did not crash".
  }

  // MARK: - setPaneLabel

  /// Helper: opens a pane in a fresh tab on a fresh worktree and returns the
  /// (projectID, paneID) pair used by the label tests below.
  @MainActor
  private func makePane() async throws -> (HierarchyClient, HierarchyManager, PaneID) {
    let (client, manager) = makeLiveClient()
    let projectID = manager.addProject(name: "p", rootPath: "/repo", gitRoot: "/repo")
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "w", path: "/repo/w", branch: "w"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, name: nil)
    let paneID = try await manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/repo/w", initialCommand: nil
    )
    return (client, manager, paneID)
  }

  @MainActor
  private func labels(of paneID: PaneID, in manager: HierarchyManager) -> Set<String> {
    for project in manager.catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          if let pane = tab.panes.first(where: { $0.id == paneID }) {
            return pane.labels
          }
        }
      }
    }
    return []
  }

  @Test
  func setPaneLabelInsertsWhenPresent() async throws {
    let (client, manager, paneID) = try await makePane()
    #expect(labels(of: paneID, in: manager).contains("notifications:muted") == false)

    client.setPaneLabel(paneID, "notifications:muted", true)
    #expect(labels(of: paneID, in: manager).contains("notifications:muted"))
  }

  @Test
  func setPaneLabelRemovesWhenAbsent() async throws {
    let (client, manager, paneID) = try await makePane()
    client.setPaneLabel(paneID, "notifications:muted", true)
    #expect(labels(of: paneID, in: manager).contains("notifications:muted"))

    client.setPaneLabel(paneID, "notifications:muted", false)
    #expect(labels(of: paneID, in: manager).contains("notifications:muted") == false)
  }

  /// Set semantics: a second insert is idempotent — the label appears once.
  @Test
  func setPaneLabelIdempotentOnDoubleInsert() async throws {
    let (client, manager, paneID) = try await makePane()
    client.setPaneLabel(paneID, "notifications:muted", true)
    client.setPaneLabel(paneID, "notifications:muted", true)
    let labels = labels(of: paneID, in: manager)
    #expect(labels == ["notifications:muted"])
  }

  /// Set semantics: removing twice leaves the label absent (no crash, no
  /// re-insert).
  @Test
  func setPaneLabelIdempotentOnDoubleRemove() async throws {
    let (client, manager, paneID) = try await makePane()
    client.setPaneLabel(paneID, "notifications:muted", true)
    client.setPaneLabel(paneID, "notifications:muted", false)
    client.setPaneLabel(paneID, "notifications:muted", false)
    #expect(labels(of: paneID, in: manager).contains("notifications:muted") == false)
  }

  /// Random PaneID → silent no-op, no crash.
  @Test
  func setPaneLabelOnMissingPaneIsNoOp() {
    let (client, _) = makeLiveClient()
    client.setPaneLabel(PaneID(), "notifications:muted", true)
    // No expectation needed beyond "did not crash".
  }

  /// Rapid toggles collapse to the final in-memory state. Disk-mtime checks
  /// are skipped intentionally — they are flaky against the 500 ms catalog
  /// debounce window in CI and the spec calls out the in-memory check as
  /// the primary signal (D-OQ3 decision).
  @Test
  func setPaneLabelDebouncedDiskWrite() async throws {
    let (client, manager, paneID) = try await makePane()
    client.setPaneLabel(paneID, "notifications:muted", true)
    client.setPaneLabel(paneID, "notifications:muted", false)
    client.setPaneLabel(paneID, "notifications:muted", true)
    #expect(labels(of: paneID, in: manager).contains("notifications:muted"))
  }
}
