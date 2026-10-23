import Foundation
import Testing

@testable import Codans
@testable import CodansCore

/// Coverage for the persistent run-Content association. The contract:
///
///   1. `setRunScriptContent` stamps `runScriptID` into the Content's
///      catalog state and schedules a save — the association must survive
///      a relaunch.
///   2. A fresh `HierarchyManager` rebuilds its run index from those
///      stamps, so `runScriptContent` resolves the restored Content
///      without any run having happened this session.
///
/// The dirty predicates that skip run Contents live on `ContentRuntime`;
/// see `ContentRuntimeTests`.
@MainActor
struct HierarchyManagerRunScriptPaneTests {
  @Test
  func setRunScriptContentStampsCatalogAndSchedulesSave() throws {
    let fixture = Self.makeFixture()
    let baseline = fixture.store.scheduleSaveCallCount
    let scriptID = UUID()

    fixture.manager.setRunScriptContent(
      worktreeID: fixture.worktreeID, scriptID: scriptID, contentID: fixture.contentID
    )

    #expect(fixture.manager.catalog.content(fixture.contentID)?.terminal?.runScriptID == scriptID)
    #expect(fixture.store.scheduleSaveCallCount == baseline + 1)
    #expect(
      fixture.manager.runScriptContent(worktreeID: fixture.worktreeID, scriptID: scriptID)
        == fixture.contentID
    )
  }

  @Test
  func initRebuildsRunIndexFromPersistedStamps() throws {
    let scriptID = UUID()
    let fixture = Self.makeFixture(runScriptID: scriptID)

    #expect(
      fixture.manager.runScriptContent(worktreeID: fixture.worktreeID, scriptID: scriptID)
        == fixture.contentID
    )
    #expect(
      fixture.manager.runScriptContents(in: fixture.worktreeID).map(\.contentID) == [fixture.contentID]
    )
  }

  @Test
  func runScriptContentIsNilForUnknownScript() throws {
    let fixture = Self.makeFixture(runScriptID: UUID())

    #expect(
      fixture.manager.runScriptContent(worktreeID: fixture.worktreeID, scriptID: UUID()) == nil
    )
  }

  @Test
  func runScriptContentForgetsAClosedContent() throws {
    let scriptID = UUID()
    let fixture = Self.makeFixture(runScriptID: scriptID)

    try fixture.manager.closeTab(fixture.tabID)

    #expect(
      fixture.manager.runScriptContent(worktreeID: fixture.worktreeID, scriptID: scriptID) == nil
    )
    #expect(fixture.manager.runScriptContents(in: fixture.worktreeID).isEmpty)
  }

  // MARK: - Helpers

  private struct Fixture {
    let manager: HierarchyManager
    let store: RecordingCatalogStore
    let contentID: ContentID
    let tabID: TabID
    let worktreeID: WorktreeID
  }

  /// Single-Project / single-Worktree / single-Pane / single-Tab catalog,
  /// optionally pre-stamped with a `runScriptID` to simulate a catalog
  /// written by a previous session.
  private static func makeFixture(runScriptID: UUID? = nil) -> Fixture {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codans-run-pane-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("catalog.json")

    let tab = Tab(content: .terminal(workingDirectory: "/tmp", runScriptID: runScriptID))
    let pane = Pane(tabs: [tab])
    let worktree = Worktree(
      name: "main", path: "/repo", splitTree: SplitTree(leaf: pane.id), panes: [pane], focusedPaneID: pane.id
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
      contentID: tab.contentID, tabID: tab.id, worktreeID: worktree.id
    )
  }
}
