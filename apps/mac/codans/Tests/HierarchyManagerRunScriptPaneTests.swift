import Foundation
import Testing

@testable import Codans
@testable import CodansCore

/// Coverage for the persistent run-pane association. The contract:
///
///   1. `setRunScriptPane` stamps `Pane.runScriptID` into the catalog and
///      schedules a save — the association must survive a relaunch.
///   2. A fresh `HierarchyManager` rebuilds `scriptRunPanes` from those
///      stamps, so `runScriptPane` resolves the restored pane without any
///      run having happened this session.
///   3. `tabIsDirty` / `worktreeIsDirty` skip run panes — their activity is
///      rendered by the tab's tinted icon and the sidebar ping dot, never
///      the generic spinner. `paneIsBusy` is the raw per-pane read those
///      affordances use instead.
@MainActor
struct HierarchyManagerRunScriptPaneTests {
  @Test
  func setRunScriptPaneStampsCatalogAndSchedulesSave() throws {
    let fixture = Self.makeFixture()
    let baseline = fixture.store.scheduleSaveCallCount
    let scriptID = UUID()

    fixture.manager.setRunScriptPane(
      worktreeID: fixture.worktreeID, scriptID: scriptID, paneID: fixture.paneID
    )

    #expect(fixture.manager.catalog.pane(fixture.paneID)?.runScriptID == scriptID)
    #expect(fixture.store.scheduleSaveCallCount == baseline + 1)
    #expect(
      fixture.manager.runScriptPane(worktreeID: fixture.worktreeID, scriptID: scriptID)
        == fixture.paneID
    )
  }

  @Test
  func initRebuildsRunPaneIndexFromPersistedStamps() throws {
    let scriptID = UUID()
    let fixture = Self.makeFixture(runScriptID: scriptID)

    #expect(
      fixture.manager.runScriptPane(worktreeID: fixture.worktreeID, scriptID: scriptID)
        == fixture.paneID
    )
  }

  @Test
  func runScriptPaneIsNilForUnknownScript() throws {
    let fixture = Self.makeFixture(runScriptID: UUID())

    #expect(
      fixture.manager.runScriptPane(worktreeID: fixture.worktreeID, scriptID: UUID()) == nil
    )
  }

  @Test
  func dirtyPredicatesSkipRunPanesButPaneIsBusyReadsThem() throws {
    let scriptID = UUID()
    let fixture = Self.makeFixture(runScriptID: scriptID)

    fixture.manager.setPaneCommandBusy(fixture.paneID, true)

    #expect(fixture.manager.paneIsBusy(fixture.paneID))
    #expect(!fixture.manager.tabIsDirty(fixture.tabID))
    #expect(!fixture.manager.worktreeIsDirty(fixture.worktreeID))
    #expect(
      fixture.manager.isScriptRunning(worktreeID: fixture.worktreeID, scriptID: scriptID)
    )
  }

  @Test
  func dirtyPredicatesStillLightForOrdinaryPanes() throws {
    let fixture = Self.makeFixture()

    fixture.manager.setPaneCommandBusy(fixture.paneID, true)

    #expect(fixture.manager.tabIsDirty(fixture.tabID))
    #expect(fixture.manager.worktreeIsDirty(fixture.worktreeID))
  }

  // MARK: - Helpers

  private struct Fixture {
    let manager: HierarchyManager
    let store: RecordingCatalogStore
    let paneID: PaneID
    let tabID: TabID
    let worktreeID: WorktreeID
  }

  /// Single-Project / single-Worktree / single-Tab / single-Pane catalog,
  /// optionally pre-stamped with a `runScriptID` to simulate a catalog
  /// written by a previous session.
  private static func makeFixture(runScriptID: UUID? = nil) -> Fixture {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codans-run-pane-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("catalog.json")

    let pane = Pane(workingDirectory: "/tmp", runScriptID: runScriptID)
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let worktree = Worktree(
      name: "main", path: "/repo", tabs: [tab], selectedTabID: tab.id
    )
    let project = Project(
      name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree], selectedWorktreeID: worktree.id
    )
    let catalog = Catalog(projects: [project])

    let store = RecordingCatalogStore(fileURL: url)
    let manager = HierarchyManager(
      catalog: catalog, store: store, runtime: FakeHierarchyRuntime()
    )
    return Fixture(
      manager: manager, store: store,
      paneID: pane.id, tabID: tab.id, worktreeID: worktree.id
    )
  }
}
